#!/usr/bin/env python3
"""Mode « performances réelles » : fiche -> calage du moteur et de la boîte au banc du vrai moteur de conduite.

python tests/test_performance.py (ou pytest). Le calage demande `lune` : sans lui, le test vérifie seulement
que la conversion avertit et garde le handling du mod.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "scripts"))
import make_fixture  # noqa: E402
from f2r.performance import find_lune, targets  # noqa: E402

SPEC = {
    "real_model": "Coupé d'essai",
    "Drivetrain": "RWD",
    "ZeroTo100S": 5.5,
    "TopSpeedKmh": 210,
    "TopSpeedLimited": True,
    "TopSpeedUnlimitedKmh": 240,
    "Gears": 7,
    "ShiftTimeS": 0.2,
    "RedlineRpm": 6800,
    "IdleRpm": 750,
    "sources": ["test"],
}


def test_targets():
    t = targets(SPEC)
    assert t["VmaxKmh"] == 240 and t["LimiterKmh"] == 210 and t["Gears"] == 7 and t["ShiftTimeS"] == 0.2
    t = targets({"ZeroTo100S": 4.0, "TopSpeedKmh": 300})                # non bridée : pas de limiteur
    assert t["VmaxKmh"] == 300 and "LimiterKmh" not in t


def test_real_performance():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        zpath = make_fixture.main(tmp / "fx")
        specs = tmp / "specs.json"
        specs.write_text(json.dumps({"vehicles": {"testcar": SPEC}}), encoding="utf-8")
        r = subprocess.run([sys.executable, str(ROOT / "scripts" / "convert_vehicle.py"), str(zpath),
                            "-o", str(tmp / "out"), "--no-build", "--no-ogg", "--specs", str(specs)],
                           capture_output=True, text=True)
        assert r.returncode == 0, r.stderr
        cfg = json.loads((tmp / "out" / "testcar" / "vehicle_config.json").read_text(encoding="utf-8"))["roblox_config"]
        perf, h = cfg["Performance"], cfg["Handling"]
        assert perf["LimiterKmh"] == 210 and perf["Target"]["VmaxKmh"] == 240
        assert cfg["Audio"]["MaxRpm"] == 6800 and cfg["Audio"]["IdleRpm"] == 750
        if not find_lune():
            assert perf["Fitted"] is False and "lune" in r.stderr
            print("lune absent : calage non vérifié")
            return
        assert perf["Fitted"] is True, r.stderr
        res = perf["Result"]
        assert h["Gears"] == 7 and abs(h["ShiftTimeUpS"] - 0.2) < 1e-9 and abs(h["ClutchChangeRateUp"] - 4.5) < 1e-6
        assert abs(res["ZeroTo100S"] / 5.5 - 1) < 0.03, res                # 0-100 réel tenu à 3 %
        assert abs(res["VmaxKmh"] - 210) < 3, res                          # limiteur électronique
        assert abs(res["VmaxUnlimitedKmh"] / 240 - 1) < 0.03, res          # débridé
        assert perf["Mod"]["Gears"] != 7 or perf["Mod"]["DriveForce"] != h["DriveForce"]
        mx = perf["Upgrades"]["Max"]
        assert mx["VmaxKmh"] > res["VmaxUnlimitedKmh"] and mx["ZeroTo100S"] <= res["ZeroTo100S"] + 0.05
        assert "Performances réelles" in r.stderr
        print(f"OK : 0-100 {res['ZeroTo100S']} s, {res['VmaxKmh']} / {res['VmaxUnlimitedKmh']} km/h, "
              f"tout amélioré {mx['ZeroTo100S']} s / {mx['VmaxKmh']} km/h")


if __name__ == "__main__":
    test_targets()
    test_real_performance()
