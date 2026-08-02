#!/usr/bin/env python3
"""Opt-in live parity and request-count comparison for Hydra Examiner.

This is deliberately not part of the automatic suite: it contacts shared
public infrastructure.  Each curl invocation is delayed (three seconds by
default), and both helpers are run only once.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path


PLUGIN = Path(__file__).resolve().parents[1]
REPOSITORY = PLUGIN.parent
HELPER = PLUGIN / "scripts" / "hydra-channel-progress"
BASELINE = "8fc866d:hydra-update-examiner/scripts/hydra-channel-progress"
PRESENTATION_FIELDS = (
    "state",
    "text",
    "icon",
    "tooltip",
    "iconColor",
    "textColor",
    "url",
    "channel",
)


CURL_WRAPPER = r"""#!/usr/bin/env bash
set -u
trace="$(mktemp "${TMPDIR:-/tmp}/hydra-curl-trace.XXXXXX")" || exit 1
url=""
for argument in "$@"; do
  case "$argument" in
    http://*|https://*) url="$argument" ;;
  esac
done
sleep "${HYDRA_LIVE_DELAY_SECONDS:-3}"
"$HYDRA_REAL_CURL" --trace-ascii "$trace" "$@"
result=$?
wire_requests="$(awk '/^=> Send header/{count += 1} END {print count + 0}' "$trace")"
printf '%s\t%s\n' "$wire_requests" "$url" >> "$HYDRA_LIVE_CURL_LOG"
rm -f "$trace"
exit "$result"
"""


def run_helper(
    helper: Path, channel: str, environment: dict[str, str]
) -> dict[str, object]:
    completed = subprocess.run(
        [str(helper), "--channel", channel],
        cwd=REPOSITORY,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=90,
        check=False,
    )
    if completed.returncode != 0 or not completed.stdout.strip():
        raise RuntimeError(
            f"{helper.name} failed ({completed.returncode}): "
            f"{completed.stderr.strip()}"
        )
    return json.loads(completed.stdout.strip().splitlines()[-1])


def request_totals(log: Path) -> tuple[int, int]:
    rows = log.read_text(encoding="utf-8").splitlines()
    return len(rows), sum(int(row.split("\t", 1)[0]) for row in rows)


def presentation(payload: dict[str, object]) -> dict[str, object]:
    projected = {key: payload.get(key) for key in PRESENTATION_FIELDS}
    projected["state"] = payload.get("presentationState", payload.get("state"))
    return projected


def eval_identity(payload: dict[str, object]) -> str:
    for line in str(payload.get("tooltip", "")).splitlines():
        if line.startswith("Hydra eval: "):
            return line
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", default="nixos-unstable")
    parser.add_argument(
        "--delay-seconds",
        type=float,
        default=3.0,
        help="delay before every curl invocation (default: 3)",
    )
    args = parser.parse_args()
    real_curl = shutil.which("curl")
    if real_curl is None:
        raise SystemExit("curl is required")

    with tempfile.TemporaryDirectory(prefix="hydra-live-parity-") as temporary:
        root = Path(temporary)
        bindir = root / "bin"
        bindir.mkdir()
        wrapper = bindir / "curl"
        wrapper.write_text(CURL_WRAPPER, encoding="utf-8")
        wrapper.chmod(0o755)
        baseline = root / "hydra-channel-progress.old"
        baseline.write_bytes(
            subprocess.run(
                ["git", "show", BASELINE],
                cwd=REPOSITORY,
                check=True,
                stdout=subprocess.PIPE,
            ).stdout
        )
        baseline.chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{bindir}:{environment.get('PATH', '')}",
                "HYDRA_REAL_CURL": real_curl,
                "HYDRA_LIVE_DELAY_SECONDS": str(max(args.delay_seconds, 0.0)),
                "XDG_CACHE_HOME": str(root / "cache"),
            }
        )

        old_log = root / "old.log"
        old_log.write_text("", encoding="utf-8")
        environment["HYDRA_LIVE_CURL_LOG"] = str(old_log)
        old = run_helper(baseline, args.channel, environment)
        old_calls, old_wire = request_totals(old_log)

        new_log = root / "new.log"
        new_log.write_text("", encoding="utf-8")
        environment["HYDRA_LIVE_CURL_LOG"] = str(new_log)
        new = run_helper(HELPER, args.channel, environment)
        new_calls, new_wire = request_totals(new_log)

        warm_log = root / "warm.log"
        warm_log.write_text("", encoding="utf-8")
        environment["HYDRA_LIVE_CURL_LOG"] = str(warm_log)
        warm = run_helper(HELPER, args.channel, environment)
        warm_calls, warm_wire = request_totals(warm_log)

        old_identity = eval_identity(old)
        new_identity = eval_identity(new)
        comparable = old_identity != "" and old_identity == new_identity
        old_view = presentation(old)
        new_view = presentation(new)
        differences = {
            key: {"old": old_view.get(key), "new": new_view.get(key)}
            for key in PRESENTATION_FIELDS
            if old_view.get(key) != new_view.get(key)
        }
        report = {
            "channel": args.channel,
            "sameEval": comparable,
            "oldEval": old_identity,
            "newEval": new_identity,
            "old": {"curlInvocations": old_calls, "wireRequests": old_wire},
            "newCold": {"curlInvocations": new_calls, "wireRequests": new_wire},
            "newImmediate": {
                "curlInvocations": warm_calls,
                "wireRequests": warm_wire,
                "samePayload": warm == new,
            },
            "presentationDiff": differences,
            "newRawState": new.get("state"),
            "newPresentationState": new.get("presentationState"),
        }
        print(json.dumps(report, indent=2, sort_keys=True))
        if old_identity == "" or new_identity == "":
            print("Parity is inconclusive because a live eval identity was unavailable.")
            return 2
        if not comparable:
            print("Parity is inconclusive because the candidate changed between runs.")
            return 2
        return 1 if differences else 0


if __name__ == "__main__":
    raise SystemExit(main())
