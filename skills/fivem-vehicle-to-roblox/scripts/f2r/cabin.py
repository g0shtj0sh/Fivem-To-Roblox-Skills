"""Habitacle d'un véhicule en voxels, pour adapter le corps des occupants (VehicleSeatFit).

Le corps d'un joueur assis doit rester dans l'habitacle : ni bras dans la portière, ni tête dans le
pavillon. On voxelise la carrosserie visible (repère de sortie, mètres) puis on classe chaque cellule :

- air extérieur : atteint depuis le bord de la grille sans traverser de paroi ;
- air de l'habitacle : atteint depuis les sièges ;
- le reste (parois, sièges, planche de bord, creux fermés comme l'intérieur d'une portière).

Une cellule est « interdite » si elle est dans l'air extérieur, ou à plus de `tolerance` de l'air de
l'habitacle (enfoncée dans une paroi). Toucher un siège ou une garniture reste permis. La grille
interdite est exportée en RLE (`Cabin.Bad`) ; le runtime y teste des points du corps.

Choix : les parois sont épaissies d'une cellule avant le remplissage pour fermer les petits jours
entre panneaux (≤ 2 cellules). Si l'air de l'habitacle rejoint l'air extérieur (cabriolet, vitre
absente), l'habitacle est marqué `Open` et le runtime n'adapte pas le corps.
"""
from __future__ import annotations

import numpy as np

# Parties qui ne bornent pas l'habitacle : roues et ce qui les suit.
_SKIP_PREFIX = ("wheel_", "hub_", "suspension_")


def _subdivide(tris: np.ndarray, max_edge: float) -> np.ndarray:
    """Points couvrant chaque triangle avec un pas ≤ max_edge (sommets des sous-triangles)."""
    pts = [tris.reshape(-1, 3)]
    cur = tris
    for _ in range(16):
        e = np.max(np.stack([np.linalg.norm(cur[:, 0] - cur[:, 1], axis=1),
                             np.linalg.norm(cur[:, 1] - cur[:, 2], axis=1),
                             np.linalg.norm(cur[:, 2] - cur[:, 0], axis=1)]), axis=0)
        big = cur[e > max_edge]
        if len(big) == 0:
            break
        a, b, c = big[:, 0], big[:, 1], big[:, 2]
        ab, bc, ca = (a + b) / 2, (b + c) / 2, (c + a) / 2
        pts.append(np.concatenate([ab, bc, ca]))
        cur = np.concatenate([np.stack([a, ab, ca], 1), np.stack([ab, b, bc], 1),
                              np.stack([ca, bc, c], 1), np.stack([ab, bc, ca], 1)])
    return np.concatenate(pts)


def _dilate(m: np.ndarray) -> np.ndarray:
    """Dilatation à 6 voisins (grille [z, y, x])."""
    o = m.copy()
    o[1:] |= m[:-1]
    o[:-1] |= m[1:]
    o[:, 1:] |= m[:, :-1]
    o[:, :-1] |= m[:, 1:]
    o[:, :, 1:] |= m[:, :, :-1]
    o[:, :, :-1] |= m[:, :, 1:]
    return o


def _flood(seed: np.ndarray, passable: np.ndarray) -> np.ndarray:
    region = seed & passable
    while True:
        nxt = _dilate(region) & passable
        if nxt.sum() == region.sum():
            return nxt
        region = nxt


def _rle(bits: np.ndarray) -> str:
    """Longueurs de plages alternées (0 d'abord), en base 36, séparées par des virgules."""
    flat = bits.ravel().astype(np.int8)
    change = np.flatnonzero(np.diff(flat)) + 1
    bounds = np.concatenate([[0], change, [len(flat)]])
    runs = np.diff(bounds).tolist()
    if flat[0] == 1:
        runs = [0] + runs

    def b36(n: int) -> str:
        s = ""
        while True:
            n, r = divmod(n, 36)
            s = "0123456789abcdefghijklmnopqrstuvwxyz"[r] + s
            if n == 0:
                return s
    return ",".join(b36(r) for r in runs)


def build_cabin(parts, seats: list[dict], *, cell: float = 0.04, tolerance: float = 0.08,
                margin: int = 3) -> dict | None:
    """Grille d'habitacle pour Cabin dans la config. `parts` : pièces visibles (pos en mètres,
    repère de sortie), `seats` : CONFIG.Seats (Position = os du siège)."""
    tris = []
    for p in parts:
        if p.mod is not None or p.owner.startswith(_SKIP_PREFIX) or p.bone.startswith(_SKIP_PREFIX):
            continue
        tris.append(p.pos.astype(np.float64)[p.idx.reshape(-1, 3)])
    if not tris or not seats:
        return None
    tris = np.concatenate(tris)
    pts = _subdivide(tris, cell * 0.5)
    lo = pts.min(axis=0) - margin * cell
    hi = pts.max(axis=0) + margin * cell
    dims = np.ceil((hi - lo) / cell).astype(int) + 1          # x, y, z
    solid = np.zeros((dims[2], dims[1], dims[0]), dtype=bool)
    ijk = np.floor((pts - lo) / cell).astype(int)
    solid[ijk[:, 2], ijk[:, 1], ijk[:, 0]] = True
    walls = _dilate(solid)                                     # ferme les jours entre panneaux
    air = ~walls

    border = np.zeros_like(solid)
    border[[0, -1], :, :] = True
    border[:, [0, -1], :] = True
    border[:, :, [0, -1]] = True
    exterior = _flood(border, air)

    seed = np.zeros_like(solid)
    seeds = []
    for s in seats:
        # au-dessus de l'os du siège, à hauteur de poitrine : la première cellule d'air libre
        base = np.array(s["Position"], dtype=np.float64)
        for dy in np.arange(0.25, 0.8, cell):
            q = np.floor((base + [0, dy, 0] - lo) / cell).astype(int)
            if (q >= 0).all() and (q < dims).all() and air[q[2], q[1], q[0]]:
                seed[q[2], q[1], q[0]] = True
                seeds.append(q)
                break
    cabin = _flood(seed, air)
    open_ = bool((cabin & exterior).any()) or not seeds
    near = cabin.copy()
    for _ in range(max(0, int(round(tolerance / cell)))):
        near = _dilate(near)
    bad = exterior | ~near
    return {
        "Origin": [round(float(v), 4) for v in lo],
        "Cell": cell,
        "Dims": [int(d) for d in dims],
        "Tolerance": tolerance,
        "Open": open_,
        "Bad": _rle(bad),
        "Stats": {"CabinCells": int(cabin.sum()), "BadCells": int(bad.sum()), "Cells": int(bad.size),
                  "Seeds": len(seeds)},
    }
