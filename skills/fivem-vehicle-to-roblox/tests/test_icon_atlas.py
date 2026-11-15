"""Planche d'icônes (vehicle_dash_emissive) : fond sombre, symbole clair, agrandie, alpha gardé ; version opaque."""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r.icon_atlas import has_alpha_mask, refine_icon_atlas  # noqa: E402


def _atlas() -> Image.Image:
    # 64 x 64 : plastique sombre opaque partout, sauf un bloc d'icônes (fond transparent blanc, « + » opaque gris
    # bordé de noir comme dans int_emis)
    a = np.zeros((64, 64, 4), np.uint8)
    a[...] = (40, 40, 42, 255)
    a[8:40, 8:40] = (255, 255, 255, 0)
    a[22:26, 12:36, :3] = 20
    a[22:26, 12:36, 3] = 255  # contour sombre
    a[23:25, 13:35] = (150, 130, 130, 255)  # corps clair du symbole
    a[12:36, 22:26, :3] = 20
    a[12:36, 22:26, 3] = 255
    a[13:35, 23:25] = (150, 130, 130, 255)
    a[30:34, 30:34] = (200, 20, 20, 255)  # symbole rouge
    return Image.fromarray(a, "RGBA")


def test_icon_atlas():
    src = _atlas()
    assert has_alpha_mask(src)
    assert not has_alpha_mask(Image.new("RGBA", (8, 8), (10, 10, 10, 74)))  # alpha constant (écran) : pas une planche
    out = refine_icon_atlas(src, 2048)
    assert out.size == (256, 256)  # x4
    o = np.asarray(out).astype(int)
    bg = o[9 * 4 + 2, 9 * 4 + 2]       # fond du bloc : sombre, transparent
    glyph = o[24 * 4, 18 * 4]          # corps du « + » : clair, opaque
    red = o[32 * 4, 32 * 4]            # symbole coloré : gardé rouge
    plastic = o[50 * 4, 50 * 4]        # hors bloc : inchangé
    assert bg[:3].max() < 80 and bg[3] < 40, bg
    assert glyph[:3].min() > 200 and glyph[3] > 200, glyph
    assert red[0] > 150 and red[1] < 80, red
    assert abs(plastic[0] - 40) < 4 and plastic[3] == 255, plastic
    opaque = out.copy()
    opaque.putalpha(255)
    assert np.asarray(opaque)[..., 3].min() == 255


if __name__ == "__main__":
    test_icon_atlas()
    print("ok")
