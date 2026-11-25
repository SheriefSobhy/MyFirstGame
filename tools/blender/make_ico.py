"""Packs art/icons/ico_<size>.png into art/icons/icon.ico (PNG-compressed entries).
Run with any Python 3 (Blender's works): python make_ico.py"""
import os
import struct

D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "art", "icons")
SIZES = [16, 32, 48, 64, 128, 256]
files = {s: os.path.join(D, "ico_%d.png" % s if s != 48 else "legacy_48.png") for s in SIZES}
data = [open(files[s], "rb").read() for s in SIZES]
out = struct.pack("<HHH", 0, 1, len(SIZES))
off = 6 + 16 * len(SIZES)
for s, d in zip(SIZES, data):
    out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(d), off)
    off += len(d)
open(os.path.join(D, "icon.ico"), "wb").write(out + b"".join(data))
print("WROTE icon.ico")
