"""Conversion des textures GTA (DDS BC1-BC7 / RGBA) en PNG compatibles Roblox (<= 2048 px)."""
from __future__ import annotations

import hashlib
import io
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image

from .icon_atlas import is_alpha_drawn_atlas, refine_icon_atlas
from .light_emissive import emissive_mask, upscale as light_upscale
from .util import Report

# Plafond de Roblox mesuré le 2026-11-15 (GLB importé) : 2048 gardé tel quel (rendu net en qualité 21),
# 4096 réduit à 2048. Coût mémoire : une 2048 = 4 x une 1024 ; seules les sources > 1024 en profitent.
MAX_SIZE = 2048
# Écart type RVB (0..1) sous lequel une texture est un aplat sans détail.
FLAT_STD = 0.02
# ... et dont la teinte est quasi blanche (moyenne RVB >= FLAT_MIN_MEAN) et entièrement opaque : seule une telle
# diffuse ne change rien à la peinture (GTA multiplie couleur x diffuse). Une teinte unie SOMBRE (black_dark,
# grille6_diff, chrome, rgba1717gray) donne la couleur de la pièce, et une alpha (glass_light : verre des phares,
# grille1_diff : grille ajourée) donne sa transparence : les retirer rendait phares et calandre opaques et clairs
# (m422, régression du 2026-11-15 16:27 constatée le 2026-11-16).
FLAT_MIN_MEAN = 0.9
FLAT_MIN_ALPHA = 0.99

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


def _mask_channel(px: np.ndarray, mask: int) -> np.ndarray | None:
    """Canal 0..255 d'un pixel DDS non compressé à partir de son masque de bits (None si masque vide)."""
    if not mask:
        return None
    shift = (mask & -mask).bit_length() - 1
    top = mask >> shift
    return ((px & mask) >> shift).astype(np.float64) * (255.0 / top)


def read_uncompressed_dds(path: Path) -> Image.Image:
    """DDS non compressé à masques de bits que Pillow refuse (« Unknown pixel format flags 2 ») : A8 (alpha seule),
    L8 / A8L8 (luminance), RVB(A) 16/24/32 bits. Premier niveau de mipmap seulement.

    325e (2026-11-19) : `black.dds` du mod est un A8 4 x 4 (alpha 255, RVB implicite noir). Illisible, il laissait
    ses pièces de carrosserie (joints, montants, bas de caisse, couche « Default ») sans texture, peintes de la
    couleur Primary d'usine par le Setup et figées : marron, insensibles à la custom. Comme dans Direct3D, un A8 se
    lit (0, 0, 0, a)."""
    b = path.read_bytes()
    if len(b) < 128 or b[:4] != b"DDS ":
        raise ValueError("pas un DDS")
    height, width = int.from_bytes(b[12:16], "little"), int.from_bytes(b[16:20], "little")
    pf_flags, fourcc = int.from_bytes(b[80:84], "little"), b[84:88]
    bits = int.from_bytes(b[88:92], "little")
    rm, gm, bm, am = (int.from_bytes(b[92 + 4 * i:96 + 4 * i], "little") for i in range(4))
    DDPF_ALPHAPIXELS, DDPF_ALPHA, DDPF_FOURCC, DDPF_RGB, DDPF_LUMINANCE = 0x1, 0x2, 0x4, 0x40, 0x20000
    if pf_flags & DDPF_FOURCC and fourcc != b"\0\0\0\0":
        raise ValueError(f"DDS compressé {fourcc!r} non géré ici")
    if bits not in (8, 16, 24, 32) or not width or not height:
        raise ValueError(f"DDS {bits} bits non géré")
    nbytes = bits // 8
    raw = np.frombuffer(b, np.uint8, width * height * nbytes, 128).reshape(-1, nbytes).astype(np.uint32)
    px = np.zeros(len(raw), np.uint32)
    for i in range(nbytes):
        px |= raw[:, i] << (8 * i)
    zero = np.zeros(len(px))
    a = _mask_channel(px, am) if pf_flags & (DDPF_ALPHA | DDPF_ALPHAPIXELS) else None
    if pf_flags & DDPF_LUMINANCE:
        r = g = bl = _mask_channel(px, rm)
    elif pf_flags & DDPF_RGB:
        r, g, bl = (_mask_channel(px, m) for m in (rm, gm, bm))
    elif pf_flags & DDPF_ALPHA:
        r = g = bl = zero
    else:
        raise ValueError(f"DDS flags {pf_flags:#x} non géré")
    chans = [c if c is not None else zero for c in (r, g, bl)] + [a if a is not None else np.full(len(px), 255.0)]
    rgba = np.clip(np.stack(chans, -1).round(), 0, 255).astype(np.uint8).reshape(height, width, 4)
    return Image.fromarray(rgba, "RGBA")


def load_image(path: Path, report: Report) -> Image.Image | None:
    try:
        img = Image.open(path)
        img.load()
        return img
    except Exception as exc:  # noqa: BLE001
        if path.suffix.lower() == ".dds":
            try:
                return read_uncompressed_dds(path)
            except Exception:  # noqa: BLE001
                pass
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


# Alpha d'une texture posée sur une pièce OPAQUE : Roblox l'applique quand même (SurfaceAppearance en Overlay, la
# couleur de la pièce transparaît). Une alpha UNIFORME et partielle n'est pas un masque de découpe mais une valeur
# d'intensité (écrans vehicle_dash_emissive : interior_emissive à 74/255 partout) : gardée, elle voilait les écrans de
# la m422 d'un gris laiteux (signalé par l'utilisateur, 2026-11-16).
ALPHA_OPAQUE_MIN = 250
ALPHA_UNIFORM_STD = 3.0


def alpha_kind(img: Image.Image) -> str:
    """'none' (pas d'alpha utile), 'uniform' (alpha partielle et constante : pas un masque) ou 'mask'."""
    if img.mode not in ("RGBA", "LA", "PA") and not (img.mode == "P" and "transparency" in img.info):
        return "none"
    a = np.asarray(img.convert("RGBA"), np.float32)[..., 3]
    if a.min() >= ALPHA_OPAQUE_MIN:
        return "none"
    if a.std() < ALPHA_UNIFORM_STD:
        return "uniform"
    return "mask"


def is_neutral_flat(img: Image.Image) -> bool:
    """Aplat neutre : RVB uniforme (écart type < FLAT_STD), quasi blanc (moyenne >= FLAT_MIN_MEAN) et opaque
    (alpha >= FLAT_MIN_ALPHA partout)."""
    a = np.asarray(img.convert("RGBA"), np.float32) / 255.0
    rgb, alpha = a[..., :3], a[..., 3]
    return bool(rgb.std() < FLAT_STD and rgb.mean() >= FLAT_MIN_MEAN and alpha.min() >= FLAT_MIN_ALPHA)


class TextureStore:
    """Résout les noms de textures GTA, convertit et met en cache les PNG produits."""

    def __init__(self, sources: dict[str, Path], out_dir: Path, report: Report, max_size: int = MAX_SIZE):
        self.sources = {k.lower(): v for k, v in sources.items()}
        self.out_dir = out_dir
        self.report = report
        self.max_size = max_size
        self.cache: dict[tuple[str, str], Path | None] = {}
        self.avg: dict[str, list[float]] = {}
        # texture neutre (aplat quasi blanc et opaque : is_neutral_flat), ex. vehicle_generic_smallspecmap
        self.flat: dict[str, bool] = {}
        self.alpha: dict[str, str] = {}  # nom -> alpha_kind
        self.missing: set[str] = set()
        # retouches par texture (rebadge) : nom -> fonction(image, role) -> image, sur la taille d'origine
        self.edits: dict = {}
        # planches d'icônes de l'habitacle (diffuse d'un shader vehicle_dash_emissive) : voir icon_atlas.py
        self.icon_atlases: set[str] = set()
        out_dir.mkdir(parents=True, exist_ok=True)

    def find(self, name: str | None) -> Path | None:
        if not name:
            return None
        n = name.lower()
        for cand in (n, n + "+hi", n.replace("+hi", "")):
            if cand in self.sources:
                return self.sources[cand]
        alias = self.near_name(n)
        return self.sources[alias] if alias else None

    def near_name(self, n: str) -> str | None:
        """Texture du pack au nom presque identique quand le shader en demande une absente : même nom suivi
        d'un numéro (« bmw_m3_e36_lights_diffuse » demandé, « bmw_m3_e36_lights_diffuse1 » livré — faute de
        l'auteur du mod, rm3e36 2026-11-19 : boîtiers de phares sans texture), ou l'inverse. Seulement si
        UNE seule texture correspond (sinon on ne devine pas) ; noté une fois dans le rapport."""
        if not hasattr(self, "aliases"):
            self.aliases: dict[str, str | None] = {}
        if n in self.aliases:
            return self.aliases[n]
        base = re.sub(r"[_]?\d+$", "", n)
        cands = sorted({k for k in self.sources if "+hi" not in k and k != n and (
            re.fullmatch(re.escape(n) + r"_?\d+", k) or (base != n and k == base))})
        alias = cands[0] if len(cands) == 1 else None
        self.aliases[n] = alias
        if alias:
            self.report.info(f"Texture « {n} » absente : « {alias} » du pack utilisée (nom presque identique).")
        return alias

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
        self.flat.setdefault(name.lower(), is_neutral_flat(img))
        self.alpha.setdefault(name.lower(), alpha_kind(img))
        if role in ("light", "emask"):  # optique : texture agrandie et masque d'émission (light_emissive.py)
            big = light_upscale(img, self.max_size)
            img = emissive_mask(big) if role == "emask" else big
            dst = self.out_dir / f"{name.lower()}{'_light' if role == 'light' else '_emask'}.png"
            img.save(dst, optimize=True)
            self.cache[key] = dst
            return dst
        if role in ("color", "opaque") and name.lower() in self.icon_atlases and is_alpha_drawn_atlas(img):
            img = refine_icon_atlas(img, self.max_size)
            if role == "opaque":  # pièce opaque (bouton de porte, console) : symbole clair sur fond sombre, sans trou
                img.putalpha(255)
            else:
                self.report.info(f"Planche d'icônes {name} : fond sombre, symboles clairs, agrandie à {img.size[0]} px.")
        elif (role in ("color", "opaque") and name.lower() in self.icon_atlases and max(img.size) < 1024
              and not name.lower().startswith("script_rt")):  # cible de rendu GTA : masquée, inutile de l'agrandir
            # cadran déjà dessiné (fond, chiffres, couleurs dans le RVB : rm3e36 gauges_diffuse 256 px) : lu à 30 cm
            # de l'œil en vue cockpit -> agrandi x4 (Lanczos), chiffres nets au lieu d'une bouillie de pixels
            k = max(1, min(4, self.max_size // max(img.size)))
            if k > 1:
                img = img.resize((img.size[0] * k, img.size[1] * k), Image.LANCZOS)
                if role == "opaque":
                    self.report.info(f"Cadran dessiné {name} : agrandi à {img.size[0]} px (opaque, couleurs d'origine).")
        if role == "opaque" and img.mode != "RGB":
            img = img.convert("RGB")  # pièce opaque : la texture seule, sans alpha (sinon Overlay de Roblox)
        img = resize_for_roblox(img, self.max_size)
        img = to_normal_png(img) if role == "normal" else to_color_png(img)
        suffix = {"normal": "_n", "opaque": "_opaque"}.get(role, "")
        dst = self.out_dir / f"{name.lower()}{suffix}.png"
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
        # retouche (brands/vehicles/<nom>.json) écrite pour la carte de brillance : appliquée comme aux autres
        # textures ; ignorée avant, le logo restait dans les reflets (audit 2026-11-19)
        edit = self.edits.get(spec_name.lower()) or self.edits.get(spec_name.lower().replace("+hi", ""))
        if edit is not None:
            img = edit(img, "spec")
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

    def flat_metal_rough(self, roughness: float, metal: bool) -> Path:
        """Carte metallicRoughness unie 4 x 4 (G = rugosité, B = métal) pour une valeur imposée."""
        r = int(round(min(max(float(roughness), 0.0), 1.0) * 255))
        key = (f"flat|{r}|{bool(metal)}", "mr")
        if key not in self.cache:
            out = np.zeros((4, 4, 3), np.uint8)
            out[..., 1] = r
            out[..., 2] = 255 if metal else 0
            dst = self.out_dir / f"f2r_flat_mr_{r}_{'m' if metal else 'd'}.png"
            Image.fromarray(out, "RGB").save(dst, optimize=True)
            self.cache[key] = dst
        return self.cache[key]

    def is_icon_atlas(self, name: str | None) -> bool:
        """Planche d'icônes dont l'alpha dessine les symboles (les pièces qui l'affichent doivent être transparentes)."""
        if not name or name.lower() not in self.icon_atlases:
            return False
        src = self.find(name)
        img = load_image(src, self.report) if src is not None else None
        return img is not None and is_alpha_drawn_atlas(img)

    def has_uniform_alpha(self, name: str | None) -> bool:
        """Alpha partielle et constante (pas un masque de découpe) : voir alpha_kind."""
        if not name:
            return False
        if name.lower() not in self.alpha:
            self.get(name)
        return self.alpha.get(name.lower()) == "uniform"

    def is_flat(self, name: str | None) -> bool:
        """True si la texture est un aplat NEUTRE (uni, quasi blanc, opaque : is_neutral_flat) : sur une pièce peinte
        elle n'apporte rien de plus que la couleur, et la garder poserait une SurfaceAppearance qui empêche les
        finitions de la custom. Une teinte unie sombre ou une alpha comptent : False."""
        if not name:
            return False
        if name.lower() not in self.flat:
            self.get(name)
        return self.flat.get(name.lower(), False)

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
