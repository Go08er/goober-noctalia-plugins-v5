#!/usr/bin/env python3
"""Focused offline tests for Wall-in-One's standalone process backend."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import time
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "wall-in-one-backend" / "wall-in-one-backend"
LAUNCHER = ROOT / "wall-in-one" / "scripts" / "motionbgs-provider"
BACKEND_LAUNCHER = ROOT / "wall-in-one" / "scripts" / "backend-provider"
BACKEND_CHECKSUM = ROOT / "wall-in-one-backend" / "wall-in-one-backend.sha256"

MARKER = (
    '{"schema":1,"owner":"goober/wall-in-one","provider":"MotionBGS",'
    '"deletion_authority":"adjacent .motionbgs.json sidecar required"}\n'
)
GUARD = b"WIO-MBGS-GUARD1\n"
BACKEND_GUARD = b"WIO-BACKEND-GUARD1\n"


def fixture_png(
    width: int = 2, height: int = 2, *, ancillary_bytes: int = 0
) -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    rows = b"".join(b"\x00" + b"\x20\x40\x60" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk("IHDR".encode(), struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + (chunk(b"tEXt", b"x" * ancillary_bytes) if ancillary_bytes else b"")
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def fixture_webp_vp8x() -> bytes:
    # Extended WebP files use VP8X rather than the lossy VP8 or lossless VP8L
    # chunk tag. The preview boundary validates the RIFF length and this tag;
    # provider-thumbnail remains responsible for the MIME/signature cross-check.
    chunk = b"VP8X" + struct.pack("<I", 10) + (b"\x00" * 10)
    payload = b"WEBP" + chunk
    return b"RIFF" + struct.pack("<I", len(payload)) + payload


def fixture_jpeg_segment_bomb() -> bytes:
    return b"\xff\xd8" + (b"\xff\xe1\x00\x02" * 4097) + b"\xff\xd9"

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


WALLHAVEN_FAKE_CURL = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import struct
import sys
import time
import zlib


def png(width=2, height=2):
    def chunk(kind, payload):
        return (
            struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
        )
    rows = b"".join(b"\x00" + b"\x20\x40\x60" * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows))
        + chunk(b"IEND", b"")
    )


def jpeg_segment_bomb():
    return b"\xff\xd8" + (b"\xff\xe1\x00\x02" * 4097) + b"\xff\xd9"


arguments = sys.argv[1:]
values = {}
index = 0
value_options = {
    "--connect-timeout", "--max-time", "--max-filesize", "--speed-limit",
    "--speed-time", "--proto", "--proto-redir", "--max-redirs", "--header",
    "--user-agent", "--output", "--write-out", "--url", "--request",
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
headers = values.get("--header", [])
if not output or not (
    url.startswith("https://wallhaven.cc/api/v1/")
    or url.startswith("https://w.wallhaven.cc/full/")
):
    raise SystemExit(64)
if (
    "--disable" not in arguments
    or "--location" in arguments
    or values.get("--max-redirs") != "0"
    or values.get("--proto") != "=https"
    or values.get("--proto-redir") != "=https"
):
    raise SystemExit(64)

credential_paths = [value[1:] for value in headers if value.startswith("@")]
credential_ok = False
if credential_paths:
    credential = Path(credential_paths[0])
    credential_ok = credential.read_text(encoding="utf-8") == (
        "X-API-Key: " + os.environ.get("WIO_TEST_WALLHAVEN_KEY", "") + "\n"
    )

log = os.environ.get("WIO_FAKE_CURL_LOG")
if log:
    with open(log, "a", encoding="utf-8") as stream:
        stream.write(json.dumps({
            "url": url,
            "argv": arguments,
            "credential_ok": credential_ok,
            "curl_home": os.environ.get("CURL_HOME"),
        }, separators=(",", ":")) + "\n")

mode = os.environ.get("WIO_FAKE_CURL_MODE", "good")
if mode == "transport-error":
    print("fixture transport failure", file=sys.stderr)
    raise SystemExit(7)
if mode == "slow":
    time.sleep(1.0)

status = 200
effective_url = url
content_type = "application/json"
image = png()

def item(identifier):
    return {
        "id": identifier,
        "url": "https://wallhaven.cc/w/" + identifier,
        "short_url": "https://whvn.cc/" + identifier,
        "views": 10,
        "favorites": 3,
        "source": "fixture",
        "purity": "sfw",
        "category": "general",
        "dimension_x": 2,
        "dimension_y": 2,
        "resolution": "2x2",
        "ratio": "1",
        "file_size": len(image),
        "file_type": "image/png",
        "created_at": "2026-08-04 00:00:00",
        "colors": ["#112233", "invalid"],
        "path": "https://w.wallhaven.cc/full/" + identifier[:2] + "/wallhaven-" + identifier + ".png",
        "thumbs": {
            "large": "https://th.wallhaven.cc/lg/" + identifier[:2] + "/" + identifier + ".jpg",
            "original": "https://evil.invalid/thumb.jpg",
            "small": "https://th.wallhaven.cc/small/" + identifier[:2] + "/" + identifier + ".jpg",
        },
        "tags": [{"id": 7, "name": "Fixture", "alias": "", "category": "General", "purity": "sfw"}],
        "uploader": {"username": "fixture-user", "group": "User"},
    }

if url.startswith("https://w.wallhaven.cc/"):
    content_type = "image/png"
    body = image
    if mode == "jpeg-segment-bomb":
        content_type = "image/jpeg"
        body = jpeg_segment_bomb()
    elif mode == "wrong-mime":
        content_type = "text/html"
    elif mode == "invalid-image":
        body = b"not a png".ljust(len(image), b"x")
    elif mode == "wrong-dimensions":
        body = png(3, 2)
    elif mode == "corrupt-crc":
        body = bytearray(image)
        body[-5] ^= 1
        body = bytes(body)
    elif mode == "effective-mismatch":
        effective_url = "https://w.wallhaven.cc/full/zz/wallhaven-zz9999.png"
elif mode == "status-401":
    status = 401
    body = b'{"error":"unauthorized"}'
elif mode == "status-429":
    status = 429
    body = b'{"error":"limited"}'
elif mode == "wrong-mime":
    content_type = "text/html"
    body = b"<html></html>"
elif mode == "effective-mismatch":
    effective_url = "https://wallhaven.cc/api/v1/search?page=999"
    body = b"{}"
elif mode == "invalid-json":
    body = b"{broken"
elif mode == "oversized-json":
    body = b'{' + (b'x' * (512 * 1024)) + b'}'
elif "/api/v1/search?" in url:
    entries = ["broken"] + [item(f"aa{index:04d}") for index in range(26)]
    body = json.dumps({
        "data": entries,
        "meta": {"current_page": 2, "last_page": 9, "per_page": 24, "total": 217, "seed": "ABC123"},
    }, separators=(",", ":")).encode()
else:
    identifier = url.rsplit("/", 1)[-1]
    selected = item("zz9999" if mode == "id-mismatch" else identifier)
    body = json.dumps({"data": selected}, separators=(",", ":")).encode()

output.write_bytes(body)
sys.stdout.write(f"{status}\t{effective_url}\t{content_type}\t{len(body)}")
"""


PALETTES_FAKE_CURL = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

arguments = sys.argv[1:]
values = {}
index = 0
value_options = {
    "--connect-timeout", "--max-time", "--max-filesize", "--speed-limit",
    "--speed-time", "--proto", "--proto-redir", "--max-redirs", "--header",
    "--user-agent", "--output", "--write-out", "--url", "--request",
}
while index < len(arguments):
    option = arguments[index]
    if option in value_options:
        if index + 1 >= len(arguments):
            raise SystemExit(64)
        values[option] = arguments[index + 1]
        index += 2
    else:
        index += 1
url = values.get("--url", "")
output = Path(values.get("--output", ""))
if (
    url != "https://api.noctalia.dev/palettes"
    or not output
    or "--disable" not in arguments
    or "--location" in arguments
    or values.get("--max-redirs") != "0"
    or values.get("--proto") != "=https"
    or values.get("--proto-redir") != "=https"
):
    raise SystemExit(64)
log = os.environ.get("WIO_PALETTES_CURL_LOG")
if log:
    Path(log).write_text(json.dumps({"url": url, "argv": arguments}) + "\n", encoding="utf-8")
mode = os.environ.get("WIO_PALETTES_CURL_MODE", "good")
if mode == "transport-error":
    print("fixture palette transport failed", file=sys.stderr)
    raise SystemExit(7)
status = 200
effective = url
content_type = "application/json"
if mode == "wrong-type":
    content_type = "text/html"
if mode == "redirect":
    effective = "https://evil.invalid/palettes"
body = json.dumps({
    "palettes": [
        {"name": "Zulu", "md5": "A" * 32, "dark": {"surface": "#010203", "primary": "#111111"}},
        {"name": "Alpha", "preview": {"light": {"surface": "#FAFAFA", "accents": ["#ABCDEF"]}}},
        {"name": "Alpha"},
        {"name": ""},
    ]
}, separators=(",", ":")).encode()
output.write_bytes(body)
sys.stdout.write(f"{status}\t{effective}\t{content_type}\t{len(body)}")
"""


FAKE_THUMBNAIL = r"""#!/usr/bin/env bash
set -uo pipefail

[[ $# == 4 && $1 == fetch ]] || exit 64
provider=$2
url=$3
output=$4
mode=${WIO_FAKE_THUMB_MODE:-good}
[[ -z ${WIO_FAKE_THUMB_LOG:-} ]] || printf '%s\t%s\n' "$provider" "$url" >>"$WIO_FAKE_THUMB_LOG"

if [[ $mode == error ]]; then
  printf 'WIO-THUMB1\terror\tremote\t503\tfixture unavailable\n'
  exit 69
elif [[ $mode == malformed ]]; then
  printf 'not-a-thumbnail-wire\n'
  exit 0
elif [[ $mode == slow ]]; then
  sleep 2
fi

source=${WIO_FAKE_THUMB_IMAGE:?}
if [[ $mode == bad-signature ]]; then
  source=${WIO_FAKE_THUMB_BAD:?}
elif [[ $mode == vp8x ]]; then
  source=${WIO_FAKE_THUMB_VP8X:?}
fi
if [[ $mode == symlink-output ]]; then
  ln -s -- "$source" "$output"
else
  cp -- "$source" "$output"
fi
bytes=$(stat -c '%s' -- "$output") || exit 74
wire_provider=$provider
wire_url=$url
wire_path=$output
wire_type=image/png
[[ $mode != vp8x ]] || wire_type=image/webp
wire_bytes=$bytes
[[ $mode != wrong-provider ]] || wire_provider=motionbgs
[[ $mode != wrong-url ]] || wire_url=https://evil.invalid/preview.png
[[ $mode != wrong-path ]] || wire_path=/tmp/not-the-staging-path
[[ $mode != wrong-mime ]] || wire_type=text/html
[[ $mode != wrong-bytes ]] || wire_bytes=$((bytes + 1))
printf 'WIO-THUMB1\tok\t%s\t200\t%s\t%s\t%s\t%s\n' \
  "$wire_provider" "$wire_url" "$wire_type" "$wire_bytes" "$wire_path"
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
            "motionbgs-rpc",
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
            [str(HELPER), "motionbgs-probe", "--protocol", "1"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(
            probe.stdout.strip(),
            "WIO-MBGS-PROBE1\tok\t1\t1.0.0\tsearch,details,download,clear",
        )
        subprocess.run([str(HELPER), "motionbgs-self-test"], check=True, timeout=10)
        backend_probe = subprocess.run(
            [str(HELPER), "probe", "--protocol", "1"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(
            backend_probe.stdout.strip(),
            "WIO-BACKEND-PROBE1\tok\t1\t0.1.0\t"
            "library.scan,palettes.inventory,preview.sync,wallhaven.search,wallhaven.detail,"
            "wallhaven.download,wallhaven.clear",
        )
        backend_self_test = subprocess.run(
            [str(HELPER), "self-test"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        self.assertEqual(
            backend_self_test.stdout.strip(),
            "WIO-BACKEND-SELFTEST1\tok\t0.1.0",
        )
        launcher_backend_probe = subprocess.run(
            ["bash", str(BACKEND_LAUNCHER), "probe", str(HELPER)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(launcher_backend_probe.stdout, backend_probe.stdout)
        subprocess.run(
            ["bash", str(BACKEND_LAUNCHER), "self-test"], check=True, timeout=10
        )
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


class PalettesBackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wall-in-one-palettes-")
        self.root = Path(self.temporary.name)
        self.transport = self.root / "transport"
        self.data = self.root / "data"
        self.config = self.root / "config"
        self.custom = self.config / "noctalia" / "palettes"
        self.fake_bin = self.root / "bin"
        for directory in (self.transport, self.data, self.custom, self.fake_bin):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        curl = self.fake_bin / "curl"
        curl.write_text(PALETTES_FAKE_CURL, encoding="utf-8")
        curl.chmod(0o755)
        self.curl_log = self.root / "curl.log"
        self.environment = os.environ.copy()
        self.environment.update(
            PATH=f"{self.fake_bin}:{self.environment.get('PATH', '')}",
            NOCTALIA_CONFIG_HOME=str(self.config),
            WIO_PALETTES_CURL_LOG=str(self.curl_log),
            CURL_HOME=str(self.root / "hostile-curl-home"),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def request(self, request_id: str, *, force: bool = False) -> tuple[Path, Path, Path]:
        guard = self.transport / f".wall-in-one-backend-guard-{request_id}"
        guard.write_bytes(BACKEND_GUARD)
        guard.chmod(0o600)
        request = self.transport / f"request-{request_id}.json"
        response = self.transport / f"response-{request_id}.json"
        request.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "request_id": request_id,
                    "action": "palettes.inventory",
                    "transport_directory": str(self.transport),
                    "data_directory": str(self.data),
                    "guard_path": str(guard),
                    "operation_timeout_ms": 40_000,
                    "custom_directory": str(self.custom),
                    "cache_path": str(self.data / "palettes-cache.json"),
                    "force_refresh": force,
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        request.chmod(0o600)
        return request, response, guard

    def invoke(
        self,
        request: Path,
        response: Path,
        guard: Path,
        *,
        mode: str = "good",
        launcher: bool = False,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.environment.copy()
        environment["WIO_PALETTES_CURL_MODE"] = mode
        command = (
            ["bash", str(BACKEND_LAUNCHER), "rpc", str(HELPER), str(request), str(response), str(guard)]
            if launcher
            else [
                str(HELPER), "rpc", "--protocol", "1", "--request", str(request),
                "--response", str(response), "--guard", str(guard),
            ]
        )
        return subprocess.run(
            command,
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            env=environment,
        )

    def inventory(self, response: Path) -> tuple[dict[str, object], dict[str, list[dict[str, object]]]]:
        payload = json.loads(response.read_text(encoding="utf-8"))
        inventory = payload["inventory"]
        sections: dict[str, list[dict[str, object]]] = {}
        for section in ("community", "custom"):
            items: list[dict[str, object]] = []
            for descriptor in inventory["sections"][section]["pages"]:
                page = Path(descriptor["path"])
                self.assertEqual(page.stat().st_size, descriptor["bytes"])
                page_payload = json.loads(page.read_text(encoding="utf-8"))
                self.assertEqual(page_payload["action"], "palettes.page")
                items.extend(page_payload["items"])
                page.unlink()
            self.assertEqual(len(items), inventory["sections"][section]["count"])
            sections[section] = items
        return payload, sections

    def write_cache(self, entries: list[dict[str, object]], fetched_at: int) -> None:
        (self.data / "palettes-cache.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "fetched_at": fetched_at,
                    "fetched_at_text": "fixture-cache",
                    "entries": entries,
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )

    def test_fresh_cache_and_custom_inventory_avoid_network(self) -> None:
        self.write_cache([{"name": "Cached"}], int(time.time()))
        (self.custom / "Warm.json").write_text(
            json.dumps({"mSurface": "#010203", "mPrimary": "#abcdef"}) + "\n",
            encoding="utf-8",
        )
        (self.custom / "Broken.json").write_text("{broken\n", encoding="utf-8")
        request, response, guard = self.request("palettes-fresh")
        result = self.invoke(request, response, guard, launcher=True)
        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        payload, sections = self.inventory(response)
        inventory = payload["inventory"]
        self.assertEqual([entry["name"] for entry in sections["community"]], ["Cached"])
        self.assertEqual([entry["name"] for entry in sections["custom"]], ["Warm"])
        self.assertEqual(sections["custom"][0]["preview"]["dark"]["surface"], "#010203")
        self.assertEqual(sections["custom"][0]["preview"]["dark"]["accents"], ["#ABCDEF"])
        self.assertEqual(inventory["invalid_custom"], 1)
        self.assertEqual(inventory["last_event"], "cache-fresh")
        self.assertFalse(inventory["network_attempted"])
        self.assertFalse(self.curl_log.exists())

    def test_declarative_directory_and_palette_symlinks_are_read_safely(self) -> None:
        self.write_cache([{"name": "Cached"}], int(time.time()))
        declarative_root = self.root / "nix-store-fixture"
        declarative_palettes = declarative_root / "palette-directory"
        declarative_palettes.mkdir(parents=True)
        (declarative_palettes / "DirectoryLink.json").write_text(
            json.dumps({"mSurface": "#101112", "mPrimary": "#AABBCC"}) + "\n",
            encoding="utf-8",
        )
        linked_palette = declarative_root / "linked-palette.json"
        linked_palette.write_text(
            json.dumps({"mSurface": "#202122", "mSecondary": "#DDEEFF"}) + "\n",
            encoding="utf-8",
        )
        (declarative_palettes / "FileLink.json").symlink_to(linked_palette)
        os.mkfifo(declarative_palettes / "BlockedPipe.json")
        self.custom.rmdir()
        self.custom.symlink_to(declarative_palettes, target_is_directory=True)

        request, response, guard = self.request("palettes-declarative-links")
        result = self.invoke(request, response, guard, launcher=True)
        self.assertEqual(result.returncode, 0, msg=result.stderr or result.stdout)
        payload, sections = self.inventory(response)
        self.assertEqual(
            [entry["name"] for entry in sections["custom"]],
            ["DirectoryLink", "FileLink"],
        )
        self.assertEqual(payload["inventory"]["invalid_custom"], 1)
        self.assertIn("1 custom palette file", payload["inventory"]["custom_error"])
        self.assertFalse(self.curl_log.exists())

    def test_stale_cache_fetches_normalizes_pages_and_updates_atomically(self) -> None:
        self.write_cache([{"name": "Old"}], int(time.time()) - 24 * 60 * 60)
        request, response, guard = self.request("palettes-refresh")
        self.invoke(request, response, guard)
        payload, sections = self.inventory(response)
        inventory = payload["inventory"]
        self.assertEqual([entry["name"] for entry in sections["community"]], ["Alpha", "Zulu"])
        self.assertEqual(sections["community"][1]["md5"], "a" * 32)
        self.assertEqual(inventory["last_event"], "refresh-complete")
        self.assertEqual(inventory["cache"]["source"], "primary")
        self.assertTrue((self.data / "palettes-cache.json.bak").is_file())
        cached = json.loads((self.data / "palettes-cache.json").read_text(encoding="utf-8"))
        self.assertEqual([entry["name"] for entry in cached["entries"]], ["Alpha", "Zulu"])
        record = json.loads(self.curl_log.read_text(encoding="utf-8"))
        self.assertEqual(record["url"], "https://api.noctalia.dev/palettes")
        self.assertIn("--disable", record["argv"])
        self.assertNotIn("--location", record["argv"])
        self.assertLessEqual(response.stat().st_size, 128 * 1024)

    def test_failed_refresh_serves_stale_cache_and_rejects_wrong_paths(self) -> None:
        self.write_cache([{"name": "Last Known"}], int(time.time()) - 24 * 60 * 60)
        request, response, guard = self.request("palettes-stale")
        self.invoke(request, response, guard, mode="transport-error")
        payload, sections = self.inventory(response)
        self.assertEqual([entry["name"] for entry in sections["community"]], ["Last Known"])
        self.assertEqual(payload["inventory"]["last_event"], "refresh-failed")
        self.assertIn("transport", payload["inventory"]["community_error"])

        request, response, guard = self.request("palettes-bad-path")
        envelope = json.loads(request.read_text(encoding="utf-8"))
        envelope["cache_path"] = str(self.root / "outside.json")
        request.write_text(json.dumps(envelope, separators=(",", ":")) + "\n", encoding="utf-8")
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tinvalid-path\t", result.stdout)
        self.assertFalse(response.exists())


class PreviewBackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wall-in-one-preview-")
        self.root = Path(self.temporary.name)
        self.provider_parent = self.root / "provider-previews"
        self.cache = self.provider_parent / "v1"
        self.transport = self.cache / "rpc"
        self.bin = self.root / "bin"
        for directory in (self.transport, self.bin):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.helper = self.bin / "provider-thumbnail"
        self.helper.write_text(FAKE_THUMBNAIL, encoding="utf-8")
        self.helper.chmod(0o755)
        self.image = self.root / "fixture.png"
        self.image.write_bytes(fixture_png())
        self.bad_image = self.root / "bad.png"
        self.bad_image.write_bytes(b"not a png".ljust(len(fixture_png()), b"x"))
        self.vp8x_image = self.root / "fixture.webp"
        self.vp8x_image.write_bytes(fixture_webp_vp8x())
        self.helper_log = self.root / "helper.log"
        self.environment = os.environ.copy()
        self.environment.update(
            WIO_FAKE_THUMB_IMAGE=str(self.image),
            WIO_FAKE_THUMB_BAD=str(self.bad_image),
            WIO_FAKE_THUMB_VP8X=str(self.vp8x_image),
            WIO_FAKE_THUMB_LOG=str(self.helper_log),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def wallhaven_item(self, identifier: str = "aa0000") -> dict[str, str]:
        return {
            "provider": "wallhaven",
            "id": identifier,
            "url": f"https://th.wallhaven.cc/lg/{identifier[:2]}/{identifier}.jpg",
        }

    def motion_item(self, identifier: str = "night-city") -> dict[str, str]:
        return {
            "provider": "motionbgs",
            "id": identifier,
            "url": "https://motionbgs.com/i/c/364x205/media/9136/night-city.jpg.webp",
        }

    def request(
        self,
        request_id: str,
        items: list[dict[str, str]],
        *,
        helper: Path | None = None,
        timeout_ms: int = 30_000,
        transport: Path | None = None,
    ) -> tuple[Path, Path, Path]:
        transport = transport or self.transport
        guard = transport / f".wall-in-one-backend-guard-{request_id}"
        guard.write_bytes(BACKEND_GUARD)
        guard.chmod(0o600)
        request = transport / f"request-{request_id}.json"
        response = transport / f"response-{request_id}.json"
        request.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "request_id": request_id,
                    "action": "preview.sync",
                    "transport_directory": str(transport),
                    "guard_path": str(guard),
                    "operation_timeout_ms": timeout_ms,
                    "thumbnail_helper": str(helper or self.helper),
                    "items": items,
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        request.chmod(0o600)
        return request, response, guard

    def invoke(
        self,
        request: Path,
        response: Path,
        guard: Path,
        *,
        mode: str = "good",
        check: bool = True,
        launcher: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.environment.copy()
        environment["WIO_FAKE_THUMB_MODE"] = mode
        command = (
            [
                "bash",
                str(BACKEND_LAUNCHER),
                "rpc",
                str(HELPER),
                str(request),
                str(response),
                str(guard),
            ]
            if launcher
            else [
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
        )
        return subprocess.run(
            command,
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
            env=environment,
        )

    def manifest_path(self) -> Path:
        return self.cache / "manifest.json"

    def write_manifest(self, entries: dict[str, dict[str, object]]) -> None:
        self.manifest_path().write_text(
            json.dumps({"schema": 1, "entries": entries}, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )

    def seed_entry(
        self,
        item: dict[str, str],
        *,
        stamp: int = 1,
        sequence: int = 1,
        last_used: int = 1,
        size: int | None = None,
    ) -> tuple[str, dict[str, object]]:
        filename = f"{item['provider']}-{item['id']}-{stamp}-{sequence}.png"
        path = self.cache / filename
        if size is None:
            path.write_bytes(fixture_png())
        else:
            with path.open("wb") as stream:
                stream.truncate(size)
        return (
            item["provider"] + ":" + item["id"],
            {
                "provider": item["provider"],
                "id": item["id"],
                "url": item["url"],
                "filename": filename,
                "bytes": path.stat().st_size,
                "last_used": last_used,
            },
        )

    def response(self, path: Path) -> dict[str, object]:
        return json.loads(path.read_text(encoding="utf-8"))

    def test_cache_hit_touches_manifest_without_invoking_helper(self) -> None:
        item = self.wallhaven_item()
        key, entry = self.seed_entry(item)
        self.write_manifest({key: entry})
        request, response, guard = self.request("preview-hit", [item])
        self.invoke(request, response, guard, mode="error")
        payload = self.response(response)
        self.assertEqual(
            payload["items"],
            [{"index": 1, "state": "ready", "filename": entry["filename"], "cached": True}],
        )
        self.assertEqual(payload["pending_count"], 0)
        self.assertFalse(self.helper_log.exists())
        manifest = self.response(self.manifest_path())
        self.assertGreater(manifest["entries"][key]["last_used"], 1)

    def test_fetches_only_one_missing_item_and_leaves_the_rest_pending(self) -> None:
        items = [self.wallhaven_item("aa0000"), self.wallhaven_item("ab0001"), self.motion_item()]
        request, response, guard = self.request("preview-first", items)
        self.invoke(request, response, guard)
        payload = self.response(response)
        self.assertLessEqual(response.stat().st_size, 128 * 1024)
        self.assertEqual([item["state"] for item in payload["items"]], ["ready", "pending", "pending"])
        self.assertFalse(payload["items"][0]["cached"])
        self.assertNotIn("/", payload["items"][0]["filename"])
        self.assertEqual(payload["pending_count"], 2)
        self.assertEqual(len(self.helper_log.read_text(encoding="utf-8").splitlines()), 1)

        request, response, guard = self.request("preview-second", items)
        self.invoke(request, response, guard)
        payload = self.response(response)
        self.assertEqual([item["state"] for item in payload["items"]], ["ready", "ready", "pending"])
        self.assertTrue(payload["items"][0]["cached"])
        self.assertFalse(payload["items"][1]["cached"])
        self.assertEqual(payload["pending_count"], 1)
        self.assertEqual(len(self.helper_log.read_text(encoding="utf-8").splitlines()), 2)

    def test_extended_webp_vp8x_preview_is_accepted(self) -> None:
        item = self.motion_item()
        request, response, guard = self.request("preview-vp8x", [item])
        self.invoke(request, response, guard, mode="vp8x")
        payload = self.response(response)
        self.assertEqual(payload["items"][0]["state"], "ready")
        self.assertTrue(payload["items"][0]["filename"].endswith(".webp"))
        installed = self.cache / payload["items"][0]["filename"]
        self.assertEqual(installed.read_bytes(), fixture_webp_vp8x())

    def test_launcher_allows_preview_files_above_metadata_response_limit(self) -> None:
        large_preview = fixture_png(ancillary_bytes=192 * 1024)
        self.assertGreater(len(large_preview), 160 * 1024)
        self.assertLess(len(large_preview), 2 * 1024 * 1024)
        self.image.write_bytes(large_preview)
        item = self.wallhaven_item()
        request, response, guard = self.request("preview-launcher-large", [item])
        result = self.invoke(request, response, guard, launcher=True)
        self.assertEqual(result.returncode, 0)
        payload = self.response(response)
        self.assertEqual(payload["items"][0]["state"], "ready")
        installed = self.cache / payload["items"][0]["filename"]
        self.assertEqual(installed.read_bytes(), large_preview)

    def test_helper_failures_are_item_errors_and_never_install(self) -> None:
        modes = {
            "error": "remote",
            "malformed": "helper",
            "bad-signature": "content-type",
            "wrong-provider": "protocol",
            "wrong-url": "protocol",
            "wrong-path": "protocol",
            "wrong-mime": "protocol",
            "wrong-bytes": "protocol",
            "symlink-output": "protocol",
        }
        for index, (mode, kind) in enumerate(modes.items()):
            with self.subTest(mode=mode):
                request, response, guard = self.request(
                    f"preview-failure-{index}", [self.wallhaven_item(), self.motion_item()]
                )
                self.invoke(request, response, guard, mode=mode)
                payload = self.response(response)
                self.assertEqual(payload["items"][0]["state"], "error")
                self.assertEqual(payload["items"][0]["kind"], kind)
                self.assertEqual(payload["items"][1]["state"], "pending")
                self.assertEqual(payload["pending_count"], 1)
                self.assertFalse(any(self.cache.glob("wallhaven-aa0000-*.png")))

    def test_corrupt_and_oversized_manifests_reset_and_owned_orphans_are_removed(self) -> None:
        orphan = self.cache / "wallhaven-aa9999-1-1.png"
        orphan.write_bytes(fixture_png())
        sentinel = self.cache / "user-file.png"
        sentinel.write_bytes(b"keep")
        for index, raw in enumerate((b"{broken\n", b"x" * (64 * 1024 + 1))):
            with self.subTest(index=index):
                self.manifest_path().write_bytes(raw)
                request, response, guard = self.request(
                    f"preview-reset-{index}", [self.wallhaven_item()]
                )
                self.invoke(request, response, guard)
                payload = self.response(response)
                self.assertEqual(payload["items"][0]["state"], "ready")
                manifest = self.response(self.manifest_path())
                self.assertEqual(manifest["schema"], 1)
                self.assertLessEqual(len(manifest["entries"]), 1)
                self.assertFalse(orphan.exists())
                self.assertTrue(sentinel.exists())

    def test_prunes_entry_and_byte_caps_while_preserving_requested_hit(self) -> None:
        entries: dict[str, dict[str, object]] = {}
        requested = self.wallhaven_item("aa0065")
        for index in range(66):
            item = self.wallhaven_item(f"aa{index:04d}")
            key, entry = self.seed_entry(item, stamp=10 + index, sequence=1, last_used=index + 1)
            entries[key] = entry
        self.write_manifest(entries)
        request, response, guard = self.request("preview-prune-count", [requested])
        self.invoke(request, response, guard, mode="error")
        self.assertEqual(self.response(response)["items"][0]["state"], "ready")
        manifest = self.response(self.manifest_path())
        self.assertLessEqual(len(manifest["entries"]), 64)
        self.assertIn("wallhaven:aa0065", manifest["entries"])

        for name in list(self.cache.iterdir()):
            if name.is_file() and name.name != "manifest.json":
                name.unlink()
        entries = {}
        for index in range(33):
            item = self.wallhaven_item(f"ab{index:04d}")
            key, entry = self.seed_entry(
                item, stamp=100 + index, sequence=1, last_used=index + 1, size=2 * 1024 * 1024
            )
            entries[key] = entry
        requested = self.wallhaven_item("ab0032")
        self.write_manifest(entries)
        request, response, guard = self.request("preview-prune-bytes", [requested])
        self.invoke(request, response, guard, mode="error")
        manifest = self.response(self.manifest_path())
        self.assertLessEqual(sum(entry["bytes"] for entry in manifest["entries"].values()), 64 * 1024 * 1024)
        self.assertIn("wallhaven:ab0032", manifest["entries"])

    def test_traversal_symlinks_guard_timeout_and_no_replace_fail_closed(self) -> None:
        victim = self.root / "victim"
        victim.write_bytes(b"do-not-delete")
        item = self.wallhaven_item()
        owned_link = self.cache / "wallhaven-aa0000-1-1.png"
        owned_link.symlink_to(victim)
        self.write_manifest(
            {
                "wallhaven:aa0000": {
                    "provider": "wallhaven", "id": "aa0000", "url": item["url"],
                    "filename": "wallhaven-aa0000-1-1.png", "bytes": len(victim.read_bytes()),
                    "last_used": 1,
                },
                "wallhaven:aa0001": {
                    "provider": "wallhaven", "id": "aa0001",
                    "url": self.wallhaven_item("aa0001")["url"], "filename": "../../victim",
                    "bytes": len(victim.read_bytes()), "last_used": 1,
                },
            }
        )
        real_helper = self.bin / "real-provider-thumbnail"
        self.helper.rename(real_helper)
        self.helper.symlink_to(real_helper)
        request, response, guard = self.request("preview-symlink", [item])
        self.invoke(request, response, guard)
        payload = self.response(response)
        self.assertEqual(payload["items"][0]["kind"], "invalid-helper")
        self.assertEqual(victim.read_bytes(), b"do-not-delete")
        self.assertFalse(owned_link.exists())

        self.helper.unlink()
        real_helper.rename(self.helper)
        request, response, guard = self.request("preview-guard", [item])
        environment = self.environment.copy()
        environment["WIO_FAKE_THUMB_MODE"] = "slow"
        process = subprocess.Popen(
            [
                str(HELPER), "rpc", "--protocol", "1", "--request", str(request),
                "--response", str(response), "--guard", str(guard),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
        deadline = time.monotonic() + 3
        while not self.helper_log.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        guard.unlink()
        stdout, _stderr = process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("\terror\tcancelled\t", stdout)
        self.assertFalse(response.exists())
        self.assertFalse(any(self.cache.glob(".wall-in-one-preview-*.stage")))

        request, response, guard = self.request("preview-conflict", [item])
        response.write_text("sentinel\n", encoding="utf-8")
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(response.read_text(encoding="utf-8"), "sentinel\n")

        request, response, guard = self.request("preview-timeout-high", [item], timeout_ms=45_001)
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tinvalid-request\t", result.stdout)

        wrong_parent = self.root / "not-provider-previews" / "v1" / "rpc"
        wrong_parent.mkdir(parents=True)
        request, response, guard = self.request(
            "preview-wrong-root", [item], transport=wrong_parent
        )
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tinvalid-path\t", result.stdout)


class WallhavenBackendTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wall-in-one-wallhaven-")
        self.root = Path(self.temporary.name)
        self.transport = self.root / "transport"
        self.images = self.root / "images"
        self.managed = self.images / "Wall-in-One" / "Wallhaven"
        self.fake_bin = self.root / "bin"
        for directory in (self.transport, self.managed, self.fake_bin):
            directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        (self.managed / ".managed-by-wall-in-one-v1.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "plugin": "goober/wall-in-one",
                    "kind": "wallhaven",
                    "ownership": "managed",
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        fake_curl = self.fake_bin / "curl"
        fake_curl.write_text(WALLHAVEN_FAKE_CURL, encoding="utf-8")
        fake_curl.chmod(0o755)
        self.curl_log = self.root / "curl.log"
        self.api_key = "Fixture_Private_Key"
        self.environment = os.environ.copy()
        self.environment["PATH"] = f"{self.fake_bin}:{self.environment.get('PATH', '')}"
        self.environment["WIO_FAKE_CURL_LOG"] = str(self.curl_log)
        self.environment["WIO_TEST_WALLHAVEN_KEY"] = self.api_key
        self.environment["CURL_HOME"] = str(self.root / "hostile-curl-home")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def filters(self, **overrides: object) -> dict[str, object]:
        result: dict[str, object] = {
            "query": "night city",
            "categories": "111",
            "purity": "100",
            "sorting": "date_added",
            "order": "desc",
            "atleast": "1920x1080",
            "resolutions": "",
            "ratios": "16x9,16x10",
            "colors": "0066cc",
            "top_range": "1M",
            "seed": "",
            "page": 2,
        }
        result.update(overrides)
        return result

    def item(self) -> dict[str, object]:
        image = fixture_png()
        return {
            "id": "aa0000",
            "path": "https://w.wallhaven.cc/full/aa/wallhaven-aa0000.png",
            "short_url": "https://whvn.cc/aa0000",
            "file_type": "image/png",
            "file_size": len(image),
            "dimension_x": 2,
            "dimension_y": 2,
        }

    def jpeg_segment_bomb_item(self) -> dict[str, object]:
        image = fixture_jpeg_segment_bomb()
        return {
            "id": "aa0000",
            "path": "https://w.wallhaven.cc/full/aa/wallhaven-aa0000.jpg",
            "short_url": "https://whvn.cc/aa0000",
            "file_type": "image/jpeg",
            "file_size": len(image),
            "dimension_x": 2,
            "dimension_y": 2,
        }

    def request(
        self,
        request_id: str,
        action: str,
        *,
        authenticated: bool = False,
        timeout_ms: int = 15_000,
        **fields: object,
    ) -> tuple[Path, Path, Path, Path | None]:
        guard = self.transport / f".wall-in-one-backend-guard-{request_id}"
        guard.write_bytes(BACKEND_GUARD)
        guard.chmod(0o600)
        credential: Path | None = None
        if authenticated:
            credential = self.transport / f".wall-in-one-backend-wallhaven-key-{request_id}"
            credential.write_text(f"X-API-Key: {self.api_key}\n", encoding="utf-8")
            credential.chmod(0o600)
        payload: dict[str, object] = {
            "schema": 1,
            "request_id": request_id,
            "action": action,
            "transport_directory": str(self.transport),
            "guard_path": str(guard),
            "operation_timeout_ms": timeout_ms,
            "api_key_path": str(credential) if credential else "",
        }
        payload.update(fields)
        request = self.transport / f"request-{request_id}.json"
        response = self.transport / f"response-{request_id}.json"
        request.write_text(
            json.dumps(payload, separators=(",", ":")) + "\n", encoding="utf-8"
        )
        request.chmod(0o600)
        return request, response, guard, credential

    def invoke(
        self,
        request: Path,
        response: Path,
        guard: Path,
        *,
        mode: str = "good",
        log_curl: bool = True,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        environment = self.environment.copy()
        environment["WIO_FAKE_CURL_MODE"] = mode
        if not log_curl:
            environment.pop("WIO_FAKE_CURL_LOG", None)
        return subprocess.run(
            [
                str(HELPER), "rpc", "--protocol", "1", "--request", str(request),
                "--response", str(response), "--guard", str(guard),
            ],
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=20,
            env=environment,
        )

    def response(self, path: Path) -> dict[str, object]:
        return json.loads(path.read_text(encoding="utf-8"))

    def curl_records(self) -> list[dict[str, object]]:
        if not self.curl_log.exists():
            return []
        return [
            json.loads(line)
            for line in self.curl_log.read_text(encoding="utf-8").splitlines()
        ]

    def test_search_is_bounded_normalized_and_uses_hardened_curl(self) -> None:
        request, response, guard, _credential = self.request(
            "wallhaven-search", "wallhaven.search", filters=self.filters()
        )
        result = self.invoke(request, response, guard)
        payload = self.response(response)
        self.assertEqual(
            result.stdout.strip(),
            f"WIO-BACKEND-RPC1\tok\twallhaven-search\t{response}\t{response.stat().st_size}",
        )
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["kind"], "search")
        self.assertEqual(len(payload["items"]), 24)
        self.assertEqual(payload["meta"]["dropped"], 1)
        self.assertEqual(payload["meta"]["total"], 217)
        first = payload["items"][0]
        self.assertEqual(first["id"], "aa0000")
        self.assertEqual(first["resolution"], "2x2")
        self.assertEqual(first["colors"], ["#112233"])
        self.assertEqual(first["thumbs"]["original"], "")
        self.assertLessEqual(response.stat().st_size, 128 * 1024)
        records = self.curl_records()
        self.assertEqual(len(records), 1)
        self.assertIn("q=night%20city", records[0]["url"])
        self.assertIn("ratios=16x9%2C16x10", records[0]["url"])
        self.assertIsNone(records[0]["curl_home"])
        self.assertIn("--disable", records[0]["argv"])
        self.assertNotIn("--location", records[0]["argv"])
        self.assertEqual(records[0]["argv"][records[0]["argv"].index("--max-redirs") + 1], "0")

    def test_private_api_header_is_not_exposed_in_argv_or_url(self) -> None:
        request, response, guard, credential = self.request(
            "wallhaven-private",
            "wallhaven.search",
            authenticated=True,
            filters=self.filters(purity="101"),
        )
        self.invoke(request, response, guard)
        self.assertTrue(self.response(response)["ok"])
        self.assertIsNotNone(credential)
        self.assertFalse(credential.exists())
        record = self.curl_records()[0]
        self.assertTrue(record["credential_ok"])
        serialized = json.dumps(record)
        self.assertNotIn(self.api_key, serialized)
        self.assertNotIn("apikey", record["url"].lower())

    def test_nsfw_without_key_and_bad_exact_filters_fail_before_network(self) -> None:
        request, response, guard, _credential = self.request(
            "wallhaven-no-key",
            "wallhaven.search",
            filters=self.filters(purity="101"),
        )
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tvalidation\t", result.stdout)
        self.assertFalse(response.exists())
        self.assertEqual(self.curl_records(), [])

        request, response, guard, _credential = self.request(
            "wallhaven-bad-filter",
            "wallhaven.search",
            filters=self.filters(atleast="1920x1080", resolutions="2560x1440"),
        )
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tvalidation\t", result.stdout)
        self.assertFalse(response.exists())

    def test_detail_normalizes_tags_and_rejects_wrong_identity(self) -> None:
        request, response, guard, _credential = self.request(
            "wallhaven-detail", "wallhaven.detail", id="aa0000"
        )
        self.invoke(request, response, guard)
        payload = self.response(response)
        self.assertEqual(payload["kind"], "detail")
        self.assertEqual(payload["selected"]["id"], "aa0000")
        self.assertEqual(payload["selected"]["tags"][0]["name"], "Fixture")
        self.assertEqual(payload["selected"]["uploader"]["username"], "fixture-user")

        request, response, guard, _credential = self.request(
            "wallhaven-detail-wrong", "wallhaven.detail", id="aa0000"
        )
        self.invoke(request, response, guard, mode="id-mismatch")
        payload = self.response(response)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["kind"], "response")

    def test_api_transport_failures_are_bounded_error_responses(self) -> None:
        for index, (mode, expected_kind) in enumerate(
            (
                ("wrong-mime", "content-type"),
                ("effective-mismatch", "redirects"),
                ("invalid-json", "response"),
                ("status-401", "authentication"),
                ("status-429", "rate_limit"),
            )
        ):
            with self.subTest(mode=mode):
                request, response, guard, _credential = self.request(
                    f"wallhaven-error-{index}", "wallhaven.detail", id="aa0000"
                )
                self.invoke(request, response, guard, mode=mode)
                payload = self.response(response)
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["error"]["kind"], expected_kind)

    def test_download_validates_and_installs_media_and_sidecar_no_replace(self) -> None:
        target = self.managed / "wallhaven-aa0000.png"
        request, response, guard, _credential = self.request(
            "wallhaven-download",
            "wallhaven.download",
            item=self.item(),
            image_root=str(self.images),
            target_path=str(target),
        )
        self.invoke(request, response, guard, log_curl=False)
        payload = self.response(response)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["download"]["path"], str(target))
        self.assertEqual(target.read_bytes(), fixture_png())
        sidecar = Path(str(target) + ".wallhaven.json")
        provenance = json.loads(sidecar.read_text(encoding="utf-8"))
        self.assertEqual(provenance["provider"], "Wallhaven")
        self.assertEqual(provenance["source_page"], "https://wallhaven.cc/w/aa0000")
        self.assertEqual(provenance["bytes"], len(fixture_png()))

        request, second_response, guard, _credential = self.request(
            "wallhaven-download-again",
            "wallhaven.download",
            item=self.item(),
            image_root=str(self.images),
            target_path=str(target),
        )
        result = self.invoke(request, second_response, guard, check=False, log_curl=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tconflict\t", result.stdout)
        self.assertFalse(second_response.exists())

    def test_bad_download_content_never_installs(self) -> None:
        for index, (mode, expected_kind) in enumerate(
            (
                ("wrong-mime", "content-type"),
                ("invalid-image", "content-type"),
                ("corrupt-crc", "content-type"),
                ("wrong-dimensions", "dimensions"),
                ("effective-mismatch", "redirects"),
            )
        ):
            with self.subTest(mode=mode):
                target = self.managed / f"wallhaven-aa0000-{index}.png"
                # The backend derives one exact name; use a fresh managed tree
                # per case so each request retains that security invariant.
                if index > 0:
                    previous_target = self.managed / "wallhaven-aa0000.png"
                    previous_sidecar = Path(str(previous_target) + ".wallhaven.json")
                    previous_target.unlink(missing_ok=True)
                    previous_sidecar.unlink(missing_ok=True)
                target = self.managed / "wallhaven-aa0000.png"
                request, response, guard, _credential = self.request(
                    f"wallhaven-bad-media-{index}",
                    "wallhaven.download",
                    item=self.item(),
                    image_root=str(self.images),
                    target_path=str(target),
                )
                self.invoke(request, response, guard, mode=mode, log_curl=False)
                payload = self.response(response)
                self.assertFalse(payload["ok"])
                self.assertEqual(payload["error"]["kind"], expected_kind)
                self.assertFalse(target.exists())
                self.assertFalse(Path(str(target) + ".wallhaven.json").exists())

    def test_jpeg_segment_count_is_bounded(self) -> None:
        target = self.managed / "wallhaven-aa0000.jpg"
        request, response, guard, _credential = self.request(
            "wallhaven-jpeg-segment-cap",
            "wallhaven.download",
            item=self.jpeg_segment_bomb_item(),
            image_root=str(self.images),
            target_path=str(target),
        )
        self.invoke(
            request,
            response,
            guard,
            mode="jpeg-segment-bomb",
            log_curl=False,
        )
        payload = self.response(response)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["kind"], "content-type")
        self.assertIn("too many segments", payload["error"]["message"])
        self.assertFalse(target.exists())
        self.assertFalse(Path(str(target) + ".wallhaven.json").exists())

    def test_marker_guard_rate_limit_clear_and_response_no_replace(self) -> None:
        marker = self.managed / ".managed-by-wall-in-one-v1.json"
        marker.write_text("{}\n", encoding="utf-8")
        target = self.managed / "wallhaven-aa0000.png"
        request, response, guard, _credential = self.request(
            "wallhaven-marker",
            "wallhaven.download",
            item=self.item(),
            image_root=str(self.images),
            target_path=str(target),
        )
        result = self.invoke(request, response, guard, check=False, log_curl=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tinvalid-marker\t", result.stdout)
        self.assertFalse(target.exists())
        marker.write_text(
            '{"schema":1,"plugin":"goober/wall-in-one","kind":"wallhaven","ownership":"managed"}\n',
            encoding="utf-8",
        )

        first, first_response, first_guard, _credential = self.request(
            "wallhaven-rate-1", "wallhaven.detail", id="aa0000"
        )
        self.invoke(first, first_response, first_guard)
        second, second_response, second_guard, _credential = self.request(
            "wallhaven-rate-2", "wallhaven.detail", id="aa0000"
        )
        started = time.monotonic()
        self.invoke(second, second_response, second_guard)
        self.assertGreaterEqual(time.monotonic() - started, 1.8)

        clear, clear_response, clear_guard, _credential = self.request(
            "wallhaven-clear", "wallhaven.clear"
        )
        self.invoke(clear, clear_response, clear_guard)
        cleared = self.response(clear_response)
        self.assertEqual(cleared["kind"], "empty")
        self.assertEqual(cleared["items"], [])

        conflict, conflict_response, conflict_guard, _credential = self.request(
            "wallhaven-conflict", "wallhaven.clear"
        )
        conflict_response.write_text("sentinel\n", encoding="utf-8")
        result = self.invoke(conflict, conflict_response, conflict_guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(conflict_response.read_text(encoding="utf-8"), "sentinel\n")

    def test_wallhaven_timeout_accepts_media_budget_but_rejects_more(self) -> None:
        request, response, guard, _credential = self.request(
            "wallhaven-timeout-max", "wallhaven.clear", timeout_ms=120_000
        )
        self.invoke(request, response, guard)
        self.assertTrue(self.response(response)["ok"])

        request, response, guard, _credential = self.request(
            "wallhaven-timeout-over", "wallhaven.clear", timeout_ms=120_001
        )
        result = self.invoke(request, response, guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("\terror\tinvalid-request\t", result.stdout)


class BackendBoundedPrimitiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="wall-in-one-bounds-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_tracked_checksum_matches_the_installable_backend(self) -> None:
        digest, filename = BACKEND_CHECKSUM.read_text(encoding="ascii").split()
        self.assertEqual(filename, "wall-in-one-backend")
        self.assertEqual(digest, hashlib.sha256(HELPER.read_bytes()).hexdigest())

    def run_internal(self, source: str, *arguments: Path) -> dict[str, object]:
        result = subprocess.run(
            [sys.executable, "-c", source, str(HELPER), *(str(path) for path in arguments)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )
        return json.loads(result.stdout)

    def test_directory_scan_retains_a_fixed_sorted_set_and_checks_liveness(self) -> None:
        directory = self.root / "library"
        directory.mkdir()
        expected = [f"item-{index:04d}.jpg" for index in range(1100)]
        for name in reversed(expected):
            (directory / name).touch()
        (directory / "unsafe\\name.jpg").touch()
        payload = self.run_internal(
            """
import json
import runpy
import sys

backend = runpy.run_path(sys.argv[1], run_name="wall_in_one_backend_bounds")
calls = [0]
def ensure_live():
    calls[0] += 1
names = backend["_backend_directory_names"](sys.argv[2], ensure_live)
print(json.dumps({"names": names, "calls": calls[0]}))
""",
            directory,
        )
        self.assertEqual(payload["names"], sorted(expected)[:1024])
        self.assertGreaterEqual(payload["calls"], 35)

    def test_preview_orphan_cleanup_streams_and_checks_liveness(self) -> None:
        cache = self.root / "provider-previews" / "v1"
        cache.mkdir(parents=True)
        for index in range(96):
            (cache / f"user-{index:04d}.png").write_bytes(b"keep")
        orphan = cache / "wallhaven-aa0000-1-1.png"
        orphan.write_bytes(fixture_png())
        payload = self.run_internal(
            """
import json
import runpy
import sys

backend = runpy.run_path(sys.argv[1], run_name="wall_in_one_backend_bounds")
calls = [0]
def ensure_live(_request):
    calls[0] += 1
cleanup = backend["_preview_cleanup_orphans"]
cleanup.__globals__["_backend_ensure_live"] = ensure_live
changed = cleanup({"cache_directory": sys.argv[2]}, {"entries": {}})
print(json.dumps({"changed": changed, "calls": calls[0]}))
""",
            cache,
        )
        self.assertTrue(payload["changed"])
        self.assertGreaterEqual(payload["calls"], 4)
        self.assertFalse(orphan.exists())
        self.assertEqual(len(list(cache.glob("user-*.png"))), 96)


class BackendLibraryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.transport = self.root / "transport"
        self.data = self.root / "data"
        self.images = self.root / "images"
        self.videos = self.root / "videos"
        self.workshops = self.root / "workshops"
        for directory in (
            self.transport,
            self.data,
            self.images,
            self.videos,
            self.workshops,
        ):
            directory.mkdir()

        self.wallhaven = self.images / "Wall-in-One" / "Wallhaven"
        self.automatic = self.images / "Wall-in-One" / "Automatic Stills"
        self.motionbgs = self.videos / "Wall-in-One" / "MotionBGS"
        for directory in (self.wallhaven, self.automatic, self.motionbgs):
            directory.mkdir(parents=True, exist_ok=True)

        self.local_still = self.images / "user.jpg"
        self.representative = self.images / "representative.png"
        self.local_video = self.videos / "user.mp4"
        self.local_still.write_bytes(b"jpeg-fixture")
        self.representative.write_bytes(b"png-fixture")
        self.local_video.write_bytes(b"video-fixture")

        self.wallhaven_file = self.wallhaven / "wallhaven-abc123.jpg"
        self.wallhaven_file.write_bytes(b"wallhaven-fixture")
        Path(str(self.wallhaven_file) + ".wallhaven.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "plugin": "goober/wall-in-one",
                    "provider": "Wallhaven",
                    "path": str(self.wallhaven_file),
                    "id": "abc123",
                    "source_page": "https://wallhaven.cc/w/abc123",
                    "bytes": self.wallhaven_file.stat().st_size,
                }
            ),
            encoding="utf-8",
        )

        self.automatic_file = self.automatic / "video-user-auto.png"
        self.automatic_file.write_bytes(b"automatic-fixture")
        Path(str(self.automatic_file) + ".wall-in-one.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "plugin": "goober/wall-in-one",
                    "kind": "automatic-still",
                    "path": str(self.automatic_file),
                    "provider": "video",
                    "dynamic_id": "video:" + str(self.local_video),
                }
            ),
            encoding="utf-8",
        )

        self.motion_file = self.motionbgs / "night-city.hd.mp4"
        self.motion_file.write_bytes(b"motion-fixture")
        Path(str(self.motion_file) + ".motionbgs.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "plugin": "goober/wall-in-one",
                    "provider": "MotionBGS",
                    "path": str(self.motion_file),
                    "source_page": "https://motionbgs.com/night-city",
                    "quality": "hd",
                    "bytes": self.motion_file.stat().st_size,
                }
            ),
            encoding="utf-8",
        )

        self.workshop = self.workshops / "4242"
        self.workshop.mkdir()
        self.project = self.workshop / "project.json"
        self.project.write_text(
            json.dumps(
                {
                    "title": "Fixture Workshop",
                    "type": "scene",
                    "preview": "preview.jpg",
                }
            ),
            encoding="utf-8",
        )
        (self.workshop / "preview.jpg").write_bytes(b"preview-fixture")

        still_info = self.representative.stat()
        video_info = self.local_video.stat()
        project_info = self.project.stat()
        self.runtime = self.data / "runtime.json"
        self.runtime.write_text(
            json.dumps(
                {
                    "schema_version": 6,
                    "pair_registry": {
                        "video:" + str(self.local_video): {
                            "dynamic_id": "video:" + str(self.local_video),
                            "still_path": str(self.representative),
                            "still_size": still_info.st_size,
                            "still_mtime": int(still_info.st_mtime),
                            "source_size": video_info.st_size,
                            "source_mtime": int(video_info.st_mtime),
                        },
                        "4242": {
                            "dynamic_id": "4242",
                            "still_path": str(self.representative),
                            "still_size": still_info.st_size,
                            "still_mtime": int(still_info.st_mtime),
                            "source_size": project_info.st_size,
                            "source_mtime": int(project_info.st_mtime),
                        },
                    },
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        self.runtime.chmod(0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def request(self, request_id: str) -> tuple[Path, Path, Path]:
        guard = self.transport / f".wall-in-one-backend-guard-{request_id}"
        guard.write_bytes(b"WIO-BACKEND-GUARD1\n")
        guard.chmod(0o600)
        request = self.transport / f"request-{request_id}.json"
        response = self.transport / f"response-{request_id}.json"
        request.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "request_id": request_id,
                    "action": "library.scan",
                    "transport_directory": str(self.transport),
                    "data_directory": str(self.data),
                    "guard_path": str(guard),
                    "operation_timeout_ms": 30_000,
                    "instance_id": "fixture-instance",
                    "image_root": str(self.images),
                    "video_root": str(self.videos),
                    "workshop_roots": [str(self.workshops)],
                    "wallhaven_directory": str(self.wallhaven),
                    "automatic_stills_directory": str(self.automatic),
                    "motionbgs_directory": str(self.motionbgs),
                    "runtime_path": str(self.runtime),
                },
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        request.chmod(0o600)
        return request, response, guard

    def invoke(
        self,
        request: Path,
        response: Path,
        guard: Path,
        *,
        check: bool = True,
        launcher: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = (
            [
                "bash",
                str(BACKEND_LAUNCHER),
                "rpc",
                str(HELPER),
                str(request),
                str(response),
                str(guard),
            ]
            if launcher
            else [
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
        )
        return subprocess.run(
            command,
            check=check,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=10,
        )

    def read_library(self, response: Path) -> tuple[dict[str, object], dict[str, list[dict[str, object]]]]:
        payload = json.loads(response.read_text(encoding="utf-8"))
        manifest = payload["library"]
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["page_size"], 12)
        rebuilt: dict[str, list[dict[str, object]]] = {}
        for section in ("stills", "videos", "workshops"):
            section_manifest = manifest["sections"][section]
            items: list[dict[str, object]] = []
            for expected_page, descriptor in enumerate(
                section_manifest["pages"], start=1
            ):
                page_path = Path(descriptor["path"])
                page_bytes = page_path.read_bytes()
                self.assertEqual(
                    set(descriptor), {"page", "path", "bytes", "count"}
                )
                self.assertEqual(descriptor["page"], expected_page)
                self.assertEqual(descriptor["bytes"], len(page_bytes))
                self.assertEqual(page_path.parent, self.transport)
                self.assertEqual(
                    page_path.name,
                    f".wall-in-one-library-{payload['request_id']}-{section}-{expected_page}.json",
                )
                page = json.loads(page_bytes.decode("utf-8"))
                self.assertEqual(
                    set(page),
                    {
                        "schema",
                        "request_id",
                        "action",
                        "section",
                        "page",
                        "total_pages",
                        "items",
                    },
                )
                self.assertEqual(page["request_id"], payload["request_id"])
                self.assertEqual(page["action"], "library.page")
                self.assertEqual(page["section"], section)
                self.assertEqual(page["page"], expected_page)
                self.assertEqual(page["total_pages"], len(section_manifest["pages"]))
                self.assertLessEqual(len(page["items"]), 12)
                self.assertEqual(descriptor["count"], len(page["items"]))
                items.extend(page["items"])
            self.assertEqual(section_manifest["count"], len(items))
            rebuilt[section] = items
        return payload, rebuilt

    def test_library_scan_preserves_inventory_and_pairing_contract(self) -> None:
        for index in range(13):
            (self.images / f"paging-{index:02d}.jpg").write_bytes(b"page-fixture")
        request, response, guard = self.request("library-1")
        result = self.invoke(request, response, guard, launcher=True)
        self.assertEqual(
            result.stdout.strip(),
            f"WIO-BACKEND-RPC1\tok\tlibrary-1\t{response}\t{response.stat().st_size}",
        )
        payload, rebuilt = self.read_library(response)
        self.assertEqual(
            {key: payload[key] for key in ("schema", "request_id", "action", "ok")},
            {
                "schema": 1,
                "request_id": "library-1",
                "action": "library.scan",
                "ok": True,
            },
        )
        stills = {entry["path"]: entry for entry in rebuilt["stills"]}
        videos = {entry["path"]: entry for entry in rebuilt["videos"]}
        workshops = {entry["id"]: entry for entry in rebuilt["workshops"]}
        self.assertIn(str(self.local_still), stills)
        self.assertEqual(stills[str(self.wallhaven_file)]["provider"], "Wallhaven")
        self.assertTrue(stills[str(self.wallhaven_file)]["deletable"])
        self.assertEqual(stills[str(self.automatic_file)]["dynamic_id"], "video:" + str(self.local_video))
        self.assertEqual(videos[str(self.motion_file)]["provider_id"], "night-city")
        self.assertEqual(videos[str(self.motion_file)]["quality"], "hd")
        self.assertEqual(videos[str(self.local_video)]["paired_preview"], str(self.representative))
        self.assertEqual(workshops["4242"]["paired_preview"], str(self.representative))
        self.assertEqual(workshops["4242"]["preview"], str(self.workshop / "preview.jpg"))
        self.assertEqual(
            next(
                entry["path"]
                for entry in rebuilt["stills"]
                if entry.get("provider_id") == "abc123"
            ),
            str(self.wallhaven_file),
        )
        self.assertEqual(
            next(
                entry["path"]
                for entry in rebuilt["videos"]
                if entry.get("provider_id") == "night-city"
                and entry.get("quality") == "hd"
            ),
            str(self.motion_file),
        )
        for entry in [*stills.values(), *videos.values()]:
            self.assertRegex(entry["id"], r"^(image|video):fixture-instance:[0-9a-f]{24}$")
        self.assertEqual(
            [item["name"].lower() for item in rebuilt["stills"]],
            sorted(item["name"].lower() for item in rebuilt["stills"]),
        )
        self.assertGreater(len(payload["library"]["sections"]["stills"]["pages"]), 1)

    def test_invalid_runtime_degrades_only_representative_index(self) -> None:
        self.runtime.write_text("{truncated", encoding="utf-8")
        request, response, guard = self.request("library-bad-runtime")
        self.invoke(request, response, guard)
        _payload, library = self.read_library(response)
        self.assertGreater(len(library["stills"]), 0)
        self.assertGreater(len(library["videos"]), 0)
        self.assertTrue(
            all(not entry.get("paired_preview") for entry in library["videos"])
        )
        self.assertTrue(
            all(not entry.get("paired_preview") for entry in library["workshops"])
        )

    def test_malformed_provider_sidecars_degrade_to_user_owned_entries(self) -> None:
        for sidecar in (
            Path(str(self.wallhaven_file) + ".wallhaven.json"),
            Path(str(self.motion_file) + ".motionbgs.json"),
        ):
            record = json.loads(sidecar.read_text(encoding="utf-8"))
            record["bytes"] = 0
            sidecar.write_text(json.dumps(record) + "\n", encoding="utf-8")
        request, response, guard = self.request("library-invalid-sidecars")
        self.invoke(request, response, guard)
        _payload, library = self.read_library(response)
        entries = {
            entry["path"]: entry
            for entry in [*library["stills"], *library["videos"]]
        }
        for media_path in (self.wallhaven_file, self.motion_file):
            entry = entries[str(media_path)]
            self.assertEqual(entry["provider"], "local")
            self.assertEqual(entry["ownership"], "user")
            self.assertFalse(entry["managed"])
            self.assertFalse(entry["deletable"])
            self.assertNotIn("provider_id", entry)

    def test_same_root_suppresses_gif_from_stills_and_response_is_no_replace(self) -> None:
        shared = self.root / "shared"
        shared.mkdir()
        animated = shared / "animated.gif"
        animated.write_bytes(b"gif-fixture")
        request, response, guard = self.request("library-shared")
        envelope = json.loads(request.read_text(encoding="utf-8"))
        envelope.update(
            image_root=str(shared),
            video_root=str(shared),
            wallhaven_directory=str(shared / "Wall-in-One" / "Wallhaven"),
            automatic_stills_directory=str(shared / "Wall-in-One" / "Automatic Stills"),
            motionbgs_directory=str(shared / "Wall-in-One" / "MotionBGS"),
        )
        request.write_text(json.dumps(envelope, separators=(",", ":")) + "\n", encoding="utf-8")
        request.chmod(0o600)
        self.invoke(request, response, guard)
        _payload, library = self.read_library(response)
        self.assertNotIn(str(animated), {entry["path"] for entry in library["stills"]})
        self.assertIn(str(animated), {entry["path"] for entry in library["videos"]})

        second_request, _unused, second_guard = self.request("library-conflict")
        sentinel = self.transport / "response-library-conflict.json"
        sentinel.write_text("sentinel\n", encoding="utf-8")
        result = self.invoke(second_request, sentinel, second_guard, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.startswith("WIO-BACKEND-RPC1\terror\tconflict\t"))
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "sentinel\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
