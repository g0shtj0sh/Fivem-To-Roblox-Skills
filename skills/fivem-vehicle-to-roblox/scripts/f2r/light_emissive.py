"""Optiques (shader vehicle_lightsemissive) : texture agrandie et masque d'émission, pour que seules les parties
CLAIRES de la texture s'allument, comme GTA (diffuse x intensité), au lieu d'une pièce entière en Néon.

Constat (m422, light_emissive 512 px, 2026-11-15) : les feux de jour sont des traits blancs en diagonale sur gris
foncé ; allumée en Néon sans texture, toute la pièce brillait (trop fort, traits invisibles). Roblox expose sur
SurfaceAppearance EmissiveMaskContent / EmissiveStrength / EmissiveTint : le masque décide où ça brille.

Masque (0..1, sur la texture agrandie) = max(
  aplats clairs        : smoothstep(valeur, SOLID)              (lentille, ronds rouge / orange),
  traits fins clairs   : smoothstep(valeur, LINE) x smoothstep(valeur - flou, CONTRAST)  (traits du feu de jour)
)  où valeur = max(R, G, B) (le rouge et l'orange comptent comme clairs) et flou = gaussien LOCAL_BLUR px.
Réglé sur la m422 : traits 96 % allumés (p95), réflecteur en pointillés 2 % en moyenne, fond noir 0.
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageFilter

UPSCALE = 4
SOLID = (185.0, 235.0)
LINE = (145.0, 180.0)
CONTRAST = (14.0, 36.0)
LOCAL_BLUR = 10  # px sur la texture agrandie
NORM_TARGET = 235.0  # valeur visée pour la partie la plus claire d'une texture d'optique
NORM_MAX = 3.0


def _ss(x: np.ndarray, a: float, b: float) -> np.ndarray:
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def upscale(img: Image.Image, max_size: int) -> Image.Image:
    rgb = img.convert("RGB")
    w, h = rgb.size
    k = max(1, min(UPSCALE, max_size // max(w, h)))
    return rgb.resize((w * k, h * k), Image.LANCZOS) if k > 1 else rgb


def emissive_mask(color: Image.Image) -> Image.Image:
    """``color`` : la texture déjà agrandie (upscale). Renvoie un masque en niveaux de gris (RGB)."""
    v = np.asarray(color.convert("RGB")).astype(np.float32).max(-1)
    # texture sombre (verre rouge des feux stop, ext_lights du m422 : valeur max ~150) : sa partie la plus claire
    # devient la référence, sinon rien ne s'allume. Plafond x NORM_MAX pour ne pas allumer un simple bruit.
    lit = v[v > 8]
    ref = float(np.percentile(lit, 99.5)) if lit.size else 255.0
    v = np.clip(v * min(NORM_MAX, NORM_TARGET / max(ref, 1.0)), 0, 255) if ref < NORM_TARGET else v
    blur = np.asarray(Image.fromarray(v.astype(np.uint8)).filter(ImageFilter.GaussianBlur(LOCAL_BLUR))).astype(np.float32)
    m = np.maximum(_ss(v, *SOLID), _ss(v, *LINE) * _ss(v - blur, *CONTRAST))
    return Image.fromarray((m * 255).astype(np.uint8)).convert("RGB")
