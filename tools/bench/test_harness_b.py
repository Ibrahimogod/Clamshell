#!/usr/bin/env python3
"""Self-test for harness_b.py: renders a synthetic 240 fps clip (camera noise, a distracting static
background, a Mac square and a Duo square that follows it 37.5 ms later) and checks the measured lag.

    python3 tools/bench/test_harness_b.py
"""
from __future__ import annotations

import os
import random
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
W, H, FPS = 320, 180, 240
LAG_FRAMES = 9                      # 37.5 ms at 240 fps


def render(path: str, seconds: float = 12, lag_frames: int = LAG_FRAMES) -> None:
    rng = random.Random(7)
    flips, t = [], 0
    while t < seconds * FPS:        # Mac flips every 96-120 frames (400-500 ms)
        t += rng.randint(96, 120)
        flips.append(t)
    background = bytes(rng.randint(40, 200) for _ in range(W * H))
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{W}x{H}",
                             "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-qp", "10", "-pix_fmt", "yuv420p", path],
                            stdin=subprocess.PIPE)
    assert proc.stdin
    for f in range(int(seconds * FPS)):
        mac_white = sum(1 for x in flips if x <= f) % 2 == 1
        duo_white = sum(1 for x in flips if x + lag_frames <= f) % 2 == 1
        frame = bytearray(background)
        for (x0, y0, white) in ((30, 30, mac_white), (220, 90, duo_white)):
            v = 235 if white else 20
            for y in range(y0, y0 + 40):
                frame[y * W + x0:y * W + x0 + 40] = bytes([v]) * 40
        for _ in range(200):                                   # sensor noise
            i = rng.randrange(W * H)
            frame[i] = max(0, min(255, frame[i] + rng.randint(-15, 15)))
        proc.stdin.write(frame)
    proc.stdin.close()
    assert proc.wait() == 0


class HarnessBTest(unittest.TestCase):
    def test_measures_known_lag(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            clip = os.path.join(d, "clip.mp4")
            render(clip)
            out = subprocess.run([sys.executable, os.path.join(HERE, "harness_b.py"), clip],
                                 capture_output=True, text=True, check=True).stdout
            print(out)
            m = re.search(r"p50 ([\d.]+)", out)
            self.assertIsNotNone(m, out)
            assert m
            self.assertAlmostEqual(float(m.group(1)), LAG_FRAMES * 1000 / FPS, delta=1000 / FPS)
            self.assertIn("x 0.09", out.split("Mac square:")[1].splitlines()[0])   # the leading square is the Mac
            self.assertIn("PASS", out)


if __name__ == "__main__":
    unittest.main()
