#!/usr/bin/env python3
"""Generates src/TextFix/assets/textfix.ico.

Kept in the repo so the icon is reproducible rather than a binary someone has to trust. Draws a
rounded square with a check mark, supersampled 8x and downsampled per size so the 16 px tray icon
stays legible instead of being a shrunken version of the 256 px art.

The ICO is written by hand: BMP (DIB) entries for every size below 256 and a PNG entry for 256,
which is the combination Windows has handled reliably since Vista. Requires Pillow.

    python tools/make-icon.py
"""

import io
import os
import struct

from PIL import Image, ImageDraw

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
SUPERSAMPLE = 8

BACKGROUND = (58, 54, 196, 255)      # indigo, dark enough for a white glyph at 16 px
BACKGROUND_EDGE = (40, 37, 150, 255)  # a hair darker, so the tile has an edge on a dark taskbar
GLYPH = (255, 255, 255, 255)


def draw_master(size: int, with_text_lines: bool) -> Image.Image:
    """Draws one icon at `size`, rendered at SUPERSAMPLE times that and reduced."""
    scale = size * SUPERSAMPLE
    image = Image.new("RGBA", (scale, scale), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # Rounded tile, inset slightly so the corners are not clipped by the icon bounds.
    inset = scale * 0.03
    radius = scale * 0.22
    draw.rounded_rectangle(
        [inset, inset, scale - inset, scale - inset],
        radius=radius,
        fill=BACKGROUND,
        outline=BACKGROUND_EDGE,
        width=max(1, int(scale * 0.02)),
    )

    if with_text_lines:
        # Two short lines that read as text behind the check. Only drawn at sizes with room for
        # them; below 48 px they turn into grey mush and hurt legibility.
        line_width = scale * 0.075
        for index, (x_end, y) in enumerate(((0.62, 0.30), (0.50, 0.46))):
            draw.line(
                [(scale * 0.22, scale * y), (scale * x_end, scale * y)],
                fill=(255, 255, 255, 110),
                width=int(line_width),
            )
        del index

    # The check mark: three points, stroked with rounded joints.
    stroke = scale * (0.115 if size >= 32 else 0.135)
    points = [
        (scale * 0.26, scale * 0.60),
        (scale * 0.44, scale * 0.77),
        (scale * 0.76, scale * 0.31),
    ]
    draw.line(points, fill=GLYPH, width=int(stroke), joint="curve")
    # joint="curve" rounds the corner but leaves the two ends square; discs cap them.
    for point in (points[0], points[2]):
        draw.ellipse(
            [point[0] - stroke / 2, point[1] - stroke / 2, point[0] + stroke / 2, point[1] + stroke / 2],
            fill=GLYPH,
        )

    return image.resize((size, size), Image.LANCZOS)


def bmp_entry(image: Image.Image) -> bytes:
    """A 32-bit BGRA DIB plus the empty AND mask an ICO entry expects."""
    width, height = image.size
    header = struct.pack(
        "<IiiHHIIiiII",
        40,             # biSize
        width,
        height * 2,     # colour data plus mask, as the format requires
        1,              # biPlanes
        32,             # biBitCount
        0,              # BI_RGB
        0,              # biSizeImage
        0, 0, 0, 0,
    )
    pixels = image.load()
    rows = []
    for y in range(height - 1, -1, -1):  # DIBs are bottom-up
        row = bytearray()
        for x in range(width):
            r, g, b, a = pixels[x, y]
            row += bytes((b, g, r, a))
        rows.append(bytes(row))
    # 1 bpp mask, rows padded to 4 bytes. Left all zero: the alpha channel carries transparency.
    mask_stride = ((width + 31) // 32) * 4
    mask = bytes(mask_stride * height)
    return header + b"".join(rows) + mask


def png_entry(image: Image.Image) -> bytes:
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output = os.path.join(root, "src", "TextFix", "assets", "textfix.ico")
    os.makedirs(os.path.dirname(output), exist_ok=True)

    payloads = []
    for size in SIZES:
        image = draw_master(size, with_text_lines=size >= 48)
        payloads.append((size, png_entry(image) if size >= 256 else bmp_entry(image)))

    count = len(payloads)
    directory = b""
    offset = 6 + 16 * count
    for size, data in payloads:
        dimension = 0 if size >= 256 else size  # 0 means 256 in the ICO directory
        directory += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, len(data), offset)
        offset += len(data)

    with open(output, "wb") as handle:
        handle.write(struct.pack("<HHH", 0, 1, count))
        handle.write(directory)
        for _, data in payloads:
            handle.write(data)

    print("wrote " + output + " (" + str(os.path.getsize(output)) + " bytes, " + str(count) + " sizes)")


if __name__ == "__main__":
    main()
