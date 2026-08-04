#!/usr/bin/env python3
"""Focused offline tests for the standalone MotionBGS process boundary."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "motionbgs-helper" / "wall-in-one-motionbgs"
LAUNCHER = ROOT / "wall-in-one" / "scripts" / "motionbgs-provider"

MARKER = (
    '{"schema":1,"owner":"goober/wall-in-one","provider":"MotionBGS",'
    '"deletion_authority":"adjacent .motionbgs.json sidecar required"}\n'
)
GUARD = b"WIO-MBGS-GUARD1\n"

FAKE_CURL = r"""#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time

arguments = sys.argv[1:]
values = {}
index = 0
value_options = {
    "--connect-timeout", "--max-time", "--max-filesize", "--speed-limit",
    "--speed-time", "--proto", "--proto-redir", "--max-redirs", "--header",
    "--user-agent", "--dump-header", "--output", "--write-out", "--url",
    "--request",
}
while index < len(arguments):
    option = arguments[index]
    if option in value_options:
        if index + 1 >= len(arguments):
            raise SystemExit(64)
        if option == "--header":
            values.setdefault(option, []).append(arguments[index + 1])
        else:
            values[option] = arguments[index + 1]
        index += 2
    else:
        index += 1

url = values.get("--url", "")
output = Path(values.get("--output", ""))
headers = Path(values.get("--dump-header", ""))
if not url.startswith("https://motionbgs.com/") or not output or not headers:
    raise SystemExit(64)

log = os.environ.get("WIO_FAKE_CURL_LOG")
if log:
    with open(log, "a", encoding="utf-8") as stream:
        stream.write(url + "\n")

mode = os.environ.get("WIO_FAKE_CURL_MODE", "good")
status = 200
content_type = "text/html"
extra_header = ""
effective_url = url

if mode == "transport-error":
    print("fixture transport failure", file=sys.stderr)
    raise SystemExit(7)
if mode == "cross-origin":
    status = 302
    extra_header = "Location: https://evil.invalid/catalog\r\n"
    body = b"redirect"
elif mode == "same-origin-listing-redirect" and "/search?" in url:
    status = 302
    extra_header = "Location: /tag:fixture-motion/\r\n"
    body = b"redirect"
elif mode == "wrong-search-query-redirect" and "/search?" in url:
    status = 302
    extra_header = "Location: /search?q=different\r\n"
    body = b"redirect"
elif mode == "allowed-download-redirect" and "/dl/" in url:
    status = 302
    extra_header = "Location: /media/42/fixture.mp4\r\n"
    body = b"redirect"
elif mode == "wrong-id-download-redirect" and "/dl/" in url:
    status = 302
    extra_header = "Location: /media/99/wrong.mp4\r\n"
    body = b"redirect"
elif mode == "challenge":
    status = 403
    body = b"<!doctype html><html><head><title>Just a moment...</title></head></html>"
elif mode == "wrong-mime":
    content_type = "application/json"
    body = b"{}"
elif mode == "oversized-html":
    body = b"<!doctype html>" + (b"x" * (1024 * 1024))
elif mode == "wrong-html-signature":
    body = b"this is not HTML"
elif mode == "empty-html":
    body = b"<!doctype html><html><head><title>Empty</title></head><body></body></html>"
elif mode == "changed-html":
    body = b"<!doctype html><html><body><article data-wallpaper='fixture'></article></body></html>"
elif mode == "wrong-mp4-mime" and "/dl/" in url:
    content_type = "application/json"
    body = (24).to_bytes(4, "big") + b"ftyp" + b"isom" + (b"\x00" * 12)
elif mode == "invalid-mp4" and "/dl/" in url:
    content_type = "video/mp4"
    body = b"not an ISO-BMFF payload"
elif mode == "effective-url-mismatch" and "/dl/" in url:
    content_type = "video/mp4"
    body = (24).to_bytes(4, "big") + b"ftyp" + b"isom" + (b"\x00" * 12)
    effective_url = "https://motionbgs.com/media/99/wrong.mp4"
elif mode == "slow-download" and "/dl/" in url:
    time.sleep(1.5)
    content_type = "video/mp4"
    body = (24).to_bytes(4, "big") + b"ftyp" + b"isom" + (b"\x00" * 12)
elif mode == "deadline-download" and "/dl/" in url:
    time.sleep(5.2)
    content_type = "video/mp4"
    body = (24).to_bytes(4, "big") + b"ftyp" + b"isom" + (b"\x00" * 12)
elif mode in {"allowed-download-redirect", "wrong-id-download-redirect"} and "/media/" in url:
    content_type = "video/mp4"
    body = (24).to_bytes(4, "big") + b"ftyp" + b"isom" + (b"\x00" * 12)
elif "/dl/" in url:
    content_type = "video/mp4"
    body = (24).to_bytes(4, "big") + b"ftyp" + b"isom" + (b"\x00" * 12)
elif url.endswith("/fixture-motion"):
    body = b'''<!doctype html><html><head>
      <meta property="og:title" content="Fixture Motion Live Wallpaper">
      <meta property="og:image" content="/media/42/poster.jpg">
      <meta property="og:video" content="/media/42/preview.mp4">
    </head><body>
      <a href="/dl/hd/42/">1920x1080 (3.0 MB)</a>
      <a href="/dl/4k/42/">3840x2160 (8.0 MB)</a>
    </body></html>'''
else:
    body = b'''<!doctype html><html><head><title>1+ Fixture</title></head><body>
      <a href="/fixture-motion" title="Fixture Motion Live Wallpaper">
        <span class="ttl">Fixture Motion</span><span class="frm">HD</span>
        <img data-src="/i/c/364x205/media/42/fixture.jpg">
      </a>
    </body></html>'''

headers.write_bytes(
    (f"HTTP/1.1 {status} Fixture\r\nContent-Type: {content_type}\r\n" + extra_header + "\r\n").encode("ascii")
)
output.write_bytes(body)
sys.stdout.write(f"{status}\t{effective_url}\t{content_type}\t{len(body)}")
"""


class MotionBgsHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(
            prefix="wall-in-one-motionbgs-helper-"
        )
        self.root = Path(self.temporary.name)
        self.cache = self.root / "cache"
        self.downloads = self.root / "downloads"
        self.fake_bin = self.root / "bin"
        for directory in (self.cache, self.downloads, self.fake_bin):
            directory.mkdir(mode=0o700)
        (self.downloads / ".wall-in-one-motionbgs-managed.json").write_text(
            MARKER, encoding="utf-8"
        )
        fake_curl = self.fake_bin / "curl"
        fake_curl.write_text(FAKE_CURL, encoding="utf-8")
        fake_curl.chmod(0o755)
        self.curl_log = self.root / "curl.log"
        self.environment = os.environ.copy()
        self.environment["PATH"] = f"{self.fake_bin}:{self.environment.get('PATH', '')}"
        self.environment["WIO_FAKE_CURL_LOG"] = str(self.curl_log)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def request(self, request_id: str, action: str, **fields: object) -> Path:
        path = self.cache / f"request-{request_id}.json"
        guard = self.cache / f".wall-in-one-motionbgs-guard-{request_id}"
        guard.write_bytes(GUARD)
        guard.chmod(0o600)
        payload: dict[str, object] = {
            "schema": 1,
            "request_id": request_id,
            "action": action,
            "cache_directory": str(self.cache),
            "cache_ttl_seconds": 1800,
            "guard_path": str(guard),
            "operation_timeout_ms": 30_000,
        }
        payload.update(fields)
        path.write_text(
            json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8"
        )
        path.chmod(0o600)
        return path

    def guard_for(self, request: Path) -> Path:
        payload = json.loads(request.read_text(encoding="utf-8"))
        return Path(payload["guard_path"])

    def command(
        self, request: Path, response: Path, *, launcher: bool, guard: Path
    ) -> list[str]:
        if launcher:
            return [
                "bash",
                str(LAUNCHER),
                "rpc",
                str(HELPER),
                str(request),
                str(response),
                str(guard),
            ]
        return [
            str(HELPER),
            "rpc",
            "--protocol",
            "1",
            "--request",
            str(request),
            "--response",
            str(response),
            "--guard",
            str(guard),
        ]

    def invocation_environment(self, mode: str) -> dict[str, str]:
        environment = self.environment.copy()
        environment["WIO_FAKE_CURL_MODE"] = mode
        return environment

    def invoke(
        self,
        request: Path,
        response: Path,
        *,
        launcher: bool = False,
        mode: str = "good",
        check: bool = True,
        guard: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        guard = guard or self.guard_for(request)
        return subprocess.run(
            self.command(request, response, launcher=launcher, guard=guard),
            check=check,
            env=self.invocation_environment(mode),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )

    def start_invocation(
        self,
        request: Path,
        response: Path,
        *,
        launcher: bool = False,
        mode: str = "good",
    ) -> subprocess.Popen[str]:
        guard = self.guard_for(request)
        return subprocess.Popen(
            self.command(request, response, launcher=launcher, guard=guard),
            env=self.invocation_environment(mode),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def wait_for_transport(
        self, fragment: str, *, minimum: int = 1, timeout: float = 5.0
    ) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.curl_log.exists():
                matches = [
                    line
                    for line in self.curl_log.read_text(encoding="utf-8").splitlines()
                    if fragment in line
                ]
                if len(matches) >= minimum:
                    return
            time.sleep(0.02)
        self.fail(
            f"fake curl did not record {minimum} request(s) containing {fragment!r}"
        )

    def read_response(self, response: Path) -> dict[str, object]:
        return json.loads(response.read_text(encoding="utf-8"))

    def search_fields(self, *, force: bool = False) -> dict[str, object]:
        return {
            "mode": "search",
            "query": "fixture motion",
            "genre": "",
            "page": 1,
            "limit": 48,
            "cache_ttl_seconds": 1800,
            "force": force,
        }

    def detail_fields(self, *, force: bool = False) -> dict[str, object]:
        return {"slug": "fixture-motion", "cache_ttl_seconds": 1800, "force": force}

    def download_fields(self, **overrides: object) -> dict[str, object]:
        fields: dict[str, object] = {
            **self.detail_fields(),
            "quality": "hd",
            "download_directory": str(self.downloads),
            "managed_marker_path": str(
                self.downloads / ".wall-in-one-motionbgs-managed.json"
            ),
            "max_download_bytes": 16 * 1024 * 1024,
            "download_timeout_seconds": 10,
            "operation_timeout_ms": 15_000,
        }
        fields.update(overrides)
        return fields

    def prime_details(self, request_id: str = "details-prime") -> None:
        request = self.request(request_id, "details", **self.detail_fields())
        response = self.cache / f"response-{request_id}.json"
        self.invoke(request, response)
        self.assertTrue(self.read_response(response)["ok"])

    def test_probe_and_local_self_tests(self) -> None:
        probe = subprocess.run(
            [str(HELPER), "probe", "--protocol", "1"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(
            probe.stdout.strip(),
            "WIO-MBGS-PROBE1\tok\t1\t1.0.0\tsearch,details,download,clear",
        )
        subprocess.run([str(HELPER), "self-test"], check=True, timeout=10)
        launcher_probe = subprocess.run(
            ["bash", str(LAUNCHER), "probe", str(HELPER)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(launcher_probe.stdout, probe.stdout)
        subprocess.run(["bash", str(LAUNCHER), "self-test"], check=True, timeout=10)

    def test_clear_rpc_and_launcher_gate(self) -> None:
        request = self.request("clear-1", "clear", cache_ttl_seconds=1800)
        response = self.cache / "response-clear-1.json"
        result = self.invoke(request, response, launcher=True)
        self.assertEqual(
            result.stdout.strip(),
            f"WIO-MBGS-RPC1\tok\tclear-1\t{response}\t{response.stat().st_size}",
        )
        payload = self.read_response(response)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["cleared"])
        self.assertEqual(payload["action"], "clear")

        request = self.request("clear-bad-guard", "clear")
        response = self.cache / "response-clear-bad-guard.json"
        self.guard_for(request).write_bytes(b"WIO-MBGS-GUARD1")
        result = self.invoke(request, response, launcher=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("WIO-MBGS-RPC1\terror\tcancelled\t"))
        self.assertFalse(response.exists())

        request = self.request("clear-mismatch", "clear")
        response = self.cache / "response-clear-mismatch.json"
        other_guard = self.cache / ".wall-in-one-motionbgs-guard-other"
        other_guard.write_bytes(GUARD)
        other_guard.chmod(0o600)
        result = self.invoke(request, response, guard=other_guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(
            result.stdout.startswith("WIO-MBGS-RPC1\terror\tinvalid-path\t")
        )
        self.assertFalse(response.exists())

    def test_search_cache_avoids_a_second_transport(self) -> None:
        request = self.request("search-1", "search", **self.search_fields())
        response = self.cache / "response-search-1.json"
        self.invoke(request, response)
        payload = self.read_response(response)
        self.assertTrue(payload["ok"])
        self.assertFalse(payload["cached"])
        self.assertEqual(payload["items"][0]["slug"], "fixture-motion")
        first_calls = self.curl_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(first_calls), 1)

        request = self.request("search-2", "search", **self.search_fields())
        response = self.cache / "response-search-2.json"
        self.invoke(request, response, mode="transport-error")
        payload = self.read_response(response)
        self.assertTrue(payload["ok"])
        self.assertTrue(payload["cached"])
        self.assertEqual(
            self.curl_log.read_text(encoding="utf-8").splitlines(), first_calls
        )

    def test_details_and_transactional_download(self) -> None:
        request = self.request("details-1", "details", **self.detail_fields())
        response = self.cache / "response-details-1.json"
        self.invoke(request, response)
        selected = self.read_response(response)["selected"]
        self.assertEqual(selected["downloads"]["hd"]["id"], "42")

        request = self.request(
            "download-1",
            "download",
            **self.download_fields(),
        )
        response = self.cache / "response-download-1.json"
        self.invoke(request, response, launcher=True)
        payload = self.read_response(response)
        self.assertTrue(payload["cached"])
        self.assertEqual(payload["selected"]["slug"], "fixture-motion")
        download = payload["download"]
        media = Path(download["path"])
        sidecar = Path(download["sidecar"])
        self.assertTrue(media.is_file())
        self.assertTrue(sidecar.is_file())
        provenance = json.loads(sidecar.read_text(encoding="utf-8"))
        self.assertEqual(provenance["provider"], "MotionBGS")
        self.assertEqual(provenance["path"], str(media))
        self.assertEqual(provenance["bytes"], media.stat().st_size)
        self.assertEqual(len(provenance["sha256"]), 64)
        self.assertFalse(
            any(
                path.name.startswith(".motionbgs-") for path in self.downloads.iterdir()
            )
        )

    def test_provider_failure_is_a_nonce_bound_response(self) -> None:
        request = self.request(
            "challenge-1", "search", **self.search_fields(force=True)
        )
        response = self.cache / "response-challenge-1.json"
        result = self.invoke(request, response, mode="challenge")
        self.assertEqual(result.returncode, 0)
        payload = self.read_response(response)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["request_id"], "challenge-1")
        self.assertEqual(payload["error"]["kind"], "challenge")

    def test_cross_origin_redirect_fails_closed(self) -> None:
        request = self.request("redirect-1", "search", **self.search_fields(force=True))
        response = self.cache / "response-redirect-1.json"
        self.invoke(request, response, mode="cross-origin")
        payload = self.read_response(response)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["kind"], "invalid-url")

    def test_same_origin_redirects_are_route_and_media_id_bound(self) -> None:
        request = self.request(
            "listing-redirect", "search", **self.search_fields(force=True)
        )
        response = self.cache / "response-listing-redirect.json"
        self.invoke(request, response, mode="same-origin-listing-redirect")
        payload = self.read_response(response)
        self.assertTrue(payload["ok"])
        self.assertEqual(
            payload["source_url"], "https://motionbgs.com/tag:fixture-motion/"
        )

        request = self.request(
            "listing-wrong-query", "search", **self.search_fields(force=True)
        )
        response = self.cache / "response-listing-wrong-query.json"
        self.invoke(request, response, mode="wrong-search-query-redirect")
        payload = self.read_response(response)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["kind"], "redirects")

        self.prime_details("details-redirect")
        request = self.request(
            "download-redirect-ok", "download", **self.download_fields()
        )
        response = self.cache / "response-download-redirect-ok.json"
        self.invoke(request, response, mode="allowed-download-redirect")
        payload = self.read_response(response)
        self.assertTrue(payload["ok"])
        self.assertEqual(
            payload["download"]["download_url"],
            "https://motionbgs.com/media/42/fixture.mp4",
        )

        installed_before = {path.name for path in self.downloads.iterdir()}
        for request_id, mode in (
            ("download-redirect-wrong-id", "wrong-id-download-redirect"),
            ("download-effective-mismatch", "effective-url-mismatch"),
        ):
            with self.subTest(mode=mode):
                request = self.request(request_id, "download", **self.download_fields())
                response = self.cache / f"response-{request_id}.json"
                self.invoke(request, response, mode=mode)
                payload = self.read_response(response)
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["error"]["kind"], "redirects")
                self.assertEqual(
                    {path.name for path in self.downloads.iterdir()}, installed_before
                )

    def test_html_mime_signature_and_markup_fail_closed(self) -> None:
        expected = {
            "wrong-mime": "content-type",
            "oversized-html": "transport",
            "wrong-html-signature": "content-type",
            "empty-html": "site-markup",
            "changed-html": "site-markup",
        }
        for index, (mode, error_kind) in enumerate(expected.items(), start=1):
            with self.subTest(mode=mode):
                request_id = f"html-invalid-{index}"
                request = self.request(
                    request_id, "search", **self.search_fields(force=True)
                )
                response = self.cache / f"response-{request_id}.json"
                self.invoke(request, response, mode=mode)
                payload = self.read_response(response)
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["error"]["kind"], error_kind)

    def test_invalid_mp4_signature_never_installs_media(self) -> None:
        self.prime_details("details-invalid-mp4")
        for mode in ("wrong-mp4-mime", "invalid-mp4"):
            with self.subTest(mode=mode):
                request_id = f"download-{mode}"
                request = self.request(request_id, "download", **self.download_fields())
                response = self.cache / f"response-{request_id}.json"
                self.invoke(request, response, mode=mode)
                payload = self.read_response(response)
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["error"]["kind"], "content-type")
                self.assertEqual(
                    {path.name for path in self.downloads.iterdir()},
                    {".wall-in-one-motionbgs-managed.json"},
                )

    def test_preexisting_media_is_not_replaced(self) -> None:
        self.prime_details("details-preexisting")
        occupied = self.downloads / "fixture-motion.hd.mp4"
        occupied.write_bytes(b"user-owned sentinel")
        occupied_sidecar = self.downloads / "fixture-motion.hd-1.mp4.motionbgs.json"
        occupied_sidecar.write_bytes(b"user-owned sidecar sentinel")
        request = self.request(
            "download-preexisting", "download", **self.download_fields()
        )
        response = self.cache / "response-download-preexisting.json"
        self.invoke(request, response)
        payload = self.read_response(response)
        self.assertTrue(payload["ok"])
        self.assertEqual(occupied.read_bytes(), b"user-owned sentinel")
        self.assertEqual(occupied_sidecar.read_bytes(), b"user-owned sidecar sentinel")
        self.assertEqual(
            Path(payload["download"]["path"]).name, "fixture-motion.hd-2.mp4"
        )

    def test_guard_removal_during_transfer_cancels_without_installing(self) -> None:
        self.prime_details("details-cancel-transfer")
        request = self.request("cancel-transfer", "download", **self.download_fields())
        response = self.cache / "response-cancel-transfer.json"
        process = self.start_invocation(
            request, response, launcher=True, mode="slow-download"
        )
        self.wait_for_transport("/dl/hd/42/")
        self.guard_for(request).unlink()
        stdout, stderr = process.communicate(timeout=10)
        self.assertNotEqual(process.returncode, 0, msg=stderr)
        self.assertIn("cancelled", stdout)
        self.assertFalse(response.exists())
        self.assertEqual(
            {path.name for path in self.downloads.iterdir()},
            {".wall-in-one-motionbgs-managed.json"},
        )

        request = self.request(
            "deadline-transfer",
            "download",
            **self.download_fields(operation_timeout_ms=5_000),
        )
        response = self.cache / "response-deadline-transfer.json"
        result = self.invoke(
            request,
            response,
            launcher=True,
            mode="deadline-download",
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timeout", result.stdout)
        self.assertFalse(response.exists())
        self.assertEqual(
            {path.name for path in self.downloads.iterdir()},
            {".wall-in-one-motionbgs-managed.json"},
        )

    def test_waiting_invocation_observes_cancelled_guard_without_stampede(self) -> None:
        self.prime_details("details-lock-cancel")
        first_request = self.request(
            "lock-holder", "download", **self.download_fields()
        )
        first_response = self.cache / "response-lock-holder.json"
        first = self.start_invocation(
            first_request, first_response, launcher=True, mode="slow-download"
        )
        self.wait_for_transport("/dl/hd/42/")

        second_request = self.request(
            "lock-waiter", "download", **self.download_fields()
        )
        second_response = self.cache / "response-lock-waiter.json"
        second = self.start_invocation(
            second_request, second_response, launcher=True, mode="slow-download"
        )
        time.sleep(0.15)
        self.guard_for(second_request).unlink()
        second_stdout, second_stderr = second.communicate(timeout=5)
        self.assertNotEqual(second.returncode, 0, msg=second_stderr)
        self.assertIn("cancelled", second_stdout)
        self.assertFalse(second_response.exists())

        first_stdout, first_stderr = first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0, msg=first_stderr or first_stdout)
        self.assertTrue(first_response.is_file())
        download_calls = [
            line
            for line in self.curl_log.read_text(encoding="utf-8").splitlines()
            if "/dl/hd/42/" in line
        ]
        self.assertEqual(len(download_calls), 1)

    def test_no_replace_response_is_preserved(self) -> None:
        request = self.request("conflict-1", "clear")
        response = self.cache / "response-conflict-1.json"
        response.write_text("sentinel\n", encoding="utf-8")
        result = self.invoke(request, response, launcher=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("WIO-MBGS-RPC1\terror\tconflict\t"))
        self.assertEqual(response.read_text(encoding="utf-8"), "sentinel\n")

    def test_oversized_request_is_rejected_before_execution(self) -> None:
        request = self.cache / "request-oversized.json"
        request.write_bytes(b"{" + b" " * (8 * 1024) + b"}")
        response = self.cache / "response-oversized.json"
        guard = self.cache / ".wall-in-one-motionbgs-guard-oversized"
        guard.write_bytes(GUARD)
        guard.chmod(0o600)
        result = self.invoke(request, response, launcher=True, guard=guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(
            result.stdout.startswith("WIO-MBGS-RPC1\terror\tinvalid-request\t")
        )
        self.assertFalse(response.exists())

    def test_owned_oversized_cache_is_replaced_safely(self) -> None:
        cache_path = self.cache / "cache-v1.json"
        cache_path.write_bytes(b"x" * (2 * 1024 * 1024 + 1))
        cache_path.chmod(0o600)
        request = self.request("clear-oversized", "clear", cache_ttl_seconds=1800)
        response = self.cache / "response-clear-oversized.json"
        self.invoke(request, response)
        self.assertTrue(self.read_response(response)["ok"])
        self.assertLess(cache_path.stat().st_size, 2 * 1024 * 1024)
        self.assertEqual(
            json.loads(cache_path.read_text(encoding="utf-8"))["schema"], 1
        )

        outside = self.root / "outside-rate.txt"
        outside.write_text("do-not-read-or-replace\n", encoding="utf-8")
        rate_path = self.cache / ".wall-in-one-motionbgs-last-request"
        rate_path.symlink_to(outside)
        request = self.request(
            "unsafe-rate", "search", **self.search_fields(force=True)
        )
        response = self.cache / "response-unsafe-rate.json"
        self.invoke(request, response)
        payload = self.read_response(response)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["kind"], "invalid-path")
        self.assertTrue(rate_path.is_symlink())
        self.assertEqual(
            outside.read_text(encoding="utf-8"), "do-not-read-or-replace\n"
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
