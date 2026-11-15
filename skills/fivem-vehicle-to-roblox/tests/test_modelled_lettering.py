"""Rebadge : lettrages modélisés (lettres en relief dans la géométrie, sans texture de badge).

Constat m422 (2026-11-15) : le « ///M » du pommeau de vitesse est fait de 30 petits îlots de triangles posés
sur le pommeau, avec le cuir noir de la pièce. Le rebadge par texture ne le voit pas ; la conversion le
dessine sur une planche (lettering_candidates / lettering_sheet) et une boîte remove_islands le supprime.
"""
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r import rebadge  # noqa: E402
from f2r.cwxml import Shader  # noqa: E402
from f2r.util import Report  # noqa: E402
from f2r.vehicle import Part  # noqa: E402


def quad(x, y, z, w, h):
    return [[x, y, z], [x + w, y, z], [x + w, y, z + h], [x, y, z + h]]


# pièce « pommeau » : un grand quad (le cuir, 6 cm) + 6 petits quads serrés (les lettres, 4 mm, 1 mm d'écart)
# + 1 petit quad isolé plus loin (une vis : ne doit pas être pris dans la grappe ni dans la boîte)
quads = [quad(0, 0, 0, 0.06, 0.06)]
quads += [quad(0.01 + i * 0.005, 0.001, 0.02, 0.004, 0.01) for i in range(6)]
quads += [quad(0.05, 0.001, 0.05, 0.004, 0.004)]
pos = np.array([v for q in quads for v in q], np.float32)
idx = np.array([k for i in range(len(quads)) for k in (4 * i, 4 * i + 1, 4 * i + 2, 4 * i, 4 * i + 2, 4 * i + 3)],
               np.uint32)
sh = Shader("vehicle_mesh", "x", textures={"DiffuseSampler": "rgba171717ff"})


def make_part():
    return Part(name="chassis__mesh_13", bone="chassis", owner="chassis", shader=sh, kind="mesh", paint=None,
                custom_color=None, light=None, pos=pos.copy(), nrm=np.tile([0, 1, 0], (len(pos), 1)).astype(np.float32),
                uv=np.zeros((len(pos), 2), np.float32), idx=idx.copy(), tex_diffuse="rgba171717ff")


# 1) détection : une seule grappe, les 6 lettres (ni le cuir, trop grand, ni la vis, trop loin)
parts = [make_part()]
cands = rebadge.lettering_candidates(parts)
assert len(cands) == 1, cands
c = cands[0]
assert c["part"] == "chassis__mesh_13" and len(c["islands"]) == 6, c
lo, hi = np.array(c["box"][0]), np.array(c["box"][1])
assert np.allclose(lo, [0.01, 0.001, 0.02], atol=1e-4) and np.allclose(hi, [0.039, 0.001, 0.03], atol=1e-4), c["box"]
assert all(isinstance(v, float) for v in c["box"][0])          # JSON propre (pas de float32)

with tempfile.TemporaryDirectory() as d:
    png = Path(d) / "_rebadge" / "lettrages_modelises.png"
    rebadge.lettering_sheet(cands, png)
    assert Image.open(png).size[0] > 0

# 2) suppression par boîte : les 6 lettres partent (12 triangles), le cuir et la vis restent
parts = [make_part()]
ops = [{"op": "remove_islands", "part": "chassis__mesh_13", "box": c["box"], "why": "test"}]
removed = rebadge.remove_geometry(parts, ops, Report())
assert removed == 12, removed
assert parts[0].tri_count == 2 + 2, parts[0].tri_count
assert rebadge.lettering_candidates(parts) == []

# 3) filtre de pièce : une boîte posée sur une autre pièce ne retire rien (et avertit)
parts = [make_part()]
rep = Report()
assert rebadge.remove_geometry(parts, [{"op": "remove_islands", "part": "door_", "box": c["box"]}], rep) == 0
assert parts[0].tri_count == 16

# 4) opération inconnue refusée
try:
    rebadge.remove_geometry([make_part()], [{"op": "delete_everything", "box": c["box"]}], Report())
    raise AssertionError("opération inconnue acceptée")
except ValueError:
    pass

print("ok")
