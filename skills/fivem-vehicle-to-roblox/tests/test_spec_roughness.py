"""Brillance GTA (SpecSampler) -> carte glTF metallicRoughness (G = rugosité, B = métal)."""
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r.cwxml import Shader  # noqa: E402
from f2r.textures import TextureStore, spec_to_roughness  # noqa: E402
from f2r.util import Report  # noqa: E402


def rgb(r, g, b, n=4):
    return Image.new("RGB", (n, n), (int(r * 255), int(g * 255), int(b * 255)))


# peinture GTA (smallspecmap blanche, falloff 225, intensité 0,75) : brillante
paint = spec_to_roughness(rgb(1, 1, 1), 0.75, 225, (1, 0, 0))
assert 0.1 < paint.mean() < 0.2, paint.mean()
# plastique (spec sombre, falloff 10, intensité 0,09) : presque mat
plastic = spec_to_roughness(rgb(0.16, 0.17, 0.16), 0.09, 10, (1, 0, 0))
assert plastic.mean() > 0.9, plastic.mean()
# brillance nulle -> rugosité 1 ; jamais sous le minimum
assert spec_to_roughness(rgb(1, 0, 0), 1, 100, (1, 0, 0)).min() == 1.0
assert spec_to_roughness(rgb(1, 1, 1), 1, 900, (1, 0, 0)).min() >= 0.05

with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    big = np.zeros((64, 64, 3), np.uint8)
    big[:, :32] = (255, 255, 255)
    Image.fromarray(big).save(d / "mix_spec.png")
    rgb(0.71, 0.86, 0.87).save(d / "chrome_s.png")
    store = TextureStore({"mix_spec": d / "mix_spec.png", "chrome_s": d / "chrome_s.png"}, d / "out", Report())
    sh = Shader("vehicle_mesh", "x", textures={"SpecSampler": "mix_spec"})
    mr = np.asarray(Image.open(store.metal_rough(sh, "black")))
    assert mr.shape == (64, 64, 3) and mr[..., 2].max() == 0          # carte variable gardée, pas de métal
    assert mr[0, 0, 1] < mr[0, 63, 1]                                   # moitié brillante plus lisse
    ch = Shader("vehicle_mesh", "x", textures={"SpecSampler": "chrome_s"})
    cm = np.asarray(Image.open(store.metal_rough(ch, "chrome")))
    assert cm.shape == (4, 4, 3) and cm[..., 2].min() == 255            # chrome = métal, carte uniforme réduite
    assert cm[..., 1].max() <= round(0.10 * 255)                        # rugosité du chrome plafonnée
    assert store.metal_rough(Shader("vehicle_mesh", "x"), "black") is None   # pas de SpecSampler -> rien
print("OK : spec -> rugosité (peinture, plastique, bornes), carte variable, chrome métal, absence")
