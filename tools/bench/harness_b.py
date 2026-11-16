#!/usr/bin/env python3
"""Harness B: glass-to-glass latency from a high-speed video (docs/video.md §2).

Film the Mac's own screen and the Duo side by side, in slow motion (240 fps), while Clamshell Host shows its
flash square ("Flash square for 240 fps filming (harness B)" in the menu, or CLAMSHELL_FLASH=1). The
square flips black/white on both screens every 400-500 ms. The script finds the two squares by themselves
(the two blobs that flip between two levels), times every flip on each one with sub-frame interpolation,
and reports how far the Duo trails the Mac.

    python3 tools/bench/harness_b.py clip.mov [--fps 240] [--mac x,y,w,h --phone x,y,w,h] [--start 1 --duration 20]

Regions are fractions of the frame (0..1), for when automatic detection picks the wrong thing. Keep the
camera still (prop it up) and keep both screens otherwise still while filming. Only needs ffmpeg/ffprobe.
"""
from __future__ import annotations

import argparse
import json
import shutil
import statistics
import subprocess
import sys

GRID_W, GRID_H = 96, 54
MAX_LAG_S = 0.35            # a phone flip more than this after a Mac flip isn't its echo


def probe_fps(path: str) -> float | None:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=r_frame_rate,avg_frame_rate", "-of", "json", path],
                         capture_output=True, text=True, check=False)
    try:
        s = json.loads(out.stdout)["streams"][0]
    except (ValueError, KeyError, IndexError):
        return None
    for key in ("r_frame_rate", "avg_frame_rate"):
        num, _, den = s.get(key, "0/0").partition("/")
        try:
            v = float(num) / float(den or 1)
        except (ValueError, ZeroDivisionError):
            continue
        if v > 0:
            return v
    return None


def read_frames(path: str, start: float, duration: float | None) -> list[bytes]:
    cmd = ["ffmpeg", "-v", "error", "-ss", str(start), "-i", path]
    if duration:
        cmd += ["-t", str(duration)]
    cmd += ["-fps_mode", "passthrough", "-vf", f"scale={GRID_W}:{GRID_H}:flags=area,format=gray",
            "-f", "rawvideo", "-"]
    data = subprocess.run(cmd, capture_output=True, check=True).stdout
    n = GRID_W * GRID_H
    return [data[i:i + n] for i in range(0, len(data) - n + 1, n)]


def flipping_mask(frames: list[bytes]) -> list[bool]:
    """Pixels that spend real time at both a dark and a bright level (a flash square, not noise or motion)."""
    n = GRID_W * GRID_H
    lo, hi = [255] * n, [0] * n
    for f in frames:
        for i, v in enumerate(f):
            if v < lo[i]:
                lo[i] = v
            if v > hi[i]:
                hi[i] = v
    dark, bright = [0] * n, [0] * n
    for f in frames:
        for i, v in enumerate(f):
            r = hi[i] - lo[i]
            if r < 60:
                continue
            if v < lo[i] + r // 4:
                dark[i] += 1
            elif v > hi[i] - r // 4:
                bright[i] += 1
    t = len(frames)
    return [dark[i] > 0.2 * t and bright[i] > 0.2 * t for i in range(n)]


def blobs(mask: list[bool]) -> list[list[int]]:
    seen, out = [False] * len(mask), []
    for start, on in enumerate(mask):
        if not on or seen[start]:
            continue
        stack, blob = [start], []
        seen[start] = True
        while stack:
            i = stack.pop()
            blob.append(i)
            x, y = i % GRID_W, i // GRID_W
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                j = ny * GRID_W + nx
                if 0 <= nx < GRID_W and 0 <= ny < GRID_H and mask[j] and not seen[j]:
                    seen[j] = True
                    stack.append(j)
        out.append(blob)
    return sorted(out, key=len, reverse=True)


def region_pixels(spec: str) -> list[int]:
    x, y, w, h = (float(v) for v in spec.split(","))
    x0, y0 = int(x * GRID_W), int(y * GRID_H)
    x1, y1 = max(x0 + 1, int((x + w) * GRID_W)), max(y0 + 1, int((y + h) * GRID_H))
    return [yy * GRID_W + xx for yy in range(y0, min(y1, GRID_H)) for xx in range(x0, min(x1, GRID_W))]


def describe(pixels: list[int]) -> str:
    xs, ys = [i % GRID_W for i in pixels], [i // GRID_W for i in pixels]
    return (f"x {min(xs) / GRID_W:.2f}-{(max(xs) + 1) / GRID_W:.2f}, "
            f"y {min(ys) / GRID_H:.2f}-{(max(ys) + 1) / GRID_H:.2f} ({len(pixels)} cells)")


def edges(series: list[float]) -> list[tuple[float, bool]]:
    """(frame position with sub-frame interpolation, rising?) for every threshold crossing."""
    s = sorted(series)
    lo, hi = s[len(s) // 20], s[-(len(s) // 20) - 1]
    thr = (lo + hi) / 2
    out = []
    for i in range(1, len(series)):
        a, b = series[i - 1], series[i]
        if (a < thr) != (b < thr):
            out.append((i - 1 + (thr - a) / (b - a), b > a))
    return out


def match(lead: list[tuple[float, bool]], trail: list[tuple[float, bool]], fps: float) -> list[float]:
    lags, j = [], 0
    for t, rising in lead:
        while j < len(trail) and trail[j][0] < t:
            j += 1
        for k in range(j, len(trail)):
            dt = (trail[k][0] - t) / fps
            if dt > MAX_LAG_S:
                break
            if trail[k][1] == rising:
                lags.append(dt * 1000)
                break
    return lags


def pct(values: list[float], p: float) -> float:
    s = sorted(values)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("--fps", type=float, help="capture frame rate (default: from the file)")
    ap.add_argument("--mac", help="Mac square region x,y,w,h as fractions")
    ap.add_argument("--phone", help="Duo square region x,y,w,h as fractions")
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--duration", type=float)
    a = ap.parse_args()
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        print("needs ffmpeg and ffprobe on PATH (brew install ffmpeg)")
        return 2
    fps = a.fps or probe_fps(a.video)
    if not fps:
        print("could not read the frame rate; pass --fps")
        return 2
    frames = read_frames(a.video, a.start, a.duration)
    print(f"# harness B — {a.video}: {len(frames)} frames at {fps:g} fps ({len(frames) / fps:.1f} s), "
          f"one frame = {1000 / fps:.2f} ms")
    if fps < 200:
        print(f"warning: {fps:g} fps is coarse for a 50 ms budget; if this is a slow-motion clip that plays back "
              "at 30 fps, pass its capture rate with --fps 240")
    if len(frames) < fps:
        print("clip too short: film at least 10 s")
        return 1

    if a.mac and a.phone:
        regions = [region_pixels(a.mac), region_pixels(a.phone)]
        named = True
    else:
        found = [b for b in blobs(flipping_mask(frames)) if len(b) >= 4]
        if len(found) < 2:
            print(f"found {len(found)} flashing region(s), need 2. Is the flash square on, are both screens in shot "
                  "and the camera still? Or pass --mac/--phone.")
            return 1
        regions = found[:2]
        named = False

    series = [[sum(f[i] for i in r) / len(r) for f in frames] for r in regions]
    e = [edges(s) for s in series]
    ab, ba = match(e[0], e[1], fps), match(e[1], e[0], fps)
    if named or len(ab) >= len(ba):
        mac, phone, lags = 0, 1, ab
    else:
        mac, phone, lags = 1, 0, ba
    print(f"Mac square:   {describe(regions[mac])}, {len(e[mac])} flips")
    print(f"Duo square:   {describe(regions[phone])}, {len(e[phone])} flips")
    if not lags:
        print("no Duo flip follows a Mac flip within 350 ms; check the regions")
        return 1
    print(f"matched flips: {len(lags)} of {len(e[mac])}")
    print(f"glass-to-glass ms: p50 {pct(lags, 50):.1f} · p95 {pct(lags, 95):.1f} · min {min(lags):.1f} · "
          f"max {max(lags):.1f} · mean {statistics.fmean(lags):.1f}")
    print(f"(± {1000 / fps / 2:.1f} ms camera quantisation, and the Mac-side reference may lead its own panel by up "
          "to one refresh, so the true figure can be ~0-8 ms higher)")
    p50 = pct(lags, 50)
    print(f"M1 exit criterion (LAN p50 ≤ 50 ms): {'PASS' if p50 <= 50 else 'FAIL'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
