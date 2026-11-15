#!/usr/bin/env python3
"""La palette runtime (roblox/runtime/VehiclePaints.lua) est bien celle que génère gta_colors.py,
et chaque peinture a un libellé français et un groupe de menu (python tests/test_paints.py ou pytest)."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from f2r import gta_colors  # noqa: E402
from f2r.roblox import runtime_sources  # noqa: E402


def test_runtime_module_is_generated():
    on_disk = (ROOT / "roblox" / "runtime" / "VehiclePaints.lua").read_text(encoding="utf-8")
    assert on_disk == gta_colors.lua_module(), "relancer : python scripts/f2r/gta_colors.py"
    assert "VehiclePaints" in runtime_sources()


def test_every_paint_has_label_and_group():
    assert set(gta_colors.LABELS_FR) == set(gta_colors.PALETTE) == set(range(160))
    groups = {gta_colors.group(i) for i in gta_colors.PALETTE}
    assert groups == {"Classic", "Matte", "Metals", "Chrome", "Utility", "Worn", "Alloy"}
    assert gta_colors.group(120) == "Chrome" and gta_colors.group(12) == "Matte"
    assert gta_colors.group(15) == "Utility" and gta_colors.group(21) == "Worn"


def test_flat_diffuse_keeps_paint_without_texture():
    """Une diffuse uniforme (vehicle_generic_smallspecmap) ne doit pas donner de SurfaceAppearance à la carrosserie."""
    import tempfile

    import numpy as np
    from PIL import Image

    from f2r.textures import TextureStore
    from f2r.util import Report

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        Image.new("RGB", (4, 4), (255, 255, 255)).save(tmp / "vehicle_generic_smallspecmap.png")
        grad = np.tile(np.linspace(0, 255, 64, dtype=np.uint8), (64, 1))
        Image.fromarray(np.stack([grad] * 3, -1), "RGB").save(tmp / "decal.png")
        store = TextureStore({"vehicle_generic_smallspecmap": tmp / "vehicle_generic_smallspecmap.png",
                              "decal": tmp / "decal.png"}, tmp / "out", Report())
        assert store.is_flat("vehicle_generic_smallspecmap")
        assert not store.is_flat("decal")
        assert not store.is_flat(None) and not store.is_flat("absente")


if __name__ == "__main__":
    test_runtime_module_is_generated()
    test_every_paint_has_label_and_group()
    test_flat_diffuse_keeps_paint_without_texture()
    print("ok")
