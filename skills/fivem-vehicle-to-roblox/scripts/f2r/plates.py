"""Plaques d'immatriculation : position exacte de la plaque et de sa zone de texte.

Dans GTA V, le texte n'est pas dans la texture : le shader ``vehicle_licenseplate`` dessine jusqu'à
8 caractères dans le rectangle ``LicensePlateFontExtents`` = (u0, v0, u1, v1) de l'espace UV de la
plaque. On retrouve ici ce rectangle (et celui de la plaque entière) sur le maillage, pour poser
dans Roblox une surface de texte exactement au même endroit.

Repère de sortie : repère local du véhicule (x droite, y haut, z arrière), en mètres.
"""
from __future__ import annotations

import numpy as np

# Valeur par défaut du shader (presets Sollumz / CodeWalker) si le paramètre est absent ou invalide.
DEFAULT_FONT_EXTENTS = (0.043, 0.38, 0.945, 0.841)
DEFAULT_LETTERS = 8


def islands(idx: np.ndarray, n_vertices: int) -> list[np.ndarray]:
    """Triangles regroupés par composantes connexes (une plaque avant et une arrière dans la même
    pièce donnent deux îlots). Renvoie une liste de tableaux (k, 3) d'indices de sommets."""
    tris = idx.reshape(-1, 3).astype(np.int64)
    parent = np.arange(n_vertices)

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for a, b, c in tris:
        ra, rb, rc = find(a), find(b), find(c)
        parent[rb] = ra
        parent[find(rc)] = ra
    roots = np.array([find(t[0]) for t in tris]) if len(tris) else np.zeros(0, int)
    return [tris[roots == r] for r in np.unique(roots)]


def _bary(p, a, b, c):
    v0, v1, v2 = b - a, c - a, p - a
    d00, d01, d11 = v0 @ v0, v0 @ v1, v1 @ v1
    d20, d21 = v2 @ v0, v2 @ v1
    den = d00 * d11 - d01 * d01
    if abs(den) < 1e-14:
        return None
    v = (d11 * d20 - d01 * d21) / den
    w = (d00 * d21 - d01 * d20) / den
    return np.array([1 - v - w, v, w])


def uv_to_pos(P: np.ndarray, UV: np.ndarray, tris: np.ndarray, uv) -> np.ndarray:
    """Position 3D du point d'UV ``uv`` sur le maillage (triangle le plus proche si le point est hors maillage)."""
    uv = np.asarray(uv, float)
    best, best_err = None, np.inf
    for t in tris:
        w = _bary(uv, UV[t[0]], UV[t[1]], UV[t[2]])
        if w is None:
            continue
        err = float(np.clip(-w, 0, None).sum())  # 0 si le point est dans le triangle
        if err < best_err:
            best, best_err = (t, w), err
            if err <= 1e-6:
                break
    if best is None:
        return P[tris.ravel()].mean(axis=0)
    t, w = best
    if best_err > 1e-6:  # hors du triangle : on borne les coordonnées barycentriques
        w = np.clip(w, 0, None)
        w = w / (w.sum() or 1)
    return w[0] * P[t[0]] + w[1] * P[t[1]] + w[2] * P[t[2]]


def _rect(P, UV, tris, u0, v0, u1, v1, normal):
    """Rectangle 3D correspondant au rectangle UV (u0,v0)-(u1,v1) ; v croît vers le bas de l'image."""
    top_left = uv_to_pos(P, UV, tris, (u0, v0))
    top_right = uv_to_pos(P, UV, tris, (u1, v0))
    bottom_left = uv_to_pos(P, UV, tris, (u0, v1))
    right = top_right - top_left
    up = top_left - bottom_left
    width, height = float(np.linalg.norm(right)), float(np.linalg.norm(up))
    center = top_left + right / 2 - up / 2
    return center, right / (width or 1), up / (height or 1), width, height


def plate_zones(pos: np.ndarray, nrm: np.ndarray, uv: np.ndarray, idx: np.ndarray, vectors: dict) -> list[dict]:
    """Une zone par plaque (îlot) : rectangle de la plaque entière et zone de texte du shader."""
    ext = list(vectors.get("LicensePlateFontExtents") or DEFAULT_FONT_EXTENTS)[:4]
    if len(ext) < 4 or not (ext[2] > ext[0] and ext[3] > ext[1]):
        ext = list(DEFAULT_FONT_EXTENTS)
    letters = vectors.get("NumLetters")
    letters = int(round(letters[0])) if letters else DEFAULT_LETTERS
    if not 1 <= letters <= 8:
        letters = DEFAULT_LETTERS
    P, N, UV = pos.astype(float), nrm.astype(float), uv.astype(float)
    zones = []
    for tris in islands(idx, len(P)):
        used = np.unique(tris.ravel())
        n = N[used].mean(axis=0)
        n = n / (np.linalg.norm(n) or 1)
        umin, vmin = UV[used].min(axis=0)
        umax, vmax = UV[used].max(axis=0)
        # plaque entière = étendue UV de l'îlot (normalement 0..1)
        pc, right, up, pw, ph = _rect(P, UV, tris, umin, vmin, umax, vmax, n)
        if pw < 1e-3 or ph < 1e-3:
            continue  # îlot dégénéré (UV écrasées) : pas une plaque exploitable
        # repère direct (texte jamais en miroir), normale vers l'extérieur
        if np.dot(np.cross(right, up), n) < 0:
            right = -right
        normal = np.cross(right, up)
        normal = normal / (np.linalg.norm(normal) or 1)
        # zone de texte : extents exprimés dans l'espace UV de la plaque (0..1)
        fu = lambda f: umin + f * (umax - umin)  # noqa: E731
        fv = lambda f: vmin + f * (vmax - vmin)  # noqa: E731
        tc, _, _, tw, th = _rect(P, UV, tris, fu(ext[0]), fv(ext[1]), fu(ext[2]), fv(ext[3]), n)
        # zone de texte en fractions de la plaque (origine en haut à gauche, comme une interface Roblox)
        dx, dy = float(np.dot(tc - pc, right)), float(np.dot(tc - pc, up))
        text_rect = [(pw / 2 + dx - tw / 2) / pw, (ph / 2 - dy - th / 2) / ph, tw / pw, th / ph]
        zones.append({
            "Center": [round(float(x), 5) for x in pc],
            "Right": [round(float(x), 5) for x in right],
            "Up": [round(float(x), 5) for x in up],
            "Normal": [round(float(x), 5) for x in normal],
            "Width": round(pw, 5), "Height": round(ph, 5),
            "TextCenter": [round(float(x), 5) for x in tc],
            "TextWidth": round(tw, 5), "TextHeight": round(th, 5),
            "TextRect": [round(min(max(v, 0.0), 1.0), 5) for v in text_rect],
            "Letters": letters,
            "Front": bool(normal[2] < 0),  # normale vers l'avant (-Z) : plaque avant
        })
    return zones
