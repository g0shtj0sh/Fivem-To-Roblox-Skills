"""Mode « performances réelles » : caler le moteur et la boîte sur les vraies données du véhicule.

Les fiches (puissance, couple, 0-100, vitesse de pointe bridée / débridée, rapports, régimes, sources)
sont dans specs/vehicle_specs.json, une par nom de modèle, vérifiées sur internet (SKILL.md § 1f).

Le calage fait tourner le VRAI moteur de conduite (roblox/runtime/VehicleDynamics.lua) sous lune
(scripts/perf_solve.luau) : il cherche DriveForce, la vitesse plate et la traînée qui redonnent le
0-100 et la vitesse de pointe réels, avec le nombre de rapports et le temps de passage réels.
L'adhérence, la suspension, la direction et le freinage restent ceux du mod (choix de conception).
La vitesse bridée d'origine devient un limiteur électronique, levé par l'amélioration `Unlimited`.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from .util import Report

SKILL_DIR = Path(__file__).resolve().parents[2]
SPECS_FILE = SKILL_DIR / "specs" / "vehicle_specs.json"
SOLVER = SKILL_DIR / "scripts" / "perf_solve.luau"
DYNAMICS = SKILL_DIR / "roblox" / "runtime" / "VehicleDynamics.lua"

# champs du handling remplacés par le calage (les valeurs du mod sont gardées dans Performance.Mod)
FITTED_KEYS = ("DriveForce", "Gears", "DriveMaxFlatVelMs", "DriveMaxFlatVelKmh", "MaxFlatVelMs", "MaxFlatVelKmh",
               "RedlineTopGearKmh", "DragAccelCoeff", "DragCoeff", "ClutchChangeRateUp", "ClutchChangeRateDown",
               "ShiftTimeUpS", "ShiftTimeDownS")


def load_specs(name: str, path: str | None = None) -> dict | None:
    """Fiche du véhicule : fichier donné (--specs), sinon specs/vehicle_specs.json à son nom de modèle."""
    if path:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        return data.get("vehicles", {}).get(name.lower()) if "vehicles" in data else data
    if SPECS_FILE.exists():
        return json.loads(SPECS_FILE.read_text(encoding="utf-8")).get("vehicles", {}).get(name.lower())
    return None


def targets(spec: dict) -> dict:
    """Cibles du calage à partir d'une fiche."""
    top = spec.get("TopSpeedKmh")
    unlimited = spec.get("TopSpeedUnlimitedKmh") or top
    t = {
        "ZeroTo100S": spec.get("ZeroTo100S"),
        "VmaxKmh": unlimited,
        "LimiterKmh": top if spec.get("TopSpeedLimited") and top and unlimited and unlimited > top else None,
        "Gears": spec.get("Gears"),
        "ShiftTimeS": spec.get("ShiftTimeS"),
        "ComHeightM": spec.get("ComHeightM"),
    }
    return {k: v for k, v in t.items() if v is not None}


def find_lune() -> str | None:
    for c in (os.environ.get("F2R_LUNE"), shutil.which("lune"), str(Path.home() / ".cargo" / "bin" / "lune"),
              str(Path.home() / ".rokit" / "bin" / "lune")):
        if c and Path(c).exists():
            return c
    return None


def solve(cfg: dict, target: dict, lune: str) -> dict:
    """Lance perf_solve.luau sur la config Roblox (Handling, Wheels, StatMods, DriveTuning)."""
    payload = {"Handling": cfg.get("Handling") or {}, "Wheels": cfg.get("Wheels") or {},
               "DriveTuning": cfg.get("DriveTuning") or {}, "StatMods": cfg.get("StatMods") or {},
               "Target": target}
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = Path(tmp) / "in.json", Path(tmp) / "out.json"
        src.write_text(json.dumps(payload), encoding="utf-8")
        env = dict(os.environ, F2R_DYNAMICS=str(DYNAMICS))
        r = subprocess.run([lune, "run", str(SOLVER), str(src), str(dst)], capture_output=True, text=True,
                           env=env, timeout=600)
        if r.returncode != 0 or not dst.exists():
            raise RuntimeError((r.stderr or r.stdout).strip()[-800:])
        return json.loads(dst.read_text(encoding="utf-8"))


def _pct(a, b) -> str:
    return f"{(a / b - 1) * 100:+.1f} %" if a and b else "—"


def apply_real_performance(name: str, cfg: dict, report: Report, specs_path: str | None = None,
                           enabled: bool = True) -> dict | None:
    """Cale cfg["Handling"] sur la fiche réelle et pose cfg["Performance"]. Renvoie la section Performance."""
    if not enabled:
        report.info("Performances réelles : désactivées (--no-real-specs), handling du mod gardé.")
        return None
    spec = load_specs(name, specs_path)
    if not spec:
        report.warn(f"Performances réelles : aucune fiche pour « {name} ». Chercher sur internet les vraies "
                    "données du véhicule (0-100, vitesse de pointe bridée / débridée, rapports, régimes), les "
                    "écrire dans specs/vehicle_specs.json puis reconvertir (SKILL.md § 1f). En attendant, le "
                    "moteur et la boîte sont ceux du mod.")
        return None
    h = cfg.setdefault("Handling", {})
    target = targets(spec)
    perf: dict = {"Source": "specs", "Vehicle": spec.get("real_model") or spec.get("Vehicle") or name,
                  "Specs": {k: v for k, v in spec.items() if k not in ("sources", "Sources", "about")},
                  "Sources": spec.get("sources") or spec.get("Sources") or [],
                  "Target": target, "LimiterKmh": target.get("LimiterKmh"),
                  "Mod": {k: h.get(k) for k in FITTED_KEYS if h.get(k) is not None}}
    audio = cfg.get("Audio") or {}
    if spec.get("RedlineRpm") or spec.get("IdleRpm"):
        perf["Mod"]["AudioIdleRpm"], perf["Mod"]["AudioMaxRpm"] = audio.get("IdleRpm"), audio.get("MaxRpm")
        if spec.get("IdleRpm"):
            audio["IdleRpm"] = spec["IdleRpm"]
        if spec.get("RedlineRpm"):
            audio["MaxRpm"] = spec["RedlineRpm"]
    drive = str(spec.get("Drivetrain", "")).upper()
    mod_drive = ("AWD" if (h.get("DriveFront") or 0) > 0 and (h.get("DriveRear") or 0) > 0
                 else "FWD" if (h.get("DriveFront") or 0) > 0 else "RWD")
    if drive and drive != mod_drive:
        report.warn(f"Performances réelles : la fiche est en {drive}, le mod en {mod_drive} (transmission du mod "
                    "gardée : elle fait partie de la tenue de route). Vérifier que la fiche est la bonne version.")
    if "VmaxKmh" not in target:
        report.warn("Performances réelles : fiche sans vitesse de pointe, calage impossible.")
        return None
    lune = find_lune()
    if not lune:
        report.warn("Performances réelles : `lune` introuvable (PATH, F2R_LUNE, ~/.cargo/bin). L'installer "
                    "(`cargo install lune --locked`, ou le binaire des versions GitHub de lune-org/lune) puis "
                    "reconvertir : le calage fait tourner le vrai moteur de conduite. Handling du mod gardé.")
        perf["Fitted"] = False
        cfg["Performance"] = perf
        return perf
    try:
        res = solve(cfg, target, lune)
    except Exception as exc:  # noqa: BLE001
        report.warn(f"Performances réelles : calage en échec ({exc}). Handling du mod gardé.")
        return None
    h.update(res["Handling"])
    if h.get("Gears") == 1:
        h["Gearbox"] = h.get("Gearbox", "auto")
    perf["Fitted"] = True
    perf["Result"] = res["Result"]
    perf["Upgrades"] = res.get("Upgrades", {})
    cfg["Performance"] = perf

    r = res["Result"]
    lim = target.get("LimiterKmh")
    lines = [
        f"Performances réelles ({perf['Vehicle']}) : moteur et boîte calés sur la fiche, au banc du vrai moteur "
        "de conduite (adhérence, suspension, direction et freins du mod gardés).",
        f"  0-100 km/h : visé {target.get('ZeroTo100S', '—')} s, obtenu {r.get('ZeroTo100S')} s "
        f"({_pct(r.get('ZeroTo100S'), target.get('ZeroTo100S'))}) ; 0-200 km/h {r.get('ZeroTo200S')} s",
        f"  vitesse de pointe : " + (f"bridée {lim} km/h → {r.get('VmaxKmh')} km/h ; " if lim else "")
        + f"débridée visée {target['VmaxKmh']} km/h → {r.get('VmaxUnlimitedKmh')} km/h "
          f"({_pct(r.get('VmaxUnlimitedKmh'), target['VmaxKmh'])})",
        f"  {h.get('Gears')} rapports, passages à "
        + ", ".join(f"{s['From']}→{s['To']} {s['Kmh']} km/h" for s in r.get("Shifts", [])),
        f"  DriveForce {perf['Mod'].get('DriveForce')} → {h['DriveForce']}, vitesse plate "
        f"{perf['Mod'].get('DriveMaxFlatVelKmh') or round((perf['Mod'].get('DriveMaxFlatVelMs') or 0) * 3.6, 1)}"
        f" → {h['DriveMaxFlatVelKmh']} km/h, rapports {perf['Mod'].get('Gears')} → {h['Gears']}",
    ]
    mx = perf["Upgrades"].get("Max")
    if mx:
        lines.append(f"  tout amélioré ({mx['Levels']}) : 0-100 {mx.get('ZeroTo100S')} s, {mx.get('VmaxKmh')} km/h")
    for ln in lines:
        report.info(ln)
    if r.get("TractionLimited"):
        report.warn(f"Performances réelles : l'adhérence du mod ne permet pas le 0-100 réel ({target.get('ZeroTo100S')}"
                    f" s) ; meilleur temps possible {r.get('BestZeroTo100S')} s, calé à 2 % au-dessus.")
    err = abs((r.get("ZeroTo100S") or 0) / (target.get("ZeroTo100S") or 1) - 1)
    if not r.get("TractionLimited") and err > 0.05:
        report.warn(f"Performances réelles : 0-100 obtenu {r.get('ZeroTo100S')} s, à plus de 5 % de la cible.")
    return perf
