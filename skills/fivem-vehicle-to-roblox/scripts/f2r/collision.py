"""Collision officielle du véhicule GTA V (Physics/LOD1 du fragment .yft) -> hitbox fidèle pour Roblox.

Le fragment d'un véhicule contient sa propre collision : un `Bound` composite dont chaque enfant
est rattaché à un groupe physique nommé comme l'os qui le porte (chassis, bonnet, door_dside_f…) :

    Physics/LOD1/Archetype/Bounds[type=Composite]/Children/Item[i]   (Geometry, BVH, Disc, Box…)
    Physics/LOD1/Children/Item[i]/GroupIndex  ->  Physics/LOD1/Groups/Item[g]/Name

Pour un enfant Geometry/BVH (export XML CodeWalker) : `Vertices` sont relatifs à `GeometryCenter`,
puis `CompositeTransform` (matrice 4×4, ligne de translation en dernier) les place dans le repère du
véhicule. Repère GTA (X droite, Y avant, Z haut) -> repère local du skill (x, z, -y), comme vehicle.py.

Sortie : des maillages convexes ou non (exportés dans le GLB sous le nom col__<os>__<n>) et des
cylindres de roues (Disc). On écarte les groupes *_lowlod (doublon basse définition) et *_dummy
(boîte englobante), qui ne décrivent pas la forme.
"""
from __future__ import annotations

import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

SKIP_SUFFIXES = ("_lowlod", "_dummy")
MESH_TYPES = ("Geometry", "GeometryBVH", "BVH")


@dataclass
class CollisionMesh:
    name: str
    owner_group: str
    pos: np.ndarray          # (n, 3) float32, repère local du skill (mètres)
    idx: np.ndarray          # (3m,) uint32
    convex: bool
    skipped_primitives: int = 0


@dataclass
class CollisionWheel:
    group: str
    center: list[float]      # repère local (mètres)
    radius: float
    width: float


@dataclass
class VehicleCollision:
    meshes: list[CollisionMesh] = field(default_factory=list)
    wheels: list[CollisionWheel] = field(default_factory=list)
    skipped: list[str] = field(default_factory=list)

    @property
    def triangles(self) -> int:
        return sum(len(m.idx) // 3 for m in self.meshes)


def _vec(el, tag) -> np.ndarray | None:
    e = el.find(tag)
    if e is None:
        return None
    return np.array([float(e.get(a, 0)) for a in "xyz"], dtype=np.float64)


def _to_local(p: np.ndarray) -> np.ndarray:
    """GTA (x, y, z) -> local (x, z, -y)."""
    p = np.asarray(p, dtype=np.float64)
    return np.stack([p[..., 0], p[..., 2], -p[..., 1]], axis=-1)


def _transform(el) -> np.ndarray:
    """CompositeTransform (4 lignes de 4, translation en dernière ligne) -> matrice 4×4 colonne."""
    e = el.find("CompositeTransform")
    m = np.eye(4)
    if e is not None and e.text and e.text.strip():
        vals = [float(v) for v in e.text.split()]
        if len(vals) == 16:
            m = np.array(vals, dtype=np.float64).reshape(4, 4).T
    return m


def _signed_volume(pos: np.ndarray, tris: np.ndarray) -> float:
    a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
    return float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6.0)


def _is_convex(pos: np.ndarray, tris: np.ndarray, tol: float = 0.01) -> bool:
    """Vrai si le maillage est fermé et que tous ses sommets sont derrière chacune de ses faces
    (tolérance 1 cm). Les faces sont orientées par le signe du volume, pas par le centroïde
    (qui se trompe sur une forme concave). Mesuré sur m422 : châssis, capot et coffre concaves
    (jusqu'à 65 cm de dépassement), portières presque convexes (3,5 cm), vitres ouvertes."""
    if len(tris) < 4:
        return False
    edges: dict[tuple[int, int], int] = {}
    for t in tris:
        for i in range(3):
            k = (min(t[i], t[(i + 1) % 3]), max(t[i], t[(i + 1) % 3]))
            edges[k] = edges.get(k, 0) + 1
    if any(v != 2 for v in edges.values()):
        return False                       # maillage ouvert : pas un volume
    a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
    n = np.cross(b - a, c - a)
    ln = np.linalg.norm(n, axis=1)
    ok = ln > 1e-12
    n, a = n[ok] / ln[ok, None], a[ok]
    if _signed_volume(pos, tris) < 0:
        n = -n
    d = np.einsum("fk,fvk->fv", n, pos[None, :, :] - a[:, None, :])
    return bool(np.all(d <= tol))


def parse_collision(path: Path) -> VehicleCollision | None:
    """Lit la collision d'un .yft.xml ; None si le fragment n'en a pas."""
    root = ET.parse(path).getroot()
    lod = root.find("Physics/LOD1")
    if lod is None:
        return None
    comp = lod.find("Archetype/Bounds")
    if comp is None:
        return None
    groups = [g.findtext("Name") or f"group{i}" for i, g in enumerate(lod.findall("Groups/Item"))]
    frag_children = lod.findall("Children/Item")
    if comp.get("type") == "Composite":
        bounds = comp.findall("Children/Item")
    else:
        bounds = [comp]
    out = VehicleCollision()
    counters: dict[str, int] = {}
    for i, b in enumerate(bounds):
        gname = groups[0] if groups else "chassis"
        if i < len(frag_children):
            try:
                gi = int(frag_children[i].find("GroupIndex").get("value"))
                gname = groups[gi]
            except (AttributeError, ValueError, IndexError, TypeError):
                pass
        if gname.endswith(SKIP_SUFFIXES):
            out.skipped.append(f"{gname} ({b.get('type')})")
            continue
        btype = b.get("type") or ""
        T = _transform(b)
        if btype in MESH_TYPES:
            vtx = b.find("Vertices")
            if vtx is None or not (vtx.text or "").strip():
                continue
            V = np.array([[float(x) for x in ln.split(",")] for ln in vtx.text.strip().splitlines() if ln.strip()])
            c = _vec(b, "GeometryCenter")
            if c is not None:
                V = V + c
            tris, prims = [], 0
            for poly in b.find("Polygons") if b.find("Polygons") is not None else []:
                if poly.tag == "Triangle":
                    tris.append([int(poly.get("v1")), int(poly.get("v2")), int(poly.get("v3"))])
                else:                       # Box / Sphere / Capsule / Cylinder dans la géométrie : rares
                    prims += 1
            if not tris:
                out.skipped.append(f"{gname} ({btype} sans triangle)")
                continue
            Vh = np.c_[V, np.ones(len(V))] @ T.T
            P = _to_local(Vh[:, :3])
            idx = np.array(tris, dtype=np.int64)
            n = counters.get(gname, 0) + 1
            counters[gname] = n
            out.meshes.append(CollisionMesh(name=f"col__{gname}__{n}", owner_group=gname,
                                            pos=P.astype(np.float32), idx=idx.reshape(-1).astype(np.uint32),
                                            convex=_is_convex(P, idx), skipped_primitives=prims))
        elif btype == "Disc":
            mx = _vec(b, "BoxMax")
            center = (T @ np.array([0, 0, 0, 1.0]))[:3]
            out.wheels.append(CollisionWheel(group=gname, center=[float(v) for v in _to_local(center)],
                                             radius=float(max(mx[1], mx[2])),
                                             # Disc : la marge vaut le rayon ; la demi-largeur est BoxMax.x
                                             width=float(max(2 * mx[0], 0.05))))
        elif btype == "Box":
            lo, hi = _vec(b, "BoxMin"), _vec(b, "BoxMax")
            corners = np.array([[x, y, z] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])])
            P = _to_local((np.c_[corners, np.ones(8)] @ T.T)[:, :3])
            box_tris = np.array([[0, 1, 3], [0, 3, 2], [4, 6, 7], [4, 7, 5], [0, 4, 5], [0, 5, 1],
                                 [2, 3, 7], [2, 7, 6], [0, 2, 6], [0, 6, 4], [1, 5, 7], [1, 7, 3]])
            n = counters.get(gname, 0) + 1
            counters[gname] = n
            out.meshes.append(CollisionMesh(name=f"col__{gname}__{n}", owner_group=gname,
                                            pos=P.astype(np.float32), idx=box_tris.reshape(-1).astype(np.uint32),
                                            convex=True))
        else:
            out.skipped.append(f"{gname} ({btype} non géré)")
    return out if (out.meshes or out.wheels) else None


def flat_mesh(pos: np.ndarray, idx: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Sommets dupliqués par face (normales plates). Un maillage fermé de volume négatif est
    retourné pour que ses faces regardent vers l'extérieur ; un maillage ouvert (vitre) garde
    l'ordre du jeu. Renvoie (pos, nrm, idx) prêts pour le GLB."""
    tris = idx.reshape(-1, 3).astype(np.int64)
    p64 = pos.astype(np.float64)
    if _signed_volume(p64, tris) < 0:
        tris = tris[:, [0, 2, 1]]
    a, b, c = p64[tris[:, 0]], p64[tris[:, 1]], p64[tris[:, 2]]
    n = np.cross(b - a, c - a)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)
    P = np.stack([a, b, c], axis=1).reshape(-1, 3).astype(np.float32)
    N = np.repeat(n, 3, axis=0).astype(np.float32)
    I = np.arange(len(P), dtype=np.uint32)
    return P, N, I
