#!/usr/bin/env python3
"""
hex2float.py  --  Convert an 8-digit hex string to its IEEE-754 single
                  precision (float32) value.

Usage:
    python3 hex2float.py DEADBEEF [more hex words ...]
    echo 3F800000 | python3 hex2float.py        # read from stdin
"""

import sys
import struct


def hex_to_float(hexstr):
    """Interpret an up-to-8-digit hex string as a 32-bit float."""
    word = int(hexstr.strip().lstrip("0x").lstrip("0X") or "0", 16)
    if word < 0 or word > 0xFFFFFFFF:
        raise ValueError(f"'{hexstr}' is not a 32-bit value")
    return struct.unpack("<f", struct.pack("<I", word))[0]


def main():
    args = sys.argv[1:]
    if not args:
        args = sys.stdin.read().split()
    for h in args:
        try:
            print(f"{h} -> {hex_to_float(h)!r}")
        except ValueError as e:
            print(f"{h} -> error: {e}")


if __name__ == "__main__":
    main()
