"""Comble la collision officielle là où la carrosserie visible la dépasse (kits larges, ailes élargies).

Constat (rm3e36, M3 E36 en kit Rocket Bunny, 2026-11-19) : la collision du .yft est celle de la caisse d'origine ;
les ailes élargies du kit la dépassent de 10 à 20 cm. Verify mesurait 75 % des rayons à moins de 15 cm de la
carrosserie (seuil 80 %), dont 17 % « trop juste ».

Méthode :
  1. sommets des pièces visibles de l'os racine (caisse) hors options de custom, vitres, optiques et intérieur ;
  2. un sommet est « découvert » s'il est hors de tous les morceaux de collision fermés (parité d'un rayon) ET à
     plus de `threshold` (10 cm) de leur surface (point le plus proche sur un triangle, calcul exact) ;
  3. jamais sous le bas de la collision d'origine : la garde au sol et la conduite ne changent pas ;
  4. regroupement en cellules de `cell` (30 cm) ; pour chaque cellule, enveloppe convexe des sommets découverts
     ET de leurs points les plus proches sur la collision : la pièce remplit l'écart entre la carrosserie et la
     collision d'origine, sans déborder vers l'extérieur ;
  5. passages de roues dégagés : une pièce qui empiète sur le volume balayé par une roue (pneu en compression
     maximale, `travel` au-dessus de sa position de repos) est redécoupée en cellules deux fois plus petites, puis
     abandonnée si elle empiète encore (premier essai rm3e36 : coques à 4-8 cm sous le dessus des pneus, Verify).
Chaque pièce est convexe (précision Hull dans Roblox), nommée col__<os>__fill<n>, soudée à l'os racine.
"""
from __future__ import annotations

import numpy as np

SKIP_KINDS = ("glass", "light", "siren", "interior", "decal", "tire", "plate", "emissive", "rotor")


# ------------------------------------------------------------------ géométrie

def closest_on_triangles(p: np.ndarray, a: np.ndarray, b: np.ndarray, c: np.ndarray) -> np.ndarray:
    """Point le plus proche de chaque p (N,3) sur chaque triangle (T,3) : (N, T, 3). Ericson, vectorisé."""
    p = p[:, None, :]
    ab, ac, ap = b - a, c - a, p - a
    d1 = np.einsum("ntk,tk->nt", ap, ab)
    d2 = np.einsum("ntk,tk->nt", ap, ac)
    bp = p - b
    d3 = np.einsum("ntk,tk->nt", bp, ab)
    d4 = np.einsum("ntk,tk->nt", bp, ac)
    cp = p - c
    d5 = np.einsum("ntk,tk->nt", cp, ab)
    d6 = np.einsum("ntk,tk->nt", cp, ac)
    va = d3 * d6 - d5 * d4
    vb = d5 * d2 - d1 * d6
    vc = d1 * d4 - d3 * d2
    denom = va + vb + vc
    denom = np.where(np.abs(denom) < 1e-18, 1e-18, denom)
    v = vb / denom
    w = vc / denom
    out = a + ab * v[..., None] + ac * w[..., None]                       # intérieur
    # régions des arêtes
    m_ab = (vc <= 0) & (d1 >= 0) & (d3 <= 0)
    t_ab = np.where(np.abs(d1 - d3) < 1e-18, 0, d1 / np.where(np.abs(d1 - d3) < 1e-18, 1, d1 - d3))
    out = np.where(m_ab[..., None], a + ab * t_ab[..., None], out)
    m_ac = (vb <= 0) & (d2 >= 0) & (d6 <= 0)
    t_ac = np.where(np.abs(d2 - d6) < 1e-18, 0, d2 / np.where(np.abs(d2 - d6) < 1e-18, 1, d2 - d6))
    out = np.where(m_ac[..., None], a + ac * t_ac[..., None], out)
    m_bc = (va <= 0) & ((d4 - d3) >= 0) & ((d5 - d6) >= 0)
    den_bc = (d4 - d3) + (d5 - d6)
    t_bc = np.where(np.abs(den_bc) < 1e-18, 0, (d4 - d3) / np.where(np.abs(den_bc) < 1e-18, 1, den_bc))
    out = np.where(m_bc[..., None], b + (c - b) * t_bc[..., None], out)
    # régions des sommets
    out = np.where(((d1 <= 0) & (d2 <= 0))[..., None], a, out)
    out = np.where(((d3 >= 0) & (d4 <= d3))[..., None], b, out)
    out = np.where(((d6 >= 0) & (d5 <= d6))[..., None], c, out)
    return out


def nearest_points(p: np.ndarray, a: np.ndarray, b: np.ndarray, c: np.ndarray, chunk: int = 2048):
    """(distance (N,), point le plus proche (N,3)) sur l'ensemble des triangles."""
    dist = np.empty(len(p))
    best = np.empty((len(p), 3))
    for i in range(0, len(p), chunk):
        q = closest_on_triangles(p[i:i + chunk], a, b, c)
        d = np.linalg.norm(q - p[i:i + chunk, None, :], axis=2)
        k = d.argmin(axis=1)
        dist[i:i + chunk] = d[np.arange(len(k)), k]
        best[i:i + chunk] = q[np.arange(len(k)), k]
    return dist, best


def _closed(idx: np.ndarray) -> bool:
    edges: dict[tuple[int, int], int] = {}
    for t in idx.reshape(-1, 3):
        for i in range(3):
            k = (int(min(t[i], t[(i + 1) % 3])), int(max(t[i], t[(i + 1) % 3])))
            edges[k] = edges.get(k, 0) + 1
    return bool(edges) and all(v == 2 for v in edges.values())


def inside_mesh(p: np.ndarray, pos: np.ndarray, idx: np.ndarray, chunk: int = 4096) -> np.ndarray:
    """Parité d'un rayon légèrement incliné (évite arêtes et sommets) : vrai si p est dans le maillage fermé."""
    tris = idx.reshape(-1, 3)
    a, b, c = pos[tris[:, 0]].astype(np.float64), pos[tris[:, 1]].astype(np.float64), pos[tris[:, 2]].astype(np.float64)
    d = np.array([1.0, 0.0137, 0.0071])
    d /= np.linalg.norm(d)
    e1, e2 = b - a, c - a
    h = np.cross(d, e2)
    det = np.einsum("tk,tk->t", e1, h)
    ok = np.abs(det) > 1e-12
    inv = np.where(ok, 1.0 / np.where(ok, det, 1), 0)
    out = np.zeros(len(p), bool)
    for i in range(0, len(p), chunk):
        s = p[i:i + chunk, None, :] - a[None]
        u = np.einsum("ntk,tk->nt", s, h) * inv
        q = np.cross(s, e1[None])
        v = np.einsum("k,ntk->nt", d, q) * inv
        t = np.einsum("ntk,tk->nt", q, e2) * inv
        hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (t > 1e-9)
        out[i:i + chunk] = (hit.sum(axis=1) % 2) == 1
    return out


def _manifold_sphere(tris: np.ndarray, nverts: int) -> bool:
    """Surface fermée de genre 0 : chaque arête dans 2 faces exactement et T = 2V - 4 (Euler)."""
    edges: dict[tuple[int, int], int] = {}
    for t in tris:
        for k in range(3):
            key = (int(min(t[k], t[(k + 1) % 3])), int(max(t[k], t[(k + 1) % 3])))
            edges[key] = edges.get(key, 0) + 1
    return all(v == 2 for v in edges.values()) and len(tris) == 2 * nverts - 4


def convex_hull(pts: np.ndarray, seed: int = 0):
    """Enveloppe convexe 3D, manifold garanti (vérifiée) : points légèrement « secoués » (joggle, comme QHull QJ)
    pour sortir des cas coplanaires, qui donnaient des faces en trop (rm3e36 : 28 enveloppes sur 88 refusées par le
    CSG de Roblox, « non-manifold »). Renvoie (sommets, triangles orientés vers l'extérieur) ou None."""
    base = np.unique(np.round(np.asarray(pts, float), 6), axis=0)
    if len(base) < 4:
        return None
    rng = np.random.default_rng(seed)
    for jog in (1e-5, 1e-4, 5e-4):
        got = _hull_once(base + rng.normal(scale=jog, size=base.shape))
        if got is not None and _manifold_sphere(got[1], len(got[0])):
            return got
    return None


def _hull_once(pts: np.ndarray, eps: float = 1e-9):
    """Enveloppe convexe incrémentale (petits nuages), test de visibilité sur normales unitaires."""
    # tétraèdre de départ non dégénéré
    i0 = 0
    i1 = int(np.argmax(np.linalg.norm(pts - pts[i0], axis=1)))
    line = pts[i1] - pts[i0]
    if np.linalg.norm(line) < 1e-6:
        return None
    dl = np.linalg.norm(np.cross(pts - pts[i0], line), axis=1)
    i2 = int(np.argmax(dl))
    if dl[i2] < 1e-6:
        return None
    nrm = np.cross(pts[i1] - pts[i0], pts[i2] - pts[i0])
    dp = (pts - pts[i0]) @ nrm
    i3 = int(np.argmax(np.abs(dp)))
    if abs(dp[i3]) < 1e-9:
        return None
    faces = [(i0, i1, i2), (i0, i3, i1), (i1, i3, i2), (i2, i3, i0)]
    centroid = pts[[i0, i1, i2, i3]].mean(axis=0)

    def oriented(f):
        a, b, c = pts[f[0]], pts[f[1]], pts[f[2]]
        n = np.cross(b - a, c - a)
        return f if (centroid - a) @ n < 0 else (f[0], f[2], f[1])

    faces = [oriented(f) for f in faces]
    for k in range(len(pts)):
        if k in (i0, i1, i2, i3):
            continue
        p = pts[k]
        visible = []
        for f in faces:
            a, b, c = pts[f[0]], pts[f[1]], pts[f[2]]
            n = np.cross(b - a, c - a)
            ln = np.linalg.norm(n)
            if ln > 1e-15 and (p - a) @ (n / ln) > eps:
                visible.append(f)
        if not visible:
            continue
        edge_count: dict[tuple[int, int], int] = {}
        for f in visible:
            for e in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
                key = (min(e), max(e))
                edge_count[key] = edge_count.get(key, 0) + 1
        horizon = []
        for f in visible:
            for e in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
                if edge_count[(min(e), max(e))] == 1:
                    horizon.append(e)
        faces = [f for f in faces if f not in visible]
        for e in horizon:
            faces.append((e[0], e[1], k))
    used = sorted({i for f in faces for i in f})
    remap = {v: i for i, v in enumerate(used)}
    tris = np.array([[remap[i] for i in f] for f in faces], np.uint32)
    return pts[used].astype(np.float32), tris


def _hull_volume(v: np.ndarray, t: np.ndarray) -> float:
    a, b, c = v[t[:, 0]], v[t[:, 1]], v[t[:, 2]]
    return float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6.0)


# ------------------------------------------------------------------ comblement

def wheel_samples(wheels, travel: float = 0.16, margin: float = 0.03) -> np.ndarray:
    """Points du volume balayé par chaque roue : pneu (rayon + marge) du bas jusqu'à `travel` au-dessus du repos."""
    pts = []
    for w in wheels or []:
        c = np.asarray(w.center, float)
        r, wd = float(w.radius) + margin, float(w.width) + 2 * margin
        # colonnes serrées et 1 cm en hauteur : une pièce mince passait entre des points espacés de 9 cm
        for fx in np.linspace(-0.5, 0.5, 7):
            for fz in np.linspace(-1, 1, 15):
                top = r * np.sqrt(max(0.0, 1 - fz * fz))
                for fy in np.arange(-top, top + travel + 0.005, 0.01):
                    pts.append(c + np.array([fx * wd, fy, fz * r]))
    return np.array(pts) if pts else np.zeros((0, 3))


def wheel_cutters(wheels, handling: dict | None, margin: float = 0.03, outer_reach: float = 0.6) -> list[dict]:
    """Mêmes volumes que VehicleCollision.WheelCutters (runtime) : par roue, un « stade » d'axe x (deux cylindres de
    rayon R aux débattements haut et bas + la boîte entre eux), de la face intérieure de la roue braquée au maximum
    jusqu'à 0,6 m au-delà de sa face extérieure. Les pièces de comblement qui les touchent ne seraient pas creusables
    (CSG refusé sur un petit maillage convexe) : on les écarte à la conversion."""
    h = handling or {}
    upper = float(h.get("SuspensionUpperLimit", 0.1)) + float(h.get("SuspensionRaise", 0) or 0)
    lower = float(h.get("SuspensionLowerLimit", -0.15))
    lock = float(h.get("SteeringLockRad") or np.radians(float(h.get("SteeringLockDeg", 35))))
    out = []
    for w in wheels or []:
        c = np.asarray(w.center, float)
        r, hw = float(w.radius), float(w.width) / 2
        steers = c[2] < 0  # roues avant (l'avant du véhicule vers -Z)
        th = lock if steers else 0.0
        z_half = np.sqrt(r * r + hw * hw) if steers else r
        inward = hw * np.cos(th) + r * np.sin(th)
        x_in = abs(c[0]) - inward - margin
        x_out = abs(c[0]) + hw + outer_reach
        out.append({"side": -1.0 if c[0] < 0 else 1.0, "x_in": x_in, "x_out": x_out, "z": c[2],
                    "R": z_half + margin, "y_top": c[1] + upper, "y_bot": c[1] + lower})
    return out


def in_cutters(q: np.ndarray, cutters: list[dict]) -> np.ndarray:
    inside = np.zeros(len(q), bool)
    for k in cutters:
        ax = q[:, 0] * k["side"]
        dz = q[:, 2] - k["z"]
        y = np.clip(q[:, 1], k["y_bot"], k["y_top"])
        dist = np.sqrt(dz * dz + (q[:, 1] - y) ** 2)
        inside |= (ax >= k["x_in"]) & (ax <= k["x_out"]) & (dist <= k["R"])
    return inside


def _hull_hits_cutters(v: np.ndarray, t: np.ndarray, cutters: list[dict], step: float = 0.015) -> bool:
    if not cutters:
        return False
    if np.any(in_cutters(v, cutters)):
        return True
    lo, hi = v.min(axis=0), v.max(axis=0)
    axes = [np.arange(lo[i], hi[i] + step, step) for i in range(3)]
    g = np.stack(np.meshgrid(*axes, indexing="ij"), axis=-1).reshape(-1, 3)
    g = g[in_cutters(g, cutters)]
    return _hull_contains(v, t, g)


def _hull_contains(v: np.ndarray, t: np.ndarray, q: np.ndarray, tol: float = 1e-4) -> bool:
    if len(q) == 0:
        return False
    a, b, c = v[t[:, 0]], v[t[:, 1]], v[t[:, 2]]
    n = np.cross(b - a, c - a)
    if _hull_volume(v, t) < 0:
        n = -n
    d = np.einsum("fk,qfk->qf", n, q[:, None, :] - a[None])
    return bool(np.any(np.all(d <= tol * np.linalg.norm(n, axis=1)[None], axis=1)))


def fill_uncovered(parts, coll_meshes, root: str, threshold: float = 0.08, cell: float = 0.22,
                   max_points: int = 48, min_points: int = 4, seed: int = 7, wheels=None, travel: float = 0.16,
                   handling: dict | None = None, exclude_wheels: bool = False):
    """exclude_wheels=False (défaut) : les pièces vont jusque dans les passages de roues et le Setup les y creuse
    (CSG, comme la collision d'origine) — seul moyen de couvrir des ailes élargies, qui sont dans le volume de découpe.
    True : écarte à la conversion ce qui touche le volume de découpe (si le CSG de Roblox refuse les pièces).
    Renvoie (pièces, stats). pièces = [(nom, sommets (n,3), triangles (m,3))] ; vide si rien à combler."""
    body = [p for p in parts if p.bone == root and p.mod is None and p.kind not in SKIP_KINDS
            and p.window is None and p.extra is None and p.tri_count > 0]
    return _fill_bone(body, coll_meshes, root, threshold, cell, max_points, min_points, seed, wheels, travel,
                      handling, exclude_wheels)


def fill_all_bones(parts, coll_meshes, bones: list[str], **kw):
    """Comblement os par os (racine, capot, coffre, portières…) : chaque pièce suit son os (capot ouvert, portière).
    rm3e36 : sans le capot, 23 des 50 rayons « trop juste » de Verify tombaient sur le capot."""
    pieces, stats = [], {"points": 0, "uncovered": 0, "pieces": 0, "dropped_wheel": 0}
    for bone in bones:
        body = [p for p in parts if p.bone == bone and p.mod is None and p.kind not in SKIP_KINDS
                and p.window is None and p.extra is None and p.tri_count > 0]
        if not body:
            continue
        got, st = _fill_bone(body, coll_meshes, bone, **kw)
        pieces += [(name, v, t, bone) for name, v, t in got]
        for k in stats:
            stats[k] += st.get(k, 0)
    return pieces, stats


def _fill_bone(body, coll_meshes, root, threshold=0.08, cell=0.22, max_points=48, min_points=4, seed=7, wheels=None,
               travel=0.16, handling=None, exclude_wheels=False):
    if not body or not coll_meshes:
        return [], {"points": 0, "uncovered": 0}
    pts = np.unique(np.round(np.concatenate([p.pos for p in body]).astype(np.float64), 4), axis=0)
    cpos = [m.pos.astype(np.float64) for m in coll_meshes]
    cidx = [m.idx.reshape(-1, 3).astype(np.int64) for m in coll_meshes]
    A = np.concatenate([P[I[:, 0]] for P, I in zip(cpos, cidx)])
    B = np.concatenate([P[I[:, 1]] for P, I in zip(cpos, cidx)])
    C = np.concatenate([P[I[:, 2]] for P, I in zip(cpos, cidx)])
    floor = min(float(P[:, 1].min()) for P in cpos) + 0.02
    pts = pts[pts[:, 1] >= floor]
    inside = np.zeros(len(pts), bool)
    for P, I in zip(cpos, cidx):
        if _closed(I):
            inside |= inside_mesh(pts, P, I)
    cand = pts[~inside]
    dist, near = nearest_points(cand, A, B, C)
    out_mask = dist > threshold
    up, upnear = cand[out_mask], near[out_mask]
    stats = {"points": int(len(pts)), "uncovered": int(len(up))}
    if len(up) == 0:
        return [], stats
    rng = np.random.default_rng(seed)
    all_cutters = wheel_cutters(wheels, handling)  # convexes (stade extrudé) : sommets dedans => pièce dedans
    cutters = all_cutters if exclude_wheels else []
    if cutters:
        keep = ~in_cutters(up, cutters)  # sommets dans un passage de roue : jamais dans une pièce
        up, upnear = up[keep], upnear[keep]
    blockers = wheel_samples(wheels, travel) if exclude_wheels else np.zeros((0, 3))
    pieces = []
    dropped = 0

    def build(sel_pts, sel_near):
        cloud = np.concatenate([sel_pts, sel_near])
        if len(cloud) > max_points:
            # sous-échantillon qui garde les extrêmes (enveloppe stable)
            ext = np.unique(np.concatenate([cloud.argmin(axis=0), cloud.argmax(axis=0)]))
            rest = np.setdiff1d(np.arange(len(cloud)), ext)
            take = rng.choice(rest, size=max(0, max_points - len(ext)), replace=False) if len(rest) else []
            cloud = cloud[np.concatenate([ext, np.asarray(take, int)])]
        hull = convex_hull(cloud)
        if hull is None:
            return None
        v, t = hull
        v64, t64 = v.astype(np.float64), t.astype(np.int64)
        if abs(_hull_volume(v64, t64)) < 2e-6:  # < 2 cm³ : copeau inutile
            return None
        if all_cutters and bool(np.all(in_cutters(v64, all_cutters))):
            return None  # entièrement dans un passage de roue : le Setup la creuserait jusqu'à rien
        return v, t, (_hull_contains(v64, t64, blockers) or _hull_hits_cutters(v64, t64, cutters))

    def place(sel_pts, sel_near, size, depth):
        nonlocal dropped
        keys = np.floor(sel_pts / size).astype(np.int64)
        for key in sorted({tuple(k) for k in keys}):
            sel = np.all(keys == np.array(key), axis=1)
            if sel.sum() < min_points:
                continue
            got = build(sel_pts[sel], sel_near[sel])
            if got is None:
                continue
            v, t, blocks = got
            if not blocks:
                pieces.append((f"col__{root}__fill{len(pieces) + 1}", v, t))
            elif depth < 2:
                place(sel_pts[sel], sel_near[sel], size / 2, depth + 1)
            else:
                dropped += 1

    place(up, upnear, cell, 0)
    stats["pieces"] = len(pieces)
    stats["dropped_wheel"] = dropped
    return pieces, stats
