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
"""
from __future__ import annotations

import json
import re
from dataclasses import replace
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

from .util import Report

BADGE_TEX = re.compile(r"badge|logo|emblem|emblm|marque|brand", re.I)
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
        return np.array(op["color"], np.float32) if op.get("color") else default

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
