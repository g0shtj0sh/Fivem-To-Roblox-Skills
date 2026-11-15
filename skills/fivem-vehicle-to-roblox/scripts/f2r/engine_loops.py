"""Boucles moteur par régime, tirées d'un balayage d'accélération (façon GTA).

GTA V enregistre chaque moteur en montée de régime rapport engagé (ralenti → rupteur, ≈ 7 s), puis en
décélération pied levé, côté moteur et côté échappement ; son moteur granulaire lit ces balayages au régime
courant. Roblox ne lit pas de grains : on fabrique des BOUCLES STABLES à des régimes MESURÉS, que le runtime
mélange deux à deux (fondu à puissance constante) en ajustant la hauteur (`PlaybackSpeed = régime / régime
de la boucle`).

Ce que fait ce module, sans rien supposer du moteur :
1. `pitch_curve` : mesure la hauteur RELATIVE du balayage au cours du temps — décalage entre deux trames
   voisines de leur spectre en fréquence logarithmique (indifférent aux erreurs d'octave d'une mesure de
   fondamentale), cumulé, rendu monotone. Le régime = ralenti × rapport de hauteur.
2. `flatten` : pour un régime cible, prend une fenêtre du balayage autour de l'instant où il est atteint et la
   relit à vitesse variable pour que sa hauteur reste CONSTANTE (sinon la boucle « monte » puis retombe à
   chaque répétition : vibrato).
3. `make_loop` : longueur = nombre entier de cycles moteur (2 tours en 4 temps), fondu enchaîné de la fin sur
   le début : raccord sans clic ni saut de phase.
4. Les niveaux relatifs du balayage sont CONSERVÉS (un seul gain par flux) : un moteur est plus fort en haut
   qu'au ralenti.

Les mêmes fonctions servent aux balayages de synthèse (`synth_sweep`), aux enregistrements d'un pack et aux
fichiers du jeu.
"""
from __future__ import annotations

import numpy as np

# ------------------------------------------------------------------ hauteur relative d'un balayage

def _log_spectrogram(x: np.ndarray, sr: int, n_fft: int, hop: int, fmin: float, fmax: float,
                     bins_per_oct: int) -> tuple[np.ndarray, np.ndarray]:
    """Spectre de magnitude (log) rééchantillonné sur une grille de fréquence logarithmique."""
    win = np.hanning(n_fft)
    n_frames = max(1, 1 + (len(x) - n_fft) // hop)
    freqs = np.fft.rfftfreq(n_fft, 1 / sr)
    n_bins = int(np.log2(fmax / fmin) * bins_per_oct)
    grid = fmin * 2 ** (np.arange(n_bins) / bins_per_oct)
    out = np.empty((n_frames, n_bins), np.float32)
    for i in range(n_frames):
        seg = x[i * hop:i * hop + n_fft]
        if len(seg) < n_fft:
            seg = np.pad(seg, (0, n_fft - len(seg)))
        mag = np.abs(np.fft.rfft(seg * win))
        out[i] = np.log1p(np.interp(grid, freqs, mag) * 50)
    centers = (np.arange(n_frames) * hop + n_fft / 2) / sr
    return out, centers


def pitch_curve(x: np.ndarray, sr: int, *, rising: bool = True, hop_s: float = 0.01,
                bins_per_oct: int = 480, max_step_oct: float = 0.06) -> tuple[np.ndarray, np.ndarray]:
    """Rapport de hauteur (1 au début) en fonction du temps, pour un balayage monotone.

    Renvoie (temps des trames en s, rapport). `rising=False` pour une décélération (le rapport décroît).
    """
    n_fft = 1 << int(np.ceil(np.log2(sr * 0.09)))  # ≈ 90 ms : résout l'ordre d'allumage dès le ralenti
    hop = max(1, int(sr * hop_s))
    spec, t = _log_spectrogram(x, sr, n_fft, hop, 25.0, min(5000.0, sr / 2.2), bins_per_oct)
    # BLANCHIMENT : on retire l'enveloppe spectrale (moyenne glissante sur 1/3 d'octave). Les résonances
    # du pot et de la caisse ne bougent pas avec le régime ; sans ça elles dominent la corrélation et le
    # décalage mesuré reste à 0 (essai 2026-11-15 : ×1,04 mesuré au lieu de ×8,5 sur un balayage GTA).
    w = max(3, bins_per_oct // 3)
    kern = np.ones(w) / w
    env = np.array([np.convolve(np.pad(r, w // 2, mode="edge"), kern, mode="valid")[:len(r)] for r in spec])
    spec = np.maximum(spec - env, 0)
    spec = spec / (np.linalg.norm(spec, axis=1, keepdims=True) + 1e-9)
    max_lag = max(2, int(max_step_oct * bins_per_oct))
    steps = np.zeros(len(spec))
    k = max(1, int(round(0.05 / hop_s)))  # on compare à la trame d'il y a 50 ms : décalage plus grand que le bruit
    for i in range(k, len(spec)):
        a, b = spec[i - k], spec[i]
        best, best_lag, scores = -np.inf, 0, {}
        for lag in range(-max_lag, max_lag + 1):
            if lag >= 0:
                s = float(np.dot(a[:len(a) - lag], b[lag:]))
            else:
                s = float(np.dot(a[-lag:], b[:len(b) + lag]))
            scores[lag] = s
            if s > best:
                best, best_lag = s, lag
        # interpolation parabolique autour du maximum (sous-bin)
        l0, l1, l2 = scores.get(best_lag - 1), best, scores.get(best_lag + 1)
        frac = 0.0
        if l0 is not None and l2 is not None:
            den = l0 - 2 * l1 + l2
            if den < 0:
                frac = 0.5 * (l0 - l2) / den
        steps[i] = (best_lag + frac) / bins_per_oct / k
    # un balayage est monotone : on rejette les pas de mauvais sens (bruit, transitoires)
    steps = np.maximum(steps, 0) if rising else np.minimum(steps, 0)
    octaves = np.cumsum(steps)
    # lissage léger
    m = 5
    if len(octaves) > 2 * m:
        kernel = np.ones(2 * m + 1) / (2 * m + 1)
        padded = np.pad(octaves, m, mode="edge")
        octaves = np.convolve(padded, kernel, mode="valid")
    return t, 2.0 ** octaves


def rpm_curve(x: np.ndarray, sr: int, idle_rpm: float, max_rpm: float, *, rising: bool = True,
              report=None, label: str = "") -> tuple[np.ndarray, np.ndarray, dict]:
    """Régime en fonction du temps d'un balayage MONTANT (une décélération est retournée avant).

    Hauteur relative par `pitch_curve_dp` ; le haut du balayage est calé sur le rupteur (GTA enregistre
    jusqu'aux « top revs ») et le bas en découle : MESURÉ sur le son « Banshee » de GTA (2026-11-15), la montée
    couvre ×4,5 (≈ 1 600 → 7 200 tr/min, enregistrée en 2ᵉ), pas ralenti → rupteur. Le ralenti a sa propre
    boucle. Une étendue sous ×1,5 signale un suivi raté : on étale alors ralenti → rupteur."""
    t, ratio, _ = pitch_curve_dp(x, sr, rising=True)
    span = float(ratio[-1] / max(ratio[0], 1e-6))
    info = {"measured_span": round(span, 2), "rescaled": False}
    top = max_rpm * 0.98
    if span < 1.5:
        info["rescaled"] = True
        if report is not None:
            report.warn(f"Balayage {label} : étendue de hauteur mesurée ×{span:.2f} — suivi douteux, "
                        "courbe étalée de ralenti à rupteur.")
        lo = np.log(ratio / ratio[0])
        rpm = idle_rpm * np.exp(lo / max(lo[-1], 1e-6) * np.log(top / idle_rpm))
    else:
        rpm = top * ratio / ratio[-1]
        rpm = np.maximum(rpm, idle_rpm * 0.8)
    info["rpm_range"] = [round(float(rpm[0])), round(float(rpm[-1]))]
    return t, rpm, info


# ------------------------------------------------------------------ boucles

def flatten(x: np.ndarray, sr: int, t_frames: np.ndarray, rpm_frames: np.ndarray, target_rpm: float,
            out_len: int) -> np.ndarray | None:
    """Relit le balayage autour de `target_rpm` à vitesse variable pour en garder la hauteur constante.

    Lire l'entrée à la vitesse ρ multiplie sa hauteur par ρ : pour obtenir `target_rpm` partout,
    ρ(τ) = target / rpm(τ). On intègre τ échantillon par échantillon, centré sur l'instant où le balayage
    passe par `target_rpm`.
    """
    order = np.argsort(rpm_frames)
    r_sorted = rpm_frames[order]
    if target_rpm < r_sorted[0] or target_rpm > r_sorted[-1]:
        return None
    t_c = float(np.interp(target_rpm, r_sorted, t_frames[order]))
    rpm_at = lambda tau: np.interp(tau / sr, t_frames, rpm_frames)  # noqa: E731
    half = out_len // 2

    def walk(center):
        taus = np.empty(out_len)
        tau = center
        for n in range(half, out_len):
            taus[n] = tau
            tau += target_rpm / max(rpm_at(tau), 1.0)
        tau = center
        for n in range(half - 1, -1, -1):
            tau -= target_rpm / max(rpm_at(tau), 1.0)
            taus[n] = tau
        return taus

    center = t_c * sr
    taus = walk(center)
    # aux extrémités du balayage la fenêtre déborde : on la recale à l'intérieur (la hauteur reste celle
    # visée, le timbre vient d'un régime un peu voisin) plutôt que de perdre le palier
    for _ in range(4):
        over = taus[-1] - (len(x) - 2)
        under = -taus[0]
        if over > 0:
            center -= over + 1
        elif under > 0:
            center += under + 1
        else:
            break
        taus = walk(center)
    if taus[0] < 0 or taus[-1] >= len(x) - 1:
        return None
    return np.interp(taus, np.arange(len(x)), x)


def make_loop(seg: np.ndarray, sr: int, rpm: float, seconds: float = 0.45, cylinders: int = 4) -> np.ndarray:
    """Boucle d'un nombre entier de cycles moteur, refermée par un fondu à puissance constante."""
    cycle = sr * 120.0 / max(rpm, 100.0)  # échantillons par cycle 4 temps (2 tours)
    n_cycles = max(2, int(round(seconds * sr / cycle)))
    length = int(round(n_cycles * cycle))
    fade = int(min(max(2 * cycle, sr * 0.03), length * 0.3))  # 2 cycles : raccords plus doux en haut du régime
    if len(seg) < length + fade:
        length = len(seg) - fade
    body = seg[:length].copy()
    tail = seg[length:length + fade]
    w = np.linspace(0, 1, fade)
    body[:fade] = body[:fade] * np.sin(w * np.pi / 2) + tail * np.cos(w * np.pi / 2)
    return body


def seam_jump(loop: np.ndarray) -> float:
    """Saut d'amplitude au raccord, rapporté à la crête (0 = parfait)."""
    return float(abs(loop[-1] - loop[0]) / (np.abs(loop).max() + 1e-9))


def residual_drift(loop: np.ndarray, sr: int) -> float:
    """Variation de hauteur restante dans une boucle (demi-tons, début → fin ; 0 = parfaitement stable)."""
    if len(loop) < int(sr * 0.2):
        return 0.0
    _, up, _ = pitch_curve_dp(loop, sr, rising=True, max_step_oct=0.01)
    _, down, _ = pitch_curve_dp(loop, sr, rising=False, max_step_oct=0.01)
    a, b = 12 * np.log2(up[-1]), 12 * np.log2(down[-1])
    return float(a if abs(a) > abs(b) else b)


def target_rpms(idle_rpm: float, max_rpm: float, count: int) -> list[float]:
    """Paliers espacés en échelle logarithmique (même écart de hauteur entre voisins)."""
    lo, hi = idle_rpm * 1.12, max_rpm * 0.97
    return [float(lo * (hi / lo) ** (i / (count - 1))) for i in range(count)]


def extract_loops(x: np.ndarray, sr: int, idle_rpm: float, max_rpm: float, *, rising: bool, count: int = 8,
                  seconds: float = 0.45, cylinders: int = 4, report=None, label: str = "",
                  curve: tuple[np.ndarray, np.ndarray, dict] | None = None
                  ) -> tuple[list[tuple[float, np.ndarray]], dict]:
    """Boucles (régime, signal) à `count` paliers dans l'étendue mesurée ; niveaux relatifs conservés.

    `curve` : courbe de régime déjà mesurée (moteur et échappement d'une même prise partagent la leur :
    mesurée sur leur somme, plus sûre que chacune seule — la décélération du « Banshee » divergeait de
    4 demi-tons en fin de balayage quand chaque piste était suivie seule)."""
    sweep = x if rising else x[::-1]
    t, rpm, info = curve if curve is not None else rpm_curve(sweep, sr, idle_rpm, max_rpm, report=report,
                                                             label=label)
    info = dict(info)
    lo = max(float(rpm.min()) * 1.04, idle_rpm * 1.12)
    hi = min(float(rpm.max()) * 0.97, max_rpm * 0.97)
    targets = [float(lo * (hi / lo) ** (i / (count - 1))) for i in range(count)] if hi > lo * 1.05 else [lo]
    out = []
    for r in targets:
        cycle = sr * 120.0 / r
        need = int(seconds * sr + 3 * cycle) + int(sr * 0.05)
        seg = flatten(sweep, sr, t, rpm, r, need)
        if seg is None:
            continue
        out.append((r, make_loop(seg, sr, r, seconds, cylinders)))
    info["loops"] = len(out)
    return out, info


def shared_curve(streams: list[np.ndarray], sr: int, idle_rpm: float, max_rpm: float, *, rising: bool,
                 report=None, label: str = ""):
    """Courbe de régime commune à plusieurs pistes synchrones (moteur + échappement d'une même prise)."""
    n = min(len(s) for s in streams)
    mix = sum(s[:n] / (np.abs(s[:n]).max() + 1e-9) for s in streams)
    sweep = mix if rising else mix[::-1]
    return rpm_curve(sweep, sr, idle_rpm, max_rpm, report=report, label=label)


# ------------------------------------------------------------------ balayage de synthèse (moteur original)

def synth_sweep(idle_rpm: float, max_rpm: float, cylinders: int, *, seconds: float = 7.0, layer: str = "exhaust",
                load: str = "on", sr: int = 44100, seed: int = 7) -> np.ndarray:
    """Balayage moteur ORIGINAL (aucun enregistrement) : ralenti → rupteur, à la manière d'une montée
    rapport engagé. Couche « exhaust » : grave, saturé ; « engine » : mécanique, plus aigu, plus de bruit.
    `load = "off"` : moins de couple, plus de bruit d'admission coupé (décélération)."""
    rng = np.random.default_rng(seed + (0 if layer == "exhaust" else 1) + (0 if load == "on" else 2))
    n = int(seconds * sr)
    u = np.linspace(0, 1, n)
    rpm = idle_rpm * (max_rpm / idle_rpm) ** (u ** 0.85)
    cycle_hz = rpm / 120.0
    phase = 2 * np.pi * np.cumsum(cycle_hz) / sr
    fire_order = cylinders  # ordre d'allumage (par cycle)
    sig = np.zeros(n)
    for k in range(1, 4 * cylinders + 1):
        is_fire = (k % cylinders) == 0
        amp = (2.0 if is_fire else 0.35) / (k ** (0.9 if layer == "exhaust" else 0.6))
        if layer == "engine" and k > cylinders:
            amp *= 1.6
        sig += amp * np.sin(k * phase + rng.uniform(0, 2 * np.pi))
    sig /= np.abs(sig).max() + 1e-9
    # bruit coloré modulé par l'allumage
    noise = rng.normal(0, 1, n)
    b = np.array([0.05]) if layer == "exhaust" else np.array([0.25])
    lp = np.empty(n)
    acc = 0.0
    for i in range(n):  # passe-bas d'ordre 1
        acc += b[0] * (noise[i] - acc)
        lp[i] = acc
    lp /= np.abs(lp).max() + 1e-9
    pulse = 0.5 + 0.5 * np.sin(fire_order * phase)
    torque = 1.0 if load == "on" else 0.45
    mix = sig * torque + lp * pulse * (0.25 if layer == "engine" else 0.12) * (1.0 if load == "on" else 1.6)
    drive = (2.6 if layer == "exhaust" else 1.6) * (0.6 + 0.4 * u) * torque
    mix = np.tanh(mix * drive)
    level = 0.35 + 0.65 * u  # plus fort en haut, comme un vrai moteur
    out = mix * level
    if load == "off":
        out = out[::-1]  # une décélération descend du rupteur au ralenti
    return out / (np.abs(out).max() + 1e-9) * 0.9


# ------------------------------------------------------------------ suivi robuste (somme d'harmoniques + chemin monotone)

def pitch_curve_dp(x: np.ndarray, sr: int, *, rising: bool = True, fmin: float = 20.0, fmax: float = 900.0,
                   hop_s: float = 0.01, per_oct: int = 96, harmonics: int = 6,
                   max_step_oct: float = 0.03) -> tuple[np.ndarray, np.ndarray]:
    """Hauteur relative d'un balayage : saillance par somme d'harmoniques sur spectre blanchi, puis meilleur
    chemin MONOTONE sur toute la durée (programmation dynamique). Une erreur d'octave éventuelle reste la
    même sur tout le chemin : le rapport de hauteur, seul utilisé, n'en dépend pas."""
    n_fft = 1 << int(np.ceil(np.log2(sr * 0.17)))
    hop = max(1, int(sr * hop_s))
    win = np.hanning(n_fft)
    freqs = np.fft.rfftfreq(n_fft, 1 / sr)
    n_frames = max(1, 1 + (len(x) - n_fft) // hop)
    cands = fmin * 2 ** (np.arange(int(np.log2(fmax / fmin) * per_oct)) / per_oct)
    weights = 1.0 / np.sqrt(np.arange(1, harmonics + 1))
    sal = np.zeros((n_frames, len(cands)), np.float32)
    w_env = max(5, int(150 / (sr / n_fft)))  # enveloppe sur ≈ 150 Hz
    kern = np.ones(w_env) / w_env
    for i in range(n_frames):
        seg = x[i * hop:i * hop + n_fft]
        if len(seg) < n_fft:
            seg = np.pad(seg, (0, n_fft - len(seg)))
        mag = np.abs(np.fft.rfft(seg * win))
        env = np.convolve(mag, kern, mode="same") + 1e-9
        white = np.maximum(mag / env - 1.0, 0)  # pics harmoniques au-dessus de l'enveloppe
        acc = np.zeros(len(cands))
        for h, wt in enumerate(weights, start=1):
            acc += wt * np.interp(cands * h, freqs, white, right=0.0)
        sal[i] = acc / (acc.max() + 1e-9)
    max_step = max(1, int(round(max_step_oct * per_oct)))
    n_c = len(cands)
    score = sal[0].copy()
    back = np.zeros((n_frames, n_c), np.int32)
    for i in range(1, n_frames):
        new = np.full(n_c, -np.inf)
        arg = np.zeros(n_c, np.int32)
        for d in range(0, max_step + 1):
            if rising:
                src = np.full(n_c, -np.inf)
                src[d:] = score[:n_c - d] if d else score
                idx = np.arange(n_c) - d
            else:
                src = np.full(n_c, -np.inf)
                src[:n_c - d] = score[d:] if d else score
                idx = np.arange(n_c) + d
            better = src > new
            new[better] = src[better]
            arg[better] = idx[better]
        score = new + sal[i]
        back[i] = arg
    path = np.zeros(n_frames, np.int32)
    path[-1] = int(np.argmax(score))
    for i in range(n_frames - 1, 0, -1):
        path[i - 1] = back[i, path[i]]
    f0 = cands[path]
    t = (np.arange(n_frames) * hop + n_fft / 2) / sr
    # lissage (le chemin avance par marches de 1/96 d'octave)
    m = 7
    lf = np.log(f0)
    if len(lf) > 2 * m:
        lf = np.convolve(np.pad(lf, m, mode="edge"), np.ones(2 * m + 1) / (2 * m + 1), mode="valid")
    return t, np.exp(lf - lf[0]), np.exp(lf)
