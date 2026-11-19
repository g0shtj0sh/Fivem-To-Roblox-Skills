#!/usr/bin/env python3
"""Dépose les scripts d'installation d'un véhicule converti dans le dossier d'un projet Rojo
synchronisé en direct avec Studio (ex. VibeStarter : include/ -> ReplicatedStorage.rbxts_include),
pour qu'un agent les exécute par execute_luau sans recopier leur source dans ses messages.

    python scripts/studio_stage.py <sortie>/<nom> --project <dossier du projet Rojo>
    python scripts/studio_stage.py --clean <sortie>/<nom> --project <dossier>   (fichiers de ce véhicule)
    python scripts/studio_stage.py --clean --project <dossier>                  (tout, si plus aucun véhicule)

Fichiers déposés dans <dossier synchronisé>/F2R_Transfer/ :
    FiveMRuntime.txt      -> StringValue  (loadstring(...)() : installe le runtime)
    <nom>_Setup.txt       -> StringValue  (loadstring(...)({ target = modèle }))
    ApplySoundIds.txt     -> StringValue  (renseigne les SoundId d'un véhicule déjà installé)
    <nom>_sound_ids.txt   -> StringValue  (texte de sounds/sound_ids.json, s'il existe)
    Verify.lua            -> ModuleScript (require(...)(opts) -> JSON ; aussi côté client en Play,
                                           où loadstring est interdit)
    DriveBench.lua        -> ModuleScript (mesures de conduite, client du conducteur en Play)
    TestTrack.lua         -> ModuleScript (piste d'essai temporaire, serveur en Play)
    PlayLock.lua          -> ModuleScript (tour de rôle pour le Play entre agents)
Plusieurs agents peuvent déposer en même temps : les fichiers communs sont identiques et écrits
de façon atomique ; --clean <sortie>/<nom> ne retire que les fichiers de ce véhicule.
Affiche un JSON : chemin Studio du dossier, fichiers, octets.
Le dossier choisi doit être monté avec "$ignoreUnknownInstances": true (Rojo n'y efface rien d'autre)
et ignoré par git (rien n'est commité).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

FOLDER = "F2R_Transfer"


def _walk(node: dict, path: list[str], out: list[tuple[str, str, bool]]) -> None:
    if not isinstance(node, dict):
        return
    p = node.get("$path")
    if isinstance(p, dict):
        p = p.get("optional")
    if isinstance(p, str) and path:
        out.append((p, ".".join(path), bool(node.get("$ignoreUnknownInstances"))))
    for k, v in node.items():
        if not k.startswith("$") and isinstance(v, dict):
            _walk(v, path + [k], out)


def find_sync_dir(project: Path) -> tuple[Path, str]:
    """Dossier du projet monté dans Studio où l'on peut ajouter des fichiers sans risque."""
    for name in (".vibestarter.rojo.project.json", "default.project.json"):
        f = project / name
        if not f.is_file():
            continue
        tree = json.loads(f.read_text(encoding="utf-8")).get("tree", {})
        mounts: list[tuple[str, str, bool]] = []
        _walk(tree, [], mounts)
        cands = [(p, s) for p, s, ign in mounts if ign and (project / p).is_dir()]
        # « include » (VibeStarter / roblox-ts) d'abord : ignoré par git et jamais nettoyé par rbxtsc
        cands.sort(key=lambda c: (Path(c[0]).name != "include", len(c[0])))
        for p, studio in cands:
            if _git_ignored(project, project / p / FOLDER / "probe.txt"):
                return project / p, studio
        if cands:
            return project / cands[0][0], cands[0][1]
    raise SystemExit("Aucun dossier monté avec $ignoreUnknownInstances trouvé dans le projet Rojo "
                     f"({project}). Utiliser studio/chunks/ (execute_luau en morceaux) à la place.")


def _git_ignored(project: Path, path: Path) -> bool:
    try:
        r = subprocess.run(["git", "-C", str(project), "check-ignore", "-q", str(path)],
                           capture_output=True)
        return r.returncode == 0
    except FileNotFoundError:
        return False


def _vehicle_name(vdir: Path) -> str:
    man = vdir / "studio" / "manifest.json"
    if man.is_file():
        return json.loads(man.read_text(encoding="utf-8"))["vehicle"]
    return vdir.name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vehicle_dir", nargs="?", help="<sortie>/<nom> produit par convert_vehicle.py")
    ap.add_argument("--project", required=True, help="dossier du projet Rojo synchronisé avec Studio")
    ap.add_argument("--clean", action="store_true", help="retirer le dossier F2R_Transfer du projet")
    args = ap.parse_args()

    project = Path(args.project).resolve()
    sync_dir, studio_path = find_sync_dir(project)
    dest = sync_dir / FOLDER
    if args.clean:
        # Les autres agents peuvent encore se servir du dossier : on ne retire que les fichiers du
        # véhicule désigné, et le dossier entier seulement quand plus aucun véhicule n'y est déposé.
        removed = []
        if args.vehicle_dir and dest.exists():
            vname = _vehicle_name(Path(args.vehicle_dir).resolve())
            for f in (f"{vname}_Setup.txt", f"{vname}_sound_ids.txt"):
                if (dest / f).exists():
                    (dest / f).unlink()
                    removed.append(f)
        left = sorted(p.name for p in dest.glob("*_Setup.txt")) if dest.exists() else []
        if dest.exists() and not left:
            shutil.rmtree(dest)
            removed.append(FOLDER)
        print(json.dumps({"removed": removed, "vehicles_left": [n[:-10] for n in left],
                          "studio_path": f"{studio_path}.{FOLDER}"}))
        return 0
    if not args.vehicle_dir:
        ap.error("vehicle_dir requis (sauf avec --clean)")
    vdir = Path(args.vehicle_dir).resolve()
    sdir = vdir / "studio"
    if not (sdir / "manifest.json").is_file():
        raise SystemExit(f"{sdir}/manifest.json introuvable : relancer convert_vehicle.py (version récente).")
    name = _vehicle_name(vdir)
    dest.mkdir(parents=True, exist_ok=True)
    plan = {
        "FiveMRuntime.txt": sdir / "FiveMRuntime.lua",
        f"{name}_Setup.txt": sdir / f"{name}_Setup.studio.lua",
        "ApplySoundIds.txt": sdir / "ApplySoundIds.lua",
        "Verify.lua": sdir / "Verify.lua",
        "DriveBench.lua": sdir / "DriveBench.lua",
        "TestTrack.lua": sdir / "TestTrack.lua",
        "PlayLock.lua": sdir / "PlayLock.lua",
    }
    ids = vdir / "sounds" / "sound_ids.json"
    if ids.is_file():
        plan[f"{name}_sound_ids.txt"] = ids
    files = {}
    for target, src in plan.items():
        if not src.is_file():
            continue
        tmp = dest / f".{target}.{os.getpid()}.tmp"     # écriture atomique : un autre agent peut
        shutil.copyfile(src, tmp)                        # déposer le même fichier au même moment
        os.replace(tmp, dest / target)
        files[target] = src.stat().st_size
    print(json.dumps({"studio_path": f"{studio_path}.{FOLDER}", "dir": str(dest), "vehicle": name,
                      "files": files}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
