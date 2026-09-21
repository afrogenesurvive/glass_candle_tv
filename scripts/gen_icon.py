#!/usr/bin/env python3
"""
Generate the black_glass_candle app icon.

    gen_icon.py [output.icns]

Two stages, both dependency-free:

  1. Draw the artwork and write a PNG using only zlib + struct. No Pillow, no
     cairo. Anti-aliasing is done by 2x2 supersampling per pixel.
  2. Wrap that PNG into an .icns container.

The ICNS container is written directly rather than via `iconutil`, because
`iconutil` no longer converts iconset directories to .icns on macOS 26+ (the
same reason DS-mon's build takes this route). `sips` does the resizing and the
resized PNGs are embedded as-is.

Note this is only the Finder/app-bundle icon. The menu bar item is drawn at
runtime in StatusBar/StatusBarView.swift and does not use this file.
"""

import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib

# -----------------------------------------------------------------------------
# Palette — "black glass": near-black ground, warm candle.
# -----------------------------------------------------------------------------
BG_INNER = (0x1C, 0x1F, 0x27)
BG_OUTER = (0x0B, 0x0C, 0x10)
GLASS_EDGE = (0x3A, 0x40, 0x4E)
WAX_LIGHT = (0xF2, 0xEC, 0xDD)
WAX_DARK = (0xC9, 0xBE, 0xA6)
WICK = (0x2A, 0x22, 0x1C)
FLAME_CORE = (0xFF, 0xF0, 0xC0)
FLAME_MID = (0xFF, 0xC4, 0x5C)
FLAME_EDGE = (0xF0, 0x7A, 0x25)
GLOW = (0xFF, 0xB0, 0x50)


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def rounded_rect(x, y, x0, y0, x1, y1, r):
    """Point-in-rounded-rectangle. Clamping to the inner rect gives the signed
    distance to the corner circles, which is all that is needed here."""
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= r * r


def flame_shape(x, y, cx, y_base, y_tip, r_base):
    """Teardrop: a circular base tapering to a point.

    The base is a true circle so the flame reads as lit rather than clipped;
    above it the half-width decays as (1-t)**0.75, which is blunt near the
    bottom and needle-sharp at the tip.
    """
    if y < y_base or y > y_tip:
        return False
    if y <= y_base + r_base:
        cy = y_base + r_base
        return (x - cx) ** 2 + (y - cy) ** 2 <= r_base ** 2
    span = y_tip - (y_base + r_base)
    if span <= 0:
        return False
    t = (y - (y_base + r_base)) / span
    return abs(x - cx) <= r_base * (1.0 - t) ** 0.75


def sample(px, py, size):
    """Return (r, g, b, a) floats for a point in a size x size square, y-up."""
    s = size
    u = px / s          # 0..1
    v = py / s          # 0..1, y-up
    cx = 0.5

    # ---- geometry (all in 0..1 units) -------------------------------------
    plate = (0.055, 0.055, 0.945, 0.945)   # x0, y0, x1, y1
    plate_r = 0.215

    body_w = 0.235
    body_bot = 0.180
    body_top = 0.600
    body_r = 0.045

    wick_bot = body_top - 0.015
    wick_top = body_top + 0.055

    flame_base = wick_top - 0.012
    flame_tip = 0.895
    flame_r = 0.088

    # ---- glow (drawn first, behind everything) ----------------------------
    glow_cy = flame_base + 0.13
    gd = math.hypot(u - cx, (v - glow_cy) * 1.06)
    glow_a = max(0.0, 1.0 - gd / 0.44) ** 2.3 * 0.55

    # ---- background plate -------------------------------------------------
    inside_plate = rounded_rect(u, v, plate[0], plate[1], plate[2], plate[3], plate_r)

    if not inside_plate:
        # Outside the plate: keep the glow, drop the rest. Gives the icon a soft
        # halo instead of a hard square edge.
        if glow_a > 0.004:
            return (*GLOW, glow_a)
        return (0.0, 0.0, 0.0, 0.0)

    # Plate fill: radial-ish gradient, brighter towards the flame.
    rad = math.hypot((u - cx) / 0.72, (v - 0.52) / 0.72)
    base = lerp(BG_INNER, BG_OUTER, rad)
    col = lerp(base, GLOW, glow_a * 0.55)
    alpha = 1.0

    # Plate edge: a thin glass rim.
    edge_d = min(u - plate[0], plate[2] - u, v - plate[1], plate[3] - v)
    if edge_d < 0.008:
        col = lerp(col, GLASS_EDGE, 0.75)

    # ---- flame ------------------------------------------------------------
    if flame_shape(u, v, cx, flame_base, flame_tip, flame_r):
        t = (v - flame_base) / max(1e-6, flame_tip - flame_base)
        # Hotter and paler towards the bottom, orange at the tip.
        if t < 0.5:
            fc = lerp(FLAME_CORE, FLAME_MID, t / 0.5)
        else:
            fc = lerp(FLAME_MID, FLAME_EDGE, (t - 0.5) / 0.5)
        col = fc
    else:
        # Soft glow bleed around the flame, drawn over the plate.
        if flame_base - 0.06 <= v <= flame_tip + 0.06:
            fd = abs(u - cx) + abs(v - (flame_base + 0.16)) * 0.55
            bleed = max(0.0, 1.0 - fd / 0.30) ** 2.6 * 0.5
            if bleed > 0.003:
                col = lerp(col, GLOW, bleed)

    # ---- wick -------------------------------------------------------------
    if wick_bot <= v <= wick_top and abs(u - cx) <= 0.011:
        col = WICK

    # ---- candle body ------------------------------------------------------
    half = body_w / 2
    if rounded_rect(u, v, cx - half, body_bot, cx + half, body_top, body_r):
        # Vertical wax gradient with a specular band for the "glass" feel.
        t = (v - body_bot) / (body_top - body_bot)
        col = lerp(WAX_DARK, WAX_LIGHT, t)
        spec = max(0.0, 1.0 - abs(u - (cx - 0.055)) / 0.035) * 0.5
        col = lerp(col, (255, 255, 255), spec * (0.35 + 0.65 * (1 - t)))

    return (*col, alpha)


def render(size):
    """Render to a list of RGBA bytes."""
    supersample = 2
    offsets = [(i + 0.5) / supersample for i in range(supersample)]
    inv = 1.0 / (supersample * supersample)

    rows = []
    for y in range(size):
        row = bytearray()
        # Output row y counts from the TOP; `sample` works in a y-up space.
        # Pixel row y spans [size-y-1, size-y], so the sub-sample offset adds.
        for x in range(size):
            r = g = b = a = 0.0
            for oy in offsets:
                for ox in offsets:
                    sr, sg, sb, sa = sample(x + ox, size - y - 1 + oy, size)
                    r += sr * sa
                    g += sg * sa
                    b += sb * sa
                    a += sa
            r *= inv
            g *= inv
            b *= inv
            a *= inv
            # Un-premultiply so partially covered edge pixels keep their colour.
            if a > 1e-6:
                r, g, b = r / a, g / a, b / a
            # NOTE: sample() returns colour channels already in 0..255 (so the
            # palette constants above stay readable); only alpha is 0..1.
            row += bytes((
                max(0, min(255, int(r + 0.5))),
                max(0, min(255, int(g + 0.5))),
                max(0, min(255, int(b + 0.5))),
                max(0, min(255, int(a * 255 + 0.5))),
            ))
        rows.append(row)
    return rows


def write_png(path, width, height, rows):
    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = b''.join(b'\x00' + bytes(row) for row in rows)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(raw, 9))
    png += chunk(b'IEND', b'')
    with open(path, 'wb') as fh:
        fh.write(png)


def build_icns(source_png, output_icns):
    sizes = [
        (16, b'ic04'), (32, b'ic05'), (128, b'ic07'),
        (256, b'ic08'), (512, b'ic09'), (1024, b'ic10'),
    ]
    tmpdir = tempfile.mkdtemp(prefix='bgc_icns_')
    try:
        entries = []
        for size, icon_type in sizes:
            out = os.path.join(tmpdir, f'icon_{size}.png')
            subprocess.run(
                ['sips', '-z', str(size), str(size), source_png, '--out', out],
                capture_output=True, check=True,
            )
            with open(out, 'rb') as fh:
                entries.append((icon_type, fh.read()))

        total = 8 + sum(8 + len(data) for _, data in entries)
        with open(output_icns, 'wb') as fh:
            fh.write(b'icns')
            fh.write(struct.pack('>I', total))
            for icon_type, data in entries:
                fh.write(icon_type)
                fh.write(struct.pack('>I', 8 + len(data)))
                fh.write(data)
    finally:
        for name in os.listdir(tmpdir):
            os.remove(os.path.join(tmpdir, name))
        os.rmdir(tmpdir)


def main():
    out_icns = sys.argv[1] if len(sys.argv) > 1 else 'AppIcon.icns'
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.dirname(os.path.abspath(out_icns))
    os.makedirs(out_dir, exist_ok=True)

    size = 512
    print(f'==> drawing icon ({size}x{size}, 2x2 supersampled)')
    rows = render(size)

    png_path = os.path.join(out_dir, 'AppIcon-src.png')
    write_png(png_path, size, size, rows)
    print(f'    wrote {png_path} ({os.path.getsize(png_path)} bytes)')

    if sys.platform == 'darwin':
        print('==> building .icns')
        build_icns(png_path, out_icns)
        print(f'    wrote {out_icns} ({os.path.getsize(out_icns)} bytes)')
    else:
        print('    skipping .icns (not macOS)')

    return 0


if __name__ == '__main__':
    sys.exit(main())
