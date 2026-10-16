"""Draws Resources/AppIcon.png (1024x1024): a dashed snip selection with a pen, on a blue gradient."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 1024
OUT = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.png"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS icon grid: 824px rounded square centred in 1024, with a soft drop shadow.
    inset, size, radius = 100, 824, 185
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (inset, inset + 14, inset + size, inset + size + 14), radius, fill=(0, 0, 0, 110)
    )
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18)))

    grad = Image.new("RGBA", (S, S))
    top, bottom = (64, 156, 255, 255), (88, 64, 220, 255)
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, inset + size, inset + size), radius, fill=255)
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)

    # The snipped area: a lighter panel inside a dashed selection rectangle.
    x0, y0, x1, y1 = 250, 300, 774, 724
    panel = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(panel).rounded_rectangle((x0, y0, x1, y1), 28, fill=(255, 255, 255, 56))
    img.alpha_composite(panel)
    d = ImageDraw.Draw(img)
    dash, gap, w = 46, 26, 18

    def dashed(p, q):
        (ax, ay), (bx, by) = p, q
        length = abs(bx - ax) + abs(by - ay)
        pos = 0
        while pos < length:
            end = min(pos + dash, length)
            if ax == bx:
                d.line([(ax, ay + pos), (ax, ay + end)], fill="white", width=w)
            else:
                d.line([(ax + pos, ay), (ax + end, ay)], fill="white", width=w)
            pos += dash + gap

    dashed((x0, y0), (x1, y0))
    dashed((x0, y1), (x1, y1))
    dashed((x0, y0), (x0, y1))
    dashed((x1, y0), (x1, y1))

    # Corner handles
    for cx, cy in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)]:
        d.rounded_rectangle((cx - 30, cy - 30, cx + 30, cy + 30), 10, fill="white")

    # A red pen stroke across the snip, like a quick markup.
    d.line([(340, 600), (440, 500), (530, 570), (660, 430)], fill=(255, 77, 77, 255), width=34, joint="curve")
    for x, y in [(340, 600), (660, 430)]:
        d.ellipse((x - 17, y - 17, x + 17, y + 17), fill=(255, 77, 77, 255))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    img.save(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
