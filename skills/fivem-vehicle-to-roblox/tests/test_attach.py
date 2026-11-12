"""Rattachement aux pièces mobiles (python tests/test_attach.py ou pytest).

Une optique pondérée sur le châssis mais montée dans la peau du coffre doit suivre le coffre ; une pièce
posée SOUS la peau (ce qu'un capot ou un coffre recouvre) et une pièce posée sur la carrosserie fixe
doivent rester sur le châssis.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from f2r.vehicle import VehicleBuilder  # noqa: E402
from f2r.util import Report  # noqa: E402


class _Skel:
    root_name = "chassis"


def _grid_plane(x0, x1, y0, y1, z, step, hole=None):
    """Plaque verticale (normale +Z, vers l'arrière) maillée en triangles, avec un trou optionnel."""
    pts, tris = [], []
    xs = np.arange(x0, x1 + 1e-9, step)
    ys = np.arange(y0, y1 + 1e-9, step)
    idx = {}
    for i, x in enumerate(xs):
        for j, y in enumerate(ys):
            idx[(i, j)] = len(pts)
            pts.append((x, y, z))
    for i in range(len(xs) - 1):
        for j in range(len(ys) - 1):
            cx, cy = (xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2
            if hole and hole[0] <= cx <= hole[1] and hole[2] <= cy <= hole[3]:
                continue
            a, b, c, d = idx[(i, j)], idx[(i + 1, j)], idx[(i + 1, j + 1)], idx[(i, j + 1)]
            tris += [(a, b, c), (a, c, d)]
    P = np.array(pts, dtype=float)
    return P, np.full_like(P, 0.0) + np.array([0.0, 0.0, 1.0]), np.array(tris, dtype=np.int64)


def _geom(kind, P, N, tris, group):
    return dict(sh=type("S", (), {"name": "vehicle_" + kind})(), kind=kind, P=P, N=N, tris=tris,
                tri_group=np.array([group] * len(tris), dtype=object))


def run() -> None:
    vb = object.__new__(VehicleBuilder)
    vb.skel = _Skel()
    vb.report = Report()
    vb.attach_debug = []
    # carrosserie : un bloc fermé de centre (0, 0, 0) ; on ne garde que sa face arrière z = 2,3
    body_P, body_N, body_T = _grid_plane(-1.0, 1.0, 0.0, 0.3, 2.3, 0.05)  # pare-chocs (châssis), y 0..0,3
    lid_P, lid_N, lid_T = _grid_plane(-0.6, 0.6, 0.3, 0.6, 2.3, 0.05, hole=(-0.5, -0.35, 0.4, 0.5))  # coffre
    lamp_P, lamp_N, lamp_T = _grid_plane(-0.5, -0.35, 0.4, 0.5, 2.29, 0.025)  # optique dans le trou du coffre
    under_P, under_N, under_T = _grid_plane(0.1, 0.3, 0.4, 0.5, 2.18, 0.025)  # 12 cm sous la peau du coffre
    fixed_P, fixed_N, fixed_T = _grid_plane(0.6, 0.8, 0.05, 0.2, 2.29, 0.025)  # feu sur le pare-chocs
    # pour que le centre du véhicule soit devant (z ≈ 0), une face avant peinte du châssis
    front_P, front_N, front_T = _grid_plane(-1.0, 1.0, 0.0, 0.6, -2.3, 0.1)
    front_N = -front_N
    geoms = [
        _geom("paint", body_P, body_N, body_T, "chassis"),
        _geom("paint", front_P, front_N, front_T, "chassis"),
        _geom("paint", lid_P, lid_N, lid_T, "boot"),
        _geom("light", lamp_P, lamp_N, lamp_T, "chassis"),
        _geom("mesh", under_P, under_N, under_T, "chassis"),
        _geom("light", fixed_P, fixed_N, fixed_T, "chassis"),
    ]
    vb._attach_to_hinged(geoms)
    lamp, under, fixed = geoms[3], geoms[4], geoms[5]
    assert set(lamp["tri_group"]) == {"boot"}, ("optique montée dans le coffre", vb.attach_debug)
    assert set(under["tri_group"]) == {"chassis"}, ("pièce sous la peau du coffre", vb.attach_debug)
    assert set(fixed["tri_group"]) == {"chassis"}, ("feu du pare-chocs", vb.attach_debug)
    # le capot n'est jamais concerné (sa peau entoure la calandre et les phares)
    assert "bonnet" not in VehicleBuilder.ATTACH_PARTS
    print("OK : rattachement au coffre (1 îlot), 2 îlots laissés au châssis")


def test_attach() -> None:
    run()


if __name__ == "__main__":
    run()
