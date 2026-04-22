#!/usr/bin/env python3
"""
strip-empty-braille.py — Remove empty U+2800–U+28FF (Braille Patterns) cmap
entries from a TTF.

The Nerd Fonts patcher, when run with --complete, leaves empty-glyph cmap
entries for the entire braille block in the output font. Those stubs have
zero contours but still claim coverage of the range, which blocks the OS
from falling back to a font that actually has braille outlines — so
braille characters render as blank boxes in terminals (btop, spinners,
ASCII art, etc.).

This script walks each cmap subtable and deletes any codepoint in the
braille block whose glyph has no contours and no composite components.
Non-empty braille glyphs (if any) are preserved. Glyph storage itself
is left alone; only the cmap mappings are removed, so downstream tools
that look up glyphs by name still work.

Usage:
    strip-empty-braille.py <font.ttf> [-o <out.ttf>]

If -o is omitted, the input file is overwritten in place.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from fontTools.ttLib import TTFont

BRAILLE_START = 0x2800
BRAILLE_END = 0x28FF  # inclusive


def glyph_is_empty(glyf_table, glyph_name: str) -> bool:
    """Return True iff the named glyph has no contours and no components."""
    if glyph_name not in glyf_table:
        return True
    g = glyf_table[glyph_name]
    if g.isComposite():
        return False
    # numberOfContours == 0 and no points => empty outline
    return g.numberOfContours == 0


def strip_empty_braille(font: TTFont) -> int:
    """Remove empty braille cmap entries from every subtable. Return count."""
    glyf = font["glyf"]
    cmap_table = font["cmap"]

    # Identify empty braille glyphs via the best cmap (any subtable will do
    # for deciding emptiness; glyph storage is shared).
    best = font.getBestCmap()
    empties = {
        cp: best[cp]
        for cp in range(BRAILLE_START, BRAILLE_END + 1)
        if cp in best and glyph_is_empty(glyf, best[cp])
    }

    if not empties:
        return 0

    removed = 0
    for subtable in cmap_table.tables:
        # Only touch Unicode subtables.
        if not subtable.isUnicode():
            continue
        for cp in list(subtable.cmap.keys()):
            if cp in empties:
                del subtable.cmap[cp]
                removed += 1

    return len(empties)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("font", type=Path, help="Input TTF")
    ap.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output TTF (default: overwrite input)",
    )
    args = ap.parse_args()

    if not args.font.is_file():
        print(f"error: {args.font} not found", file=sys.stderr)
        return 1

    out = args.output or args.font

    font = TTFont(str(args.font))
    removed = strip_empty_braille(font)

    if removed == 0:
        print(f"no empty braille cmap entries in {args.font.name} — nothing to do")
        if out != args.font:
            font.save(str(out))
        return 0

    font.save(str(out))
    print(f"stripped {removed} empty braille cmap entries -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
