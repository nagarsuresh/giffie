#!/usr/bin/env python3
"""Renders Resources/AppIcon.icns (and a 1024 px PNG preview) with Pillow.

Usage: python3 scripts/make-icon.py
Needs Pillow and a bold sans-serif TrueType font (DejaVu Sans Bold or Liberation Sans Bold).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE = 1024
FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def render():
    scale = 4  # supersample for smooth edges
    s = SIZE * scale
    margin = int(s * 0.098)  # macOS icon grid: ~100 px margin at 1024
    body = s - 2 * margin
    radius = int(body * 0.225)

    # Diagonal gradient: violet -> pink -> orange.
    stops = [(0.0, (94, 63, 228)), (0.55, (236, 72, 153)), (1.0, (255, 149, 64))]
    small = 256  # a smooth gradient can be rendered small and scaled up
    gradient = Image.new("RGB", (small, small))
    px = gradient.load()
    for y in range(small):
        for x in range(small):
            t = (x * 0.45 + y * 0.55) / small
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t <= t1:
                    px[x, y] = lerp(c0, c1, (t - t0) / (t1 - t0))
                    break
            else:
                px[x, y] = stops[-1][1]
    gradient = gradient.resize((body, body), Image.BICUBIC)

    mask = Image.new("L", (body, body), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    # Soft drop shadow.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [margin, margin + int(s * 0.012), margin + body, margin + body + int(s * 0.012)], radius=radius,
        fill=(0, 0, 0, 90))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s * 0.012)))
    canvas.paste(gradient, (margin, margin), mask)

    draw = ImageDraw.Draw(canvas)
    white = (255, 255, 255, 255)

    # Viewfinder corner brackets.
    inset = margin + int(body * 0.17)
    far = margin + body - int(body * 0.17)
    arm = int(body * 0.17)
    width = int(body * 0.055)
    for (cx, cy, dx, dy) in [(inset, inset, 1, 1), (far, inset, -1, 1), (inset, far, 1, -1), (far, far, -1, -1)]:
        draw.rounded_rectangle(sorted_box(cx, cy, cx + dx * arm, cy + dy * width), radius=width // 2, fill=white)
        draw.rounded_rectangle(sorted_box(cx, cy, cx + dx * width, cy + dy * arm), radius=width // 2, fill=white)

    # "GIF" wordmark.
    font_path = next((p for p in FONT_CANDIDATES if os.path.exists(p)), None)
    if font_path is None:
        sys.exit("No bold TrueType font found; edit FONT_CANDIDATES.")
    font = ImageFont.truetype(font_path, int(body * 0.27))
    text = "GIF"
    box = draw.textbbox((0, 0), text, font=font)
    tw, th = box[2] - box[0], box[3] - box[1]
    tx = margin + (body - tw) // 2 - box[0]
    ty = margin + (body - th) // 2 - box[1] - int(body * 0.03)
    draw.text((tx, ty), text, font=font, fill=white)

    # Record dot under the wordmark.
    r = int(body * 0.045)
    cx, cy = margin + body // 2, ty + box[3] + int(body * 0.11)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 59, 48, 255), outline=white, width=int(r * 0.35))

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


def sorted_box(x0, y0, x1, y1):
    return [min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1)]


def main():
    icon = render()
    resources = os.path.join(ROOT, "Resources")
    os.makedirs(resources, exist_ok=True)
    icon.save(os.path.join(resources, "AppIcon.png"))
    icon.save(os.path.join(resources, "AppIcon.icns"),
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")


if __name__ == "__main__":
    main()
