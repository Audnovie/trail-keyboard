#!/usr/bin/env python3
"""Draws the app icon: a swipe trail across three key caps. python3 tools/make_icon.py"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'App', 'Assets.xcassets', 'AppIcon.appiconset', 'icon-1024.png')
S = 1024
img = Image.new('RGB', (S, S))
px = img.load()
for y in range(S):
    t = y / S
    r = int(24 + 20 * t)
    g = int(58 + 40 * t)
    b = int(140 + 60 * t)
    for x in range(S):
        px[x, y] = (r, g, b)
d = ImageDraw.Draw(img, 'RGBA')
# Three key caps.
keys = [(170, 560), (430, 360), (690, 560)]
for (x, y) in keys:
    d.rounded_rectangle([x, y, x + 170, y + 190], radius=34, fill=(255, 255, 255, 38))
# The trail: a smooth curve through the caps, fading in.
pts = []
for i in range(201):
    t = i / 200
    x = 140 + 760 * t
    y = 700 - 330 * math.sin(math.pi * t) * (0.9 + 0.1 * math.cos(3 * math.pi * t))
    pts.append((x, y))
layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
ld = ImageDraw.Draw(layer)
for i in range(1, len(pts)):
    a = int(90 + 165 * i / len(pts))
    w = int(34 + 30 * i / len(pts))
    ld.line([pts[i - 1], pts[i]], fill=(255, 255, 255, a), width=w)
    ld.ellipse([pts[i][0] - w / 2, pts[i][1] - w / 2, pts[i][0] + w / 2, pts[i][1] + w / 2], fill=(255, 255, 255, a))
layer = layer.filter(ImageFilter.GaussianBlur(1.2))
img.paste(layer, (0, 0), layer)
d = ImageDraw.Draw(img, 'RGBA')
ex, ey = pts[-1]
d.ellipse([ex - 45, ey - 45, ex + 45, ey + 45], fill=(255, 214, 102, 255))
img.save(OUT)
print('wrote', os.path.relpath(OUT, ROOT))
