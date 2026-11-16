#!/usr/bin/env python3
"""Banque de sons moteur : changer le son d'un véhicule en jeu (op « EngineSound » du runtime).

Un véhicule converti porte UN son du pack maison (boucles moteur + échappement, régimes mesurés).
Pour proposer les autres sons de SA catégorie (coupé, sport, super…) dans un menu de custom, chaque
son de la catégorie est découpé une fois en boucles, publié une fois sur Roblox, puis décrit dans le
ModuleScript `ReplicatedStorage.FiveMVehicles.EngineSoundBank` (gardé par les réinstallations du runtime).

Étapes :
  1. build : découpe les boucles de chaque son de la catégorie (même chaîne que la conversion).
       python scripts/engine_sound_bank.py build --category coupe --out <dossier>
     -> <dossier>/<son>/*.wav  +  <dossier>/bank_manifest.json
  2. publier chaque <son>/*.wav (VibeStarter : upload_file + asset_publish ; hors VibeStarter :
     scripts/roblox_upload.py) et écrire <dossier>/sound_ids.json = { "<son>/<fichier>.wav": "rbxassetid://…" }.
     `--reuse <son>=<sound_ids.json d'un véhicule>` reprend les ids d'un véhicule déjà converti avec ce son
     (fichiers identiques, vérifiés par empreinte) : rien à republier pour lui.
  3. emit : écrit le module Lua (fusionné avec une banque existante si --merge).
       python scripts/engine_sound_bank.py emit --out <dossier> [--merge EngineSoundBank.lua]
     -> <dossier>/EngineSoundBank.lua, à mettre dans ReplicatedStorage.FiveMVehicles (ModuleScript).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from f2r import audio as audio_mod  # noqa: E402
from f2r import sound_pack  # noqa: E402
from f2r.util import Report  # noqa: E402

CATEGORY_LABELS = {
    "berline": "Berline", "classique": "Classique", "compact": "Compacte", "coupe": "Coupé", "monster": "Monster",
    "muscle": "Muscle", "pickup": "Utilitaire", "sport": "Sport", "super": "Super", "suv": "SUV",
    "toutterrain": "Tout-terrain",
}


def sha1(p: Path) -> str:
    return hashlib.sha1(p.read_bytes()).hexdigest()


def label_of(engine: str, category: str) -> str:
    m = re.search(r"_(\d+)$", engine)
    return f"{CATEGORY_LABELS.get(category, category.capitalize())} {int(m.group(1))}" if m else engine


def cmd_build(args) -> int:
    report = Report()
    root = sound_pack.open_pack(args.pack or sound_pack.DEFAULT_URL, sound_pack.default_cache(), report)
    if root is None:
        print("Pack de sons introuvable.", file=sys.stderr)
        return 2
    engines = sound_pack.list_engines(root)
    cats = [args.category] if args.category else sorted(engines)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = out / "bank_manifest.json"
    manifest = json.loads(manifest_path.read_text("utf-8")) if manifest_path.exists() else {"Sounds": {}}
    for cat in cats:
        if cat not in engines:
            print(f"Catégorie inconnue : {cat} (connues : {', '.join(sorted(engines))})", file=sys.stderr)
            return 2
        for engine_dir in engines[cat]:
            name = engine_dir.name
            if args.only and name not in args.only:
                continue
            wavs = sound_pack.prepare(engine_dir, root, out / "_work" / name, name, report)
            wavs.pop("horn", None)  # le klaxon reste celui du véhicule
            dest = out / name
            dest.mkdir(parents=True, exist_ok=True)
            built = audio_mod.build_audio(dest, wavs=wavs, audio_name=name, vclass="", is_emergency=False,
                                          report=report, use_ogg=False)
            loops = []
            for loop in built["EngineLoops"]:
                f = dest / loop["File"]
                loops.append({"Name": Path(loop["File"]).stem, "File": f"{name}/{loop['File']}", "Rpm": loop["Rpm"],
                              "Load": loop["Load"], "Layer": loop["Layer"], "Sha1": sha1(f)})
            # seules les boucles moteur sont publiées : klaxon et clignotants restent ceux du véhicule
            for extra in ("horn.wav", "indicator_on.wav", "indicator_off.wav"):
                (dest / extra).unlink(missing_ok=True)
            manifest["Sounds"][name] = {"Category": cat, "Label": label_of(name, cat), "IdleRpm": built["IdleRpm"],
                                        "MaxRpm": built["MaxRpm"], "Loops": loops}
            print(f"{name} : {len(loops)} boucles", file=sys.stderr)
    manifest_path.write_text(json.dumps(manifest, indent=1, ensure_ascii=False), "utf-8")
    files = [loop["File"] for s in manifest["Sounds"].values() for loop in s["Loops"]]
    (out / "upload_list.json").write_text(json.dumps(files, indent=1), "utf-8")
    print(f"{len(manifest['Sounds'])} sons, {len(files)} boucles -> {manifest_path}")
    return 0


def lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def parse_existing(path: Path) -> dict:
    """Relit une banque écrite par ce script (bloc JSON en commentaire de fin)."""
    m = re.search(r"--\[==\[BANK_JSON\n(.*?)\n\]==\]", path.read_text("utf-8"), re.S)
    return json.loads(m.group(1)) if m else {}


def cmd_emit(args) -> int:
    out = Path(args.out)
    manifest = json.loads((out / "bank_manifest.json").read_text("utf-8"))
    ids_path = out / "sound_ids.json"
    ids = json.loads(ids_path.read_text("utf-8")) if ids_path.exists() else {}
    for spec in args.reuse or []:
        engine, _, path = spec.partition("=")
        vehicle_dir = Path(path).parent
        vehicle_ids = json.loads(Path(path).read_text("utf-8"))
        sound = manifest["Sounds"].get(engine)
        if not sound:
            print(f"--reuse : {engine} absent de la banque", file=sys.stderr)
            return 2
        for loop in sound["Loops"]:
            fname = Path(loop["File"]).name
            src = vehicle_dir / fname
            if fname in vehicle_ids and src.exists() and sha1(src) == loop["Sha1"]:
                ids.setdefault(loop["File"], vehicle_ids[fname])
            else:
                print(f"--reuse {engine} : {fname} différent du véhicule, à publier", file=sys.stderr)
    bank = parse_existing(Path(args.merge)) if args.merge else {}
    missing = []
    for name, s in manifest["Sounds"].items():
        loops = []
        for loop in s["Loops"]:
            sid = ids.get(loop["File"])
            if not sid:
                missing.append(loop["File"])
                continue
            loops.append({"Name": loop["Name"], "Rpm": loop["Rpm"], "Load": loop["Load"], "Layer": loop["Layer"],
                          "SoundId": sid})
        if len(loops) == len(s["Loops"]):
            bank[name] = {"Category": s["Category"], "Label": s["Label"], "IdleRpm": s["IdleRpm"], "Loops": loops}
    if missing:
        print(f"{len(missing)} boucles sans id (sons incomplets laissés hors de la banque) : {missing[:5]}…",
              file=sys.stderr)
    lines = ["--!strict",
             "-- FiveMVehicles/EngineSoundBank (ModuleScript, ReplicatedStorage) — généré par",
             "-- scripts/engine_sound_bank.py (skill fivem-vehicle-to-roblox). Ne pas éditer à la main.",
             "-- Sons moteur du pack maison publiés pour CE jeu : un véhicule peut prendre n'importe quel son de",
             "-- sa catégorie (op « EngineSound » de VehicleCustomization). Gardé par les réinstallations du runtime.",
             "local Bank = {}", ""]
    for name in sorted(bank):
        s = bank[name]
        lines.append(f"Bank[{lua_str(name)}] = {{ Category = {lua_str(s['Category'])}, Label = {lua_str(s['Label'])}, "
                     f"IdleRpm = {s['IdleRpm']}, Loops = {{")
        for loop in s["Loops"]:
            lines.append(f"\t{{ Name = {lua_str(loop['Name'])}, Rpm = {loop['Rpm']}, Load = {lua_str(loop['Load'])}, "
                         f"Layer = {lua_str(loop['Layer'])}, SoundId = {lua_str(loop['SoundId'])} }},")
        lines.append("} }")
    lines += ["", "return Bank", "",
              "--[==[BANK_JSON", json.dumps(bank, ensure_ascii=False, separators=(",", ":")), "]==]", ""]
    dest = out / "EngineSoundBank.lua"
    dest.write_text("\n".join(lines), "utf-8")
    print(f"{len(bank)} sons dans {dest}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--category", help="catégorie du pack (coupe, sport…) ; toutes si absent")
    b.add_argument("--only", nargs="*", help="seulement ces sons (ex. brolver_coupe_01)")
    b.add_argument("--pack", help="dossier, archive ou URL du pack (défaut : release brolver-motor-sounds-v1)")
    b.add_argument("--out", required=True)
    e = sub.add_parser("emit")
    e.add_argument("--out", required=True)
    e.add_argument("--reuse", nargs="*", help="<son>=<sounds/sound_ids.json d'un véhicule converti avec ce son>")
    e.add_argument("--merge", help="banque existante (EngineSoundBank.lua) à compléter")
    args = ap.parse_args()
    return cmd_build(args) if args.cmd == "build" else cmd_emit(args)


if __name__ == "__main__":
    raise SystemExit(main())
