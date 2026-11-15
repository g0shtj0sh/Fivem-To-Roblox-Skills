"""Optiques : masque d'émission = traits clairs et aplats vifs allumés, fond et réflecteur gris éteints ; texture
sombre (verre rouge) normalisée pour qu'elle s'allume quand même."""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r.light_emissive import emissive_mask, upscale  # noqa: E402


def test_light_emissive():
    a = np.zeros((64, 64, 3), np.uint8)
    a[:32] = 70                       # fond gris foncé (feu de jour)
    a[:32, ::8] = 225                 # traits blancs fins
    a[32:48] = 140                    # réflecteur gris moyen
    a[48:, :32] = (215, 35, 30)       # aplat rouge vif
    big = upscale(Image.fromarray(a), 256)
    assert big.size == (256, 256)
    m = np.asarray(emissive_mask(big))[..., 0] / 255
    assert m[:128, 0:4].mean() > 0.5          # trait allumé
    assert m[:128, 12:24].mean() < 0.05       # fond entre les traits éteint
    assert m[136:184].mean() < 0.05           # réflecteur gris éteint
    assert m[200:, :120].mean() > 0.5         # aplat rouge allumé
    dark = np.zeros((32, 32, 3), np.uint8)
    dark[:, ::4] = (120, 10, 10)               # verre rouge sombre (ext_lights)
    md = np.asarray(emissive_mask(upscale(Image.fromarray(dark), 128)))[..., 0] / 255
    assert md.max() > 0.8                      # normalisé : s'allume


if __name__ == "__main__":
    test_light_emissive()
    print("ok")
