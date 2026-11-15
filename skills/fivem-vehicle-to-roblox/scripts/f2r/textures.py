"""Conversion des textures GTA (DDS BC1-BC7 / RGBA) en PNG compatibles Roblox (<= 1024 px)."""
from __future__ import annotations

import hashlib
import io
import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

from .util import Report

MAX_SIZE = 1024

# --- Brillance GTA -> rugosité / métal Roblox (2026-11-15) ---------------------------------
# Carte « spec » GTA V (SpecSampler) : R = intensité spéculaire, G = brillance (exposant),
# B = Fresnel ; alpha toujours plein sur les mods mesurés (m422 : 15 cartes). L'intensité est
# dot(rgb, specMapIntMask) x specularIntensityMult, l'exposant G x specularFalloffMult.
# Conversion heuristique (non calibrée sur GTA, réglable ici) :
#   brillance = G x min(1, log2(1 + falloff) / log2(257))
#   rugosité  = 1 - brillance x sqrt(intensité)       bornée à [ROUGH_MIN, 1]
# Paramètres absents du shader (vehicle_mesh, vehicle_tire…) : SPEC_DEFAULTS.
SPEC_DEFAULTS = {"specularIntensityMult": 1.0, "specularFalloffMult": 100.0}
ROUGH_MIN = 0.05
# Pièces métalliques : noms de texture qui trahissent un métal nu (MetalnessMap = 1).
METAL_HINTS = ("chrome", "alloy")
# Le chrome GTA brille surtout par la réflexion d'environnement (reflectivePower), pas par la carte
# spec (chrome_s du m422 -> 0,40) : rugosité plafonnée pour un rendu miroir.
CHROME_ROUGH_MAX = 0.10


def _pow2_floor(n: int) -> int:
    p = 1
    while p * 2 <= n:
        p *= 2
    return p


def load_image(path: Path, report: Report) -> Image.Image | None:
    try:
        img = Image.open(path)
        img.load()
        return img
    except Exception as exc:  # noqa: BLE001
        # Repli : texconv (Windows) ou ImageMagick si présents
        for tool in ("magick", "convert"):
            exe = shutil.which(tool)
            if exe:
                try:
                    png = subprocess.run([exe, str(path), "png:-"], capture_output=True, check=True).stdout
                    return Image.open(io.BytesIO(png))
                except Exception:  # noqa: BLE001
                    pass
        report.warn(f"Texture illisible {path.name} ({exc}).")
        return None


def resize_for_roblox(img: Image.Image, max_size: int = MAX_SIZE) -> Image.Image:
    w, h = img.size
    scale = min(1.0, max_size / max(w, h))
    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
    # puissances de 2 : meilleure qualité de mipmapping côté Roblox
    nw, nh = _pow2_floor(nw), _pow2_floor(nh)
    if (nw, nh) != (w, h):
        img = img.resize((nw, nh), Image.LANCZOS)
    return img


def to_color_png(img: Image.Image) -> Image.Image:
    rgba = img.convert("RGBA")
    alpha = np.asarray(rgba)[..., 3]
    return rgba if alpha.min() < 250 else rgba.convert("RGB")


def to_normal_png(img: Image.Image) -> Image.Image:
    """GTA = convention DirectX (Y vers le bas) ; Roblox = OpenGL (Y vers le haut) -> inversion du vert.
    Gère aussi BC5 (2 canaux, bleu à reconstruire) et DXT5nm (X dans l'alpha)."""
    a = np.asarray(img.convert("RGBA")).astype(np.float32) / 255.0
    r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    if r.std() < 0.02 and al.std() > 0.05:  # DXT5nm
        r = al
    x = r * 2 - 1
    y = g * 2 - 1
    if b.mean() < 0.05 or b.std() < 0.01:   # BC5 : composante Z absente
        z = np.sqrt(np.clip(1 - x * x - y * y, 0, 1))
    else:
        z = b * 2 - 1
    y = -y
    out = np.stack([(x + 1) / 2, (y + 1) / 2, (z + 1) / 2], axis=-1)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGB")


def average_color(img: Image.Image) -> list[float]:
    a = np.asarray(img.convert("RGBA").resize((32, 32))).astype(np.float32) / 255.0
    w = a[..., 3:4]
    if w.sum() < 1e-3:
        w = np.ones_like(w)
    c = (a[..., :3] * w).sum(axis=(0, 1)) / w.sum()
    return [round(float(v), 4) for v in c]


def _vec(shader, name: str) -> float:
    v = shader.vectors.get(name)
    return float(v[0]) if v else SPEC_DEFAULTS[name]


def spec_params(shader) -> tuple[float, float, tuple[float, float, float]]:
    mask = shader.vectors.get("specMapIntMask")
    m = tuple(float(c) for c in mask[:3]) if mask else (1.0, 0.0, 0.0)
    if sum(m) <= 0:
        m = (1.0, 0.0, 0.0)
    return _vec(shader, "specularIntensityMult"), _vec(shader, "specularFalloffMult"), m


def spec_to_roughness(spec: Image.Image, int_mult: float, falloff: float,
                      mask: tuple[float, float, float]) -> np.ndarray:
    a = np.asarray(spec.convert("RGB")).astype(np.float32) / 255.0
    intensity = np.clip((a[..., 0] * mask[0] + a[..., 1] * mask[1] + a[..., 2] * mask[2]) * int_mult, 0, 1)
    gloss = a[..., 1] * min(1.0, float(np.log2(1 + max(falloff, 0.0)) / np.log2(257)))
    return np.clip(1.0 - gloss * np.sqrt(intensity), ROUGH_MIN, 1.0)


def is_metal(*names: str | None) -> bool:
    return any(h in (n or "").lower() for n in names for h in METAL_HINTS)


class TextureStore:
    """Résout les noms de textures GTA, convertit et met en cache les PNG produits."""

    def __init__(self, sources: dict[str, Path], out_dir: Path, report: Report, max_size: int = MAX_SIZE):
        self.sources = {k.lower(): v for k, v in sources.items()}
        self.out_dir = out_dir
        self.report = report
        self.max_size = max_size
        self.cache: dict[tuple[str, str], Path | None] = {}
        self.avg: dict[str, list[float]] = {}
        self.missing: set[str] = set()
        # retouches par texture (rebadge) : nom -> fonction(image, role) -> image, sur la taille d'origine
        self.edits: dict = {}
        out_dir.mkdir(parents=True, exist_ok=True)

    def find(self, name: str | None) -> Path | None:
        if not name:
            return None
        n = name.lower()
        for cand in (n, n + "+hi", n.replace("+hi", "")):
            if cand in self.sources:
                return self.sources[cand]
        return None

    def get(self, name: str | None, role: str = "color") -> Path | None:
        if not name:
            return None
        key = (name.lower(), role)
        if key in self.cache:
            return self.cache[key]
        src = self.find(name)
        if src is None:
            self.missing.add(name.lower())
            self.cache[key] = None
            return None
        img = load_image(src, self.report)
        if img is None:
            self.cache[key] = None
            return None
        edit = self.edits.get(name.lower()) or self.edits.get(name.lower().replace("+hi", ""))
        if edit is not None:
            img = edit(img, role)
        self.avg.setdefault(name.lower(), average_color(img))
        img = resize_for_roblox(img, self.max_size)
        img = to_normal_png(img) if role == "normal" else to_color_png(img)
        dst = self.out_dir / f"{name.lower()}{'_n' if role == 'normal' else ''}.png"
        img.save(dst, optimize=True)
        self.cache[key] = dst
        return dst

    def metal_rough(self, shader, diffuse: str | None = None) -> Path | None:
        """Carte glTF metallicRoughness (G = rugosité, B = métal) tirée du SpecSampler du shader.
        Carte uniforme -> 4 x 4 px (rien à gagner à la garder grande). None sans SpecSampler lisible."""
        spec_name = shader.textures.get("SpecSampler") if shader is not None else None
        if not spec_name:
            return None
        int_mult, falloff, mask = spec_params(shader)
        metal = is_metal(spec_name, diffuse)
        key = (f"{spec_name.lower()}|{int_mult:.4f}|{falloff:.2f}|{mask}|{metal}", "mr")
        if key in self.cache:
            return self.cache[key]
        src = self.find(spec_name)
        img = load_image(src, self.report) if src is not None else None
        if img is None:
            self.missing.add(spec_name.lower())
            self.cache[key] = None
            return None
        img = resize_for_roblox(img, self.max_size)
        rough = spec_to_roughness(img, int_mult, falloff, mask)
        if any("chrome" in (n or "").lower() for n in (spec_name, diffuse)):
            rough = np.minimum(rough, CHROME_ROUGH_MAX)
        if float(rough.std()) < 0.01:
            rough = np.full((4, 4), float(rough.mean()), np.float32)
        out = np.zeros((*rough.shape, 3), np.uint8)
        out[..., 1] = np.round(rough * 255).astype(np.uint8)
        out[..., 2] = 255 if metal else 0
        tag = hashlib.md5(key[0].encode()).hexdigest()[:8]  # déterministe (le GLB doit l'être)
        dst = self.out_dir / f"{spec_name.lower()}_mr_{tag}.png"
        Image.fromarray(out, "RGB").save(dst, optimize=True)
        self.cache[key] = dst
        return dst

    def average(self, name: str | None) -> list[float] | None:
        if not name:
            return None
        if name.lower() not in self.avg:
            self.get(name)
        return self.avg.get(name.lower())

    def siblings(self, name: str) -> list[str]:
        """Livrées : 'adder_sign_1' -> ['adder_sign_1', 'adder_sign_2', ...]"""
        import re
        m = re.match(r"^(.*?)(\d+)$", name.lower())
        if not m:
            return [name.lower()]
        prefix = m.group(1)
        found = []
        for k in self.sources:
            mm = re.match(rf"^{re.escape(prefix)}(\d+)$", k)
            if mm:
                found.append((int(mm.group(1)), k))
        return [k for _, k in sorted(found)] or [name.lower()]
