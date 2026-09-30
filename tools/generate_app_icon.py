#!/usr/bin/env python3
"""Recreate the opaque 1024px app icon from the widget's heart-circle motif.

Pillow is needed only to regenerate the PNG, not to build the iOS application.
"""
from pathlib import Path
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
SIZE = 1024
SCALE = 3
S = SIZE * SCALE

# An opaque plum field with a gentle top-left glow. iOS supplies the icon mask.
y, x = np.mgrid[0:S, 0:S].astype(np.float32)
glow = np.maximum(0, 1 - np.sqrt(((x - 460) / 3400) ** 2 + ((y - 260) / 2900) ** 2))
t = np.clip(y / S * 0.65 + x / S * 0.35, 0, 1)
rgb = np.empty((S, S, 3), dtype=np.uint8)
for channel, (top, bottom) in enumerate(zip((101, 75, 161), (48, 39, 111))):
    rgb[:, :, channel] = np.clip(top * (1 - t) + bottom * t + glow * (9 if channel != 1 else 2), 0, 255)
icon = Image.fromarray(rgb, "RGB").convert("RGBA")

def heart_points(cx, cy, size):
    points = []
    for i in range(721):
        a = 2 * math.pi * i / 720
        px = 16 * math.sin(a) ** 3
        py = 13 * math.cos(a) - 5 * math.cos(2 * a) - 2 * math.cos(3 * a) - math.cos(4 * a)
        points.append((round(cx + size * px / 17), round(cy - size * py / 17)))
    return points

cx, cy = S // 2, round(S * 0.50)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.ellipse((cx - 349 * SCALE, cy - 323 * SCALE, cx + 349 * SCALE, cy + 375 * SCALE), fill=(17, 9, 61, 91))
icon = Image.alpha_composite(icon, shadow.filter(ImageFilter.GaussianBlur(43 * SCALE)))

disc = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(disc)
d.ellipse((cx - 340 * SCALE, cy - 340 * SCALE, cx + 340 * SCALE, cy + 340 * SCALE), fill=(252, 247, 255, 255))
d.ellipse((cx - 307 * SCALE, cy - 307 * SCALE, cx + 307 * SCALE, cy + 307 * SCALE), fill=(242, 233, 255, 255))
icon = Image.alpha_composite(icon, disc)

# Two overlapping colors make one heart, like the shared canvas.
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).polygon(heart_points(cx, cy + 29 * SCALE, 250 * SCALE), fill=255)
color = np.empty((S, S, 4), dtype=np.uint8)
blend = np.clip((x / SCALE - 340) / 330, 0, 1)
for channel, (left, right) in enumerate(zip((244, 107, 124), (128, 103, 216))):
    color[:, :, channel] = left * (1 - blend) + right * blend
color[:, :, 3] = np.asarray(mask)
heart = Image.fromarray(color, "RGBA")
icon = Image.alpha_composite(icon, heart)

# A small brush highlight keeps the shape legible when reduced on the Home Screen.
highlight = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(highlight)
hd.arc((cx - 177 * SCALE, cy - 143 * SCALE, cx - 48 * SCALE, cy - 14 * SCALE), 188, 277, fill=(255, 237, 242, 175), width=17 * SCALE)
icon = Image.alpha_composite(icon, highlight)

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
icon.convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(OUTPUT, optimize=True)
print(OUTPUT)
