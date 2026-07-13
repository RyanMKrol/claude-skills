#!/usr/bin/env python3
"""Crop a clean per-object card image from a JBP exercise drawing.

The single-object exercise illustrations (a lone key / wallet / umbrella / phone …) each carry a
drill name-label box (スミス, ささき, エマ…) and a "1./2./e.g." marker that must NOT appear on a
vocab card. Workflow, validated on Lesson 2:

  1. GRID: render the source image with a 50px coordinate grid so you can read off, in the source's
     own pixel space, the object's bounding box and the label/marker boxes to erase.
       python3 crop_objects.py grid <src.jpg> <out_grid.png>
       -> Read out_grid.png, note crop=(l,t,r,b) and whiteouts=[(l,t,r,b), ...]
  2. CROP: white out the label + marker boxes, then crop to the object.
       from crop_objects import process
       process(src, out_png, whiteouts=[(l,t,r,b),...], crop=(l,t,r,b))
  3. VERIFY: Read the output PNG. Confirm the label/number are gone and the object isn't clipped;
     adjust boxes and re-run. Composite scenes with no clean single object are attached whole
     instead (or a single item cropped from the scene by the same process()).

Deps: Pillow only.
"""
import sys
from PIL import Image, ImageDraw


def grid(src, out, step=50, pad=30):
    """Render src with a labeled coordinate grid (source pixel space) for reading crop boxes."""
    im = Image.open(src).convert("RGB")
    w, h = im.size
    c = Image.new("RGB", (w + pad, h + pad), "white")
    c.paste(im, (pad, pad))
    d = ImageDraw.Draw(c)
    for x in range(0, w + 1, step):
        d.line([(pad + x, pad), (pad + x, pad + h)], fill=(255, 0, 0))
        d.text((pad + x - 6, 2), str(x), fill=(200, 0, 0))
    for y in range(0, h + 1, step):
        d.line([(pad, pad + y), (pad + w, pad + y)], fill=(255, 0, 0))
        d.text((2, pad + y - 4), str(y), fill=(200, 0, 0))
    c.save(out)
    print(f"grid written: {out}  (source size {w}x{h})")


def process(src, out, whiteouts=(), crop=None):
    """White out `whiteouts` rectangles [(l,t,r,b)…] then crop to `crop`=(l,t,r,b). Save PNG."""
    im = Image.open(src).convert("RGB")
    d = ImageDraw.Draw(im)
    for box in whiteouts:
        d.rectangle(box, fill="white")
    (im.crop(crop) if crop else im).save(out)
    print(f"cropped: {out}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "grid":
        grid(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
