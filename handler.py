"""
lambda/cost_reporter/handler.py

FinOps Cost Intelligence Reporter
----------------------------------
Triggered automatically after every terraform apply AND daily at 8am IST.

What it does:
  1. Queries AWS Cost Explorer for last 7 days + today's actuals
  2. Calculates per-service cost breakdown (EC2, RDS, ALB, Data Transfer, etc.)
  3. Computes hourly rate and 30-day projection
  4. Generates a beautiful HTML dashboard and uploads to S3
  5. Posts structured cost breakdown to Slack
"""

import json
import os
import boto3
import urllib.request
from datetime import datetime, timedelta, timezone

# ── AWS clients ────────────────────────────────────────────────────
ce     = boto3.client("ce",     region_name="us-east-1")  # Cost Explorer is us-east-1 only
s3     = boto3.client("s3",     region_name=os.environ.get("AWS_REGION_NAME", "ap-south-1"))

# ── Config from Lambda env vars ────────────────────────────────────
DASHBOARD_BUCKET = os.environ.get("DASHBOARD_BUCKET", "")
SLACK_WEBHOOK    = os.environ.get("SLACK_WEBHOOK", "")
PROJECT          = os.environ.get("PROJECT", "iac-demo")
ENVIRONMENT      = os.environ.get("ENVIRONMENT", "prod")

SERVICE_DISPLAY_NAMES = {
    "Amazon Elastic Compute Cloud - Compute": "EC2 Instances",
    "Amazon Relational Database Service":     "RDS PostgreSQL",
    "Amazon EC2 - ELB":                       "Load Balancer (ALB)",
    "AWS Data Transfer":                       "Data Transfer",
    "Amazon Simple Storage Service":          "S3 Storage",
    "AWSLambda":                              "Lambda",
    "Amazon Route 53":                        "Route 53",
}

SERVICE_COLORS = {
    "EC2 Instances":       "#378ADD",
    "RDS PostgreSQL":      "#1D9E75",
    "Load Balancer (ALB)": "#D85A30",
    "Data Transfer":       "#BA7517",
    "S3 Storage":          "#533AB7",
    "Lambda":              "#3B6D11",
    "Other":               "#888780",
}


def lambda_handler(event, context):
    print(f"[CostReporter] Starting cost analysis for {PROJECT}/{ENVIRONMENT}")

    today     = datetime.now(timezone.utc).date()
    start_7d  = (today - timedelta(days=7)).isoformat()
    start_30d = (today - timedelta(days=30)).isoformat()
    end_date  = today.isoformat()

    # ── 1. Pull 7-day cost by service ─────────────────────────────
    response_7d = ce.get_cost_and_usage(
        TimePeriod={"Start": start_7d, "End": end_date},
        Granularity="DAILY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    # ── 2. Pull 30-day totals for trend ───────────────────────────
    response_30d = ce.get_cost_and_usage(
        TimePeriod={"Start": start_30d, "End": end_date},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    # ── 3. Get 30-day forecast ─────────────────────────────────────
    try:
        forecast_end = (today + timedelta(days=30)).isoformat()
        forecast_resp = ce.get_cost_forecast(
            TimePeriod={"Start": end_date, "End": forecast_end},
            Metric="UNBLENDED_COST",
            Granularity="MONTHLY",
        )
        forecast_total = float(forecast_resp["Total"]["Amount"])
    except Exception as e:
        print(f"[CostReporter] Forecast unavailable: {e}")
        forecast_total = None

    # ── 4. Aggregate by service (7-day) ───────────────────────────
    service_totals = {}
    daily_totals   = {}  # date → total cost

    for result in response_7d["ResultsByTime"]:
        day = result["TimePeriod"]["Start"]
        day_sum = 0.0
        for group in result["Groups"]:
            svc_raw  = group["Keys"][0]
            svc_name = SERVICE_DISPLAY_NAMES.get(svc_raw, "Other")
            cost     = float(group["Metrics"]["UnblendedCost"]["Amount"])
            if cost < 0.001:
                continue
            service_totals[svc_name] = service_totals.get(svc_name, 0.0) + cost
            day_sum += cost
        daily_totals[day] = round(day_sum, 4)

    total_7d   = sum(service_totals.values())
    avg_daily  = total_7d / 7 if total_7d > 0 else 0
    hourly_est = avg_daily / 24
    monthly_est= avg_daily * 30

    # Top cost driver
    top_service = max(service_totals, key=service_totals.get) if service_totals else "N/A"
    top_cost    = service_totals.get(top_service, 0)

    print(f"[CostReporter] 7d total: ${total_7d:.4f} | Hourly: ${hourly_est:.4f} | Monthly est: ${monthly_est:.2f}")

    # ── 5. Build Slack message ─────────────────────────────────────
    slack_payload = build_slack_message(
        service_totals, total_7d, hourly_est, monthly_est,
        forecast_total, top_service, top_cost, daily_totals
    )

    if SLACK_WEBHOOK:
        post_to_slack(slack_payload)
    else:
        print("[CostReporter] SLACK_WEBHOOK not set — skipping notification")
        print(f"[CostReporter] Would have sent: {json.dumps(slack_payload, indent=2)}")

    # ── 6. Generate and upload HTML dashboard to S3 ───────────────
    html = build_html_dashboard(
        service_totals, total_7d, hourly_est, monthly_est,
        forecast_total, top_service, daily_totals
    )

    if DASHBOARD_BUCKET:
        s3.put_object(
            Bucket=DASHBOARD_BUCKET,
            Key="index.html",
            Body=html.encode("utf-8"),
            ContentType="text/html",
            CacheControl="no-cache",
        )
        dashboard_url = f"http://{DASHBOARD_BUCKET}.s3-website.ap-south-1.amazonaws.com"
        print(f"[CostReporter] Dashboard uploaded → {dashboard_url}")
    else:
        print("[CostReporter] DASHBOARD_BUCKET not set — skipping S3 upload")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "total_7d":     round(total_7d, 4),
            "hourly_est":   round(hourly_est, 4),
            "monthly_est":  round(monthly_est, 2),
            "top_service":  top_service,
            "services":     {k: round(v, 4) for k, v in service_totals.items()},
        })
    }


def build_slack_message(service_totals, total_7d, hourly, monthly, forecast, top_svc, top_cost, daily):
    """Builds a rich Slack Block Kit message"""

    service_lines = []
    for svc, cost in sorted(service_totals.items(), key=lambda x: -x[1]):
        pct   = (cost / total_7d * 100) if total_7d > 0 else 0
        bar   = "█" * int(pct / 10) + "░" * (10 - int(pct / 10))
        service_lines.append(f"`{bar}` *{svc}* — ${cost:.4f} ({pct:.1f}%)")

    forecast_line = f"\n>📈 *30-day forecast:* `${forecast:.2f}`" if forecast else ""

    return {
        "text": f"☁️ Infrastructure Cost Report — {PROJECT}/{ENVIRONMENT}",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f"☁️ FinOps Report — {PROJECT} / {ENVIRONMENT}"}
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*💰 Last 7 Days*\n`${total_7d:.4f}`"},
                    {"type": "mrkdwn", "text": f"*⏱️ Est. Hourly Rate*\n`${hourly:.4f}/hr`"},
                    {"type": "mrkdwn", "text": f"*📅 Est. Monthly*\n`${monthly:.2f}/mo`"},
                    {"type": "mrkdwn", "text": f"*🔝 Top Cost Driver*\n`{top_svc}` (${top_cost:.4f})"},
                ]
            },
            {"type": "divider"},
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": "*Cost by Service (7 days):*\n" + "\n".join(service_lines) + forecast_line
                }
            },
            {
                "type": "context",
                "elements": [{
                    "type": "mrkdwn",
                    "text": f"Generated at {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} | Powered by AWS Cost Explorer"
                }]
            }
        ]
    }


def post_to_slack(payload):
    data = json.dumps(payload).encode("utf-8")
    req  = urllib.request.Request(
        SLACK_WEBHOOK,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"[CostReporter] Slack response: {resp.status}")
    except Exception as e:
        print(f"[CostReporter] Slack error: {e}")


def build_html_dashboard(service_totals, total_7d, hourly, monthly, forecast, top_svc, daily_totals):
    """Generates a complete single-file HTML dashboard uploaded to S3"""

    # Build chart data
    labels     = json.dumps(list(daily_totals.keys()))
    values     = json.dumps([round(v, 4) for v in daily_totals.values()])
    svc_labels = json.dumps(list(service_totals.keys()))
    svc_values = json.dumps([round(v, 4) for v in service_totals.values()])
    svc_colors = json.dumps([SERVICE_COLORS.get(s, "#888780") for s in service_totals.keys()])

    forecast_card = f"""
    <div class="metric-card accent">
      <div class="metric-label">30-Day Forecast</div>
      <div class="metric-value">${forecast:.2f}</div>
    </div>""" if forecast else ""

    service_rows = ""
    for svc, cost in sorted(service_totals.items(), key=lambda x: -x[1]):
        pct   = (cost / total_7d * 100) if total_7d > 0 else 0
        color = SERVICE_COLORS.get(svc, "#888780")
        service_rows += f"""
        <tr>
          <td><span class="dot" style="background:{color}"></span>{svc}</td>
          <td>${cost:.4f}</td>
          <td>{pct:.1f}%</td>
          <td><div class="bar-wrap"><div class="bar-fill" style="width:{pct:.1f}%;background:{color}"></div></div></td>
        </tr>"""

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>☁️ FinOps Dashboard — {PROJECT}</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  body {{ font-family: 'Segoe UI', system-ui, sans-serif; background: #0d1117; color: #e6edf3; min-height: 100vh; }}
  .topbar {{ background: #161b22; border-bottom: 1px solid #30363d; padding: 16px 32px; display: flex; align-items: center; gap: 12px; }}
  .topbar h1 {{ font-size: 18px; font-weight: 600; }}
  .topbar .badge {{ background: #1D9E75; color: #fff; font-size: 11px; padding: 3px 8px; border-radius: 12px; font-weight: 600; }}
  .topbar .env {{ background: #378ADD; color: #fff; font-size: 11px; padding: 3px 8px; border-radius: 12px; }}
  .topbar .ts {{ margin-left: auto; font-size: 12px; color: #8b949e; }}
  .container {{ max-width: 1200px; margin: 0 auto; padding: 32px; }}
  .metrics-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }}
  .metric-card {{ background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 20px; }}
  .metric-card.accent {{ border-color: #1D9E75; }}
  .metric-label {{ font-size: 12px; color: #8b949e; margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.05em; }}
  .metric-value {{ font-size: 28px; font-weight: 700; color: #e6edf3; font-variant-numeric: tabular-nums; }}
  .metric-sub {{ font-size: 12px; color: #8b949e; margin-top: 4px; }}
  .top-driver {{ color: #1D9E75; }}
  .charts-grid {{ display: grid; grid-template-columns: 2fr 1fr; gap: 24px; margin-bottom: 32px; }}
  .chart-card {{ background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 24px; }}
  .chart-card h3 {{ font-size: 14px; color: #8b949e; margin-bottom: 20px; text-transform: uppercase; letter-spacing: 0.05em; }}
  .table-card {{ background: #161b22; border: 1px solid #30363d; border-radius: 10px; padding: 24px; }}
  .table-card h3 {{ font-size: 14px; color: #8b949e; margin-bottom: 20px; text-transform: uppercase; letter-spacing: 0.05em; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
  th {{ text-align: left; padding: 10px 12px; border-bottom: 1px solid #30363d; color: #8b949e; font-weight: 500; font-size: 12px; }}
  td {{ padding: 12px; border-bottom: 1px solid #21262d; }}
  tr:last-child td {{ border-bottom: none; }}
  .dot {{ display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 8px; vertical-align: middle; }}
  .bar-wrap {{ background: #21262d; border-radius: 4px; height: 6px; width: 120px; }}
  .bar-fill {{ height: 6px; border-radius: 4px; transition: width 0.3s; }}
  @media (max-width: 768px) {{ .charts-grid {{ grid-template-columns: 1fr; }} }}
</style>
</head>
<body>

<div class="topbar">
  <span style="font-size:20px">☁️</span>
  <h1>FinOps Cost Dashboard</h1>
  <span class="badge">{PROJECT}</span>
  <span class="env">{ENVIRONMENT}</span>
  <span class="ts">Updated: {generated}</span>
</div>

<div class="container">

  <div class="metrics-grid">
    <div class="metric-card">
      <div class="metric-label">Last 7 Days</div>
      <div class="metric-value">${total_7d:.4f}</div>
      <div class="metric-sub">Actual spend</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Hourly Rate</div>
      <div class="metric-value">${hourly:.4f}</div>
      <div class="metric-sub">Based on 7-day avg</div>
    </div>
    <div class="metric-card">
      <div class="metric-label">Est. Monthly</div>
      <div class="metric-value">${monthly:.2f}</div>
      <div class="metric-sub">Projection at current rate</div>
    </div>
    {forecast_card}
    <div class="metric-card">
      <div class="metric-label">Top Cost Driver</div>
      <div class="metric-value top-driver" style="font-size:16px;margin-top:4px">{top_svc}</div>
      <div class="metric-sub">${service_totals.get(top_svc, 0):.4f} (7 days)</div>
    </div>
  </div>

  <div class="charts-grid">
    <div class="chart-card">
      <h3>Daily Spend — Last 7 Days</h3>
      <canvas id="lineChart" height="80"></canvas>
    </div>
    <div class="chart-card">
      <h3>Cost by Service</h3>
      <canvas id="donutChart"></canvas>
    </div>
  </div>

  <div class="table-card">
    <h3>Service Breakdown</h3>
    <table>
      <thead><tr><th>Service</th><th>7-Day Cost</th><th>Share</th><th>Distribution</th></tr></thead>
      <tbody>{service_rows}</tbody>
    </table>
  </div>

</div>

<script>
const lineCtx = document.getElementById('lineChart').getContext('2d');
new Chart(lineCtx, {{
  type: 'line',
  data: {{
    labels: {labels},
    datasets: [{{
      label: 'Daily Cost ($)',
      data: {values},
      borderColor: '#378ADD',
      backgroundColor: 'rgba(55,138,221,0.1)',
      fill: true,
      tension: 0.3,
      pointBackgroundColor: '#378ADD',
      pointRadius: 4,
    }}]
  }},
  options: {{
    responsive: true,
    plugins: {{ legend: {{ display: false }} }},
    scales: {{
      x: {{ ticks: {{ color: '#8b949e', font: {{ size: 11 }} }}, grid: {{ color: '#21262d' }} }},
      y: {{ ticks: {{ color: '#8b949e', font: {{ size: 11 }}, callback: v => '$' + v.toFixed(4) }}, grid: {{ color: '#21262d' }} }}
    }}
  }}
}});

const donutCtx = document.getElementById('donutChart').getContext('2d');
new Chart(donutCtx, {{
  type: 'doughnut',
  data: {{
    labels: {svc_labels},
    datasets: [{{ data: {svc_values}, backgroundColor: {svc_colors}, borderWidth: 0 }}]
  }},
  options: {{
    responsive: true,
    plugins: {{
      legend: {{ position: 'bottom', labels: {{ color: '#8b949e', font: {{ size: 11 }}, padding: 12 }} }}
    }}
  }}
}});
</script>
</body>
</html>"""
