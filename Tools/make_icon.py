"""Draws Crate's app icon: a Cover Flow glyph on a music-red gradient.

Usage: python3 Tools/make_icon.py
Writes the iOS, watchOS and macOS app icon images into Resources/*/Assets.xcassets/AppIcon.appiconset.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048  # drawn at 2x and downsampled, for smooth edges
K = S / 1024
TOP, BOTTOM = (255, 96, 122), (238, 34, 60)
NOTE_COLOR = (244, 58, 84, 255)
CY = 440  # covers' centerline, in 1024-point units
CENTER = (512 - 210, CY - 210, 512 + 210, CY + 210)
CORNER = 26
GAP = 9  # space cut around a nearer cover so overlapping white covers read as separate
REFLECTION_ALPHA = 0.32
REFLECTION_DEPTH = 170

# Side covers on the left, outermost first: (inner x, outer x, inner height, outer height), opacity.
# Like the app, each faces the center, so its outer edge is the taller one.
SIDES = [
    ((190, 96, 262, 300), 0.40),
    ((262, 150, 292, 340), 0.62),
    ((338, 214, 322, 376), 0.86),
]


def p(v):
    return int(round(v * K))


def side_polygon(inner_x, outer_x, inner_h, outer_h, right=False):
    pts = [(inner_x, CY - inner_h / 2), (outer_x, CY - outer_h / 2),
           (outer_x, CY + outer_h / 2), (inner_x, CY + inner_h / 2)]
    return [(1024 - x, y) for x, y in pts] if right else pts


def reflected(poly):
    """Each vertical edge flipped about its own bottom end, as a cover standing on a glossy floor."""
    bottom = {x: max(y for px_, y in poly if px_ == x) for x, _ in poly}
    return [(x, 2 * bottom[x] - y) for x, y in poly]


def scaled(points):
    return [(p(x), p(y)) for x, y in points]


def mask_of(draw_fn, grow=0):
    m = Image.new("L", (S, S), 0)
    draw_fn(ImageDraw.Draw(m))
    if grow:
        m = m.filter(ImageFilter.MaxFilter(p(grow) | 1))
    return m


def white(mask, alpha):
    layer = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    layer.putalpha(mask.point(lambda a: int(a * alpha)))
    return layer


def gradient():
    strip = Image.new("RGBA", (1, 256))
    for y in range(256):
        t = y / 255
        strip.putpixel((0, y), tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,))
    return strip.resize((S, S), Image.BILINEAR)


def note(layer):
    """A beamed pair of eighth notes on the center cover."""
    d = ImageDraw.Draw(layer)
    stem = 24
    left_x, right_x = 512 - 90, 512 + 90
    top_l, top_r = CY - 118, CY - 146
    d.polygon(scaled([(left_x - stem / 2, top_l), (right_x + stem / 2, top_r),
                      (right_x + stem / 2, top_r + 54), (left_x - stem / 2, top_l + 54)]), fill=NOTE_COLOR)
    d.rectangle(scaled([(left_x - stem / 2, top_l), (left_x + stem / 2, CY + 92)]), fill=NOTE_COLOR)
    d.rectangle(scaled([(right_x - stem / 2, top_r), (right_x + stem / 2, CY + 62)]), fill=NOTE_COLOR)
    for stem_x, stem_bottom in ((left_x, CY + 92), (right_x, CY + 62)):
        head = Image.new("RGBA", (p(150), p(150)), (0, 0, 0, 0))
        ImageDraw.Draw(head).ellipse(scaled([(15, 42), (135, 108)]), fill=NOTE_COLOR)
        head = head.rotate(22, resample=Image.BICUBIC)
        # the head's right side meets the stem's bottom
        layer.alpha_composite(head, (p(stem_x + stem / 2 - 128), p(stem_bottom - 68)))


def glyph():
    """The white Cover Flow glyph (covers only, no reflection) on transparent."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    center_mask = mask_of(lambda d: d.rounded_rectangle([p(v) for v in CENTER], radius=p(CORNER), fill=255))
    for right in (False, True):
        for i, (geometry, alpha) in enumerate(SIDES):
            poly = side_polygon(*geometry, right=right)
            shape = mask_of(lambda d: d.polygon(scaled(poly), fill=255))
            if i + 1 < len(SIDES):
                nearer = side_polygon(*SIDES[i + 1][0], right=right)
                cutout = mask_of(lambda d: d.polygon(scaled(nearer), fill=255), grow=GAP)
            else:
                cutout = mask_of(lambda d: d.rounded_rectangle([p(v) for v in CENTER], radius=p(CORNER), fill=255),
                                 grow=GAP)
            layer.alpha_composite(white(ImageChops.subtract(shape, cutout), alpha))
    layer.alpha_composite(white(center_mask, 1))
    note(layer)
    return layer


def reflection():
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    for right in (False, True):
        for geometry, alpha in SIDES:
            poly = reflected(side_polygon(*geometry, right=right))
            layer.alpha_composite(white(mask_of(lambda d: d.polygon(scaled(poly), fill=255)), alpha))
    # the center cover and its note, flipped about the cover's bottom edge
    covers = glyph()
    box = [p(v) for v in CENTER]
    center = covers.crop(box).transpose(Image.FLIP_TOP_BOTTOM)
    layer.alpha_composite(center, (box[0], box[3] + p(4)))
    fade_strip = Image.new("L", (1, 256))
    for y in range(256):
        fade_strip.putpixel((0, y), int((1 - y / 255) * 255 * REFLECTION_ALPHA))
    fade = Image.new("L", (S, S), 0)
    floor = CENTER[3] - 40  # side covers' bottoms sit a little above the center cover's
    fade.paste(fade_strip.resize((S, p(REFLECTION_DEPTH + 40))), (0, p(floor)))
    layer.putalpha(ImageChops.multiply(layer.getchannel("A"), fade))
    return layer


def full_bleed():
    out = gradient()
    out.alpha_composite(reflection())
    out.alpha_composite(glyph())
    return out


def mac_tile(full):
    """macOS icons are a rounded tile with margins and a soft shadow rather than full-bleed art."""
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    inset, size = p(100), p(824)
    tile_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(tile_mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=p(185), fill=255)
    shadow_mask = Image.new("L", (S, S), 0)
    shadow_mask.paste(tile_mask, (inset, inset + p(12)))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shadow.putalpha(shadow_mask.filter(ImageFilter.GaussianBlur(p(18))).point(lambda a: int(a * 0.45)))
    canvas.alpha_composite(shadow)
    tile = full.resize((size, size), Image.LANCZOS)
    tile.putalpha(tile_mask)
    canvas.alpha_composite(tile, (inset, inset))
    return canvas


MAC_SIZES = [16, 32, 128, 256, 512]


def main():
    root = Path(__file__).resolve().parent.parent / "Resources"
    full = full_bleed()
    square = full.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    for platform in ("iOS", "watchOS"):
        square.save(root / platform / "Assets.xcassets/AppIcon.appiconset/AppIcon.png")
    mac = mac_tile(full)
    mac_dir = root / "macOS/Assets.xcassets/AppIcon.appiconset"
    for size in MAC_SIZES:
        for scale in (1, 2):
            mac.resize((size * scale, size * scale), Image.LANCZOS).save(mac_dir / f"AppIcon-{size}@{scale}x.png")


if __name__ == "__main__":
    main()
