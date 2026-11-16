"""Rebadge : lettrages modélisés (lettres en relief dans la géométrie, sans texture de badge).

Constat m422 (2026-11-15) : le « ///M » du pommeau de vitesse est fait de 30 petits îlots de triangles posés
sur le pommeau, avec le cuir noir de la pièce. Le rebadge par texture ne le voit pas ; la conversion le
dessine sur une planche (lettering_candidates / lettering_sheet) et une boîte remove_islands le supprime.
"""
import sys
import tempfile
from pathlib import Path

import numpy as np
from dataclasses import replace
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

# 5) restyle_islands : les lettres partent dans une pièce neuve au matériau imposé, la pièce d'origine garde le reste
with tempfile.TemporaryDirectory() as d:
    parts = [make_part()]
    ops = [{"op": "restyle_islands", "part": "chassis__mesh_13", "box": c["box"], "name": "silencer",
            "color": [62, 60, 58], "roughness": 0.55, "metal": True, "why": "test"}]
    created = rebadge.restyle_geometry(parts, ops, Path(d), Report())
    assert created == ["chassis__mesh_13__silencer"], created
    base = [q for q in parts if q.name == "chassis__mesh_13"][0]
    new = [q for q in parts if q.name == "chassis__mesh_13__silencer"][0]
    assert base.tri_count == 4 and new.tri_count == 12, (base.tri_count, new.tri_count)
    assert new.mr_override == (0.55, True) and new.tex_diffuse == "f2r_chassis__mesh_13__silencer"
    assert "SpecSampler" not in new.shader.textures and base.mr_override is None
    assert new.idx.max() < len(new.pos) and len(new.pos) == 24          # sommets compactés (6 quads)
    px = np.asarray(Image.open(Path(d) / "f2r_chassis__mesh_13__silencer.png").convert("RGB"))
    assert (px == [62, 60, 58]).all()
print("ok restyle")

# 6) restyle_islands avec `facing` : seulement les TRIANGLES de la boîte tournés vers la direction, même quand ils
#    appartiennent à un grand îlot (tranche d'une coque de verre de feu à la jointure coffre / aile, m422 2026-11-16)
cube_v = np.array([[x, y, z] for x in (0, 0.1) for y in (0, 0.1) for z in (0, 0.1)], np.float32)
faces = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
tri_list = []
for a, b, c2, d2 in faces:
    for t in ((a, b, c2), (a, c2, d2)):
        p0, p1, p2 = cube_v[list(t)]
        n = np.cross(p1 - p0, p2 - p0)
        if np.dot(n, (p0 + p1 + p2) / 3 - 0.05) < 0:  # enroulement vers l'extérieur
            t = (t[0], t[2], t[1])
        tri_list.extend(t)
cube = Part(name="chassis__badges_7", bone="chassis", owner="chassis", shader=sh, kind="mesh", paint=None,
            custom_color=None, light=None, pos=cube_v.copy(), nrm=np.tile([0, 1, 0], (8, 1)).astype(np.float32),
            uv=np.zeros((8, 2), np.float32), idx=np.array(tri_list, np.uint32), tex_diffuse="rgba171717ff")
box = [[-0.01, -0.01, -0.01], [0.11, 0.11, 0.11]]
with tempfile.TemporaryDirectory() as d:
    parts = [cube]
    ops = [{"op": "restyle_islands", "part": "chassis__badges_7", "box": box, "facing": [1, 0, 0], "name": "lensedge",
            "color": [38, 14, 16], "roughness": 0.6, "metal": False, "why": "test"}]
    created = rebadge.restyle_geometry(parts, ops, Path(d), Report())
    assert created == ["chassis__badges_7__lensedge"], created
    base = [q for q in parts if q.name == "chassis__badges_7"][0]
    new = [q for q in parts if q.name == "chassis__badges_7__lensedge"][0]
    assert base.tri_count == 10 and new.tri_count == 2, (base.tri_count, new.tri_count)
    assert np.allclose(new.pos[:, 0], 0.1)                                  # la face +X seulement
    # sans `facing`, la même boîte prend l'îlot entier (le cube)
    parts2 = [replace(cube, idx=np.array(tri_list, np.uint32))]
    ops2 = [dict(ops[0], facing=None)]
    ops2[0].pop("facing")
    rebadge.restyle_geometry(parts2, ops2, Path(d), Report())
    assert [q.name for q in parts2] == ["chassis__badges_7__lensedge"] and parts2[0].tri_count == 12
print("ok restyle facing")
