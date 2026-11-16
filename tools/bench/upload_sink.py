#!/usr/bin/env python3
"""Self-hosted upload sink for `clamshell-bench upload --to host:port`.

Run this on your VPS (or any machine outside your home network), then run the bench on the Mac at home. It
accepts one TCP connection at a time, reads and discards everything, and prints the received rate each
second plus a summary that leaves out the first (slow-start) second. Nothing is stored or forwarded.

    python3 tools/bench/upload_sink.py --port 9443 [--bind 0.0.0.0] [--max-seconds 60]

Open the port only while testing (e.g. `sudo ufw allow 9443/tcp`, then `sudo ufw delete allow 9443/tcp`).
Standard library only.
"""
from __future__ import annotations

import argparse
import socket
import sys
import time


def serve_one(conn: socket.socket, peer: tuple, max_seconds: float) -> None:
    conn.settimeout(5)
    start = last = time.monotonic()
    total = since_last = 0
    per_second: list[float] = []
    buf = bytearray(1 << 20)
    print(f"connection from {peer[0]}:{peer[1]}")
    try:
        while True:
            n = conn.recv_into(buf)
            if n == 0:
                break
            total += n
            since_last += n
            now = time.monotonic()
            if now - last >= 1:
                mbps = since_last * 8 / (now - last) / 1e6
                per_second.append(mbps)
                print(f"  {now - start:5.1f} s  {mbps:7.1f} Mbit/s", flush=True)
                since_last, last = 0, now
            if now - start > max_seconds:
                print("  max duration reached, closing")
                break
    except socket.timeout:
        print("  idle for 5 s, closing")
    finally:
        conn.close()
    elapsed = time.monotonic() - start
    steady = per_second[1:] or per_second
    if steady:
        steady_mean = sum(steady) / len(steady)
        print(f"received {total / 1e6:.1f} MB in {elapsed:.1f} s · steady-state upload {steady_mean:.1f} Mbit/s "
              f"(first second excluded) · remote video budget ≈ 60% → {steady_mean * 0.6:.1f} Mbit/s (ADR-0008)")
    else:
        print(f"received {total} bytes in {elapsed:.1f} s (too short to measure)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=9443)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--max-seconds", type=float, default=60)
    ap.add_argument("--once", action="store_true", help="exit after the first connection")
    a = ap.parse_args()
    with socket.create_server((a.bind, a.port), reuse_port=False) as srv:
        print(f"upload sink listening on {a.bind}:{a.port} — Ctrl-C to stop")
        while True:
            try:
                conn, peer = srv.accept()
            except KeyboardInterrupt:
                print()
                return 0
            serve_one(conn, peer, a.max_seconds)
            if a.once:
                return 0


if __name__ == "__main__":
    sys.exit(main())
