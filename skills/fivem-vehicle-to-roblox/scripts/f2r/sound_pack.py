"""Pack de sons moteur maison (ex. « brolver-motor-sounds »).

Structure attendue (dossier, ou archive .rar/.zip/.7z qui le contient) :

    sounds/
      <categorie>/<son>/<son>_{moteur,echappement}_{acceleration,deceleration,ralenti}.wav
      klaxon/<nom>_01.wav ...

Catégories : berline, classique, compact, coupe, monster, muscle, pickup, sport,
super, suv, toutterrain. La catégorie est choisie d'après la classe GTA du
véhicule ; le son précis dans la catégorie est tiré de façon déterministe du nom
du modèle (même véhicule -> même son à chaque conversion), sauf choix explicite.

Les pistes « moteur » et « échappement » sont confiées telles quelles à
audio.build_audio, qui en fait deux couches (engine_* côté capot, exhaust_* côté pots).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import zlib
from pathlib import Path

from .util import Report, extract_archive, file_lock, unique_tmp

ENV_VAR = "F2R_ENGINE_PACK"
DEFAULT_URL = ("https://github.com/g0shtj0sh/Fivem-To-Roblox-Skills/releases/download/"
               "brolver-motor-sounds-v1/brolver-motor-sounds.rar")

CLASS_TO_CATEGORY = {
    "VC_COMPACT": "compact",
    "VC_SEDAN": "berline",
    "VC_SUV": "suv",
    "VC_COUPE": "coupe",
    "VC_MUSCLE": "muscle",
    "VC_SPORT_CLASSIC": "classique",
    "VC_SPORT": "sport",
    "VC_SUPER": "super",
    "VC_MOTORCYCLE": "sport",
    "VC_OFF_ROAD": "toutterrain",
    "VC_MILITARY": "toutterrain",
    "VC_INDUSTRIAL": "pickup",
    "VC_UTILITY": "pickup",
    "VC_VAN": "pickup",
    "VC_COMMERCIAL": "pickup",
    "VC_SERVICE": "pickup",
    "VC_EMERGENCY": "berline",
}
FALLBACK = ["berline", "sport", "coupe"]
PARTS = {"moteur": "engine", "echappement": "exhaust"}
STATES = {"acceleration": "accel", "deceleration": "decel", "ralenti": "idle"}


def _seven_zip() -> str | None:
    for c in (shutil.which("7z"), shutil.which("7za"),
              r"C:\Program Files\7-Zip\7z.exe", r"C:\Program Files (x86)\7-Zip\7z.exe"):
        if c and Path(c).exists():
            return c
    return None


def _find_root(base: Path) -> Path | None:
    """Dossier qui contient directement les catégories (sport/, super/, ...)."""
    for cand in [base, base / "sounds", *base.glob("*/sounds"), *base.glob("*")]:
        if cand.is_dir() and any((cand / c).is_dir() for c in set(CLASS_TO_CATEGORY.values())):
            return cand
    return None


def _download(url: str, cache_dir: Path, report: Report) -> Path | None:
    import urllib.request
    dest = cache_dir / url.rstrip("/").rsplit("/", 1)[-1]
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    cache_dir.mkdir(parents=True, exist_ok=True)
    tmp = unique_tmp(dest)
    try:
        report.info(f"Téléchargement du pack de sons moteur : {url}")
        with urllib.request.urlopen(url, timeout=60) as r, open(tmp, "wb") as f:
            shutil.copyfileobj(r, f)
        tmp.replace(dest)
        return dest
    except Exception as exc:  # noqa: BLE001
        report.warn(f"Téléchargement du pack de sons impossible ({exc}) : son d'origine conservé.")
        tmp.unlink(missing_ok=True)
        return None


def default_cache() -> Path:
    base = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(base) / "f2r" / "engine_pack"


def open_pack(path: str | os.PathLike, cache_dir: Path, report: Report) -> Path | None:
    # un seul agent télécharge / décompresse à la fois ; les autres attendent puis lisent le cache
    with file_lock(Path(cache_dir) / ".lock"):
        return _open_pack(path, Path(cache_dir), report)


def _open_pack(path: str | os.PathLike, cache_dir: Path, report: Report) -> Path | None:
    if str(path).startswith(("http://", "https://")):
        got = _download(str(path), cache_dir, report)
        if got is None:
            return None
        path = got
    p = Path(path)
    if not p.exists():
        report.warn(f"Pack de sons moteur introuvable : {p}")
        return None
    if p.is_file():
        dest = cache_dir / f"{p.stem}-{int(p.stat().st_mtime)}-{p.stat().st_size}"
        if not (dest / ".ok").exists():
            if dest.exists():
                shutil.rmtree(dest)
            if p.suffix.lower() in (".rar", ".7z") and not (shutil.which("7z") or shutil.which("7za")):
                seven = _seven_zip()
                unrar = shutil.which("unrar") or shutil.which("rar") if p.suffix.lower() == ".rar" else None
                if seven is None and unrar is None:
                    report.warn("Pack de sons en .rar/.7z mais ni 7-Zip ni unrar/rar trouvés : décompressez-le et "
                                "passez le dossier à --engine-pack.")
                    return None
                dest.mkdir(parents=True, exist_ok=True)
                cmd = ([seven, "x", "-y", f"-o{dest}", str(p)] if seven
                       else [unrar, "x", "-y", "-o+", str(p), str(dest) + os.sep])
                r = subprocess.run(cmd, capture_output=True, check=False)
                if r.returncode != 0:
                    report.warn(f"Extraction du pack de sons impossible ({p.name}).")
                    return None
            else:
                extract_archive(p, dest, report)
            if _find_root(dest) is None:
                report.warn(f"Pack de sons {p.name} : extraction vide (7-Zip ou unrar installé ?).")
                return None
            (dest / ".ok").write_text("ok", encoding="utf-8")
        p = dest
    root = _find_root(p)
    if root is None:
        report.warn(f"Pack de sons moteur : aucune catégorie (sport/, super/, ...) trouvée dans {p}.")
    return root


def list_engines(root: Path) -> dict[str, list[Path]]:
    out: dict[str, list[Path]] = {}
    for cat in sorted(d for d in root.iterdir() if d.is_dir() and d.name != "klaxon"):
        engines = sorted(e for e in cat.iterdir() if e.is_dir() and any(e.glob("*.wav")))
        if engines:
            out[cat.name] = engines
    return out


def category_for(vclass: str, name: str, available) -> str | None:
    n = (name or "").lower()
    if "monster" in n and "monster" in available:
        return "monster"
    cat = CLASS_TO_CATEGORY.get((vclass or "").upper())
    if cat in available:
        return cat
    for c in FALLBACK:
        if c in available:
            return c
    return next(iter(available), None)


def _pick(items: list[Path], key: str) -> Path:
    return items[zlib.crc32(key.lower().encode()) % len(items)]


def choose(root: Path, vclass: str, name: str, explicit: str | None = None) -> Path | None:
    engines = list_engines(root)
    if explicit:
        e = explicit.strip().lower()
        for items in engines.values():
            for d in items:
                if d.name.lower() == e:
                    return d
        if e in engines:                       # catégorie seule : tirage dans la catégorie
            return _pick(engines[e], name)
        return None
    cat = category_for(vclass, name, engines)
    return _pick(engines[cat], name) if cat else None


def prepare(engine_dir: Path, root: Path, work: Path, name: str, report: Report) -> dict[str, Path]:
    """Renvoie les flux au format attendu par audio.build_audio."""
    wavs: dict[str, Path] = {}
    for part, layer in PARTS.items():
        for state, kind in STATES.items():
            f = next(iter(sorted(engine_dir.glob(f"*_{part}_{state}.wav"))), None)
            if f is not None:
                wavs[f"{layer}_{kind}"] = f
    horns = sorted((root / "klaxon").glob("*.wav")) if (root / "klaxon").is_dir() else []
    if horns:
        wavs["horn"] = _pick(horns, name)
    report.info(f"Son moteur du pack maison : {engine_dir.parent.name}/{engine_dir.name}"
                + (f", klaxon {wavs['horn'].stem}" if "horn" in wavs else "") + ".")
    return wavs
