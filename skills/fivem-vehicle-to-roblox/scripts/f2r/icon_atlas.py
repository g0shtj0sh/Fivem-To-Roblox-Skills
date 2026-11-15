"""Planche d'icônes de l'habitacle (texture du shader GTA vehicle_dash_emissive) : propre et nette pour Roblox.

Constat (m422, int_emis 512 px, 2026-11-15) : les symboles des boutons (RESUME, CANCEL, flèches, P…) n'existent
que dans le canal ALPHA (symbole opaque, fond transparent) ; sous le fond transparent le RVB est un blanc
sans signification, et le RVB des symboles est un gris bordé de noir. GTA les dessine par transparence.
Dans Roblox : (1) une pièce opaque qui échantillonne cette zone (boutons des portes, console) montre le fond
blanc ; (2) même transparente, le filtrage mêle le blanc aux bords (liseré) ; (3) un symbole fait 6 à 8 px
de haut, flou une fois agrandi à l'écran.

Correction, limitée à la « zone d'icônes » (pixels à moins de ZONE_RADIUS px d'un pixel transparent) :
  - fond (alpha bas) et contour sombre des symboles -> couleur sombre du plastique de la planche (médiane
    des pixels opaques hors zone) ;
  - corps clair d'un symbole neutre -> clair (GLYPH_LIGHT) ; symbole coloré (rouge du bouton START, M rouge) gardé ;
  - agrandissement x UPSCALE (plafond max_size) : alpha bicubique puis seuil doux (smoothstep), couleur
    recomposée = mélange fond / symbole par cet alpha net. Hors zone : agrandissement Lanczos ordinaire.
Le canal alpha est gardé : une pièce transparente (badges, dash_emissive) montre le symbole seul, une pièce
opaque montre un symbole clair sur fond sombre.
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageFilter

ZONE_RADIUS = 2        # px (taille d'origine) autour des pixels transparents
ALPHA_LOW = 128        # sous ce seuil : fond transparent
MASK_MIN_FRACTION = 0.01  # part de pixels transparents qui fait d'une texture une planche d'icônes
GLYPH_LIGHT = 232      # gris clair des symboles neutres (rétroéclairage blanc)
NEUTRAL_SAT = 0.25     # saturation sous laquelle un symbole est « neutre »
UPSCALE = 4
EDGE = (0.35, 0.65)    # smoothstep de l'alpha agrandi : bords nets sans crénelage
GLYPH_LUM = (70.0, 150.0)  # clarté (0..255) qui sépare le contour sombre du symbole de son corps clair


def has_alpha_mask(img: Image.Image) -> bool:
    """Vrai si l'alpha dessine quelque chose (une part de pixels transparents ET des opaques)."""
    if img.mode not in ("RGBA", "LA", "P"):
        return False
    a = np.asarray(img.convert("RGBA"))[..., 3]
    low = float((a < ALPHA_LOW).mean())
    return MASK_MIN_FRACTION <= low <= 0.98


def _smoothstep(x: np.ndarray, e0: float, e1: float) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def refine_icon_atlas(img: Image.Image, max_size: int) -> Image.Image:
    src = np.asarray(img.convert("RGBA")).astype(np.float32)
    h, w = src.shape[:2]
    rgb, a = src[..., :3], src[..., 3]
    low = a < ALPHA_LOW
    zone_img = Image.fromarray((low * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(2 * ZONE_RADIUS + 1))
    zone = np.asarray(zone_img) > 0
    outside = (~zone) & (a >= 250)
    bg = np.median(rgb[outside], axis=0) if outside.any() else np.array([30.0, 31.0, 34.0])

    # Le symbole visible est la partie CLAIRE de la zone opaque : chaque symbole porte un contour sombre
    # dans son alpha (dessiné sombre par GTA sur le plastique). Couverture = alpha x clarté pour les
    # neutres, alpha seul pour les colorés (rouge, bleu). Couleur : neutres -> clair, colorés gardés,
    # puis étalée sur le fond voisin (pas de liseré au filtrage).
    mx, mn = rgb.max(-1), rgb.min(-1)
    sat = (mx - mn) / np.maximum(mx, 1.0)
    neutral = sat < NEUTRAL_SAT
    lum = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    cover = (a / 255.0) * np.where(neutral, _smoothstep(lum, *GLYPH_LUM), 1.0)
    glyph = np.where(neutral[..., None], GLYPH_LIGHT, rgb)
    glyph = np.where((cover < 0.5)[..., None], 0.0, glyph)
    gimg = Image.fromarray(np.clip(glyph, 0, 255).astype(np.uint8))
    for _ in range(3):  # étale la couleur des symboles dans le fond voisin (MaxFilter par canal)
        spread = np.asarray(gimg.filter(ImageFilter.MaxFilter(3))).astype(np.float32)
        cur = np.asarray(gimg).astype(np.float32)
        empty = cur.sum(-1) == 0
        cur[empty] = spread[empty]
        gimg = Image.fromarray(cur.astype(np.uint8))

    scale = max(1, min(UPSCALE, max_size // max(w, h)))
    W, H = w * scale, h * scale
    a_hi = np.asarray(Image.fromarray(a.astype(np.uint8)).resize((W, H), Image.BICUBIC)).astype(np.float32) / 255
    a_hi = _smoothstep(a_hi, *EDGE)
    c8 = Image.fromarray(np.clip(cover * 255, 0, 255).astype(np.uint8))
    c_hi = _smoothstep(np.asarray(c8.resize((W, H), Image.BICUBIC)).astype(np.float32) / 255, *EDGE)
    zone_hi = np.asarray(zone_img.resize((W, H), Image.NEAREST)) > 0
    glyph_hi = np.asarray(gimg.resize((W, H), Image.BICUBIC)).astype(np.float32)
    base_hi = np.asarray(img.convert("RGBA").resize((W, H), Image.LANCZOS)).astype(np.float32)

    out = base_hi.copy()
    mix = bg[None, None, :] * (1 - c_hi[..., None]) + glyph_hi * c_hi[..., None]
    out[..., :3] = np.where(zone_hi[..., None], mix, base_hi[..., :3])
    out[..., 3] = np.where(zone_hi, a_hi * 255, base_hi[..., 3])
    return Image.fromarray(np.clip(np.round(out), 0, 255).astype(np.uint8), "RGBA")
