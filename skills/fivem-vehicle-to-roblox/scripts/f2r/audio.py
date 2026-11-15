"""Sons du véhicule pour Roblox.

Deux sources possibles :
  1. Son custom du mod (.awc exporté en .wav par CodeWalker) : on repère le balayage
     d'accélération (montée en régime) et on y découpe des boucles à plusieurs régimes.
  2. Aucun son custom (le véhicule réutilise un son vanilla via audioNameHash) : synthèse
     procédurale d'un moteur (nb de cylindres estimé), + klaxon, sirène, clignotant.

Toutes les boucles sont parfaitement bouclables (périodiques) et décrites dans
audio_manifest : { "EngineLoops": [{"File":..., "Rpm":..., "Load":"on"/"off"}], ... }
"""
from __future__ import annotations

import shutil
import subprocess
import wave
from pathlib import Path

import numpy as np

from .util import Report

SR = 44100

# Estimation grossière du nombre de cylindres à partir du nom audio vanilla (audioNameHash)
CYLINDERS_HINT = {
    4: ["sultan", "futo", "blista", "issi", "panto", "kuruma", "elegy", "jester", "penumbra", "prairie",
        "asea", "dilettante", "rhapsody", "brioso", "club", "calico", "remus", "zr350", "rt3000", "sugoi"],
    6: ["comet", "carbonizzare", "coquette", "feltzer", "schafter", "surano", "rapidgt", "massacro",
        "ninef", "banshee", "sentinel", "oracle", "felon", "tailgater", "fugitive", "baller", "growler"],
    8: ["dominator", "gauntlet", "buffalo", "dukes", "sabregt", "vigero", "phoenix", "ruiner", "stalion",
        "blade", "hotknife", "granger", "sandking", "bison", "police", "sheriff", "fbi", "mesa"],
    10: ["infernus", "tempesta", "vacca", "bullet", "itali", "torero", "zentorno"],
    12: ["adder", "t20", "cheetah", "entityxf", "osiris", "reaper", "turismor", "nero", "autarch",
         "krieger", "emerus", "vagner", "xa21", "tyrant", "thrax", "zorrusso"],
}


def guess_cylinders(audio_name: str, vclass: str) -> int:
    a = (audio_name or "").lower()
    for cyl, names in CYLINDERS_HINT.items():
        if any(n in a for n in names):
            return cyl
    c = (vclass or "").upper()
    if "MOTORCYCLE" in c:
        return 2
    if "SUPER" in c:
        return 12
    if c in ("VC_MUSCLE", "VC_OFF_ROAD", "VC_SUV", "VC_EMERGENCY", "VC_VAN", "VC_COMMERCIAL"):
        return 8
    if c in ("VC_SPORT",):
        return 6
    return 4


# ------------------------------------------------------------------ wav IO

def write_wav(path: Path, data: np.ndarray, sr: int = SR) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    d = np.clip(data, -1.0, 1.0)
    pcm = (d * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path), "rb") as w:
        sr = w.getframerate()
        n = w.getnframes()
        ch = w.getnchannels()
        sw = w.getsampwidth()
        raw = w.readframes(n)
    if sw == 2:
        a = np.frombuffer(raw, "<i2").astype(np.float32) / 32768.0
    elif sw == 1:
        a = (np.frombuffer(raw, np.uint8).astype(np.float32) - 128) / 128.0
    elif sw == 4:
        a = np.frombuffer(raw, "<i4").astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"wav {sw * 8} bits non supporté")
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return a, sr


def to_ogg(wav: Path) -> Path:
    """Convertit en .ogg si ffmpeg est disponible (fichiers plus légers à uploader)."""
    ff = shutil.which("ffmpeg")
    if not ff:
        return wav
    ogg = wav.with_suffix(".ogg")
    r = subprocess.run([ff, "-y", "-loglevel", "error", "-i", str(wav), "-c:a", "libvorbis", "-q:a", "6", str(ogg)],
                       check=False)
    return ogg if r.returncode == 0 and ogg.exists() else wav


# ------------------------------------------------------------------ synthèse

def _periodic_noise(n: int, rng, lo: float, hi: float, sr: int = SR) -> np.ndarray:
    """Bruit filtré passe-bande parfaitement périodique sur n échantillons."""
    spec = np.zeros(n // 2 + 1, complex)
    f = np.fft.rfftfreq(n, 1 / sr)
    band = (f >= lo) & (f <= hi)
    spec[band] = np.exp(1j * rng.uniform(0, 2 * np.pi, band.sum())) / np.sqrt(np.maximum(f[band], 1))
    x = np.fft.irfft(spec, n)
    return x / (np.abs(x).max() + 1e-9)


def synth_engine_loop(rpm: float, cylinders: int, load: str, seconds: float = 1.0, seed: int = 1) -> np.ndarray:
    """Boucle moteur périodique : harmoniques de l'ordre d'allumage + bruit d'admission/échappement."""
    rng = np.random.default_rng(seed + int(rpm))
    n = int(SR * seconds)
    t = np.arange(n) / SR
    cycle_hz = rpm / 120.0                     # un cycle 4 temps = 2 tours
    fire_hz = cycle_hz * cylinders             # fréquence d'allumage
    base = cycle_hz / 2 if cylinders % 2 else cycle_hz
    sig = np.zeros(n)
    max_h = int(min(4000, SR / 2 - 1000) / base)
    for k in range(1, max_h + 1):
        f = round(k * base * seconds) / seconds  # quantification -> périodicité exacte
        if f <= 0:
            continue
        # renfort des multiples de l'allumage, décroissance spectrale
        order = (k * base) / fire_hz
        amp = (1.0 / k ** 0.8) * (2.2 if abs(order - round(order)) < 1e-6 else 0.35)
        if load == "off":
            amp *= 0.55 if order > 1.5 else 0.8
        sig += amp * np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    sig /= np.abs(sig).max() + 1e-9
    noise = _periodic_noise(n, rng, 80, 2500 if load == "on" else 900)
    mix = sig * (0.85 if load == "on" else 0.75) + noise * (0.18 if load == "on" else 0.1)
    mix = np.tanh(mix * (2.2 if load == "on" else 1.4))  # saturation "échappement"
    return mix / (np.abs(mix).max() + 1e-9) * 0.9


def synth_horn(seconds: float = 1.0) -> np.ndarray:
    n = int(SR * seconds)
    t = np.arange(n) / SR
    s = np.zeros(n)
    for f0 in (420.0, 525.0):          # klaxon double ton (tierce majeure)
        for k in range(1, 12):
            f = round(f0 * k * seconds) / seconds
            s += np.sin(2 * np.pi * f * t) / k ** 1.2
    s /= np.abs(s).max() + 1e-9
    return np.tanh(s * 2.0) * 0.8


def synth_siren(kind: str = "wail") -> np.ndarray:
    period = {"wail": 4.0, "yelp": 0.4, "priority": 0.25}.get(kind, 4.0)
    lo, hi = (650, 1450) if kind != "priority" else (700, 1100)
    reps = max(1, int(round(4.0 / period)))
    n = int(SR * period) * reps
    t = np.arange(n) / SR
    phase_t = (t % period) / period
    if kind == "priority":
        f = np.where(phase_t < 0.5, lo, hi)
    else:
        f = lo + (hi - lo) * (0.5 - 0.5 * np.cos(2 * np.pi * phase_t))
    ph = 2 * np.pi * np.cumsum(f) / SR
    ph *= (np.round(ph[-1] / (2 * np.pi)) * 2 * np.pi) / ph[-1]  # fermeture de phase -> boucle propre
    s = np.sin(ph) + 0.3 * np.sin(2 * ph) + 0.15 * np.sin(3 * ph)
    return np.tanh(s * 1.3) * 0.8


def synth_click(freq: float = 2400.0, seconds: float = 0.05) -> np.ndarray:
    n = int(SR * seconds)
    t = np.arange(n) / SR
    env = np.exp(-t * 90)
    return (np.sin(2 * np.pi * freq * t) * 0.6 + np.random.default_rng(3).normal(0, 0.2, n)) * env


def synth_start(cylinders: int) -> np.ndarray:
    """Démarreur (~0,9 s) puis montée au ralenti."""
    crank = int(SR * 0.9)
    t = np.arange(crank) / SR
    starter = np.sin(2 * np.pi * 7 * t) ** 8 * np.sin(2 * np.pi * 180 * t) * 0.5
    catch = synth_engine_loop(1400, cylinders, "on", seconds=0.6)
    catch *= np.linspace(1, 0.4, len(catch))
    return np.concatenate([starter, catch])


# ------------------------------------------------------------------ découpe AWC

def _loopify(seg: np.ndarray, fade: int) -> np.ndarray:
    """Boucle sans clic : fondu enchaîné de la fin sur le début."""
    if len(seg) <= 2 * fade:
        return seg
    head = seg[:fade]
    tail = seg[-fade:]
    w = np.linspace(0, 1, fade)
    body = seg[fade:-fade].copy() if len(seg) > 2 * fade else seg
    blended = tail * (1 - w) + head * w
    return np.concatenate([blended, body])


def cut_sweep_loops(sweep: np.ndarray, sr: int, positions, idle_rpm: float, max_rpm: float, prefix: str,
                    out_dir: Path, load: str) -> list[dict]:
    loops = []
    win = int(sr * 0.6)
    fade = int(sr * 0.08)
    for i, p in enumerate(positions):
        c = int(p * len(sweep))
        a = max(0, c - win // 2)
        seg = sweep[a:a + win]
        if len(seg) < win // 2:
            continue
        seg = _loopify(seg / (np.abs(seg).max() + 1e-9) * 0.9, fade)
        f = out_dir / f"{prefix}_{load}_{i + 1}.wav"
        write_wav(f, seg, sr)
        loops.append({"File": f.name, "Rpm": round(idle_rpm + p * (max_rpm - idle_rpm)), "Load": load})
    return loops


def loop_from_file(src: Path, max_seconds: float, report: Report,
                   label: str) -> tuple[np.ndarray, int] | None:
    """Prend un .wav du jeu et en fait une boucle exploitable par Roblox.

    Les klaxons et sirenes de GTA sont deja periodiques : on se contente de
    limiter la duree, de normaliser et de fermer la boucle par un fondu.
    """
    try:
        data, sr = read_wav(src)
    except Exception as exc:  # noqa: BLE001
        report.warn(f"Son {label} illisible ({src.name} : {exc}) : synthese utilisee.")
        return None
    if len(data) < int(sr * 0.05):
        report.warn(f"Son {label} trop court ({len(data) / max(sr, 1):.2f} s) : synthese utilisee.")
        return None
    seg = data[: int(sr * max_seconds)]
    peak = float(np.abs(seg).max())
    if peak < 1e-4:
        report.warn(f"Son {label} silencieux : synthese utilisee.")
        return None
    seg = seg / peak * 0.9
    return _loopify(seg, min(int(sr * 0.05), max(1, len(seg) // 4))), sr


def pick_stream(streams: dict[str, Path], keywords) -> Path | None:
    for kw in keywords:
        for name, p in streams.items():
            if kw in name:
                return p
    return None


# ------------------------------------------------------------------ orchestration

def build_audio(out_dir: Path, *, wavs: dict[str, Path], audio_name: str, vclass: str,
                is_emergency: bool, report: Report, idle_rpm: float = 850.0, max_rpm: float = 7200.0,
                use_ogg: bool = True) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    cyl = guess_cylinders(audio_name, vclass)
    manifest: dict = {"Source": "synthese", "Cylinders": cyl, "IdleRpm": idle_rpm, "MaxRpm": max_rpm,
                      "EngineLoops": [], "Files": {}}

    # ---- boucles moteur : deux couches (moteur côté capot, échappement côté pots), comme GTA, chacune en
    # accélérateur enfoncé (balayage d'accélération) et relâché (décélération), plus son ralenti. Régime de
    # chaque boucle MESURÉ dans le balayage (engine_loops.py), hauteur aplatie, raccord sur un cycle moteur.
    from . import engine_loops as EL

    def stream(*names):
        for n in names:
            for k, pth in wavs.items():
                if k.lower() == n:
                    return pth
        return None

    layers = {
        "engine": {"accel": stream("engine_accel"), "decel": stream("engine_decel"), "idle": stream("engine_idle")},
        "exhaust": {"accel": stream("exhaust_accel"), "decel": stream("exhaust_decel"),
                    "idle": stream("exhaust_idle")},
    }
    if not any(v["accel"] for v in layers.values()):
        # pack sans nommage moteur/échappement : une seule couche, prise comme avant
        accel = pick_stream(wavs, ["engine_accel", "accel", "exhaust_accel", "engine"])
        decel = pick_stream(wavs, ["engine_decel", "decel", "exhaust_decel", "revs_off"])
        idle = pick_stream(wavs, ["idle"])
        if accel is None and wavs:
            # flux nommés par hash : le plus long est généralement le balayage d'accélération (klaxon, sirènes
            # et clignotants exclus, sinon une sirène de 6 s se retrouve découpée en boucles « moteur »)
            cands = [pth for k, pth in wavs.items()
                     if not any(x in k.lower() for x in ("horn", "siren", "indicator", "klaxon"))]
            if cands:
                accel = max(cands, key=lambda pth: pth.stat().st_size)
        layers = {"engine": {"accel": accel, "decel": decel if decel != accel else None, "idle": idle}}

    def emit_layer(layer, data, sr):
        """data : {'accel': signal|None, 'decel': signal|None, 'idle': signal|None} déjà au même gain."""
        streams = [d for d in (data.get("accel"), data.get("decel")) if d is not None]
        for kind in ("accel", "decel"):
            sig = data.get(kind)
            if sig is None:
                continue
            rising = kind == "accel"
            same = [data[k] for k in (kind,) if data.get(k) is not None]
            curve = shared.get(kind)
            loops, info = EL.extract_loops(sig, sr, idle_rpm, max_rpm, rising=rising, count=LOOPS_PER_SWEEP,
                                           cylinders=cyl, report=report, label=f"{layer} {kind}", curve=curve)
            load = "on" if rising else "off"
            for i, (rpm, loop) in enumerate(loops, start=1):
                f = out_dir / f"{layer}_{load}_{i}.wav"
                write_wav(f, loop, sr)
                manifest["EngineLoops"].append({"File": f.name, "Rpm": round(rpm), "Load": load, "Layer": layer})
            manifest.setdefault("Sweeps", {})[f"{layer}_{kind}"] = info
        idle_sig = data.get("idle")
        if idle_sig is not None:
            seg = EL.make_loop(idle_sig, sr, idle_rpm, min(0.6, len(idle_sig) / sr * 0.7), cyl)
            f = out_dir / f"{layer}_idle.wav"
            write_wav(f, seg, sr)
            manifest["EngineLoops"].append({"File": f.name, "Rpm": round(idle_rpm), "Load": "idle", "Layer": layer})
        _ = streams

    LOOPS_PER_SWEEP = 8
    shared: dict = {}
    try:
        # une prise = un régime : la courbe est mesurée sur la somme des couches synchrones
        loaded = {}
        for layer, d in layers.items():
            loaded[layer] = {k: (read_wav(pth) if pth is not None else None) for k, pth in d.items()}
        srs = {v[1] for d in loaded.values() for v in d.values() if v is not None}
        if loaded and srs:
            sr = max(srs)
            for kind, rising in (("accel", True), ("decel", False)):
                sigs = [d[kind][0] for d in loaded.values() if d.get(kind) is not None and d[kind][1] == sr]
                if sigs:
                    shared[kind] = EL.shared_curve(sigs, sr, idle_rpm, max_rpm, rising=rising, report=report,
                                                   label=kind)
            for layer, d in loaded.items():
                # un seul gain par couche : les niveaux relatifs (ralenti plus doux, haut plus fort) sont gardés
                peak = max((float(np.abs(v[0]).max()) for v in d.values() if v is not None), default=0.0)
                if peak < 1e-4:
                    continue
                data = {k: (v[0] / peak * 0.9 if v is not None and v[1] == sr else None) for k, v in d.items()}
                emit_layer(layer, data, sr)
            if manifest["EngineLoops"]:
                src = [pth.name for d in layers.values() for pth in d.values() if pth is not None]
                manifest["Source"] = "awc:" + ",".join(src)
                report.info(f"Son moteur : {len(manifest['EngineLoops'])} boucles ({', '.join(layers)}), régimes "
                            "mesurés dans les balayages (" + "; ".join(
                                f"{k} {v.get('rpm_range')}" for k, v in manifest.get("Sweeps", {}).items()) + ").")
    except Exception as exc:  # noqa: BLE001
        report.warn(f"Découpe des balayages impossible ({exc}) : synthèse à la place.")
        manifest["EngineLoops"] = []
        manifest["Source"] = "synthese"

    if not manifest["EngineLoops"]:
        # moteur ORIGINAL de synthèse, passé par la même chaîne (balayages → boucles mesurées)
        sr = SR
        shared = {}
        for layer in ("engine", "exhaust"):
            data = {"accel": EL.synth_sweep(idle_rpm, max_rpm, cyl, layer=layer, load="on", sr=sr),
                    "decel": EL.synth_sweep(idle_rpm, max_rpm, cyl, layer=layer, load="off", sr=sr),
                    "idle": synth_engine_loop(idle_rpm, cyl, "off", seconds=1.0, seed=99 + (layer == "exhaust"))}
            emit_layer(layer, data, sr)
        report.info(f"Son moteur synthétisé ({cyl} cylindres, basé sur audioNameHash='{audio_name}', 2 couches). "
                    "Remplaçable par de vrais enregistrements dans sounds/.")

    write_wav(out_dir / "engine_start.wav", synth_start(cyl))
    write_wav(out_dir / "indicator_on.wav", synth_click(2600))
    write_wav(out_dir / "indicator_off.wav", synth_click(1900))
    manifest["Files"].update({"Start": "engine_start.wav", "Horn": "horn.wav",
                              "IndicatorOn": "indicator_on.wav", "IndicatorOff": "indicator_off.wav"})

    # Klaxon : vrai son du jeu (ou du pack) s'il est la, sinon synthese.
    horn_src = pick_stream(wavs, ["horn"])
    horn_loop = loop_from_file(horn_src, 2.5, report, "de klaxon") if horn_src is not None else None
    if horn_loop is not None:
        write_wav(out_dir / "horn.wav", horn_loop[0], horn_loop[1])
        manifest["HornSource"] = f"jeu:{horn_src.stem}"
        report.info(f"Klaxon : vrai son du jeu ({horn_src.name}).")
    else:
        write_wav(out_dir / "horn.wav", synth_horn())
        manifest["HornSource"] = "synthese"

    # Sirenes : une boucle par tonalite attendue par le runtime (Siren_<kind>).
    if is_emergency:
        real = []
        for kind in ("wail", "yelp", "priority"):
            src = pick_stream(wavs, [f"siren_{kind}"])
            loop = loop_from_file(src, 8.0, report, f"de sirene {kind}") if src is not None else None
            if loop is not None:
                write_wav(out_dir / f"siren_{kind}.wav", loop[0], loop[1])
                real.append(kind)
            else:
                write_wav(out_dir / f"siren_{kind}.wav", synth_siren(kind))
            manifest["Files"][f"Siren_{kind}"] = f"siren_{kind}.wav"
        manifest["SirenSource"] = ("jeu:" + ",".join(real)) if real else "synthese"
        if real:
            report.info("Sirenes reprises du jeu : " + ", ".join(real)
                        + ("" if len(real) == 3 else " (les autres sont synthetisees)."))

    if use_ogg and shutil.which("ffmpeg"):
        def conv(name):
            return to_ogg(out_dir / name).name
        for loop in manifest["EngineLoops"]:
            loop["File"] = conv(loop["File"])
        manifest["Files"] = {k: conv(v) for k, v in manifest["Files"].items()}
    return manifest
