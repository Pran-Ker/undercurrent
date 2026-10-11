# The app icon: a slate gradient with a thin white undercurrent line. Writes every size the
# asset catalog lists. Run: python3 scripts/make_icon.py
import math, os, sys
from PIL import Image, ImageDraw

root = os.path.join(os.path.dirname(__file__), "..", "Sources", "Undercurrent", "Assets.xcassets", "AppIcon.appiconset")
sizes = [20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]

def render(n):
    S = 1024
    img = Image.new("RGB", (S, S))
    px = img.load()
    top, bottom = (0x9A, 0xAE, 0xB5), (0x23, 0x31, 0x37)
    for y in range(S):
        t = y / (S - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(S):
            px[x, y] = c
    d = ImageDraw.Draw(img)
    # Two sine lines: the current and its undercurrent.
    for (amp, phase, width, col) in [(70, 0.0, 22, (0xF9, 0xFB, 0xFB)), (46, math.pi, 12, (0xCD, 0xDB, 0xE1))]:
        pts = []
        for x in range(120, S - 120):
            y = S * 0.55 + amp * math.sin((x - 120) / (S - 240) * 2 * math.pi + phase)
            pts.append((x, y))
        d.line(pts, fill=col, width=width, joint="curve")
    return img.resize((n, n), Image.LANCZOS)

for n in sizes:
    render(n).save(os.path.join(root, f"Icon-{n}.png"))
print("icons written")
