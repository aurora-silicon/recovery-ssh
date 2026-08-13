#!/usr/bin/env python3
"""Minimal token-scoped installer server for non-macOS controllers."""

from __future__ import annotations

import http.server
import pathlib
import signal
import sys


def usage() -> "NoReturn":
    print(
        f"usage: {sys.argv[0]} BIND_ADDRESS PORT URL_PATH FILE "
        "[SHORT_INSTALLER_URL]",
        file=sys.stderr,
    )
    raise SystemExit(2)


if len(sys.argv) not in (5, 6):
    usage()

bind_address = sys.argv[1]
try:
    port = int(sys.argv[2])
except ValueError:
    usage()
if not 1 <= port <= 65535:
    usage()

url_path = sys.argv[3]
if not url_path.startswith("/"):
    usage()
installer_path = pathlib.Path(sys.argv[4])
short_installer_url = sys.argv[5] if len(sys.argv) == 6 else None


class InstallerHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        print(format % args, file=sys.stderr)

    def send_payload(self, payload: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Connection", "close")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        self.close_connection = True

    def do_GET(self) -> None:
        if self.path == "/r" and short_installer_url is not None:
            print("Recovery bootstrap requested", file=sys.stderr)
            payload = (
                "#!/bin/sh\n"
                "set -e\n"
                'installer="${TMPDIR:-/tmp}/recovery-ssh-install"\n'
                f"/usr/bin/curl -fL '{short_installer_url}' -o \"$installer\"\n"
                'exec /bin/sh "$installer"\n'
            ).encode()
            self.send_payload(payload, "text/x-shellscript")
            return

        if self.path != url_path:
            self.send_error(404, "Not Found")
            return

        try:
            payload = installer_path.read_bytes()
        except (OSError, ValueError):
            self.send_error(404, "Not Found")
            return
        print("Recovery installer requested", file=sys.stderr)
        self.send_payload(payload, "application/octet-stream")


server = http.server.HTTPServer((bind_address, port), InstallerHandler)


def stop_server(_signal_number: int, _frame: object) -> None:
    raise KeyboardInterrupt


signal.signal(signal.SIGINT, stop_server)
signal.signal(signal.SIGTERM, stop_server)
print(f"Serving {installer_path} at http://{bind_address}:{port}{url_path}", file=sys.stderr)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
