"""Classe du véhicule : la classe vérifiée (table ou --vehicle-class) remplace celle du mod."""
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import convert_vehicle as cv  # noqa: E402
from f2r.util import Report  # noqa: E402


def test_vehicle_class():
    # table du skill : m422 (M4 Competition) rangée VC_MUSCLE par le mod -> VC_COUPE
    v = {"class": "VC_MUSCLE"}
    cv.apply_verified_class("m422", v, SimpleNamespace(vehicle_class=None), Report())
    assert v["class"] == "VC_COUPE"
    # option : l'emporte sur la table, accepte la catégorie courte
    v = {"class": "VC_MUSCLE"}
    cv.apply_verified_class("m422", v, SimpleNamespace(vehicle_class="sedan"), Report())
    assert v["class"] == "VC_SEDAN"
    # véhicule absent de la table : classe du mod gardée, avertissement
    v = {"class": "VC_SPORT"}
    rep = Report()
    cv.apply_verified_class("inconnu_xyz", v, SimpleNamespace(vehicle_class=None), rep)
    assert v["class"] == "VC_SPORT"
    assert any("NON vérifiée" in w for w in rep.warnings)


if __name__ == "__main__":
    test_vehicle_class()
    print("ok")
