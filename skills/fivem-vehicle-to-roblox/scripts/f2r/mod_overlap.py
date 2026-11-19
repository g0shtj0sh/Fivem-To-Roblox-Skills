"""Pièces de custom posées EXACTEMENT sur la géométrie d'origine (z-fighting dans Roblox).

Constat (325e de HRH, calandres ``325e_gra`` / ``325e_grb``, 2026-11-19) : une pièce de custom peut être une copie
triangle pour triangle de la géométrie d'origine (même position, autre matériau : lamelles noires au lieu de la
couleur de caisse), attachée à un os qui ne se masque pas (``chassis``) et sans ``turnOffBones``. Dans GTA, deux
triangles identiques donnent exactement la même profondeur et le dernier dessiné gagne : rendu propre. Dans Roblox,
chaque MeshPart a sa propre compression de sommets, les profondeurs diffèrent d'un rien et les deux surfaces se
battent (« comme deux calandres superposées », signalé par l'utilisateur). ``_replaces_stock`` (boîtes englobantes)
ne peut rien ici : la pièce d'origine est la caisse entière.

Correctif : les triangles d'origine recouverts par les triangles d'une option de custom quittent leur pièce pour une
pièce ``<pièce>__under<n>`` (même os, même matériau), groupés par l'ensemble des options qui les recouvrent ;
attribut ``HideWithMods`` = « Grille:1,Grille:2 ». Le runtime (VehicleCustomization.Refresh) la masque quand une de
ces options est posée. Les options qui masquent déjà l'os de la pièce (turnOffBones) ne comptent pas.
"""

from __future__ import annotations

from collections import defaultdict
from dataclasses import replace

import numpy as np

# 1 mm : les copies mesurées sont identiques à 1e-5 m près ; une vraie pièce voisine n'a pas 3 sommets à 1 mm
TOLERANCE_M = 0.001


def _tri_keys(p) -> list:
    """Clé par triangle, indépendante de l'ordre des sommets (positions arrondies à TOLERANCE_M)."""
    q = np.round(p.pos.astype(np.float64) / TOLERANCE_M).astype(np.int64)
    tris = p.idx.reshape(-1, 3)
    keys = []
    for t in tris:
        a, b, c = (tuple(q[i]) for i in t)
        keys.append(tuple(sorted((a, b, c))))
    return keys


def _chain(p, ancestors) -> set:
    try:
        return set(ancestors(p.bone)) | {p.bone, p.owner}
    except Exception:  # noqa: BLE001 — os inconnu du squelette
        return {p.bone, p.owner}


def split_shadowed_stock(parts: list, mods_cfg: dict, ancestors, report) -> list[str]:
    """Sépare les triangles d'origine recouverts par une option de custom (voir l'en-tête). ``mods_cfg`` : la table
    ``Mods`` de la config (TurnOffBones par option). ``ancestors(bone)`` : os parents. Renvoie les pièces créées."""
    cover: dict = defaultdict(set)  # clé de triangle -> {"Slot:Index"}
    off_of: dict = {}
    for q in parts:
        if not q.mod or q.tri_count == 0:
            continue
        slot, index = q.mod["slot"], q.mod["index"]
        opts = (mods_cfg.get(slot) or {}).get("Options") or []
        off = set((opts[index - 1].get("TurnOffBones") or []) if 0 < index <= len(opts) else [])
        tag = f"{slot}:{index}"
        off_of[tag] = off
        for k in _tri_keys(q):
            cover[k].add(tag)
    if not cover:
        return []
    created: list[str] = []
    for p in list(parts):
        if p.mod or p.tri_count == 0 or p.kind == "collision":
            continue
        chain = _chain(p, ancestors)
        keys = _tri_keys(p)
        groups: dict = defaultdict(list)
        for i, k in enumerate(keys):
            tags = cover.get(k)
            if not tags:
                continue
            # une option qui masque déjà l'os de cette pièce n'a pas besoin d'elle
            tags = frozenset(t for t in tags if not (off_of.get(t, set()) & chain))
            if tags:
                groups[tags].append(i)
        if not groups:
            continue
        tris = p.idx.reshape(-1, 3)
        keep = np.ones(len(tris), bool)
        for n, (tags, sel_i) in enumerate(sorted(groups.items(), key=lambda kv: sorted(kv[0])), start=1):
            sel = tris[sel_i]
            verts = np.unique(sel)
            remap = np.full(len(p.pos), -1, np.int64)
            remap[verts] = np.arange(len(verts))
            name = f"{p.name}__under{n}"
            hide = ",".join(sorted(tags))
            sub = replace(p, name=name, pos=p.pos[verts].copy(), nrm=p.nrm[verts].copy(), uv=p.uv[verts].copy(),
                          idx=remap[sel].astype(np.uint32).reshape(-1), hide_with=hide)
            keep[sel_i] = False
            parts.append(sub)
            created.append(name)
            report.info(f"Custom posée sur la géométrie d'origine : {len(sel_i)} triangle(s) de {p.name} -> {name}, "
                        f"masquée(s) avec {hide} (sinon z-fighting dans Roblox).")
        p.idx = tris[keep].reshape(-1).astype(np.uint32)
    parts[:] = [p for p in parts if p.tri_count > 0]
    return created
