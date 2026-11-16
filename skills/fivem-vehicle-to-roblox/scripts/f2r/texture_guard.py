"""Garde-fou anti-régression des textures.

Chaque conversion écrit, pour chaque pièce, ce que son matériau reçoit (texture de couleur, normal map, transparence,
masque d'émission) et le compare à la dernière conversion acceptée du même véhicule (référence en cache). Une pièce
qui PERD sa texture ou sa transparence est une régression : le convertisseur le dit en tête du rapport, sort avec le
code 3 et ne remplace pas la référence. On accepte une perte voulue avec --accept-texture-changes.

Pourquoi (2026-11-16) : une règle « diffuse blanche inutile sur la peinture » trop large a retiré le verre des phares,
les grilles ajourées et toutes les teintes sombres unies (48 pièces de la m422) ; rien ne l'a signalé et la voiture
a été réinstallée ainsi. Les tests unitaires couvrent cette règle-là ; ce garde-fou couvre toutes les autres.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

VERSION = 1
EXIT_REGRESSION = 3


def default_dir() -> Path:
    base = os.environ.get("F2R_TEXTURE_BASELINES")
    if base:
        return Path(base)
    root = os.environ.get("LOCALAPPDATA") or os.path.join(os.path.expanduser("~"), ".cache")
    return Path(root) / "f2r" / "texture_baselines"


def entry(kind: str, mat, has_tex: bool) -> dict:
    return {"kind": kind, "tex": bool(has_tex), "normal": mat.normal_png is not None,
            "blend": mat.alpha == "BLEND", "emask": mat.emissive_png is not None}


def compare(base: dict, cur: dict) -> dict:
    """Pertes par rapport à la référence ({pièce: entrée}). Les pièces nouvelles ou gagnantes ne comptent pas."""
    lost = {"tex": [], "blend": [], "normal": [], "emask": [], "parts": []}
    for name, b in sorted(base.items()):
        c = cur.get(name)
        if c is None:
            lost["parts"].append(name)
            continue
        for key in ("tex", "blend", "normal", "emask"):
            if b.get(key) and not c.get(key):
                lost[key].append(name)
    lost["count"] = sum(len(v) for v in lost.values())
    return lost


def describe(lost: dict) -> list[str]:
    labels = {"tex": "texture de couleur perdue", "blend": "transparence perdue (verre, grille ajourée…)",
              "normal": "normal map perdue", "emask": "masque d'émission perdu", "parts": "pièce disparue"}
    lines = []
    for key, label in labels.items():
        names = lost.get(key) or []
        if names:
            more = f" … (+{len(names) - 12})" if len(names) > 12 else ""
            lines.append(f"{label} : {len(names)} pièce(s) — " + ", ".join(names[:12]) + more)
    return lines


def check(vehicle: str, manifest: dict, out: Path, report, accept: bool = False,
          baseline_dir: Path | None = None) -> dict:
    """Écrit out/texture_manifest.json, compare à la référence et la met à jour si rien n'est perdu (ou si accept).
    Renvoie {"status": "first"|"ok"|"accepted"|"regression", "lost": …, "baseline": chemin}."""
    out.mkdir(parents=True, exist_ok=True)
    doc = {"version": VERSION, "vehicle": vehicle, "parts": manifest}
    (out / "texture_manifest.json").write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")
    bdir = baseline_dir or default_dir()
    bpath = bdir / f"{vehicle.lower()}.json"
    textured = sum(1 for e in manifest.values() if e["tex"])
    if not bpath.exists():
        bdir.mkdir(parents=True, exist_ok=True)
        bpath.write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")
        report.info(f"Textures : {textured} pièce(s) texturée(s) ; première conversion de {vehicle}, "
                    f"référence enregistrée ({bpath}).")
        return {"status": "first", "lost": None, "baseline": str(bpath)}
    base = json.loads(bpath.read_text(encoding="utf-8")).get("parts", {})
    lost = compare(base, manifest)
    if lost["count"] == 0:
        bpath.write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")
        report.info(f"Textures : {textured} pièce(s) texturée(s), aucune perte par rapport à la conversion "
                    "précédente acceptée.")
        return {"status": "ok", "lost": lost, "baseline": str(bpath)}
    details = describe(lost)
    (out / "texture_regression.json").write_text(json.dumps(lost, indent=1, ensure_ascii=False), encoding="utf-8")
    if accept:
        bpath.write_text(json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")
        report.warn("Textures : pertes ACCEPTÉES (--accept-texture-changes), nouvelle référence enregistrée :\n  - "
                    + "\n  - ".join(details))
        return {"status": "accepted", "lost": lost, "baseline": str(bpath)}
    report.warn("RÉGRESSION DES TEXTURES par rapport à la dernière conversion acceptée de " + vehicle
                + " — NE PAS INSTALLER cette version :\n  - " + "\n  - ".join(details)
                + f"\n  Détail : {out / 'texture_regression.json'} ; référence : {bpath}. Si la perte est voulue, "
                "relancer avec --accept-texture-changes.")
    return {"status": "regression", "lost": lost, "baseline": str(bpath)}
