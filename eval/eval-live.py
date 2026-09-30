#!/usr/bin/env python3
"""Phase 3 gate: inject each fault, wait for Steward's diagnosis, and grade the report.

Needs the compose stack up with STEWARD_MODEL_PROVIDER=anthropic and ANTHROPIC_API_KEY set.
Each run costs real API credit (roughly USD 0.02-0.06 per incident on Sonnet); the Steward
monthly budget cap still applies. Usage: eval/eval-live.py [runs]  (default 3)
"""
import json, os, sys, time, urllib.request

GATEWAY = os.environ.get("GATEWAY", "http://127.0.0.1:7100")
STEWARD = os.environ.get("STEWARD", "http://127.0.0.1:7106")
PASSWORD = os.environ.get("DEMO_PASSWORD", "Local-Dev-Demo-1")

# fault -> (incident kind, acceptable action types, words the root cause should mention)
EXPECTED = {
    "stuck-coupon": ("StuckCoupon", {"refresh_coupon"}, ["redis", "progress", "settle"]),
    "wallet-outage": ("WalletOutage", {"no_action"}, ["wallet", "unavailable", "outage"]),
    "poison-message": ("PoisonMessage", {"no_action"}, ["malformed", "deserial", "poison", "json"]),
    "duplicate-settlement": ("DuplicateSettlement", {"no_action"}, ["duplicate", "twice", "idempot", "republish", "re-publish"]),
}


def call(method, url, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"null")


def token():
    return call("POST", f"{GATEWAY}/api/auth/token", body={"grantType": "password", "username": "operator1", "password": PASSWORD})["accessToken"]


def wait_for_report(tok, kind, since):
    deadline = time.time() + 600
    while time.time() < deadline:
        for incident in call("GET", f"{STEWARD}/incidents?limit=100", tok):
            if incident["kind"].lower() == kind.lower() and incident["openedAt"] >= since and incident["status"] in ("awaitingApproval", "diagnosisFailed", "resolved"):
                return call("GET", f"{STEWARD}/incidents/{incident['incidentId']}", tok)
        time.sleep(5)
    return None


def grade(fault, details):
    kind, actions, words = EXPECTED[fault]
    problems = []
    if details is None:
        return ["no diagnosed incident within 10 minutes"]
    report = details.get("report")
    if details["incident"]["status"] != "awaitingApproval" or report is None:
        return [f"status {details['incident']['status']}: {details.get('reportProblems')}"]
    cause = (report["rootCause"] + " " + report["hypothesis"]).lower()
    if not any(w in cause for w in words):
        problems.append(f"root cause does not mention any of {words}: {report['rootCause']!r}")
    outputs = {c["toolUseId"]: c["output"] for c in details["toolCalls"]}
    subject = details["incident"]["subject"]
    if not any(subject in outputs.get(e["toolCallId"], "") for e in report["evidence"]):
        problems.append(f"no cited tool result contains the faulted subject {subject}")
    proposed = {a["type"] for a in report["proposedActions"]} or {"no_action"}
    if not proposed <= actions:
        problems.append(f"proposed {sorted(proposed)}, expected one of {sorted(actions)}")
    return problems


def main():
    if os.environ.get("CONFIRM_SPEND") != "yes":
        sys.exit("This calls the Anthropic API. Re-run with CONFIRM_SPEND=yes.")
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    failures = 0
    for run in range(1, runs + 1):
        for fault in EXPECTED:
            tok = token()
            since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
            print(f"run {run} {fault}: {call('POST', f'{STEWARD}/drills/{fault}', tok)['injected']}")
            problems = grade(fault, wait_for_report(tok, EXPECTED[fault][0], since))
            failures += bool(problems)
            print("  PASS" if not problems else "  FAIL\n    " + "\n    ".join(problems))
    spend = call("GET", f"{STEWARD}/spend", token())
    print(f"month-to-date spend USD {spend['monthToDateUsd']:.4f}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
