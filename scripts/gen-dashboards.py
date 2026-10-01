#!/usr/bin/env python3
"""Generates the money-path and Steward Grafana dashboards so panels share one layout and datasource."""
import json
import pathlib

DS = {"type": "prometheus", "uid": "prometheus"}
OUT = pathlib.Path(__file__).resolve().parent.parent / "compose" / "grafana" / "dashboards"


def panel(pid, title, exprs, x, y, w=12, h=8, kind="timeseries", unit=None):
    p = {
        "id": pid,
        "type": kind,
        "title": title,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "datasource": DS,
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": legend} for i, (e, legend) in enumerate(exprs)],
    }
    if unit:
        p["fieldConfig"] = {"defaults": {"unit": unit}, "overrides": []}
    return p


def dashboard(uid, title, panels):
    return {"uid": uid, "title": title, "schemaVersion": 39, "version": 1, "refresh": "10s",
            "time": {"from": "now-30m", "to": "now"}, "tags": ["swiftbets"], "panels": panels}


placement = 'service="placement",endpoint="/coupons"'
money = dashboard("swiftbets-money-path", "SwiftBets - Money path health", [
    panel(1, "Placements accepted / second", [(f'sum(rate(http_requests_received_total{{{placement},code="201"}}[1m]))', "accepted")], 0, 0, 8, kind="stat", unit="reqps"),
    panel(2, "Placement latency", [
        (f'histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{{{placement},method="POST"}}[5m])))', "p50"),
        (f'histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{{{placement},method="POST"}}[5m])))', "p99"),
    ], 8, 0, 16, unit="s"),
    panel(3, "Placements refused by status", [(f'sum by (code) (rate(http_requests_received_total{{{placement},code!="201",method="POST"}}[1m]))', "{{code}}")], 0, 8, unit="reqps"),
    panel(4, "Settlements and payouts / second", [
        ('sum(rate(swiftbets_messages_consumed_total{service="payout",topic=~".*coupon-settled.*",outcome="handled"}[1m]))', "settlements reaching payout"),
        ('sum(rate(swiftbets_outbox_published_total{service="payout"}[1m]))', "payouts published"),
    ], 12, 8, unit="ops"),
    panel(5, "Payout retries scheduled by rung", [("sum by (rung) (increase(swiftbets_payout_retries_scheduled_total[1m]))", "{{rung}}")], 0, 16),
    panel(6, "Dead-lettered messages (10m)", [('sum by (topic) (increase(swiftbets_messages_consumed_total{outcome="dead_lettered"}[10m]))', "{{topic}}")], 12, 16),
    panel(7, "Outbox pending by service", [("sum by (service) (swiftbets_outbox_pending)", "{{service}}")], 0, 24),
    panel(8, "Handler p99 by topic", [("histogram_quantile(0.99, sum by (le, topic) (rate(swiftbets_message_handler_duration_seconds_bucket[5m])))", "{{topic}}")], 12, 24, unit="s"),
])

steward = dashboard("swiftbets-steward", "SwiftBets - Steward incidents", [
    panel(1, "Incidents raised (1h)", [("sum(increase(swiftbets_steward_incidents_raised_total[1h]))", "incidents")], 0, 0, 6, kind="stat"),
    panel(2, "Model spend (30d)", [("sum(increase(swiftbets_steward_model_cost_usd_total[30d]))", "USD")], 6, 0, 6, kind="stat", unit="currencyUSD"),
    panel(3, "Incidents raised by kind", [("sum by (kind) (increase(swiftbets_steward_incidents_raised_total[5m]))", "{{kind}}")], 12, 0, 12),
    panel(4, "Diagnoses by outcome", [("sum by (outcome) (increase(swiftbets_steward_diagnoses_total[5m]))", "{{outcome}}")], 0, 8),
    panel(5, "Remediations by status", [("sum by (type, status) (increase(swiftbets_steward_remediations_total[5m]))", "{{type}} {{status}}")], 12, 8),
    panel(6, "Model tokens by kind", [("sum by (kind) (increase(swiftbets_steward_model_tokens_total[5m]))", "{{kind}}")], 0, 16),
    panel(7, "Detector inputs: dead letters and payout retries", [
        ('sum(increase(swiftbets_messages_consumed_total{outcome="dead_lettered"}[5m]))', "dead letters"),
        ("sum(increase(swiftbets_payout_retries_scheduled_total[5m]))", "payout retries"),
    ], 12, 16),
])

for name, board in [("money-path.json", money), ("steward.json", steward)]:
    (OUT / name).write_text(json.dumps(board, indent=2) + "\n")
    print("wrote", OUT / name)
