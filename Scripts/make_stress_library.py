#!/usr/bin/env python3
"""Generate a synthetic stress-test photo library for Lumen.

Layout (under the target directory):
  flat/                 N tiny JPEGs in ONE folder (worst-case readdir)
  nested/d1/…/d40/      a 40-deep chain with a few photos per level
  unicode/              Korean / emoji / spaces / combining-mark filenames
  weird/                zero-byte .jpg, garbage .jpg, .JPG/.JpEg case variants,
                        no-extension image bytes, .txt decoy
  links/                symlink to a real photo, dangling symlink,
                        dir-symlink → ../flat, dir-symlink LOOP → links itself

Usage: make_stress_library.py <target-dir> [flat-count] (default 50000)
"""
import os
import sys
import shutil

# Smallest valid JPEG (1x1 px) — enough for the scanner; thumbnails just fail soft.
TINY_JPEG = bytes.fromhex(
    "ffd8ffe000104a46494600010100000100010000ffdb004300080606070605080707"
    "07090908080a0c140d0c0b0b0c1912130f141d1a1f1e1d1a1c1c20242e2720222c23"
    "1c1c2837292c30313434341f27393d38323c2e333432ffc0000b08000100010101"
    "1100ffc40014000100000000000000000000000000000009ffc40014100100000000"
    "00000000000000000000000000ffda0008010100003f00549fffd9"
)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    target = os.path.abspath(sys.argv[1])
    flat_count = int(sys.argv[2]) if len(sys.argv) > 2 else 50_000

    if os.path.exists(target):
        shutil.rmtree(target)
    os.makedirs(target)

    # 1. Flat folder — N files in one directory.
    flat = os.path.join(target, "flat")
    os.makedirs(flat)
    for i in range(flat_count):
        with open(os.path.join(flat, f"IMG_{i:06d}.jpg"), "wb") as f:
            f.write(TINY_JPEG)

    # 2. Deep nesting — 40 levels, 3 photos each.
    nested = os.path.join(target, "nested")
    level = nested
    for depth in range(1, 41):
        level = os.path.join(level, f"d{depth}")
        os.makedirs(level)
        for i in range(3):
            with open(os.path.join(level, f"deep_{depth}_{i}.jpg"), "wb") as f:
                f.write(TINY_JPEG)

    # 3. Unicode and awkward names.
    unicode_dir = os.path.join(target, "unicode")
    os.makedirs(unicode_dir)
    names = [
        "한글사진.jpg",
        "여행 사진 (서울) — final.jpg",
        "📸🌅.jpg",
        "café au lait.jpg",
        "ＦＵＬＬＷＩＤＴＨ.jpg",
        "étoile.jpg",          # combining acute (NFD-style)
        "tab\tname.jpg",
        "quote\"name'.jpg",
        "percent%20name.jpg",
        "very" + "long" * 50 + ".jpg",  # ~210-char filename
    ]
    for name in names:
        with open(os.path.join(unicode_dir, name), "wb") as f:
            f.write(TINY_JPEG)

    # 4. Weird/corrupt files.
    weird = os.path.join(target, "weird")
    os.makedirs(weird)
    open(os.path.join(weird, "zero_byte.jpg"), "wb").close()
    with open(os.path.join(weird, "garbage.jpg"), "wb") as f:
        f.write(b"this is not a jpeg at all" * 10)
    for variant in ("UPPER.JPG", "Mixed.JpEg", "trailing.jpeg"):
        with open(os.path.join(weird, variant), "wb") as f:
            f.write(TINY_JPEG)
    with open(os.path.join(weird, "no_extension"), "wb") as f:
        f.write(TINY_JPEG)
    with open(os.path.join(weird, "decoy.txt"), "wb") as f:
        f.write(b"not an image")

    # 5. Symlinks — including a directory loop.
    links = os.path.join(target, "links")
    os.makedirs(links)
    real = os.path.join(links, "real.jpg")
    with open(real, "wb") as f:
        f.write(TINY_JPEG)
    os.symlink(real, os.path.join(links, "alias.jpg"))
    os.symlink(os.path.join(target, "missing.jpg"), os.path.join(links, "dangling.jpg"))
    os.symlink(flat, os.path.join(links, "to_flat"))
    os.symlink(links, os.path.join(links, "loop"))

    total = flat_count + 40 * 3 + len(names) + 5 + 1
    print(f"stress library at {target} (~{total} scannable photos + edge cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
