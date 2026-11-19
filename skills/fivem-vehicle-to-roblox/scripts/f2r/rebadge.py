"""Rebadge automatique : aucun logo ni lettrage de la marque réelle sur le véhicule converti.

Ce que fait ``rebadge_parts`` sur les pièces construites (avant l'écriture du GLB) :

1. Toute pièce dont la texture de couleur s'appelle *badge*, *logo*, *emblem*… est découpée en îlots
   (triangles reliés par leurs sommets).
2. Chaque îlot est classé d'après ce qu'il montre dans la texture (pixels sous ses triangles) et sa taille :
   - **uni** (texture sans motif sous l'îlot : baguette de bas de caisse, support) : gardé tel quel ;
   - **emblème** (presque aussi large que haut, au moins 3 cm : rond de calandre, de coffre, de volant) :
     sorti en pièce ``<pièce>__emblem<n>`` avec une texture neuve = fond de l'emblème d'origine + logo du jeu,
     **et une brillance unie** (``f2r_<pièce>_spec``, valeur médiane de la brillance d'origine sous l'îlot) :
     ses UV sont recadrés sur la nouvelle texture, donc la brillance d'origine (SpecSampler) y étalerait
     toute la planche de la marque réelle en relief de reflet (logo, lettres) ; aucune normal map non plus ;
   - **lettrage** (le reste : « M4 », « competition », logo d'étrier…) : supprimé.
3. Les logos *peints* dans d'autres textures (cache-moyeu, flanc de pneu, écran) ne sont pas détectables
   automatiquement : ``--rebadge-spec`` (JSON d'opérations par texture, voir ``apply_texture_spec``) ou
   ``--texture-overrides``.
4. Les lettrages *modélisés* (lettres en relief dans la géométrie d'une pièce ordinaire : pommeau, appuie-tête,
   seuil) non plus : planche ``lettering_sheet`` à regarder, boîtes ``remove_islands`` dans le même JSON
   (clé ``geometry``, voir ``remove_geometry``).
"""
from __future__ import annotations

import json
import re
from dataclasses import replace
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from .util import Report

BADGE_TEX = re.compile(r"badg|logo|emblem|emblm|marque|brand", re.I)  # badg : badge, badges, badging
PLAIN_STD = 0.04        # écart-type des couleurs sous l'îlot en dessous duquel il est « uni »
EMBLEM_MIN_M = 0.03     # 3 cm : en dessous, c'est un détail de lettrage
EMBLEM_MAX_M = 0.40
EMBLEM_ASPECT = 1.5     # largeur / hauteur max d'un emblème (rond, carré, écusson)
LOGO_FILL = 0.86        # part du diamètre de l'emblème occupée par le logo
EMBLEM_TEX = 512


def _islands(idx: np.ndarray, nverts: int) -> list[np.ndarray]:
    tris = idx.reshape(-1, 3)
    parent = np.arange(nverts)

    def find(a: int) -> int:
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for t in tris:
        r = find(int(t[0]))
        for v in t[1:]:
            parent[find(int(v))] = r
    groups: dict[int, list[int]] = {}
    for i, t in enumerate(tris):
        groups.setdefault(find(int(t[0])), []).append(i)
    return [np.array(g) for g in groups.values()]


def _uv_mask(uv: np.ndarray, tris: np.ndarray, w: int, h: int) -> np.ndarray:
    m = Image.new("L", (w, h))
    d = ImageDraw.Draw(m)
    for t in tris:
        pts = [(float(u * w), float(v * h)) for u, v in uv[t]]
        d.polygon(pts, fill=255)
    return np.asarray(m) > 0


def _load_rgba(img: Image.Image | None) -> np.ndarray | None:
    if img is None:
        return None
    return np.asarray(img.convert("RGBA"), np.float32) / 255.0


def _edge(mask: np.ndarray) -> np.ndarray:
    er = mask.copy()
    er[1:, :] &= mask[:-1, :]
    er[:-1, :] &= mask[1:, :]
    er[:, 1:] &= mask[:, :-1]
    er[:, :-1] &= mask[:, 1:]
    return mask & ~er


def _background(img: np.ndarray, mask: np.ndarray, opaque: bool) -> np.ndarray:
    """Couleur du fond de l'emblème d'origine : bande juste à l'intérieur de son contour (anneau du
    médaillon), sans les pixels transparents que le contour de l'îlot déborde souvent."""
    ys, xs = np.nonzero(mask)
    k = max(2, int(0.06 * max(np.ptp(xs), np.ptp(ys))))
    inner = mask.copy()
    for _ in range(k):
        inner = inner & ~_edge(inner)
    band = img[mask & ~inner]
    solid = band[band[:, 3] > 0.5] if len(band) else band
    if not len(solid):
        solid = img[mask][img[mask][:, 3] > 0.5]
    if not len(solid):
        return np.array([0.08, 0.08, 0.09, 1.0 if opaque else 0.0])
    c = np.median(solid, axis=0)
    if opaque:
        c[3] = 1.0
    return c


def emblem_texture(dst: Path, background: np.ndarray, logo: Image.Image | None, fill_ratio: float) -> Path:
    """Fond uni (couleur du bord de l'emblème d'origine) + logo centré."""
    size = EMBLEM_TEX
    bg = tuple(int(round(c * 255)) for c in np.clip(background, 0, 1))
    img = Image.new("RGBA", (size, size), bg)
    if logo is not None:
        s = int(size * LOGO_FILL * (1.0 if fill_ratio > 0.70 else 0.92))
        lg = logo.convert("RGBA").resize((s, s), Image.LANCZOS)
        img.alpha_composite(lg, ((size - s) // 2, (size - s) // 2))
    if bg[3] >= 250:
        img = img.convert("RGB")
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst, optimize=True)
    return dst


def emblem_spec(dst: Path, spec: np.ndarray | None, tris: np.ndarray, uv: np.ndarray) -> Path:
    """Brillance unie de l'emblème (4 x 4 px) : médiane de la carte spec d'origine sous l'îlot, sans le motif
    qu'elle porte (le logo de la marque réelle y est aussi dessiné). Sans spec lisible : spec noire = mat."""
    c = np.zeros(4, np.float32)
    if spec is not None:
        h, w = spec.shape[:2]
        px = spec[_uv_mask(uv, tris, w, h)]
        if len(px):
            c = np.median(px, axis=0)
    c[3] = 1.0
    img = Image.new("RGBA", (4, 4), tuple(int(round(v * 255)) for v in np.clip(c, 0, 1)))
    dst.parent.mkdir(parents=True, exist_ok=True)
    img.save(dst, optimize=True)
    return dst


def rebadge_parts(parts: list, original_tex, logo_path: Path | None, out_dir: Path, report: Report) -> dict:
    """Modifie ``parts`` (liste de f2r.vehicle.Part) sur place. ``original_tex(name) -> Path`` donne la
    image **du pack** (avant --texture-overrides, ``PIL.Image`` ou None) pour lire ce que montre chaque îlot.
    Les textures d'emblème sont écrites dans ``out_dir`` sous le nom ``f2r_<pièce>.png`` (= ``tex_diffuse``)."""
    logo = Image.open(logo_path) if logo_path else None
    summary = {"emblems": [], "removed": [], "kept_plain": 0}
    new_parts = []
    cache: dict[str, np.ndarray | None] = {}
    for p in list(parts):
        tex = p.tex_diffuse or ""
        if not BADGE_TEX.search(tex) or p.tri_count == 0:
            continue
        if tex.lower() not in cache:
            cache[tex.lower()] = _load_rgba(original_tex(tex))
        img = cache[tex.lower()]
        tris = p.idx.reshape(-1, 3)
        keep = np.ones(len(tris), bool)
        for n_isl, isl in enumerate(_islands(p.idx, len(p.pos))):
            t = tris[isl]
            verts = np.unique(t)
            ext = np.sort(np.ptp(p.pos[verts], axis=0))[::-1]
            if img is not None:
                h, w = img.shape[:2]
                mask = _uv_mask(p.uv, t, w, h)
                px = img[mask]
                std = float(px[:, :3].std()) if len(px) else 0.0
            else:
                mask, px, std = None, np.zeros((0, 4)), 1.0  # texture illisible : on suppose un marquage
            if std < PLAIN_STD:
                summary["kept_plain"] += 1
                continue
            is_emblem = (EMBLEM_MIN_M <= ext[0] <= EMBLEM_MAX_M and ext[1] > 0
                         and ext[0] / ext[1] <= EMBLEM_ASPECT)
            keep[isl] = False
            if not is_emblem:
                summary["removed"].append({"part": p.name, "tris": len(isl), "size_cm": [round(float(e) * 100, 1) for e in ext]})
                continue
            # --- emblème : nouvelle pièce, UV recadrés sur un carré, texture fond + logo
            uv = p.uv[verts]
            lo, hi = uv.min(axis=0), uv.max(axis=0)
            span = float(max(hi - lo)) or 1.0
            centre = (lo + hi) / 2
            remap = {int(v): i for i, v in enumerate(verts)}
            new_idx = np.vectorize(remap.get)(t).astype(np.uint32).reshape(-1)
            new_uv = ((uv - centre) / span + 0.5).astype(np.float32)
            if mask is not None and mask.any():
                background = _background(img, mask, opaque=p.kind != "decal")
                ys, xs = np.nonzero(mask)
                bbox_area = max(1, (np.ptp(xs) + 1) * (np.ptp(ys) + 1))
                fill_ratio = float(mask.sum()) / bbox_area
            else:
                background, fill_ratio = np.array([0.08, 0.08, 0.09, 1.0]), 0.785
            k = sum(1 for q in new_parts if q.bone == p.bone) + 1
            name = f"{p.bone}__emblem{k if k > 1 else ''}"
            png = emblem_texture(out_dir / f"f2r_{name}.png", background, logo, fill_ratio)
            # Shader propre à l'emblème : sa brillance d'origine est une planche de la marque réelle, que les
            # UV recadrés étaleraient sur tout l'emblème (logo fantôme dans les reflets, 2026-11-15).
            sh_tex = {k: v for k, v in p.shader.textures.items() if k not in ("SpecSampler", "BumpSampler")}
            spec_name = p.shader.textures.get("SpecSampler")
            if spec_name:
                skey = spec_name.lower()
                if skey not in cache:
                    cache[skey] = _load_rgba(original_tex(spec_name))
                emblem_spec(out_dir / f"f2r_{name}_spec.png", cache[skey], t, p.uv)
                sh_tex["SpecSampler"] = f"f2r_{name}_spec"
            q = replace(p, name=name, pos=p.pos[verts].copy(), nrm=p.nrm[verts].copy(), uv=new_uv,
                        idx=new_idx, tex_diffuse=f"f2r_{name}", tex_normal=None,
                        shader=replace(p.shader, textures=sh_tex),
                        kind="decal" if p.kind == "decal" else "mesh", paint=None, custom_color=None)
            new_parts.append(q)
            summary["emblems"].append({"part": name, "from": p.name, "tris": len(isl),
                                       "size_cm": [round(float(e) * 100, 1) for e in ext],
                                       "background": [round(float(c), 3) for c in background]})
        if not keep.all():
            p.idx = tris[keep].reshape(-1).astype(np.uint32)
    parts[:] = [p for p in parts if p.tri_count > 0] + new_parts
    report.info(f"Rebadge : {len(summary['emblems'])} emblème(s) remplacé(s) par le logo du jeu"
                f"{'' if logo else ' (aucun logo : fond uni)'}, {len(summary['removed'])} lettrage(s) / logo(s) "
                f"supprimé(s), {summary['kept_plain']} îlot(s) uni(s) gardé(s).")
    return summary


# ------------------------------------------------------------------ logos peints dans les textures

def _median_ring(a: np.ndarray, x0: int, y0: int, x1: int, y1: int) -> np.ndarray:
    h, w = a.shape[:2]
    xa, ya, xb, yb = max(x0 - 1, 0), max(y0 - 1, 0), min(x1 + 1, w), min(y1 + 1, h)
    ring = np.concatenate([a[ya, xa:xb], a[yb - 1, xa:xb], a[ya:yb, xa], a[ya:yb, xb - 1]])
    return np.median(ring, axis=0)


def _disc(shape, cx, cy, r0, r1=None):
    yy, xx = np.mgrid[:shape[0], :shape[1]]
    d = np.hypot(xx + 0.5 - cx, yy + 0.5 - cy)
    return (d <= r0) if r1 is None else ((d >= r0) & (d <= r1))


def apply_texture_spec(img: Image.Image, ops: list[dict], logo: Image.Image | None, ref_size=None,
                       role: str = "color") -> Image.Image:
    """Applique les opérations d'un ``--rebadge-spec`` à une texture (coordonnées en pixels de la texture
    d'origine, origine en haut à gauche ; ``ref_size`` = taille de mesure si elle diffère).

    Opérations : ``fill_rect`` {rect:[x0,y0,x1,y1], color?} · ``fill_disc`` {c:[x,y], r, ring?:[r0,r1]} ·
    ``fill_ring`` {c, r:[r0,r1]} · ``logo`` {c, size} (logo du jeu, ignoré sur une normal map) ·
    ``fill_all`` {color?}. Sans ``color`` : médiane du bord (rect), de l'anneau ``ring`` (disque) ou de la zone.
    Sur une normal map (``role == "normal"``) tout remplissage met une normale plate."""
    a = np.asarray(img.convert("RGBA"), np.float32) / 255.0
    a = a.copy()
    h, w = a.shape[:2]
    sx = w / ref_size[0] if ref_size else 1.0
    sy = h / ref_size[1] if ref_size else 1.0
    flat = np.array([0.5, 0.5, 1.0, 1.0], np.float32)

    def colour(op, default):
        if role == "normal":
            return flat
        if not op.get("color"):
            return default
        c = [float(v) for v in op["color"]]
        # RGBA de 0 à 1 (325e.json, rm3e36.json). [r, g, b] (alpha 1 ajouté) ou 0-255 (comme restyle_islands) : avant,
        # erreur numpy qui arrêtait la conversion, ou blanc (audit 2026-11-19)
        if len(c) == 3:
            c.append(1.0)
        if len(c) != 4:
            raise SystemExit(f"Retouche de texture {op.get('op')} : « color » attend [r, g, b, a] de 0 à 1, reçu {op['color']}.")
        rgb, alpha = c[:3], c[3]
        if max(rgb) > 1.0:  # 0-255
            rgb = [v / 255.0 for v in rgb]
        if alpha > 1.0:
            alpha /= 255.0
        return np.array(rgb + [alpha], np.float32)

    for op in ops:
        kind = op["op"]
        if kind == "fill_rect":
            x0, y0, x1, y1 = op["rect"]
            x0, x1 = int(round(x0 * sx)), int(round(x1 * sx))
            y0, y1 = int(round(y0 * sy)), int(round(y1 * sy))
            a[y0:y1, x0:x1] = colour(op, _median_ring(a, x0, y0, x1, y1))
        elif kind in ("fill_disc", "fill_ring"):
            cx, cy = op["c"][0] * sx, op["c"][1] * sy
            if kind == "fill_disc":
                m = _disc(a.shape, cx, cy, op["r"] * sx)
                ring = op.get("ring") or [op["r"] + 2, op["r"] + 6]
                default = np.median(a[_disc(a.shape, cx, cy, ring[0] * sx, ring[1] * sx)], axis=0)
            else:
                m = _disc(a.shape, cx, cy, op["r"][0] * sx, op["r"][1] * sx)
                default = np.median(a[m], axis=0)
            a[m] = colour(op, default)
        elif kind == "fill_all":
            a[:] = colour(op, np.median(a.reshape(-1, 4), axis=0))
        elif kind == "logo":
            if role == "normal" or logo is None:
                continue
            s = int(op["size"] * sx)
            lg = np.asarray(logo.convert("RGBA").resize((s, s), Image.LANCZOS), np.float32) / 255.0
            x0, y0 = int(round(op["c"][0] * sx - s / 2)), int(round(op["c"][1] * sy - s / 2))
            dst = a[y0:y0 + s, x0:x0 + s]
            al = lg[: dst.shape[0], : dst.shape[1], 3:4]
            dst[..., :3] = lg[: dst.shape[0], : dst.shape[1], :3] * al + dst[..., :3] * (1 - al)
            dst[..., 3:4] = al + dst[..., 3:4] * (1 - al)
        else:
            raise ValueError(f"rebadge-spec : opération inconnue « {kind} »")
    return Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "RGBA")


def load_spec(path: Path) -> dict:
    """{"textures": {"<nom de texture>": {"size": [w, h], "ops": [...]}, ...}}"""
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    return {k.lower(): v for k, v in doc.get("textures", {}).items()}


def load_geometry_spec(path: Path) -> list[dict]:
    """{"geometry": [{"op": "remove_islands", "box": [[x0,y0,z0],[x1,y1,z1]], "part"?: "...", "why": "..."}]}"""
    doc = json.loads(Path(path).read_text(encoding="utf-8"))
    return list(doc.get("geometry", []))


# ------------------------------------------------------------------ lettrages modélisés (géométrie)
#
# Constat (m422, 2026-11-15, capture de l'utilisateur) : le « ///M » du pommeau de vitesse, le « ///M » du
# repose-pied et les « M4 » des appuie-tête ne sont dans AUCUNE texture : ce sont des lettres modélisées,
# petits îlots de triangles posés en relief sur la pièce, avec le matériau de la pièce (cuir noir, plastique).
# Le rebadge par texture (îlots des pièces *badge*) ne les voit pas. Un détecteur purement géométrique ne sait
# pas les distinguer des vis, grilles et boutons (131 grappes sur la m422, presque toutes des vis du moteur) :
# on ne supprime donc rien d'office. La conversion dessine une planche des grappes de petits îlots
# (``lettering_sheet``) ; l'agent la regarde, et les lettrages qu'il y lit sont supprimés par des boîtes
# ``remove_islands`` dans ``brands/vehicles/<nom>.json`` (clé ``geometry``), relues à chaque conversion.

LETTER_ISLAND_MAX_M = 0.02   # un îlot de lettre : 2 cm au plus dans sa plus grande dimension
LETTER_GAP_M = 0.004         # deux îlots à moins de 4 mm l'un de l'autre font partie du même mot
LETTER_MIN_ISLANDS = 5       # en dessous : bouton, vis isolée
BOX_TOLERANCE_M = 0.001


def lettering_candidates(parts: list) -> list[dict]:
    """Grappes de petits îlots proches dans une même pièce (lettres modélisées possibles), les plus fournies
    d'abord. Chaque grappe : part, bone, islands (indices de triangles), box [[min],[max]] en mètres."""
    out = []
    for p in parts:
        if p.tri_count == 0:
            continue
        tris = p.idx.reshape(-1, 3)
        small = []
        for isl in _islands(p.idx, len(p.pos)):
            pts = p.pos[np.unique(tris[isl])]
            lo, hi = pts.min(axis=0), pts.max(axis=0)
            if float((hi - lo).max()) <= LETTER_ISLAND_MAX_M:
                small.append((isl, lo, hi))
        n = len(small)
        if n < LETTER_MIN_ISLANDS:
            continue
        par = list(range(n))

        def find(a: int) -> int:
            while par[a] != a:
                par[a] = par[par[a]]
                a = par[a]
            return a
        los = np.array([s[1] for s in small])
        his = np.array([s[2] for s in small])
        for a in range(n):
            gap = np.maximum(0, np.maximum(los[a] - his, los - his[a])).max(axis=1)
            for b in np.nonzero(gap <= LETTER_GAP_M)[0]:
                if b > a:
                    par[find(a)] = find(int(b))
        groups: dict[int, list[int]] = {}
        for a in range(n):
            groups.setdefault(find(a), []).append(a)
        for g in groups.values():
            if len(g) < LETTER_MIN_ISLANDS:
                continue
            out.append({"part": p.name, "bone": p.bone, "islands": [small[a][0] for a in g],
                        "box": [np.round(los[g].min(axis=0).astype(float), 4).tolist(),
                                np.round(his[g].max(axis=0).astype(float), 4).tolist()],
                        "_part": p})
    out.sort(key=lambda c: -len(c["islands"]))
    return out


def lettering_sheet(cands: list[dict], png: Path, cols: int = 10, tile: int = 128) -> None:
    """Planche contact : chaque grappe vue de face (plan principal de ses sommets), numérotée."""
    rows = max(1, (len(cands) + cols - 1) // cols)
    sheet = Image.new("RGB", (cols * tile, rows * (tile + 14)), "white")
    dr = ImageDraw.Draw(sheet)
    for k, c in enumerate(cands):
        p = c["_part"]
        tris = p.idx.reshape(-1, 3)
        tri_pts = np.concatenate([p.pos[tris[isl]] for isl in c["islands"]])  # (m, 3, 3)
        pts = tri_pts.reshape(-1, 3)
        ctr = pts.mean(axis=0)
        _, _, vt = np.linalg.svd(pts - ctr, full_matrices=False)
        uv = (pts - ctr) @ vt[:2].T
        lo, hi = uv.min(axis=0), uv.max(axis=0)
        s = (tile - 10) / max(float((hi - lo).max()), 1e-6)
        img = Image.new("RGB", (tile, tile), (235, 235, 235))
        di = ImageDraw.Draw(img)
        for t in ((uv - lo) * s + 5).reshape(-1, 3, 2):
            di.polygon([tuple(map(float, xy)) for xy in t], fill=(30, 30, 30))
        x, y = (k % cols) * tile, (k // cols) * (tile + 14)
        sheet.paste(img, (x, y))
        dr.text((x + 2, y + tile), f"{k} {p.name[:15]}", fill=(0, 0, 0))
    png.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(png)


def restyle_geometry(parts: list, ops: list[dict], out_dir: Path, report: Report) -> list[str]:
    """Opérations ``restyle_islands`` de la clé ``geometry`` : les îlots entièrement dans ``box`` (mêmes règles que
    ``remove_islands``) quittent leur pièce pour une pièce neuve ``<pièce>__<name>`` au matériau imposé :
    ``color`` [r, g, b] 0-255 (sRVB, texture unie ``f2r_<pièce>__<name>.png`` écrite dans ``out_dir``),
    ``roughness`` 0-1 et ``metal`` (bool) -> ``Part.mr_override``. Même os, même rattachement : la pièce suit la
    sienne. Usage : une pièce du mod qui partage son matériau avec d'autres mais doit en changer seule
    (m422 : le silencieux d'échappement, métal poli gris clair comme les manchons des sorties, 2026-11-15).
    Avec ``facing`` [x, y, z] (et ``min_dot``, 0,5 par défaut) : les TRIANGLES de la boîte tournés vers cette
    direction, sans exiger un îlot entier (tranche d'une coque de verre, 2026-11-16).
    Renvoie les noms des pièces créées."""
    created = []
    for op in ops:
        lo = np.array(op["box"][0], np.float32) - BOX_TOLERANCE_M
        hi = np.array(op["box"][1], np.float32) + BOX_TOLERANCE_M
        label = re.sub(r"[^A-Za-z0-9_]", "_", str(op.get("name") or "restyle"))
        moved = 0
        made: list[str] = []
        for p in list(parts):
            if p.tri_count == 0 or (op.get("part") and not p.name.startswith(op["part"])):
                continue
            tris = p.idx.reshape(-1, 3)
            take = np.zeros(len(tris), bool)
            facing = op.get("facing")
            if facing is not None:
                # mode FACES : triangles entièrement dans la boîte ET tournés vers `facing` (normale géométrique,
                # sens d'enroulement) à min_dot près. Pour une tranche qui appartient à un grand îlot (la coque
                # de verre d'un feu, coupée à la jointure coffre / aile : m422, 2026-11-16).
                d = np.asarray(facing, np.float64)
                d = d / max(float(np.linalg.norm(d)), 1e-12)
                t = p.pos[tris].astype(np.float64)
                inside = ((t >= lo) & (t <= hi)).all(axis=(1, 2))
                nrm = np.cross(t[:, 1] - t[:, 0], t[:, 2] - t[:, 0])
                nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
                take = inside & (nrm @ d >= float(op.get("min_dot", 0.5)))
            else:
                for isl in _islands(p.idx, len(p.pos)):
                    pts = p.pos[np.unique(tris[isl])]
                    if (pts >= lo).all() and (pts <= hi).all():
                        take[isl] = True
            if not take.any():
                continue
            sel = tris[take]
            verts = np.unique(sel)
            remap = np.full(len(p.pos), -1, np.int64)
            remap[verts] = np.arange(len(verts))
            name = f"{p.name}__{label}"
            tex = f"f2r_{name}"
            rgb = [int(max(0, min(255, c))) for c in op.get("color", [60, 58, 56])]
            out_dir.mkdir(parents=True, exist_ok=True)
            Image.new("RGBA", (4, 4), (*rgb, 255)).save(out_dir / f"{tex}.png")
            sh_tex = {k: v for k, v in p.shader.textures.items() if k != "SpecSampler"} if p.shader else {}
            q = replace(p, name=name, pos=p.pos[verts].copy(), nrm=p.nrm[verts].copy(), uv=p.uv[verts].copy(),
                        idx=remap[sel].astype(np.uint32).reshape(-1), tex_diffuse=tex,
                        shader=replace(p.shader, textures=sh_tex) if p.shader else None,
                        paint=None, custom_color=None,
                        mr_override=(float(op.get("roughness", 0.6)), bool(op.get("metal", True))))
            p.idx = tris[~take].reshape(-1).astype(np.uint32)
            parts.append(q)
            created.append(name)
            made.append(name)
            moved += int(take.sum())
        why = op.get("why", "")
        if moved:
            report.info(f"Pièce restylée ({why}) : {moved} triangle(s) -> {', '.join(made)}.")
        else:
            report.warn(f"Retouche « {why} » : aucun îlot dans la boîte {op['box']} (géométrie du mod changée ?).")
    parts[:] = [p for p in parts if p.tri_count > 0]
    return created


def remove_geometry(parts: list, ops: list[dict], report: Report, misses: list | None = None) -> int:
    """Applique les opérations ``geometry`` d'un ``brands/vehicles/<nom>.json`` : ``remove_islands`` supprime
    tout îlot dont TOUS les sommets sont dans ``box`` (mètres, repère du véhicule au repos, tolérance 1 mm),
    limité aux pièces dont le nom commence par ``part`` si donné. Renvoie le nombre de triangles retirés."""
    total = 0
    for op in ops:
        if op.get("op") != "remove_islands":
            raise ValueError(f"rebadge-spec geometry : opération inconnue « {op.get('op')} »")
        lo = np.array(op["box"][0], np.float32) - BOX_TOLERANCE_M
        hi = np.array(op["box"][1], np.float32) + BOX_TOLERANCE_M
        removed = 0
        for p in parts:
            if p.tri_count == 0 or (op.get("part") and not p.name.startswith(op["part"])):
                continue
            tris = p.idx.reshape(-1, 3)
            keep = np.ones(len(tris), bool)
            for isl in _islands(p.idx, len(p.pos)):
                pts = p.pos[np.unique(tris[isl])]
                if (pts >= lo).all() and (pts <= hi).all():
                    keep[isl] = False
            if not keep.all():
                removed += int((~keep).sum())
                p.idx = tris[keep].reshape(-1).astype(np.uint32)
        why = op.get("why", "")
        if removed:
            report.info(f"Lettrage modélisé supprimé ({why}) : {removed} triangle(s).")
        else:
            report.warn(f"Lettrage modélisé « {why} » : aucun îlot dans la boîte {op['box']} "
                        f"(géométrie du mod changée ? relever la boîte sur la planche lettrages_modelises).")
            if misses is not None:
                misses.append(why or str(op["box"]))
        total += removed
    parts[:] = [p for p in parts if p.tri_count > 0]
    return total


def copy_geometry(parts: list, ops: list[dict], report: Report, misses: list | None = None) -> int:
    """``copy_islands`` : duplique dans la même pièce tout îlot dont TOUS les sommets sont dans ``box`` (comme
    ``remove_islands``), décalé de ``offset`` (mètres, repère du véhicule). Sert à réécrire un lettrage modélisé avec
    ses propres glyphes : 325e (2026-11-19), « 325e » du coffre -> « 355e » (nom du jeu) en retirant le « 2 » par
    ``remove_islands`` puis en posant une copie du « 5 » à sa place. Appliqué APRÈS ``remove_islands`` : la copie
    tombe souvent dans la boîte de ce qu'on retire. Renvoie le nombre de triangles ajoutés."""
    total = 0
    for op in ops:
        lo = np.array(op["box"][0], np.float32) - BOX_TOLERANCE_M
        hi = np.array(op["box"][1], np.float32) + BOX_TOLERANCE_M
        off = np.array(op["offset"], np.float32)
        added = 0
        for p in parts:
            if p.tri_count == 0 or (op.get("part") and not p.name.startswith(op["part"])):
                continue
            tris = p.idx.reshape(-1, 3)
            pick = [isl for isl in _islands(p.idx, len(p.pos))
                    if (p.pos[np.unique(tris[isl])] >= lo).all() and (p.pos[np.unique(tris[isl])] <= hi).all()]
            if not pick:
                continue
            sel = tris[np.concatenate(pick)]
            verts = np.unique(sel)
            remap = {int(v): len(p.pos) + i for i, v in enumerate(verts)}
            p.pos = np.concatenate([p.pos, p.pos[verts] + off]).astype(np.float32)
            p.nrm = np.concatenate([p.nrm, p.nrm[verts]]).astype(np.float32)
            p.uv = np.concatenate([p.uv, p.uv[verts]]).astype(p.uv.dtype)
            new = np.vectorize(remap.get)(sel)
            p.idx = np.concatenate([tris, new]).reshape(-1).astype(np.uint32)
            added += len(sel)
        why = op.get("why", "")
        if added:
            report.info(f"Lettrage modélisé recopié ({why}) : {added} triangle(s).")
        else:
            report.warn(f"Copie de lettrage « {why} » : aucun îlot dans la boîte {op['box']}.")
            if misses is not None:
                misses.append(why or str(op["box"]))
        total += added
    return total
