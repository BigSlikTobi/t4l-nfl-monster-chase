#!/usr/bin/env python3
"""Developer checks for the private Card Scout worker. No app or collection writes."""
import argparse
from contextlib import closing
import datetime as dt
import json
from pathlib import Path
import re
import shlex
import sqlite3
import ssl
import subprocess
import sys
import time
import urllib.request

from cardsight import Client, DAILY_CAP, MONTHLY_CAP, USAGE_CHECK_SECONDS


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def quota(root, refresh=False, client=None):
    client = client or Client(root)
    failed = False
    if refresh:
        try: client.request("GET", "/v1/subscription/")
        except Exception: failed = True  # Provider exceptions may contain credentials/URLs.
    with client.budget_lock():
        ledger = client.ledger()
        used = ledger["calls"]
        if type(used) is not int or used < 0: raise ValueError("Invalid counter")
        checked = ledger.get("subscriptionCheckedAt")
        fresh = type(checked) in (int, float) and 0 <= time.time() - checked < USAGE_CHECK_SECONDS
        monthly_blocked = used >= MONTHLY_CAP
        blocked = monthly_blocked or ledger.get("daily", 0) >= DAILY_CAP
        paused = ledger.get("haltUntil", 0) > time.time()
        status = ("paused" if paused else "limit_reached" if blocked else
                  "unavailable" if failed else "ready" if fresh else "unchecked")
        remaining = max(0, MONTHLY_CAP - used) if monthly_blocked or (fresh and not failed) else None
        return dict(used=used, limit=MONTHLY_CAP, remaining=remaining,
                    checkedAt=checked if type(checked) in (int, float) and 0 < checked <= time.time() else None,
                    month=ledger["month"], status=status)


def health(root):
    config = json.loads((root / "config.json").read_text())
    host, port, token = config["host"], config["port"], config["token"]
    # Configuration supplies only a host, never a URL, path, or credentials.
    if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9.:-]+", host): raise ValueError("Invalid host")
    if type(port) is not int or not 1 <= port <= 65535 or not isinstance(token, str) or not token: raise ValueError("Invalid connection")
    context = ssl.create_default_context(cafile=str(root / "server.crt"))
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
    address = "[" + host + "]" if ":" in host else host
    request = urllib.request.Request(f"https://{address}:{port}/v1/ping", headers={"Authorization": "Bearer " + token})
    with opener.open(request, timeout=8) as response:
        if response.status != 200: raise ValueError("Unhealthy worker")
        raw = response.read(65537)
        if len(raw) > 65536: raise ValueError("Invalid health response")
        value = json.loads(raw)
    if not isinstance(value, dict) or value.get("status") != "ok": raise ValueError("Unhealthy worker")
    # Echo only known status and numeric version fields, never arbitrary server text.
    return dict(status="ok", **{key: value[key] for key in ("version", "analysisVersion")
                              if isinstance(value.get(key), str) and re.fullmatch(r"\d{1,6}", value[key])})


def queue(root):
    # mode=ro prevents a typo from silently creating a fresh queue.
    with closing(sqlite3.connect((root / "queue.sqlite3").resolve().as_uri() + "?mode=ro", uri=True, timeout=3)) as db:
        rows = db.execute("SELECT status,count(*) FROM jobs GROUP BY status").fetchall()
    counts = {}
    allowed = {"queued", "processing", "identified", "enriching", "analyzed", "failed", "cancelled"}
    for status, count in rows:
        key = status if status in allowed else "other"
        counts[key] = counts.get(key, 0) + count
    return dict(total=sum(counts.values()), counts=counts,
                active=sum(counts.get(s, 0) for s in ("queued", "processing", "enriching")))


def run_check(command, root, refresh=False):
    try:
        if not root.is_dir(): raise ValueError("Missing worker directory")
        if command == "quota": value = quota(root, refresh=refresh)
        elif command == "health": value = health(root)
        else: value = queue(root)
        return dict(ok=value.get("status") != "unavailable", **value)
    except Exception:
        # Do not print exception text, config, raw provider replies, or tracebacks.
        return dict(ok=False, error={"quota": "Quota could not be read.", "health": "Worker health check failed.",
                                     "queue": "Queue could not be read."}[command])


def run(command, root, refresh=False):
    commands = ("health", "queue", "quota") if command == "doctor" else (command,)
    checks = {name: run_check(name, root, refresh=refresh and name == "quota") for name in commands}
    return dict(command=command, ok=all(c["ok"] for c in checks.values()), checks=checks)


def remote(args):
    # Stream this source, not credentials or private runtime data. Run as the
    # worker user so a quota refresh preserves the usage ledger's ownership.
    command = shlex.join(["sudo", "-n", "-u", "cardscout", "python3", "-", "--data", str(args.data),
                          "--json", args.command] + (["--refresh"] if args.refresh else []))
    source = 'import sys\nsys.path.insert(0, "/opt/cardscout/service")\n' + Path(__file__).read_text()
    try:
        result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", args.ssh, command],
                                input=source, capture_output=True, text=True, timeout=45)
        value = json.loads(result.stdout)
        if result.returncode not in (0, 1) or not isinstance(value, dict) or value.get("command") != args.command:
            raise ValueError("Invalid remote result")
        if type(value.get("ok")) is not bool or not isinstance(value.get("checks"), dict): raise ValueError("Invalid remote result")
        return value
    except Exception:
        return dict(command=args.command, ok=False, error="SSH check failed. Check access and the installed worker modules.")


def format_report(report):
    lines = [report["command"] + (": ok" if report["ok"] else ": failed")]
    if "error" in report: lines.append(report["error"])
    for name, check in report.get("checks", {}).items():
        if not check.get("ok"):
            lines.append(check.get("error", name + ": unavailable")); continue
        if name == "quota":
            lines.append("CardSight: " + check["status"])
            lines.append("Remaining app requests: " + (str(check["remaining"]) if check["remaining"] is not None else "unknown; run quota --refresh"))
            lines.append(f"Counted: {check['used']} / {check['limit']} ({check['month']})")
            if check["checkedAt"] is not None:
                lines.append("Last provider check: " + dt.datetime.fromtimestamp(check["checkedAt"], dt.timezone.utc).isoformat())
        elif name == "queue":
            lines.append(f"Queue: {check['total']} jobs, {check['active']} active")
            lines.extend("  " + status + ": " + str(count) for status, count in sorted(check["counts"].items()))
        else: lines.append("Worker: " + check["status"])
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, help="Worker data directory; defaults to its standard local path")
    parser.add_argument("--ssh", help="Run checks on an existing Linux worker via trusted SSH")
    parser.add_argument("--json", action="store_true", help="Print a machine-readable report")
    commands = parser.add_subparsers(dest="command", required=True)
    for name, help_text in [("quota", "Read remaining app quota; --refresh checks the provider"),
                            ("health", "Check authenticated HTTPS health and certificate trust"),
                            ("queue", "Read aggregate queue counts without changing jobs"),
                            ("doctor", "Run health, queue and local quota checks; no provider calls")]:
        sub = commands.add_parser(name, help=help_text)
        if name == "quota": sub.add_argument("--refresh", action="store_true", help="Check CardSight usage; one-hour shared cache applies")
    args = parser.parse_args(argv)
    args.refresh = getattr(args, "refresh", False)
    if args.ssh and not re.fullmatch(r"(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9.:-]*", args.ssh): parser.error("Invalid SSH target")
    if args.data is None:
        args.data = (Path("/var/lib/cardscout/data") if args.ssh or sys.platform != "darwin"
                     else Path.home() / "Library/Application Support/CardScoutMac")
    report = remote(args) if args.ssh else run(args.command, args.data.expanduser().resolve(), args.refresh)
    print(json.dumps(report, indent=2) if args.json else format_report(report))
    return 0 if report["ok"] else 1


if __name__ == "__main__": raise SystemExit(main())
