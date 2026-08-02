#!/usr/bin/env python3
"""Deterministic request-budget and compatibility tests for Hydra Examiner.

The suite never contacts Hydra.  A curl fixture serves a coherent evaluation
and records each logical HTTP request.  The pre-refactor helper is materialized
from git revision 8fc866d so presentation parity is checked against the actual
old implementation instead of a hand-written expectation.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


PLUGIN = Path(__file__).resolve().parents[1]
REPOSITORY = PLUGIN.parent
HELPER = PLUGIN / "scripts" / "hydra-channel-progress"
BASELINE_REVISION = "8fc866d"
BASELINE_PATH = "hydra-update-examiner/scripts/hydra-channel-progress"
START_TIME = 1_700_000_000
EVAL_ID = "424242"
EVAL_REVISION = "abcdef1234567890abcdef1234567890abcdef12"
OTHER_REVISION = "1111111111111111111111111111111111111111"


FAKE_CURL = r"""#!/usr/bin/env bash
set -u

method="GET"
accept=""
output=""
headers=""
write_out=""
url=""
while (($# > 0)); do
  case "$1" in
    -H|--header)
      accept="${2:-}"
      shift 2
      ;;
    -o|--output)
      output="${2:-}"
      shift 2
      ;;
    -D|--dump-header)
      headers="${2:-}"
      shift 2
      ;;
    -w|--write-out)
      write_out="${2:-}"
      shift 2
      ;;
    -I|--head)
      method="HEAD"
      shift
      ;;
    --request)
      method="${2:-GET}"
      shift 2
      ;;
    --connect-timeout|--max-time|--retry|--retry-delay)
      shift 2
      ;;
    --*)
      shift
      ;;
    -*)
      shift
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\t%s\t%s\n' "$method" "$accept" "$url" >> "$HYDRA_FAKE_REQUEST_LOG"
if [[ -n "${HYDRA_FAKE_DELAY:-}" ]]; then
  sleep "$HYDRA_FAKE_DELAY"
fi
if [[ -n "${HYDRA_FAKE_FAIL_PATTERN:-}" && "$url" == *"$HYDRA_FAKE_FAIL_PATTERN"* ]]; then
  exit 22
fi
if [[ "${HYDRA_FAKE_DISCOVERY_OUTAGE:-0}" == "1" ]]; then
  case "$url" in
    https://nix-channels.s3.amazonaws.com/*|https://channels.nixos.org/nixos-*.*/git-revision)
      exit 22
      ;;
  esac
fi

status="200"
if [[ -n "${HYDRA_FAKE_404_PATTERN:-}" && "$url" == *"$HYDRA_FAKE_404_PATTERN"* ]]; then
  status="404"
fi
location=""
body_file=""
case "$url" in
  https://channels.nixos.org/nixos-unstable/git-revision|https://channels.nixos.org/nixos-26.05/git-revision|https://channels.nixos.org/nixos-25.11/git-revision)
    body_file="$HYDRA_FIXTURE_DIR/channel-revision.txt"
    ;;
  https://nix-channels.s3.amazonaws.com/*)
    body_file="$HYDRA_FIXTURE_DIR/channel-listing.xml"
    ;;
  https://hydra.nixos.org/jobset/nixos/unstable/evals|https://hydra.nixos.org/jobset/nixos/release-26.05/evals|https://hydra.nixos.org/jobset/nixos/release-25.11/evals)
    if [[ "$accept" == *application/json* ]]; then
      body_file="$HYDRA_FIXTURE_DIR/evals.json"
    else
      body_file="$HYDRA_FIXTURE_DIR/evals.html"
    fi
    ;;
  https://hydra.nixos.org/jobset/nixos/unstable/latest-eval)
    status="302"
    location="https://hydra.nixos.org/eval/424200?name=unstable"
    ;;
  https://hydra.nixos.org/eval/424242|https://hydra.nixos.org/eval/424243)
    if [[ "$accept" == *application/json* ]]; then
      body_file="$HYDRA_FIXTURE_DIR/eval.json"
    else
      body_file="$HYDRA_FIXTURE_DIR/eval.html"
    fi
    ;;
  https://hydra.nixos.org/eval/424242/job/tested|https://hydra.nixos.org/eval/424243/job/tested)
    body_file="$HYDRA_FIXTURE_DIR/gate.json"
    ;;
  https://hydra.nixos.org/build/9191/constituents)
    body_file="$HYDRA_FIXTURE_DIR/constituents.json"
    ;;
  *)
    exit 22
    ;;
esac
if [[ "$status" == "404" ]]; then
  body_file=""
fi

header_text="HTTP/1.1 $status Fixture\r\nContent-Type: text/plain\r\n"
if [[ -n "$location" ]]; then
  header_text+="Location: $location\r\n"
fi
header_text+="\r\n"
if [[ -n "$headers" && "$headers" != "/dev/null" ]]; then
  printf '%b' "$header_text" > "$headers"
elif [[ "$method" == "HEAD" && -z "$output" ]]; then
  printf '%b' "$header_text"
fi

if [[ "$method" != "HEAD" && -n "$body_file" ]]; then
  if [[ -n "$output" && "$output" != "/dev/null" ]]; then
    cat "$body_file" > "$output"
  else
    cat "$body_file"
  fi
fi
if [[ -n "$write_out" ]]; then
  printf '%s' "${write_out//\%\{http_code\}/$status}"
fi
"""


class FixtureRun:
    def __init__(self) -> None:
        self._temp = tempfile.TemporaryDirectory(prefix="hydra-request-budget-")
        self.root = Path(self._temp.name)
        self.bin = self.root / "bin"
        self.fixture = self.root / "fixture"
        self.cache_home = self.root / "cache"
        self.log = self.root / "requests.log"
        self.now_file = self.root / "now"
        self.baseline = self.root / "hydra-channel-progress.old"
        self.bin.mkdir()
        self.fixture.mkdir()
        self.cache_home.mkdir()
        self.log.write_text("", encoding="utf-8")
        self.set_now(START_TIME)
        self._write_fixtures()
        self._write_tools()
        self._write_baseline()

    def close(self) -> None:
        self._temp.cleanup()

    def _write_fixtures(self) -> None:
        (self.fixture / "channel-revision.txt").write_text(
            OTHER_REVISION + "\n", encoding="utf-8"
        )
        (self.fixture / "channel-listing.xml").write_text(
            "<ListBucketResult><CommonPrefixes><Prefix>nixos-26.05/</Prefix>"
            "</CommonPrefixes></ListBucketResult>\n",
            encoding="utf-8",
        )
        (self.fixture / "evals.json").write_text(
            json.dumps(
                {
                    "evals": [
                        {
                            "id": int(EVAL_ID),
                            "jobsetevalinputs": {
                                "nixpkgs": {"revision": EVAL_REVISION}
                            },
                        }
                    ]
                }
            )
            + "\n",
            encoding="utf-8",
        )
        (self.fixture / "evals.html").write_text(
            f'<a href="/eval/{EVAL_ID}">latest evaluation</a>\n', encoding="utf-8"
        )
        (self.fixture / "eval.json").write_text(
            json.dumps(
                {"jobsetevalinputs": {"nixpkgs": {"revision": EVAL_REVISION}}}
            )
            + "\n",
            encoding="utf-8",
        )
        (self.fixture / "eval.html").write_text(
            textwrap.dedent(
                f"""\
                <html><body>
                <span>nixos-26.11pre999.{EVAL_REVISION[:12]}</span>
                <ul class="nav nav-tabs">
                  <li>Queued Jobs (10)</li>
                  <li>Still Succeeding Jobs (70)</li>
                  <li>Still Failing Jobs (2)</li>
                  <li>Newly Succeeding Jobs (15)</li>
                  <li>Newly Failing Jobs (1)</li>
                  <li>Aborted / Timed out Jobs (0)</li>
                  <li>New Jobs (2)</li>
                </ul>
                <div class="tab-content"></div>
                </body></html>
                """
            ),
            encoding="utf-8",
        )
        self.set_gate(finished=False)
        constituents = [
            {"finished": 1, "buildstatus": 0} for _ in range(6)
        ] + [{"finished": 0, "buildstatus": 0} for _ in range(4)]
        (self.fixture / "constituents.json").write_text(
            json.dumps(constituents) + "\n", encoding="utf-8"
        )

    def _write_tools(self) -> None:
        curl = self.bin / "curl"
        curl.write_text(FAKE_CURL, encoding="utf-8")
        curl.chmod(0o755)
        real_date = shutil.which("date")
        assert real_date is not None
        date = self.bin / "date"
        date.write_text(
            "#!/usr/bin/env bash\n"
            "case ${1:-} in\n"
            "  +%s) cat \"$HYDRA_FAKE_NOW_FILE\" ;;\n"
            "  +%Y) printf '2026\\n' ;;\n"
            "  +%m) printf '08\\n' ;;\n"
            f"  *) exec {real_date!s} \"$@\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        date.chmod(0o755)

    def _write_baseline(self) -> None:
        result = subprocess.run(
            ["git", "show", f"{BASELINE_REVISION}:{BASELINE_PATH}"],
            cwd=REPOSITORY,
            check=True,
            stdout=subprocess.PIPE,
        )
        self.baseline.write_bytes(result.stdout)
        self.baseline.chmod(0o755)

    def set_gate(self, *, finished: bool) -> None:
        gate = {
            "id": 9191,
            "finished": 1 if finished else 0,
            "buildstatus": 0,
            "starttime": 1_699_999_000,
            "nixname": f"nixos-system-test.{EVAL_REVISION[:12]}",
        }
        (self.fixture / "gate.json").write_text(
            json.dumps(gate) + "\n", encoding="utf-8"
        )

    def set_published(self, published: bool) -> None:
        revision = EVAL_REVISION if published else OTHER_REVISION
        (self.fixture / "channel-revision.txt").write_text(
            revision + "\n", encoding="utf-8"
        )

    def set_now(self, value: int) -> None:
        self.now_file.write_text(f"{value}\n", encoding="utf-8")

    def set_channel_listing(self, *channels: str) -> None:
        prefixes = "".join(
            f"<CommonPrefixes><Prefix>{channel}/</Prefix></CommonPrefixes>"
            for channel in channels
        )
        (self.fixture / "channel-listing.xml").write_text(
            f"<ListBucketResult>{prefixes}</ListBucketResult>\n",
            encoding="utf-8",
        )

    def environment(self, **extra: str) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin}:{env.get('PATH', '')}",
                "XDG_CACHE_HOME": str(self.cache_home),
                "HOME": str(self.root / "home"),
                "HYDRA_FIXTURE_DIR": str(self.fixture),
                "HYDRA_FAKE_REQUEST_LOG": str(self.log),
                "HYDRA_FAKE_NOW_FILE": str(self.now_file),
                "LC_ALL": "C",
            }
        )
        env.update(extra)
        return env

    def run(
        self,
        helper: Path = HELPER,
        *,
        channel: str = "nixos-unstable",
        extra_args: tuple[str, ...] = (),
        check: bool = True,
        env: dict[str, str] | None = None,
    ) -> tuple[dict[str, object], subprocess.CompletedProcess[str]]:
        completed = subprocess.run(
            [str(helper), "--channel", channel, *extra_args],
            cwd=REPOSITORY,
            env=env or self.environment(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            check=False,
        )
        if check:
            if completed.returncode != 0 or completed.stdout.strip() == "":
                raise AssertionError(
                    f"helper failed ({completed.returncode}):\n"
                    f"stdout={completed.stdout!r}\nstderr={completed.stderr!r}"
                )
        try:
            payload = json.loads(completed.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError) as exc:
            raise AssertionError(
                f"helper did not emit one JSON payload:\n"
                f"stdout={completed.stdout!r}\nstderr={completed.stderr!r}"
            ) from exc
        return payload, completed

    def requests(self) -> list[tuple[str, str, str]]:
        if not self.log.exists():
            return []
        rows = []
        for line in self.log.read_text(encoding="utf-8").splitlines():
            method, accept, url = line.split("\t", 2)
            rows.append((method, accept, url))
        return rows

    def clear_requests(self) -> None:
        self.log.write_text("", encoding="utf-8")

    @property
    def cache_file(self) -> Path:
        return self.cache_home / "hydra-update-examiner" / "state.json"


class RequestBudgetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = FixtureRun()

    def tearDown(self) -> None:
        self.fixture.close()

    @staticmethod
    def ttl(name: str) -> int:
        source = HELPER.read_text(encoding="utf-8")
        pattern = rf"(?:readonly\s+)?{re.escape(name)}\s*=\s*['\"]?([0-9]+)"
        match = re.search(pattern, source)
        if match is None:
            raise AssertionError(f"helper does not declare numeric {name}")
        return int(match.group(1))

    @staticmethod
    def presentation_projection(payload: dict[str, object]) -> dict[str, object]:
        projected = {
            key: payload.get(key)
            for key in (
                "text",
                "icon",
                "tooltip",
                "iconColor",
                "textColor",
                "url",
                "channel",
            )
        }
        projected["state"] = payload.get("presentationState", payload.get("state"))
        return projected

    @staticmethod
    def tooltip_facts(payload: dict[str, object]) -> dict[str, str]:
        prefixes = (
            "Hydra eval:",
            "Candidate progress:",
            "Pending jobs:",
            "Failed/aborted:",
            "Eval revision:",
            "Channel revision:",
        )
        lines = str(payload.get("tooltip", "")).splitlines()
        return {
            prefix: next((line for line in lines if line.startswith(prefix)), "")
            for prefix in prefixes
        }

    def test_cold_cache_and_immediate_reuse(self) -> None:
        first, _ = self.fixture.run()
        self.assertEqual(first["state"], "running")
        self.assertEqual(len(self.fixture.requests()), 5)
        self.assertTrue(self.fixture.cache_file.is_file())
        self.assertLessEqual(self.fixture.cache_file.stat().st_size, 65_536)
        cache = json.loads(self.fixture.cache_file.read_text(encoding="utf-8"))
        self.assertEqual(cache["schema"], 2)
        self.assertEqual(set(cache), {"schema", "channelKey", "entry"})
        identity_request = self.fixture.requests()[1]
        self.assertEqual(identity_request[0], "GET")
        self.assertEqual(identity_request[1], "Accept: text/html")

        self.fixture.clear_requests()
        second, _ = self.fixture.run()
        self.assertEqual(second, first)
        self.assertEqual(self.fixture.requests(), [])

    def test_steady_state_refresh_costs_one_request(self) -> None:
        self.fixture.run(self.fixture.baseline)
        self.assertEqual(len(self.fixture.requests()), 6)
        self.fixture.clear_requests()
        self.fixture.run()
        self.fixture.clear_requests()
        self.fixture.set_now(START_TIME + self.ttl("PROGRESS_TTL_SECONDS") + 1)
        refreshed, _ = self.fixture.run()
        requests = self.fixture.requests()
        self.assertEqual(refreshed["state"], "running")
        self.assertEqual(len(requests), 1, requests)
        self.assertEqual(requests[0][2], f"https://hydra.nixos.org/eval/{EVAL_ID}")

        self.fixture.clear_requests()
        self.fixture.run(self.fixture.baseline)
        self.assertEqual(len(self.fixture.requests()), 6)

    def test_explicit_force_refresh_bypasses_live_ttls(self) -> None:
        first, _ = self.fixture.run()
        self.fixture.clear_requests()
        refreshed, _ = self.fixture.run(extra_args=("--force-refresh",))
        urls = [request[2] for request in self.fixture.requests()]
        self.assertEqual(
            self.presentation_projection(refreshed),
            self.presentation_projection(first),
        )
        self.assertEqual(len(urls), 5, urls)
        self.assertIn(
            "https://hydra.nixos.org/jobset/nixos/unstable/evals", urls
        )
        self.assertIn(f"https://hydra.nixos.org/eval/{EVAL_ID}", urls)

    def test_default_hourly_steady_poll_avoids_gate_chain(self) -> None:
        self.fixture.run()
        self.fixture.clear_requests()
        self.fixture.set_now(START_TIME + 3601)
        refreshed, _ = self.fixture.run()
        urls = [request[2] for request in self.fixture.requests()]
        self.assertEqual(refreshed["presentationState"], "running")
        self.assertEqual(
            urls,
            [
                "https://hydra.nixos.org/jobset/nixos/unstable/evals",
                f"https://hydra.nixos.org/eval/{EVAL_ID}",
            ],
        )

    def test_candidate_rollover_replaces_live_slot_without_history(self) -> None:
        self.fixture.run()
        next_eval = "424243"
        (self.fixture.fixture / "evals.html").write_text(
            f'<a href="/eval/{next_eval}">latest evaluation</a>\n',
            encoding="utf-8",
        )
        self.fixture.clear_requests()
        self.fixture.set_now(START_TIME + self.ttl("IDENTITY_TTL_SECONDS") + 1)
        payload, _ = self.fixture.run()
        urls = [request[2] for request in self.fixture.requests()]
        self.assertIn(f"https://hydra.nixos.org/eval/{next_eval}", urls)
        self.assertNotIn(f"https://hydra.nixos.org/eval/{EVAL_ID}", urls)
        self.assertIn(f"#{next_eval}", str(payload["tooltip"]))
        cache = json.loads(self.fixture.cache_file.read_text(encoding="utf-8"))
        self.assertEqual(cache["entry"]["candidate"]["id"], int(next_eval))

    def test_stable_alias_discovery_is_not_repeated(self) -> None:
        first, _ = self.fixture.run(channel="nixos-stable")
        self.assertEqual(first["channel"], "nixos-26.05")
        first_urls = [request[2] for request in self.fixture.requests()]
        self.assertEqual(
            first_urls.count("https://nix-channels.s3.amazonaws.com/?delimiter=/"), 1
        )

        self.fixture.clear_requests()
        self.fixture.set_now(START_TIME + self.ttl("CHANNEL_TTL_SECONDS") + 1)
        second, _ = self.fixture.run(channel="nixos-stable")
        self.assertEqual(second["channel"], "nixos-26.05")
        second_urls = [request[2] for request in self.fixture.requests()]
        self.assertNotIn(
            "https://nix-channels.s3.amazonaws.com/?delimiter=/", second_urls
        )

    def test_provisional_stable_alias_is_rechecked_until_current_exists(self) -> None:
        self.fixture.set_channel_listing("nixos-25.11")
        fallback, _ = self.fixture.run(channel="nixos-stable")
        self.assertEqual(fallback["channel"], "nixos-25.11")

        self.fixture.clear_requests()
        self.fixture.set_now(
            START_TIME + self.ttl("PROVISIONAL_DISCOVERY_TTL_SECONDS") - 1
        )
        cached, _ = self.fixture.run(channel="nixos-stable")
        self.assertEqual(cached["channel"], "nixos-25.11")
        self.assertNotIn(
            "https://nix-channels.s3.amazonaws.com/?delimiter=/",
            [request[2] for request in self.fixture.requests()],
        )

        self.fixture.set_channel_listing("nixos-26.05", "nixos-25.11")
        self.fixture.clear_requests()
        self.fixture.set_now(
            START_TIME + self.ttl("PROVISIONAL_DISCOVERY_TTL_SECONDS") + 1
        )
        current, _ = self.fixture.run(channel="nixos-stable")
        self.assertEqual(current["channel"], "nixos-26.05")
        self.assertIn(
            "https://nix-channels.s3.amazonaws.com/?delimiter=/",
            [request[2] for request in self.fixture.requests()],
        )

    def test_provisional_alias_outage_serves_cached_fallback(self) -> None:
        self.fixture.set_channel_listing("nixos-25.11")
        known, _ = self.fixture.run(channel="nixos-stable")
        self.assertEqual(known["channel"], "nixos-25.11")

        self.fixture.clear_requests()
        self.fixture.set_now(
            START_TIME + self.ttl("PROVISIONAL_DISCOVERY_TTL_SECONDS") + 1
        )
        stale, _ = self.fixture.run(
            channel="nixos-stable",
            env=self.fixture.environment(HYDRA_FAKE_DISCOVERY_OUTAGE="1"),
        )
        self.assertEqual(stale["state"], "stale")
        self.assertEqual(stale["channel"], "nixos-25.11")
        self.assertEqual(stale["presentationState"], known["presentationState"])

    def test_channel_change_overwrites_the_single_cache_slot(self) -> None:
        self.fixture.run(channel="nixos-unstable")
        unstable_cache = json.loads(
            self.fixture.cache_file.read_text(encoding="utf-8")
        )
        self.fixture.run(channel="nixos-stable")
        stable_cache = json.loads(self.fixture.cache_file.read_text(encoding="utf-8"))
        self.assertEqual(set(stable_cache), {"schema", "channelKey", "entry"})
        self.assertNotEqual(stable_cache["channelKey"], unstable_cache["channelKey"])
        self.assertEqual(stable_cache["entry"]["discovery"]["configured"], "nixos-stable")

    def test_presentation_matches_pre_refactor_helper(self) -> None:
        old, _ = self.fixture.run(self.fixture.baseline)
        old_requests = self.fixture.requests()
        self.fixture.clear_requests()
        new, _ = self.fixture.run()
        new_requests = self.fixture.requests()
        self.assertEqual(self.presentation_projection(new), self.presentation_projection(old))
        self.assertEqual(len(old_requests), 6, old_requests)
        self.assertEqual(len(new_requests), 5, new_requests)

    def test_close_and_blocked_presentations_match_pre_refactor_helper(self) -> None:
        for label, finished, extra_args in (
            ("close", False, ("--close-threshold", "50")),
            ("blocked", True, ()),
        ):
            with self.subTest(label=label):
                self.fixture.set_gate(finished=finished)
                old, _ = self.fixture.run(
                    self.fixture.baseline, extra_args=extra_args
                )
                self.fixture.clear_requests()
                self.fixture.cache_file.unlink(missing_ok=True)
                new, _ = self.fixture.run(extra_args=extra_args)
                self.assertEqual(
                    self.presentation_projection(new),
                    self.presentation_projection(old),
                )
                self.fixture.clear_requests()

    def test_published_short_circuit_and_legacy_presentation(self) -> None:
        self.fixture.set_published(True)
        old, _ = self.fixture.run(self.fixture.baseline)
        self.fixture.clear_requests()
        new, _ = self.fixture.run()
        urls = [row[2] for row in self.fixture.requests()]
        self.assertEqual(new["state"], "published-paused")
        self.assertEqual(new["presentationState"], "launched")
        # The visual payload and all already-known eval facts stay compatible.
        # Gate lines are intentionally excluded: a cold published short-circuit
        # cannot know them without violating the no-gate/no-constituents rule.
        old_view = self.presentation_projection(old)
        new_view = self.presentation_projection(new)
        old_view.pop("tooltip")
        new_view.pop("tooltip")
        self.assertEqual(new_view, old_view)
        self.assertEqual(self.tooltip_facts(new), self.tooltip_facts(old))
        self.assertEqual(len(urls), 3, urls)
        self.assertNotIn(f"https://hydra.nixos.org/eval/{EVAL_ID}/job/tested", urls)
        self.assertNotIn("https://hydra.nixos.org/build/9191/constituents", urls)

    def test_terminal_gate_is_not_polled_again_for_same_eval(self) -> None:
        self.fixture.set_gate(finished=True)
        self.fixture.run()
        self.fixture.clear_requests()
        self.fixture.set_now(START_TIME + self.ttl("IDENTITY_TTL_SECONDS") + 1)
        paused, _ = self.fixture.run()
        urls = [row[2] for row in self.fixture.requests()]
        self.assertEqual(paused["state"], "paused")
        self.assertEqual(
            urls,
            [
                "https://channels.nixos.org/nixos-unstable/git-revision",
                "https://hydra.nixos.org/jobset/nixos/unstable/evals",
            ],
        )
        self.assertNotIn(f"https://hydra.nixos.org/eval/{EVAL_ID}", urls)
        self.assertNotIn(f"https://hydra.nixos.org/eval/{EVAL_ID}/job/tested", urls)
        self.assertNotIn("https://hydra.nixos.org/build/9191/constituents", urls)

    def test_terminal_gate_survives_failed_constituent_enrichment(self) -> None:
        self.fixture.set_gate(finished=True)
        paused, _ = self.fixture.run(
            env=self.fixture.environment(
                HYDRA_FAKE_FAIL_PATTERN="/build/9191/constituents"
            )
        )
        self.assertEqual(paused["state"], "paused")
        self.assertIs(paused["stale"], False)

        self.fixture.clear_requests()
        self.fixture.set_now(START_TIME + self.ttl("IDENTITY_TTL_SECONDS") + 1)
        again, _ = self.fixture.run()
        urls = [row[2] for row in self.fixture.requests()]
        self.assertEqual(again["state"], "paused")
        self.assertNotIn(f"https://hydra.nixos.org/eval/{EVAL_ID}/job/tested", urls)
        self.assertNotIn("https://hydra.nixos.org/build/9191/constituents", urls)

    def test_boolean_finished_values_follow_hydra_openapi_shape(self) -> None:
        gate = {
            "id": 9191,
            "finished": True,
            "buildstatus": 0,
            "starttime": 1_699_999_000,
            "nixname": f"nixos-system-test.{EVAL_REVISION[:12]}",
        }
        (self.fixture.fixture / "gate.json").write_text(
            json.dumps(gate) + "\n", encoding="utf-8"
        )
        (self.fixture.fixture / "constituents.json").write_text(
            json.dumps(
                [
                    {"finished": True, "buildstatus": 0},
                    {"finished": False, "buildstatus": 0},
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        payload, _ = self.fixture.run()
        self.assertEqual(payload["state"], "paused")
        self.assertIn("Gate blockers: 0 failed, 1 pending / 2", payload["tooltip"])

    def test_missing_gate_job_keeps_eval_progress_visible(self) -> None:
        payload, _ = self.fixture.run(
            env=self.fixture.environment(
                HYDRA_FAKE_404_PATTERN=f"/eval/{EVAL_ID}/job/tested"
            )
        )
        self.assertEqual(payload["state"], "running")
        self.assertEqual(payload["presentationState"], "running")
        self.assertIs(payload["stale"], False)
        self.assertIn("gate unresolved: Queued", str(payload["tooltip"]))
        self.assertNotIn(
            "https://hydra.nixos.org/build/9191/constituents",
            [row[2] for row in self.fixture.requests()],
        )

    def test_bad_cache_inputs_are_discarded_and_replaced_atomically(self) -> None:
        bad_inputs = {
            "corrupt": b"this is not JSON",
            "truncated": b'{"schema":2,"entry":',
            "oversized": b"x" * 65_537,
            "old schema": b'{"schema":1,"channelKey":"x","entry":{}}',
        }
        for label, body in bad_inputs.items():
            with self.subTest(label=label):
                self.fixture.cache_file.parent.mkdir(parents=True, exist_ok=True)
                self.fixture.cache_file.write_bytes(body)
                self.fixture.clear_requests()
                payload, _ = self.fixture.run()
                self.assertEqual(payload["state"], "running")
                self.assertEqual(len(self.fixture.requests()), 5)
                replacement = json.loads(
                    self.fixture.cache_file.read_text(encoding="utf-8")
                )
                self.assertEqual(replacement["schema"], 2)
                self.assertLessEqual(self.fixture.cache_file.stat().st_size, 65_536)
                self.assertEqual(
                    list(self.fixture.cache_file.parent.glob("state.json.tmp.*")), []
                )

    def test_unwritable_cache_directory_fails_open(self) -> None:
        directory = self.fixture.cache_file.parent
        directory.mkdir(parents=True)
        directory.chmod(stat.S_IRUSR | stat.S_IXUSR)
        try:
            payload, completed = self.fixture.run()
        finally:
            directory.chmod(stat.S_IRWXU)
        self.assertEqual(completed.returncode, 0)
        self.assertNotIn("Permission denied", completed.stderr)
        self.assertEqual(payload["state"], "running")
        self.assertEqual(len(self.fixture.requests()), 5)
        self.assertFalse(self.fixture.cache_file.exists())

    def test_refresh_failure_serves_last_known_payload_as_stale(self) -> None:
        known, _ = self.fixture.run()
        self.fixture.clear_requests()
        age = self.ttl("PROGRESS_TTL_SECONDS") + 1
        self.fixture.set_now(START_TIME + age)
        stale, _ = self.fixture.run(
            env=self.fixture.environment(HYDRA_FAKE_FAIL_PATTERN=f"/eval/{EVAL_ID}")
        )
        self.assertEqual(stale["state"], "stale")
        self.assertEqual(stale["presentationState"], known["presentationState"])
        self.assertIs(stale["stale"], True)
        self.assertGreaterEqual(int(stale["staleAgeSeconds"]), age)
        for key in ("text", "icon", "iconColor", "textColor", "url", "channel"):
            self.assertEqual(stale[key], known[key], key)
        self.assertIn("last known", str(stale["tooltip"]).lower())
        self.assertEqual(len(self.fixture.requests()), 1)

    def test_two_cold_callers_share_one_fetch(self) -> None:
        env = self.fixture.environment(HYDRA_FAKE_DELAY="0.08")
        command = [str(HELPER), "--channel", "nixos-unstable"]
        first = subprocess.Popen(
            command,
            cwd=REPOSITORY,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        second = subprocess.Popen(
            command,
            cwd=REPOSITORY,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        first_stdout, first_stderr = first.communicate(timeout=20)
        second_stdout, second_stderr = second.communicate(timeout=20)
        self.assertEqual(first.returncode, 0, first_stderr)
        self.assertEqual(second.returncode, 0, second_stderr)
        first_payload = json.loads(first_stdout.strip().splitlines()[-1])
        second_payload = json.loads(second_stdout.strip().splitlines()[-1])
        self.assertEqual(first_payload, second_payload)
        self.assertEqual(len(self.fixture.requests()), 5, self.fixture.requests())


if __name__ == "__main__":
    unittest.main(verbosity=2)
