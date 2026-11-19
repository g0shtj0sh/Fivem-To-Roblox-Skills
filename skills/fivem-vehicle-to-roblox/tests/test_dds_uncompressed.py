#!/usr/bin/env python3
"""DDS non compressés que Pillow refuse (A8, L8, RVB à masques) : lus par textures.read_uncompressed_dds.
325e (2026-11-19) : `black.dds` (A8) illisible -> pièces de carrosserie figées en marron (python tests/test_dds_uncompressed.py)."""
from __future__ import annotations

import struct
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from f2r.textures import load_image  # noqa: E402
from f2r.util import Report  # noqa: E402


def _dds(path: Path, w: int, h: int, flags: int, bits: int, masks: tuple[int, int, int, int], data: bytes) -> Path:
    header = bytearray(128)
    header[:4] = b"DDS "
    struct.pack_into("<7I", header, 4, 124, 0x100F, h, w, w * bits // 8, 0, 1)
    struct.pack_into("<8I", header, 76, 32, flags, 0, bits, *masks)
    path.write_bytes(bytes(header) + data)
    return path


def test_uncompressed_formats():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        rep = Report()
        # A8 tout opaque (black.dds de la 325e) -> noir opaque
        a8 = np.asarray(load_image(_dds(tmp / "black.dds", 4, 4, 0x2, 8, (0, 0, 0, 0xFF), b"\xff" * 16), rep).convert("RGBA"))
        assert a8.shape == (4, 4, 4) and (a8[..., :3] == 0).all() and (a8[..., 3] == 255).all()
        # L8 -> gris opaque
        l8 = np.asarray(load_image(_dds(tmp / "l8.dds", 2, 2, 0x20000, 8, (0xFF, 0, 0, 0), b"\x80" * 4), rep).convert("RGBA"))
        assert (l8[..., :3] == 128).all() and (l8[..., 3] == 255).all()
        # B5G6R5 (masques 16 bits) : rouge pur
        rgb = np.asarray(load_image(_dds(tmp / "565.dds", 2, 1, 0x40, 16, (0xF800, 0x07E0, 0x001F, 0),
                                         struct.pack("<2H", 0xF800, 0xF800)), rep).convert("RGBA"))
        assert (rgb[..., 0] == 255).all() and (rgb[..., 1] == 0).all() and (rgb[..., 3] == 255).all()
        assert not rep.warnings, rep.warnings


if __name__ == "__main__":
    test_uncompressed_formats()
    print("ok")
