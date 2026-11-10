#!/usr/bin/env python3
"""Lecture de la collision d'un fragment (Physics/LOD1) : python tests/test_collision.py ou pytest.
Fragment XML synthétique (aucun contenu Rockstar) : un cube décalé, un doublon *_lowlod, une roue."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from f2r import collision  # noqa: E402

CUBE_V = "\n".join(f"{x}, {y}, {z}" for x in (-0.5, 0.5) for y in (-1, 1) for z in (-0.25, 0.25))
# indices du cube : sommet i = (x, y, z) bits (x<<2 | y<<1 | z)
CUBE_T = [(0, 1, 3), (0, 3, 2), (4, 6, 7), (4, 7, 5), (0, 4, 5), (0, 5, 1),
          (2, 3, 7), (2, 7, 6), (0, 2, 6), (0, 6, 4), (1, 5, 7), (1, 7, 3)]
TRIS = "\n".join(f'<Triangle m="0" v1="{a}" v2="{b}" v3="{c}" f1="0" f2="0" f3="0" />' for a, b, c in CUBE_T)


def geometry(tx: float, ty: float, tz: float) -> str:
    return f"""<Item type="Geometry">
 <BoxMin x="-0.5" y="-1" z="-0.25" /><BoxMax x="0.5" y="1" z="0.25" /><Margin value="0.04" />
 <CompositeTransform>1 0 0 0
 0 1 0 0
 0 0 1 0
 {tx} {ty} {tz} 1</CompositeTransform>
 <GeometryCenter x="0" y="0.5" z="0.1" />
 <Vertices>{CUBE_V}</Vertices>
 <Polygons>{TRIS}</Polygons>
</Item>"""


XML = f"""<?xml version="1.0"?>
<Fragment><Name>testcol</Name>
 <Physics><LOD1>
  <Archetype><Bounds type="Composite"><Children>
   {geometry(0, 0, 0.3)}
   {geometry(0, 0, 0.3)}
   <Item type="Disc">
    <BoxMin x="-0.15" y="-0.33" z="-0.33" /><BoxMax x="0.15" y="0.33" z="0.33" /><Margin value="0.33" />
    <CompositeTransform>1 0 0 0
 0 1 0 0
 0 0 1 0
 -0.8 1.3 -0.2 1</CompositeTransform>
   </Item>
  </Children></Bounds></Archetype>
  <Children>
   <Item><GroupIndex value="0" /><BoneTag value="0" /></Item>
   <Item><GroupIndex value="2" /><BoneTag value="1" /></Item>
   <Item><GroupIndex value="1" /><BoneTag value="2" /></Item>
  </Children>
  <Groups>
   <Item><Name>chassis</Name></Item>
   <Item><Name>wheel_lf</Name></Item>
   <Item><Name>chassis_lowlod</Name></Item>
  </Groups>
 </LOD1></Physics>
</Fragment>"""


def test_collision():
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "testcol.yft.xml"
        p.write_text(XML, encoding="utf-8")
        col = collision.parse_collision(p)
    assert col is not None
    assert [m.name for m in col.meshes] == ["col__chassis__1"], [m.name for m in col.meshes]
    assert col.skipped == ["chassis_lowlod (Geometry)"]
    m = col.meshes[0]
    assert m.convex, "un cube fermé doit être reconnu convexe"
    # GTA (x, y, z) + GeometryCenter (0, .5, .1) + translation (0, 0, .3) -> local (x, z, -y)
    lo, hi = m.pos.min(axis=0), m.pos.max(axis=0)
    assert np.allclose(lo, [-0.5, 0.15, -1.5], atol=1e-5), lo
    assert np.allclose(hi, [0.5, 0.65, 0.5], atol=1e-5), hi
    # roue : rayon 0,33, largeur = 2 × BoxMax.x (la marge d'un Disc vaut son rayon)
    w = col.wheels[0]
    assert w.group == "wheel_lf" and abs(w.radius - 0.33) < 1e-6 and abs(w.width - 0.30) < 1e-6
    assert np.allclose(w.center, [-0.8, -0.2, -1.3]), w.center
    # maillage plat pour le GLB : faces vers l'extérieur (volume positif)
    P, N, I = collision.flat_mesh(m.pos, m.idx)
    assert len(P) == len(N) == len(I) == 36
    c = P.mean(axis=0)
    tri = P.reshape(-1, 3, 3)
    out = np.einsum("ij,ij->i", N[::3], tri.mean(axis=1) - c)
    assert np.all(out > 0), "normales orientées vers l'intérieur"
    # un maillage ouvert n'est jamais « convexe »
    assert not collision._is_convex(m.pos.astype(float), m.idx.reshape(-1, 3)[:6].astype(int))
    print("OK : collision lue, repère, roue, doublon écarté, convexité")


if __name__ == "__main__":
    test_collision()
