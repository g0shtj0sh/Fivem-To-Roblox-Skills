"""Rebadge : un emblème sorti en pièce neuve ne garde pas la brillance (SpecSampler) de la planche d'origine.

Ses UV sont recadrés sur la nouvelle texture ; la spec d'origine (où le logo de la marque réelle est aussi
dessiné) serait alors étirée sur tout l'emblème et le logo réapparaîtrait dans les reflets (m422, 2026-11-15).
"""
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r import rebadge  # noqa: E402
from f2r.cwxml import Shader  # noqa: E402
from f2r.textures import TextureStore  # noqa: E402
from f2r.util import Report  # noqa: E402
from f2r.vehicle import Part  # noqa: E402

N = 64
# planche « badge » : emblème rond motif à gauche (u < 0,5), fond uni ailleurs
diff = np.full((N, N, 4), (40, 40, 40, 255), np.uint8)
yy, xx = np.mgrid[:N, :N]
disc = np.hypot(xx - 16, yy - 32) < 14
diff[disc & (xx < 16)] = (20, 60, 200, 255)
diff[disc & (xx >= 16)] = (240, 240, 240, 255)
# spec : fond gris uniforme, avec le « logo » dessiné en blanc sous l'emblème et à l'autre bout de la planche
spec = np.full((N, N, 4), (128, 128, 128, 255), np.uint8)
spec[disc & (np.abs(xx - 16) < 2)] = (255, 255, 255, 255)
spec[5:15, 40:60] = (255, 255, 255, 255)

# carré de 10 cm dont les UV couvrent le disque
pos = np.array([[0, 0, 0], [0.1, 0, 0], [0.1, 0.1, 0], [0, 0.1, 0]], np.float32)
uv = np.array([[2 / N, 18 / N], [30 / N, 18 / N], [30 / N, 46 / N], [2 / N, 46 / N]], np.float32)
idx = np.array([0, 1, 2, 0, 2, 3], np.uint32)

with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    Image.fromarray(diff).save(d / "badge_diff.png")
    Image.fromarray(spec).save(d / "badge_spec.png")
    sh = Shader("vehicle_badges", "x", textures={"DiffuseSampler": "badge_diff", "SpecSampler": "badge_spec",
                                                 "BumpSampler": "badge_nrml"})
    p = Part(name="chassis__badges", bone="chassis", owner="chassis", shader=sh, kind="mesh", paint=None,
             custom_color=None, light=None, pos=pos, nrm=np.tile([0, 0, 1], (4, 1)).astype(np.float32),
             uv=uv, idx=idx, tex_diffuse="badge_diff", tex_normal="badge_nrml")
    parts = [p]
    imgs = {"badge_diff": Image.open(d / "badge_diff.png"), "badge_spec": Image.open(d / "badge_spec.png")}
    out = d / "_rebadge"
    summary = rebadge.rebadge_parts(parts, lambda n: imgs.get(n.lower()), None, out, Report())
    assert len(summary["emblems"]) == 1, summary
    em = [q for q in parts if "__emblem" in q.name][0]
    assert em.tex_normal is None
    assert "BumpSampler" not in em.shader.textures
    assert sh.textures["SpecSampler"] == "badge_spec"          # shader d'origine intact (partagé)
    spec_name = em.shader.textures["SpecSampler"]
    assert spec_name == f"f2r_{em.name}_spec", spec_name
    s = np.asarray(Image.open(out / f"{spec_name}.png").convert("RGBA"))
    assert s.shape[:2] == (4, 4) and s.reshape(-1, 4).std(0).max() == 0              # brillance unie
    assert abs(int(s[0, 0, 0]) - 128) <= 2, s[0, 0]             # = fond de la spec, pas le motif

    # la carte metallicRoughness de l'emblème est unie (4 x 4) : plus aucun motif de la planche
    store = TextureStore({spec_name.lower(): out / f"{spec_name}.png", "badge_spec": d / "badge_spec.png"},
                         d / "tex", Report())
    mr = np.asarray(Image.open(store.metal_rough(em.shader, em.tex_diffuse)))
    assert mr.shape[:2] == (4, 4) and mr[..., 1].std() == 0
print("test_emblem_spec : OK")
