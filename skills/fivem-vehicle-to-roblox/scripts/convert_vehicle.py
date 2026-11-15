#!/usr/bin/env python3
"""Convertit un véhicule FiveM / GTA V (zip, dossier de ressource, ou exports CodeWalker XML)
en un pack prêt pour Roblox Studio.

Exemple :
    python convert_vehicle.py ~/Downloads/adder.zip -o ./out
    python convert_vehicle.py ./ma_ressource --vehicle adder --studs-per-meter 3.2 -o ./out

Sortie (par véhicule) :  out/<nom>/
    <nom>.glb            modèle 3D (1 MeshPart par pièce, textures PNG <= 2048 px intégrées (--max-texture))
    <nom>_Setup.lua      script à exécuter dans Studio après l'import du .glb
    textures/            PNG convertis (référence / ré-upload manuel)
    sounds/              sons moteur, démarreur, klaxon, clignotant, sirènes (.wav/.ogg)
    vehicle_config.json  toutes les données extraites (handling, kits, couleurs, lumières...)
    report.md            ce qui a été converti, avertissements, étapes manuelles restantes
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from f2r import __version__  # noqa: E402
from f2r import audio as audio_mod  # noqa: E402
from f2r import collision as collision_mod  # noqa: E402
from f2r import sound_pack  # noqa: E402
from f2r import brands, cabin, cwxml, gamelib, icon_atlas, inventory, meta, rebadge  # noqa: E402
from f2r.gltf import GlbWriter, GMaterial, quad  # noqa: E402
from f2r.gta_colors import rgb as palette_rgb  # noqa: E402
from f2r.roblox import (build_runtime_install, build_setup,  # noqa: E402
                        runtime_version, split_for_execute_luau)
from f2r.textures import TextureStore, load_image  # noqa: E402
from f2r.util import Report, extract_archive, register_names, write_json  # noqa: E402
from f2r.vehicle import (LIGHT_IDS, SEAT_BONES, STEERING_BONES,  # noqa: E402
                         Part, VehicleBuilder)

SKILL_ROOT = HERE.parent
EXTRACTOR_DIR = SKILL_ROOT / "tools" / "gta-extract"
PAINT_ORDER = ["Primary", "Secondary", "Pearlescent", "Wheel", "InteriorTrim", "Dashboard"]
EMERGENCY_FLAGS = ("FLAG_EMERGENCY_SERVICE", "FLAG_LAW_ENFORCEMENT")


# ------------------------------------------------------------------ extraction binaire

def _find_dotnet() -> str | None:
    """dotnet du PATH, sinon une installation utilisateur (dotnet-install.sh -> ~/.dotnet)."""
    found = shutil.which("dotnet")
    if found:
        return found
    for cand in (os.environ.get("DOTNET_ROOT"), str(Path.home() / ".dotnet")):
        if cand and (Path(cand) / ("dotnet.exe" if os.name == "nt" else "dotnet")).is_file():
            return str(Path(cand) / ("dotnet.exe" if os.name == "nt" else "dotnet"))
    return None


def find_extractor() -> list[str] | None:
    # `dotnet gta-extract.dll` d'abord : l'exécutable natif (apphost) ne trouve pas un
    # .NET installé hors des chemins système (~/.dotnet) sans DOTNET_ROOT, et échoue
    # alors avec « You must install .NET » (observé dans la VM VibeStarter, 2026-11-10).
    dotnet = _find_dotnet()
    exe = EXTRACTOR_DIR / "bin" / ("gta-extract.exe" if os.name == "nt" else "gta-extract")
    dll = EXTRACTOR_DIR / "bin" / "gta-extract.dll"
    if dll.exists() and dotnet:
        os.environ.setdefault("DOTNET_ROOT", str(Path(dotnet).resolve().parent))
        return [dotnet, str(dll)]
    if exe.exists():
        return [str(exe)]
    return None


def build_extractor(report: Report) -> list[str] | None:
    dotnet = _find_dotnet()
    if not dotnet:
        return None
    os.environ["PATH"] = str(Path(dotnet).parent) + os.pathsep + os.environ.get("PATH", "")
    script = EXTRACTOR_DIR / ("build.ps1" if os.name == "nt" else "build.sh")
    cmd = (["powershell", "-ExecutionPolicy", "Bypass", "-File", str(script)] if os.name == "nt"
           else ["bash", str(script)])
    report.info("Compilation de gta-extract (CodeWalker.Core)…")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        report.warn("Échec de compilation de gta-extract :\n" + (r.stderr or r.stdout)[-2000:])
        return None
    return find_extractor()


def run_extractor(cmd: list[str], src: Path, dst: Path, report: Report) -> bool:
    dst.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(cmd + ["export", str(src), "-o", str(dst)], capture_output=True, text=True)
    ok = 0
    for line in r.stdout.splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("status") == "ok":
            ok += 1
        else:
            report.warn(f"gta-extract : {Path(row.get('input', '?')).name} -> {row.get('error')}")
    report.info(f"gta-extract : {ok} ressource(s) converties en XML.")
    if r.returncode not in (0,) and ok == 0:
        report.warn("gta-extract a échoué : " + r.stderr[-1500:])
        return False
    return ok > 0


# ------------------------------------------------------------------ studio/ (automatisation)

def write_studio_bundle(out: Path, name: str, config: dict, parts_cfg: dict, sound_ids: dict) -> None:
    """Variante pour un agent qui pilote Studio par execute_luau (MCP Roblox Studio) :
    runtime installé à part (une fois par place), Setup compact, et les deux déjà découpés
    en appels execute_luau (studio/chunks/*.lua, à envoyer dans l'ordre de manifest.json)."""
    sdir = out / "studio"
    if sdir.exists():
        shutil.rmtree(sdir)
    (sdir / "chunks").mkdir(parents=True)
    runtime = build_runtime_install()
    compact = build_setup(config, parts_cfg, sound_ids, include_runtime=False, include_config_source=False)
    (sdir / "FiveMRuntime.lua").write_text(runtime, encoding="utf-8")
    (sdir / f"{name}_Setup.studio.lua").write_text(compact, encoding="utf-8")
    manifest = {"runtime_version": runtime_version(), "vehicle": name, "steps": []}
    for key, src in (("FiveMRuntime", runtime), (f"{name}_Setup", compact)):
        calls = split_for_execute_luau(src, key)
        files = []
        for i, code in enumerate(calls, 1):
            f = sdir / "chunks" / f"{key}_{i:02d}.lua"
            f.write_text(code, encoding="utf-8")
            files.append(f"chunks/{f.name}")
        manifest["steps"].append({"key": key, "bytes": len(src.encode("utf-8")), "calls": files})
    for extra in ("Verify.lua", "ApplySoundIds.lua", "DriveBench.lua", "TestTrack.lua"):
        shutil.copyfile(SKILL_ROOT / "roblox" / extra, sdir / extra)
    (sdir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")


# ------------------------------------------------------------------ collision (hitbox fidèle)

def add_collision(frag_path: Path, vb: VehicleBuilder, glb: GlbWriter, parts_cfg: dict, args,
                  report: Report) -> dict:
    """Ajoute au GLB la collision officielle du .yft (col__<os>__<n>) et renvoie CONFIG.Collision.
    Sans données de collision : hitbox = boîte englobante (comportement d'avant)."""
    if getattr(args, "no_collision", False):
        return {"Source": "box"}
    try:
        coll = collision_mod.parse_collision(frag_path)
    except Exception as exc:  # noqa: BLE001
        report.warn(f"Collision du .yft illisible ({exc}) : hitbox = boîte englobante.")
        return {"Source": "box"}
    if coll is None:
        report.warn("Le .yft ne contient pas de collision (Physics/Bounds) : hitbox = boîte englobante "
                    "(peu fidèle aux formes du véhicule).")
        return {"Source": "box"}
    root = vb.skel.root_name
    mat = GMaterial(name="F2R_Collision", base_color=[1.0, 0.0, 1.0, 1.0])
    pieces = 0
    for m in coll.meshes:
        bone = m.owner_group if m.owner_group in vb.skel.by_name else root
        owner = vb.owner_of(bone) if bone in vb.skel.by_name else root
        P, N, I = collision_mod.flat_mesh(m.pos, m.idx)
        glb.add_mesh(m.name, P, N, np.zeros((len(P), 2), np.float32), I, mat)
        chain = "/".join(list(vb.skel.ancestors(bone))) if bone in vb.skel.by_name else bone
        lo, hi = m.pos.min(axis=0), m.pos.max(axis=0)
        parts_cfg[m.name] = {"Kind": "collision", "Bone": bone, "BoneChain": chain, "Owner": owner,
                             "Center": r4((lo + hi) / 2), "Tris": len(m.idx) // 3, "Convex": m.convex}
        pieces += 1
    wheels = {}
    for w in coll.wheels:
        if w.group in vb.skel.by_name:
            wheels[w.group] = {"Center": r4(w.center), "Radius": round(w.radius, 4), "Width": round(w.width, 4)}
    report.info(f"Collision GTA : {pieces} morceau(x), {coll.triangles} triangles, {len(wheels)} roue(s)"
                + (f" ; écartés : {', '.join(coll.skipped)}" if coll.skipped else "") + ".")
    if any(m.skipped_primitives for m in coll.meshes):
        report.warn("Collision : primitives (boîte / sphère / capsule) dans une géométrie, non converties.")
    return {"Source": "gta", "Pieces": pieces, "Triangles": coll.triangles, "Wheels": wheels,
            "WheelsCollide": not getattr(args, "no_wheel_collision", False)}


# ------------------------------------------------------------------ helpers

def flip_if_inverted(p: Part) -> None:
    """Corrige l'ordre des sommets si les normales géométriques s'opposent aux normales des sommets."""
    tris = p.idx.reshape(-1, 3).astype(np.int64)
    if len(tris) == 0 or not np.any(p.nrm):
        return
    a, b, c = p.pos[tris[:, 0]], p.pos[tris[:, 1]], p.pos[tris[:, 2]]
    gn = np.cross(b - a, c - a)
    vn = p.nrm[tris[:, 0]] + p.nrm[tris[:, 1]] + p.nrm[tris[:, 2]]
    if np.mean(np.einsum("ij,ij->i", gn, vn) < 0) > 0.6:
        p.idx = tris[:, [0, 2, 1]].reshape(-1).astype(np.uint32)


def pick_ref_parts(parts: list[Part]) -> list[str]:
    cands = [p for p in parts if p.mod is None and p.tri_count > 4]
    if len(cands) < 3:
        cands = parts
    C = np.array([p.center() for p in cands], dtype=np.float64)
    i1 = int(np.argmax(np.linalg.norm(C - C.mean(axis=0), axis=1)))
    i2 = int(np.argmax(np.linalg.norm(C - C[i1], axis=1)))
    area = np.linalg.norm(np.cross(C[i2] - C[i1], C - C[i1]), axis=1)
    i3 = int(np.argmax(area))
    return [cands[i1].name, cands[i2].name, cands[i3].name]


def r4(v) -> list[float]:
    return [round(float(x), 4) for x in v]


def find_fragment(inv: inventory.Inventory, name: str):
    n = name.lower()
    for key in (n + "_hi", n):
        if key in inv.yft_xml:
            return inv.yft_xml[key]
    if n in inv.ydr_xml:
        return inv.ydr_xml[n]
    return None


# ------------------------------------------------------------------ marques (rebadge)

SKIP_HINT_DIRS = {"stream", "data", "common", "src", "xml", "_work", "audio", "sfx", "dlc_data"}


def collect_hints(src: Path, root: Path) -> list[str]:
    """Noms qui portent souvent la marque et le modèle : archive, dossiers de la ressource."""
    hints = [src.stem if src.is_file() else src.name]
    for d in sorted(root.rglob("*")):
        if d.is_dir() and len(d.relative_to(root).parts) <= 3 and d.name.lower() not in SKIP_HINT_DIRS:
            hints.append(d.name)
    seen, out = set(), []
    for h in hints:
        if h.lower() not in seen:
            seen.add(h.lower())
            out.append(h)
    return out


def rebadge_vehicle(name: str, vinfo: dict, vb: VehicleBuilder, store: TextureStore, pack_sources: dict,
                    out: Path, args, report: Report):
    """Renomme marque et modèle (table brands.json) et retire les logos de la marque réelle."""
    if getattr(args, "no_rebadge", False):
        report.warn("Rebadge désactivé (--no-rebadge) : logos et nom de la marque réelle conservés.")
        return None
    table = brands.BrandTable(getattr(args, "brands", None))
    naming = brands.resolve(table, vinfo, getattr(args, "hints", []) or [name],
                            getattr(args, "brand", None), getattr(args, "model_name", None))
    b = naming.brand
    if b is None:
        report.warn(f"Marque non reconnue (vehicleMakeName « {vinfo.get('make', '')} ») : logos retirés sans "
                    "logo de remplacement. Si c'est une vraie marque, l'ajouter à brands/brands.json (+ logo) "
                    "et reconvertir, ou passer --brand <marque du jeu>.")
    else:
        report.info(f"Marque : « {naming.real_make} » ({naming.found_in}) -> **{b.brolver}** ; modèle "
                    f"« {naming.real_model or '?'} » -> **{naming.model}**.")
    if naming.model_provisional:
        report.manual(f"Nom de modèle à choisir : « {naming.real_model} » ne se traduit pas automatiquement "
                      f"(provisoire : « {naming.model} »). Choisir un nom qui n'existe pas chez la marque d'origine "
                      "et reconvertir avec --model-name \"…\" (règle 2 de la table des marques).")
    logo_img = load_image(b.logo, report) if (b and b.logo) else None

    def original(tex: str):
        n = tex.lower()
        path = pack_sources.get(n) or pack_sources.get(n + "+hi") or pack_sources.get(n.replace("+hi", ""))
        return load_image(path, report) if path else None

    summary = rebadge.rebadge_parts(vb.parts, original, b.logo if b else None, out / "_rebadge", report)
    # logos peints (textures) et lettrages modélisés (géométrie) : spec explicite, sinon brands/vehicles/<nom>.json
    spec_path = getattr(args, "rebadge_spec", None)
    if not spec_path:
        cand = brands.DEFAULT_TABLE.parent / "vehicles" / f"{name}.json"
        spec_path = cand if cand.exists() else None
    geometry_ops = rebadge.load_geometry_spec(Path(spec_path)) if spec_path else []
    if geometry_ops:
        summary["geometry_removed_tris"] = rebadge.remove_geometry(
            vb.parts, [o for o in geometry_ops if o.get("op") == "remove_islands"], report)
        summary["restyled_parts"] = rebadge.restyle_geometry(
            vb.parts, [o for o in geometry_ops if o.get("op") == "restyle_islands"], out / "_rebadge", report)
        unknown = [o.get("op") for o in geometry_ops if o.get("op") not in ("remove_islands", "restyle_islands")]
        if unknown:
            raise ValueError(f"spec du véhicule, clé geometry : opération(s) inconnue(s) {unknown}")
    letters = rebadge.lettering_candidates(vb.parts)
    sheet = out / "_rebadge" / "lettrages_modelises.png"
    rebadge.lettering_sheet(letters, sheet)
    (out / "_rebadge" / "lettrages_modelises.json").write_text(json.dumps(
        [{"n": k, "part": c["part"], "bone": c["bone"], "islands": len(c["islands"]), "box": c["box"]}
         for k, c in enumerate(letters)], indent=1), encoding="utf-8")
    msg = (f"Lettrages modélisés : {len(letters)} grappe(s) de petits îlots dessinée(s) dans "
           f"`_rebadge/{sheet.name}` (boîtes dans `lettrages_modelises.json`).")
    if geometry_ops:
        n_rm = sum(1 for o in geometry_ops if o.get("op") == "remove_islands")
        report.info(msg + f" {n_rm} lettrage(s) déjà supprimé(s) d'après la spec du véhicule.")
    else:
        report.manual(msg + " Regarder la planche : une lettre ou un logo lisible (///M, M4, AMG, RS…) est une "
                      "vraie marque modélisée -> copier sa boîte en opération `remove_islands` de "
                      f"`brands/vehicles/{name}.json` (clé `geometry`, SKILL.md § 1b) et reconvertir.")
    for p in vb.parts:
        if p.tex_diffuse and p.tex_diffuse.startswith("f2r_"):
            store.sources[p.tex_diffuse.lower()] = out / "_rebadge" / f"{p.tex_diffuse}.png"
            spec = p.shader.textures.get("SpecSampler") if p.shader is not None else None
            if spec and spec.startswith("f2r_"):  # brillance unie de l'emblème (rebadge.emblem_spec)
                store.sources[spec.lower()] = out / "_rebadge" / f"{spec}.png"
    # logos peints dans les textures (même fichier de spec)
    if spec_path:
        spec = rebadge.load_spec(Path(spec_path))
        for tex, entry in spec.items():
            ops, size = entry.get("ops", []), entry.get("size")
            store.edits[tex] = (lambda img, role, ops=ops, size=size:
                                rebadge.apply_texture_spec(img, ops, logo_img, size, role))
        report.info(f"Rebadge des textures : {len(spec)} texture(s) retouchée(s) d'après {Path(spec_path).name}.")
    else:
        report.manual("Logos peints dans les textures (cache-moyeu, flanc de pneu, étrier, écran, volant) : non "
                      "détectables automatiquement. Contrôler la planche `textures/` et, s'il en reste, écrire "
                      f"`brands/vehicles/{name}.json` (voir SKILL.md, « Marques ») puis reconvertir.")
    naming.summary = summary
    return naming


# ------------------------------------------------------------------ conversion d'un véhicule

CLASSES_FILE = HERE.parent / "classes" / "vehicle_classes.json"


def apply_verified_class(name: str, vinfo: dict, args, report: Report) -> None:
    """Classe GTA réelle : --vehicle-class, sinon classes/vehicle_classes.json, sinon celle du mod (à vérifier).

    La vehicleClass d'un mod est souvent fausse (ex. M4 Competition rangée en VC_MUSCLE). Elle décide
    de la catégorie du son moteur et du rangement dans le menu du jeu : voir SKILL.md § 1c.
    """
    mod_class = str(vinfo.get("class", "") or "").upper()
    forced = (getattr(args, "vehicle_class", None) or "").strip().upper()
    entry = {}
    if CLASSES_FILE.exists():
        entry = json.loads(CLASSES_FILE.read_text(encoding="utf-8")).get("vehicles", {}).get(name.lower(), {})
    verified = forced or str(entry.get("class", "")).upper()
    if verified:
        if not verified.startswith("VC_"):
            verified = "VC_" + verified
        vinfo["class"] = verified
        why = "--vehicle-class" if forced else f"vérifiée ({entry.get('real_model', name)} : {entry.get('body', '?')})"
        if verified != mod_class:
            report.info(f"Classe du véhicule : {mod_class or '?'} (mod) remplacée par {verified}, {why}.")
        else:
            report.info(f"Classe du véhicule : {verified}, {why}.")
    else:
        report.warn(f"Classe du véhicule NON vérifiée : {mod_class or '?'} (celle du mod). Vérifier sur internet "
                    f"la carrosserie du vrai modèle, l'écrire dans classes/vehicle_classes.json puis reconvertir "
                    f"(SKILL.md § 1c) : elle choisit le son moteur et le rangement dans le menu.")


def convert_one(name: str, inv: inventory.Inventory, metas: dict, out: Path, args, report: Report,
                game: "gamelib.GameAssets | None" = None) -> dict:
    vinfo = metas["vehicles"].get(name, {"modelName": name})
    apply_verified_class(name, vinfo, args, report)
    variation = metas["carvariations"].get(name, {})
    carcols = metas["carcols"]
    handling_id = (vinfo.get("handlingId") or name).lower()
    handling = meta.summarize_handling(metas["handling"].get(handling_id))
    if not handling:
        report.warn(f"handling.meta : aucune entrée « {handling_id} » dans le pack (le véhicule réutilise "
                    "probablement le handling d'une voiture du jeu de base). Valeurs physiques par défaut.")
    out.mkdir(parents=True, exist_ok=True)

    frag_path = find_fragment(inv, name)
    if frag_path is None:
        raise SystemExit(f"Modèle {name}.yft introuvable (ni binaire converti ni XML).")
    report.info(f"Modèle : {frag_path.name} (LOD {args.lod})")
    frag = cwxml.parse_fragment(frag_path, args.lod)

    # kits de mods applicables à ce véhicule
    kits = [carcols["kits"][k.lower()] for k in variation.get("kits", []) if k.lower() in carcols["kits"]]
    if not kits and carcols["kits"] and len(metas["vehicles"]) <= 1:
        kits = list(carcols["kits"].values())  # pack mono-véhicule : on prend les kits fournis
    turn_off = {b.lower() for k in kits for m in k["visibleMods"] for b in m["turnOffBones"]}

    vb = VehicleBuilder(frag, report, max_tris=args.max_tris, keep_bones=turn_off, livery_uv=args.livery_uv)
    vb.build_main()
    ws, wsr = vinfo.get("wheelScale") or 0, vinfo.get("wheelScaleRear") or 0
    rear_scale = (wsr / ws) if (ws > 0 and wsr > 0 and abs(wsr / ws - 1) > 0.01) else 1.0
    vb.instance_wheels(rear_scale)
    if not vb.parts:
        raise SystemExit("Aucune géométrie trouvée dans le modèle.")

    # ---- mods (la custom)
    mods_cfg: dict = {}
    stat_cfg: dict = {}
    mod_count = 0
    for kit in kits:
        per_type: dict[str, int] = {}
        for m in kit["visibleMods"]:
            vmt = m["type"] or "VMT_UNKNOWN"
            slot = meta.MOD_SLOT_NAMES.get(vmt, vmt.replace("VMT_", "").title().replace("_", ""))
            per_type[vmt] = per_type.get(vmt, 0) + 1
            index = per_type[vmt]
            models = [x for x in [m["modelName"], *m["linkedModels"]] if x]
            mod = {"slot": slot, "index": index, "label": m["label"], "model": m["modelName"], "type": vmt}
            added = 0
            for mn in models:
                mp = find_fragment(inv, mn)
                if mp is None:
                    report.warn(f"Mod {slot} #{index} : modèle {mn} introuvable dans le pack.")
                    continue
                try:
                    added += vb.add_mod(cwxml.parse_fragment(mp, args.lod), mod, (m["bone"] or "chassis").lower())
                except Exception as exc:  # noqa: BLE001
                    report.warn(f"Mod {mn} illisible : {exc}")
            opts = mods_cfg.setdefault(slot, {"Label": slot, "Type": vmt, "Options": []})["Options"]
            opts.append({"Label": m["label"] or m["modelName"] or f"{slot} {index}", "Model": m["modelName"],
                         "TurnOffBones": [b.lower() for b in m["turnOffBones"]], "HasGeometry": added > 0})
            mod_count += 1
        for s in kit["statMods"]:
            slot = meta.MOD_SLOT_NAMES.get(s["type"], s["type"])
            stat_cfg.setdefault(slot, []).append({"Identifier": s["identifier"], "Modifier": s["modifier"]})

    # ---- textures + GLB
    sources = dict(inv.dds)
    sources.update({k: v for k, v in inv.images.items() if k not in sources})
    pack_sources = {k.lower(): v for k, v in sources.items()}
    if getattr(args, "texture_overrides", None):
        # Textures de remplacement (rebadge, retouches) : même nom que la texture du pack.
        n_over = 0
        for f in sorted(Path(args.texture_overrides).iterdir()):
            if f.suffix.lower() in (".png", ".dds", ".jpg", ".jpeg", ".tga", ".bmp"):
                sources[f.stem.lower()] = f
                n_over += 1
        report.info(f"{n_over} texture(s) remplacée(s) depuis {args.texture_overrides}.")
    store = TextureStore(sources, out / "textures", report, args.max_texture)

    # ---- marques : nom du jeu + rebadge (aucune marque réelle dans le véhicule converti)
    naming = rebadge_vehicle(name, vinfo, vb, store, pack_sources, out, args, report)

    # Textures réutilisées du jeu de base (vehshare, txdRelationships…) : on les
    # récupère dans l'installation GTA V du PC avant de construire les matériaux,
    # pour que le reste du pipeline les traite comme si elles étaient dans le pack.
    game_tex: dict = {}
    if game is not None:
        need = gamelib.collect_missing_textures(vb.parts, store)
        if need:
            txds = [t for t in ([vinfo.get("txdName") or name] + list(vinfo.get("dependentTxds") or [])) if t]
            game_tex = game.fetch_textures(need, vehicle=name, txds=txds,
                                           max_size=args.max_texture,
                                           retry=args.retry_gamefiles)
            if game_tex:
                for k, v in game_tex.items():
                    store.sources.setdefault(k.lower(), v)
                store.cache.clear()
                store.missing.clear()
                report.info(f"{len(game_tex)} texture(s) récupérée(s) du jeu de base "
                            f"(sur {len(need)} manquante(s)).")
            else:
                report.info(f"{len(need)} texture(s) absente(s) du pack n'ont pas été "
                            "retrouvées dans l'installation GTA V.")

    lo, hi = vb.bounds()
    paint_default = default_colors(variation)
    glb = GlbWriter()
    parts_cfg: dict = {}
    livery_names: list[str] = []
    for p in vb.parts:
        if p.livery and p.tex_livery and not livery_names:
            livery_names = store.siblings(p.tex_livery[0])
    # Planches d'icônes de l'habitacle (vehicle_dash_emissive) : symboles dessinés par l'alpha, fond blanc
    # sans signification -> texture refaite (icon_atlas.py) et pièces dash_emissive transparentes comme des
    # badges (sinon rectangles blancs dans Roblox, constaté sur la m422 le 2026-11-15).
    for p in vb.parts:
        if p.shader is not None and "dash_emissive" in p.shader.name and p.tex_diffuse:
            store.icon_atlases.add(p.tex_diffuse.lower())
    for p in vb.parts:
        if p.kind == "emissive" and store.is_icon_atlas(p.tex_diffuse):
            p.kind = "decal"
    _alpha_cache: dict = {}

    def _atlas_alpha(name):
        if not store.is_icon_atlas(name):
            return None
        if name.lower() not in _alpha_cache:
            src = store.find(name)
            img = load_image(src, report) if src is not None else None
            _alpha_cache[name.lower()] = np.asarray(img.convert("RGBA"))[..., 3] if img is not None else None
        return _alpha_cache[name.lower()]
    icon_atlas.split_icon_overlays(vb.parts, _atlas_alpha, report)
    for p in vb.parts:
        flip_if_inverted(p)
        mat, has_tex = make_material(p, store, paint_default, livery_names)
        glb.add_mesh(p.name, p.pos, p.nrm, p.uv, p.idx, mat)
        info = part_info(p, vb, store, has_tex)
        if mat.emissive_png is not None:
            # masque d'émission d'une optique : l'importeur Roblox l'ignore dans le GLB (vérifié 2026-11-15) ->
            # fichier à mettre en ligne (emissive/), id lu avec les sons (--sound-ids), posé par le Setup
            edir = out / "emissive"
            edir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(mat.emissive_png, edir / mat.emissive_png.name)
            info["EmissiveMask"] = mat.emissive_png.name
        parts_cfg[p.name] = info

    collision_cfg = add_collision(frag_path, vb, glb, parts_cfg, args, report)

    carriers = []
    for i, tex in enumerate(livery_names):
        png = store.get(tex)
        if png is None:
            continue
        pos, nrm, uv, idx = quad(0.05, at=(0.0, float(lo[1]) - 0.5, float(i) * 0.2))
        cname = f"LIVERY_TEX_{i + 1}"
        glb.add_mesh(cname, pos, nrm, uv, idx, GMaterial(name=cname, color_png=png, alpha="BLEND"))
        carriers.append(cname)
    glb_path = out / f"{name}.glb"
    glb.save(glb_path)
    if store.missing and game is not None:
        report.warn(f"{len(store.missing)} texture(s) introuvables même dans GTA V : "
                    + ", ".join(sorted(store.missing)[:25]) + (" …" if len(store.missing) > 25 else "")
                    + ". Couleur moyenne / unie utilisée à la place.")
    elif store.missing:
        report.warn(f"{len(store.missing)} texture(s) absente(s) du pack (souvent partagées avec le jeu, ex. vehshare) : "
                    + ", ".join(sorted(store.missing)[:25]) + (" …" if len(store.missing) > 25 else "")
                    + ". Couleur moyenne / unie utilisée à la place.")

    # ---- audio
    wavs: dict[str, Path] = {}
    for ax in inv.awc_xml:
        for s in cwxml.parse_awc(ax):
            if s.wav is not None:
                wavs[f"{ax.name}:{s.name}"] = s.wav
    for w in inv.wavs:
        wavs.setdefault(w.stem.lower(), w)
    # Son vanilla : le pack ne contient pas d'AWC, on va chercher le vrai son du
    # jeu désigné par audioNameHash (ex. ADDER) plutôt que de le synthétiser.
    audio_from_game = False
    pack_path = args.engine_pack or os.environ.get(sound_pack.ENV_VAR) or sound_pack.DEFAULT_URL
    if pack_path and not args.no_engine_pack:
        root = sound_pack.open_pack(pack_path, sound_pack.default_cache(), report)
        engine = sound_pack.choose(root, vinfo.get("class", ""), name, args.engine_sound) if root else None
        if engine is not None:
            got = sound_pack.prepare(engine, root, out / "_work_sounds", name, report)
            if got:
                wavs = got
        elif root is not None:
            report.warn(f"Pack de sons : « {args.engine_sound} » introuvable, son d'origine conservé.")
    if not wavs and game is not None:
        an = vinfo.get("audioNameHash") or name
        got = game.fetch_audio(an, retry=args.retry_gamefiles)
        if got:
            wavs.update(got)
            audio_from_game = True
            report.info(f"Son vanilla « {an} » récupéré du jeu de base "
                        f"({len(got)} flux : {', '.join(sorted(got))}).")

    is_emergency = (any(f in vinfo.get("flags", []) for f in EMERGENCY_FLAGS)
                    or variation.get("sirenSettings", -1) > 0
                    or any(b.name.startswith("siren") for b in vb.skel.bones)
                    or str(vinfo.get("class", "")).upper() == "VC_EMERGENCY")
    audio = audio_mod.build_audio(out / "sounds", wavs=wavs, audio_name=vinfo.get("audioNameHash") or name,
                                  vclass=vinfo.get("class", ""), is_emergency=is_emergency, report=report,
                                  use_ogg=not args.no_ogg)
    if audio_from_game:
        report.info("Les boucles moteur sont découpées dans le vrai son du jeu.")
    if not wavs:
        report.manual(f"Son : le véhicule utilise le son vanilla « {vinfo.get('audioNameHash') or name} » "
                      "(non inclus dans le pack) -> son moteur synthétisé. Pour un vrai son, déposez des .wav "
                      "(boucles moteur) dans le zip et relancez, ou remplacez les fichiers de sounds/.")

    # ---- configuration Roblox
    config = build_config(name, vinfo, variation, carcols, handling, vb, parts_cfg, mods_cfg, stat_cfg,
                          mod_count, carriers, livery_names, audio, is_emergency, args)
    if naming is not None:
        config["Make"] = naming.brand.brolver if naming.brand else ""
        config["Brand"] = config["Make"]
        config["ModelName"] = naming.model
        config["DisplayName"] = f"{config['Make']} {naming.model}".strip()
    config["Collision"] = collision_cfg
    sound_ids = load_sound_ids(args.sound_ids, out / "sounds")
    setup = build_setup(config, parts_cfg, sound_ids)
    (out / f"{name}_Setup.lua").write_text(setup, encoding="utf-8")
    write_studio_bundle(out, name, config, parts_cfg, sound_ids)
    write_json(out / "vehicle_config.json", {"vehicle": vinfo, "variation": variation, "handling_raw":
                                             metas["handling"].get((vinfo.get("handlingId") or name).lower()),
                                             "kits": kits, "roblox_config": config})
    write_json(out / "sounds" / "upload_manifest.json",
               {"files": sorted(p.name for p in (out / "sounds").iterdir() if p.suffix in (".wav", ".ogg"))})

    tris = sum(p.tri_count for p in vb.parts)
    stats = {"name": name, "parts": len(vb.parts), "triangles": tris, "mods": mod_count,
             "liveries": len(carriers), "textures": len([v for v in store.cache.values() if v]), "max_texture": store.max_size,
             "missing_textures": len(store.missing), "glb": str(glb_path), "glb_mb": round(glb_path.stat().st_size / 1e6, 2),
             "game_textures": len(game_tex), "audio_from_game": audio_from_game,
             "game_transfer": game.transfer_summary() if game is not None else "",
             "collision": collision_cfg,
             "horn_source": audio.get("HornSource", "synthese"),
             "naming": None if naming is None else {
                 "real_make": naming.real_make, "found_in": naming.found_in,
                 "brand": naming.brand.brolver if naming.brand else None,
                 "real_model": naming.real_model, "model": naming.model,
                 "provisional": naming.model_provisional},
             "rebadge": getattr(naming, "summary", None),
             "siren_source": audio.get("SirenSource")}
    if tris > 300_000:
        report.warn(f"{tris} triangles : lourd pour Roblox. Essayez --lod med pour un modèle plus léger.")
    return stats


def default_colors(variation: dict) -> dict:
    out = {"Default": [1.0, 1.0, 1.0]}
    cols = variation.get("colors") or []
    idx = cols[0]["indices"] if cols else []
    fallback = [[0.85, 0.85, 0.85], [0.1, 0.1, 0.1], [0.85, 0.85, 0.85], [0.15, 0.15, 0.15],
                [0.1, 0.1, 0.1], [0.1, 0.1, 0.1]]
    for i, layer in enumerate(PAINT_ORDER):
        out[layer] = palette_rgb(idx[i]) if i < len(idx) else fallback[i]
    return out


def make_material(p: Part, store: TextureStore, paint: dict, livery_names: list[str]):
    base = [1.0, 1.0, 1.0, 1.0]
    color_png = normal_png = None
    alpha = "OPAQUE"
    has_tex = False
    emissive_png = None
    if p.kind == "light" and p.tex_diffuse and store.find(p.tex_diffuse) is not None:
        # optique : sa texture (agrandie) éteinte, et un masque d'émission pour n'allumer que ses parties claires
        # (traits du feu de jour…) au lieu d'une pièce entière en Néon (light_emissive.py, m422 2026-11-15)
        color_png = store.get(p.tex_diffuse, "light")
        emissive_png = store.get(p.tex_diffuse, "emask")
        store.average(p.tex_diffuse)
        has_tex = color_png is not None
    elif p.kind == "paint" or p.paint:
        c = p.custom_color or paint.get(p.paint or "Primary", [0.85, 0.85, 0.85])
        base = [*c, 1.0]
        if p.livery and livery_names:
            color_png = store.get(livery_names[0])
            alpha = "BLEND"
        elif p.tex_diffuse and not store.is_flat(p.tex_diffuse):
            # une diffuse uniforme (ex. vehicle_generic_smallspecmap, blanche 4 x 4) n'apporte rien à la peinture :
            # sans texture, la pièce reste sans SurfaceAppearance et la custom peut changer sa finition (SetFinish)
            opaque_atlas = p.kind != "decal" and store.is_icon_atlas(p.tex_diffuse)
            color_png = store.get(p.tex_diffuse, "opaque" if opaque_atlas else "color")
            has_tex = color_png is not None
    elif p.kind in ("glass", "light", "siren"):
        store.average(p.tex_diffuse)
        base = [0.3, 0.3, 0.32, 0.5 if p.kind == "glass" else 1.0]
        alpha = "BLEND" if p.kind == "glass" else "OPAQUE"
    else:
        # planche d'icônes sur une pièce opaque : version sans transparence (sinon Roblox montre Part.Color
        # ou un fond blanc à la place du fond transparent)
        opaque_atlas = p.kind != "decal" and store.is_icon_atlas(p.tex_diffuse)
        color_png = store.get(p.tex_diffuse, "opaque" if opaque_atlas else "color")
        has_tex = color_png is not None
        if p.custom_color and color_png is None:
            base = [*p.custom_color, 1.0]
        if p.kind == "decal":
            alpha = "BLEND"
    if p.kind == "decal" and color_png is not None and store.is_icon_atlas(p.tex_diffuse):
        alpha = "BLEND"  # badges peints (branche peinture) qui affichent la planche d'icônes : transparents aussi
    mr_png = None
    if color_png is not None and p.kind not in ("glass", "light", "siren"):
        normal_png = store.get(p.tex_normal, "normal") if p.tex_normal else None
        # brillance GTA (SpecSampler) -> RoughnessMap / MetalnessMap de la SurfaceAppearance ; valeur imposée par une
        # retouche du véhicule (restyle_islands) si la spec du véhicule en donne une
        mr = getattr(p, "mr_override", None)
        mr_png = store.flat_metal_rough(*mr) if mr else store.metal_rough(p.shader, p.tex_diffuse)
    mat = GMaterial(name=f"{p.shader.name}_{p.name}"[:60], base_color=base, color_png=color_png,
                    normal_png=normal_png, mr_png=mr_png, alpha=alpha, emissive_png=emissive_png,
                    double_sided=p.kind in ("decal", "glass"))
    return mat, has_tex


def part_info(p: Part, vb: VehicleBuilder, store: TextureStore, has_tex: bool) -> dict:
    chain = "/".join(list(vb.skel.ancestors(p.bone))) if p.bone in vb.skel.by_name else p.bone
    info = {"Kind": p.kind, "Bone": p.bone, "BoneChain": chain, "Owner": p.owner,
            "Center": r4(p.center()), "Tris": p.tri_count}
    if p.paint and p.paint != "Default":
        info["Paint"] = p.paint
    if p.custom_color:
        info["CustomColor"] = r4(p.custom_color)
    if p.light:
        info["Light"] = p.light
    if p.livery:
        info["Livery"] = True
    if has_tex:
        info["HasTexture"] = True
    if p.mod:
        info["ModSlot"] = p.mod["slot"]
        info["ModIndex"] = p.mod["index"]
    if p.extra is not None:
        info["Extra"] = p.extra
    if p.window:
        info["Window"] = p.window
    if p.siren is not None:
        info["Siren"] = p.siren
    avg = store.average(p.tex_diffuse)
    if avg:
        info["AvgColor"] = avg
    if p.kind == "plate":
        info["Normal"] = r4(np.mean(p.nrm, axis=0) / (np.linalg.norm(np.mean(p.nrm, axis=0)) or 1))
    return info


def build_config(name, vinfo, variation, carcols, handling, vb: VehicleBuilder, parts_cfg, mods_cfg, stat_cfg,
                 mod_count, carriers, livery_names, audio, is_emergency, args) -> dict:
    lo, hi = vb.bounds()
    bones = vb.bones_info()
    owners = sorted({i["Owner"] for i in parts_cfg.values() if i["Kind"] != "collision"} - {vb.skel.root_name})
    wheels = vb.wheel_info()
    dynamic = sorted(set(owners) | set(wheels) | {b for b in bones if b.startswith("siren") and b[5:].isdigit()})
    hinges = vb.hinge_info({"door": 70.0, "bonnet": 50.0, "boot": 60.0, "boot_2": 60.0})
    for hb, h in hinges.items():
        cs = [i["Center"] for i in parts_cfg.values()
              if i["Owner"] == hb and "ModSlot" not in i and i["Kind"] != "collision"]
        if cs:
            h["Center"] = r4(np.mean(cs, axis=0))
    steering = None
    for sb in STEERING_BONES:
        if sb in bones:
            fwd = np.array(bones[sb]["Forward"])
            if fwd[2] > 0:
                fwd = -fwd
            # GTA : le volant suit l'angle des roues avant, ≈ 90 ° à pleine butée × steerWheelMult (vehicles.meta)
            mult = float(vinfo.get("steerWheelMult") or 1.0)
            steering = {"Bone": sb, "Axis": r4(fwd), "WheelMult": round(mult, 3), "MaxAngle": round(90 * mult, 1)}
            dynamic = sorted(set(dynamic) | {sb})
            break

    lights, light_owners = {}, {}
    for lid, role in LIGHT_IDS.items():
        role_parts = [(n, i) for n, i in parts_cfg.items() if i.get("Light") == role]
        if role in bones:
            lights[role] = bones[role]["Position"]
        elif role_parts and lid > 0:
            lights[role] = r4(np.mean([i["Center"] for _, i in role_parts], axis=0))
        if role_parts:
            light_owners[role] = role_parts[0][1]["Owner"]
    lights.pop("always_on", None)

    lid = variation.get("lightSettings", -1)
    light_settings = carcols["lights"].get(lid) or {}
    sid = variation.get("sirenSettings", -1)
    siren_src = carcols["sirens"].get(sid)
    sirens = None
    if siren_src or is_emergency:
        sirens = {"Bpm": (siren_src or {}).get("bpm", 220),
                  "HeadLightLeft": (siren_src or {}).get("headLightLeft", 0),
                  "HeadLightRight": (siren_src or {}).get("headLightRight", 0),
                  "Lights": {}}
        entries = (siren_src or {}).get("sirens", [])
        n_bones = sorted(int(b[5:]) for b in bones if b.startswith("siren") and b[5:].isdigit())
        for i in n_bones:
            e = entries[i - 1] if i - 1 < len(entries) else {}
            fl = e.get("flashiness") or {}
            rot = e.get("rotation") or {}
            sirens["Lights"][i] = {
                "Color": r4(e.get("color") or ([1, 0, 0] if i % 2 else [0, 0.2, 1])),
                "Sequencer": int(fl.get("sequencer") or (0xAAAAAAAA if i % 2 else 0x55555555)),
                "Rotate": bool(e.get("rotate", False)),
                "RotationSpeed": round(max(2.0, min(20.0, float(rot.get("speed", 2.0)) * 3)), 3),
            }

    # Caméra à la première personne (GTA, vehicles.meta) : PovCameraOffset est relatif à l'os du siège du
    # conducteur ; les passagers avant / arrière l'ajoutent à leur décalage propre (Pov*PassengerCameraOffset).
    pov = vinfo.get("povCameraOffset") or [0.0, -0.225, 0.585]
    pov_front = vinfo.get("povPassengerCameraOffset") or [0.0, 0.0, 0.0]
    pov_rear = vinfo.get("povRearPassengerCameraOffset") or [0.0, 0.0, 0.0]

    def _pov(sb: str) -> list[float]:
        extra = [0.0, 0.0, 0.0] if sb == "seat_dside_f" else (pov_front if sb.endswith("_f") else pov_rear)
        return meta._gta_vec_to_local([pov[i] + extra[i] for i in range(3)])

    seats = []
    for sb in SEAT_BONES:
        if sb in bones:
            seats.append({"Bone": sb, "Position": bones[sb]["Position"], "Driver": sb == "seat_dside_f",
                          "PovOffset": _pov(sb)})
    if not seats:
        seats.append({"Bone": "guess", "Driver": True,
                      "Position": r4([lo[0] * 0.35, (lo[1] + hi[1]) / 2 - 0.1, (lo[2] + hi[2]) / 2])})
    elif not any(s["Driver"] for s in seats):
        seats[0]["Driver"] = True

    # habitacle en voxels : adapter le corps des occupants (VehicleSeatFit)
    cabin_cfg = None
    if not getattr(args, "no_seat_fit", False):
        try:
            cabin_cfg = cabin.build_cabin(vb.parts, seats)
        except Exception as exc:  # noqa: BLE001
            vb.report.warn(f"Habitacle non calculé ({exc}) : pas d'adaptation du corps des occupants.")
        if cabin_cfg:
            st = cabin_cfg.pop("Stats")
            vb.report.info(f"Habitacle : {st['CabinCells']} cellules d'air ({cabin_cfg['Cell'] * 100:.0f} cm), "
                           f"{'ouvert (pas d adaptation du corps)' if cabin_cfg['Open'] else 'fermé'}, "
                           f"grille {len(cabin_cfg['Bad']) / 1024:.1f} Ko.")

    engine_pos = bones.get("engine", {}).get("Position") or r4([0, (lo[1] + hi[1]) / 2, lo[2] + 0.8])
    extras = sorted({i["Extra"] for i in parts_cfg.values() if "Extra" in i})

    loops = [{"Name": "", "File": l["File"], "Rpm": l["Rpm"], "Load": l["Load"], "Layer": l.get("Layer", "engine")}
             for l in audio["EngineLoops"]]
    # noms uniques par couche et par charge (engine_on_1, exhaust_off_3, exhaust_idle…)
    counters: dict[str, int] = {}
    for l in loops:
        key = f"{l['Layer']}_{l['Load']}"
        counters[key] = counters.get(key, 0) + 1
        l["Name"] = key if l["Load"] == "idle" else f"{key}_{counters[key]}"
    # sortie d'échappement : moyenne des os exhaust* (le son d'échappement y est placé, comme dans GTA)
    ex = [b["Position"] for n, b in bones.items() if (n == "exhaust" or n.startswith("exhaust_")) and b.get("Position")]
    exhaust_pos = r4([sum(p[i] for p in ex) / len(ex) for i in range(3)]) if ex else r4([0, lo[1] + 0.3, hi[2] - 0.2])

    ref = pick_ref_parts([p for p in vb.parts])
    bones_min = {b: {"Position": v["Position"], "Parent": v["Parent"]} for b, v in bones.items()}
    return {
        "Name": name,
        "DisplayName": vinfo.get("gameName") or name,
        "Make": vinfo.get("make", ""),
        "Class": vinfo.get("class", ""),
        "Type": vinfo.get("type", ""),
        "DashboardType": vinfo.get("dashboardType", ""),
        "Layout": vinfo.get("layout", ""),  # LAYOUT_LOW… : posture assise (VehiclePose)  # VDT_* de vehicles.meta (référence, cf. VehicleDashboard)
        "ConverterVersion": __version__,
        "StudsPerMeter": args.studs_per_meter,
        "ProbePart": ref[0],
        "RefParts": ref,
        "RootBone": vb.skel.root_name,
        "Bones": bones_min,
        "DynamicBones": dynamic,
        "Bounds": {"Min": r4(lo), "Max": r4(hi)},
        "Colors": {"Default": default_colors(variation),
                   "Variations": [c["indices"] for c in variation.get("colors", [])]},
        "Wheels": wheels,
        "WheelFollowers": vb.wheel_followers(),
        "Hinges": hinges,
        "SteeringWheel": steering,
        "Lights": lights,
        "LightOwners": light_owners,
        "LightSettings": light_settings,
        "Sirens": sirens,
        "HasSiren": bool(sirens),
        "Seats": seats,
        "Cabin": cabin_cfg,
        "DoorPrompts": not args.no_door_prompts,
        "EnginePosition": engine_pos,
        "ExhaustPosition": exhaust_pos,
        "Audio": {"IdleRpm": audio["IdleRpm"], "MaxRpm": audio["MaxRpm"], "Volume": 1,
                  "Cylinders": audio["Cylinders"], "Source": audio["Source"],
                  "EngineLoops": loops, "Files": audio["Files"]},
        "Mods": mods_cfg,
        "ModCount": mod_count,
        "StatMods": stat_cfg,
        "LiveryCarriers": carriers,
        "LiveryNames": livery_names,
        "DefaultLivery": 1 if carriers else 0,
        "Extras": extras,
        "Handling": handling,
        "Physics": vb.physics_info(),
        "PlateText": args.plate,
    }


def load_sound_ids(path: str | None, sounds_dir: Path) -> dict:
    """Ids des fichiers mis en ligne : sons (--sound-ids ou sounds/sound_ids.json) et masques d'émission des
    optiques (emissive/emissive_ids.json, ou dans le même JSON que les sons)."""
    ids: dict = {}
    for c in ([Path(path)] if path else [sounds_dir / "sound_ids.json"]) + [sounds_dir.parent / "emissive" / "emissive_ids.json"]:
        if c.exists():
            data = json.loads(c.read_text(encoding="utf-8"))
            ids.update({k: (v if str(v).startswith("rbxassetid://") else f"rbxassetid://{v}") for k, v in data.items()})
    return ids


# ------------------------------------------------------------------ main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="FiveM / GTA V -> Roblox (véhicules)")
    ap.add_argument("input", help="zip / dossier de la ressource FiveM / dossier d'exports CodeWalker XML")
    ap.add_argument("-o", "--out", default="roblox_out", help="dossier de sortie")
    ap.add_argument("--vehicle", action="append", help="nom du modèle à convertir (défaut : tous)")
    ap.add_argument("--lod", default="high", choices=["high", "med", "low", "vlow"])
    ap.add_argument("--studs-per-meter", type=float, default=3.571,
                    help="échelle (1 m = 3.571 studs par défaut, convention physique Roblox 1 stud = 0.28 m)")
    ap.add_argument("--max-tris", type=int, default=19000, help="triangles max par MeshPart (limite Roblox 20k)")
    ap.add_argument("--max-texture", type=int, default=2048,
                    help="taille max des textures (px) ; Roblox garde 2048 et réduit 4096 à 2048 (mesuré le 2026-11-15)")
    ap.add_argument("--livery-uv", default="auto", choices=["auto", "uv0", "uv1"])
    ap.add_argument("--no-collision", action="store_true",
                    help="ne pas reprendre la collision du .yft (hitbox = boîte englobante)")
    ap.add_argument("--no-wheel-collision", action="store_true",
                    help="cylindres de roues non solides (moteur physique à roues propres) ; par défaut ils portent le véhicule")
    ap.add_argument("--texture-overrides",
                    help="dossier d'images qui remplacent les textures du pack de même nom (rebadge, retouches)")
    ap.add_argument("--brand", help="marque du jeu à utiliser (sinon reconnue d'après vehicles.meta / noms de dossier)")
    ap.add_argument("--model-name", help="nom de modèle du jeu (sinon traduit automatiquement du modèle réel)")
    ap.add_argument("--brands", help="table des marques (défaut : brands/brands.json du skill)")
    ap.add_argument("--rebadge-spec", help="JSON de retouches des logos peints dans les textures "
                    "(défaut : brands/vehicles/<nom>.json s'il existe)")
    ap.add_argument("--no-rebadge", action="store_true", help="garder marque et logos d'origine (déconseillé)")
    ap.add_argument("--sound-ids", help="JSON {fichier: assetId} produit par roblox_upload.py")
    ap.add_argument("--engine-pack",
                    help="pack de sons moteur maison (dossier ou .rar/.zip : sounds/<categorie>/<son>/...) ; "
                         f"défaut : variable d'environnement {sound_pack.ENV_VAR}, sinon téléchargé depuis la release GitHub "
                         "(mis en cache). Remplace le son du mod.")
    ap.add_argument("--engine-sound",
                    help="son du pack à utiliser (ex. brolver_super_03) ou catégorie (ex. muscle) ; "
                         "défaut : catégorie d'après la classe GTA, son tiré du nom du modèle")
    ap.add_argument("--vehicle-class",
                    help="classe GTA réelle (ex. VC_COUPE ou coupe) : remplace celle du mod et de "
                         "classes/vehicle_classes.json")
    ap.add_argument("--no-engine-pack", action="store_true", help="ignorer le pack de sons moteur maison")
    ap.add_argument("--plate", default="F2R 000", help="texte de plaque par défaut")
    ap.add_argument("--no-ogg", action="store_true", help="garder les .wav (ne pas convertir en .ogg)")
    ap.add_argument("--no-door-prompts", action="store_true")
    ap.add_argument("--extractor", help="commande gta-extract (sinon détection / compilation auto)")
    ap.add_argument("--no-build", action="store_true", help="ne pas compiler gta-extract automatiquement")
    ap.add_argument("--retry-gamefiles", action="store_true",
                    help="ignorer le cache et re-demander au serveur d'assets les textures / sons du jeu")
    ap.add_argument("--no-seat-fit", action="store_true",
                    help="ne pas calculer l'habitacle (pas d'adaptation du corps des occupants)")
    ap.add_argument("--no-game-server", action="store_true",
                    help="ne pas chercher le serveur d'assets GTA V (comportement hors ligne)")
    ap.add_argument("--game-server-url",
                    help="URL HTTP du serveur d'assets GTA V (sinon : connecteur MCP vibestarter)")
    args = ap.parse_args(argv)

    report = Report()
    out = Path(args.out).resolve()
    work = out / "_work"
    src = Path(args.input).resolve()
    if src.is_file():
        if work.exists():
            shutil.rmtree(work)
        extract_archive(src, work / "src", report)
        root = work / "src"
    else:
        root = src
    register_names(line.strip() for line in (EXTRACTOR_DIR / "extra_strings.txt").read_text(encoding="utf-8").splitlines()
                   if line.strip() and not line.startswith("//"))
    register_names(s + ".sps" for s in list(line.strip() for line in (EXTRACTOR_DIR / "extra_strings.txt")
                                            .read_text(encoding="utf-8").splitlines() if line.startswith("vehicle_")))

    args.hints = collect_hints(src, root)
    inv = inventory.scan(root)
    if inventory.needs_conversion(inv):
        cmd = args.extractor.split() if args.extractor else find_extractor()
        if cmd is None and not args.no_build:
            cmd = build_extractor(report)
        if cmd is None:
            msg = ("Le pack contient des ressources binaires (.yft/.ytd/.awc/.rpf) et l'outil gta-extract n'est pas "
                   "disponible (SDK .NET 8 requis : https://dotnet.microsoft.com/download).\n"
                   "Alternative sans .NET : ouvrir les fichiers dans CodeWalker (Windows), clic droit > "
                   "« Export XML » sur chaque .yft/.ytd/.awc, zipper le résultat et relancer ce script dessus.")
            if not (inv.yft_xml or inv.ydr_xml):
                print(msg, file=sys.stderr)
                return 2
            report.warn(msg)
        else:
            ok = run_extractor(cmd, root, work / "xml", report)
            inv2 = inventory.scan(work / "xml", include_binaries=False)
            for attr in ("yft_xml", "ydr_xml", "ytd_xml", "dds", "images"):
                getattr(inv, attr).update(getattr(inv2, attr))
            if not ok and not (inv.yft_xml or inv.ydr_xml):
                print("gta-extract n'a converti aucune ressource binaire ; voir l'avertissement "
                      "ci-dessus (commande : " + " ".join(cmd) + ").", file=sys.stderr)
                return 2
            inv.awc_xml += inv2.awc_xml
            inv.wavs += inv2.wavs
            for k, v in inv2.metas.items():
                inv.metas.setdefault(k, []).extend(v)

    metas = {
        "vehicles": meta.parse_vehicles(inv.metas.get("vehicles"), report),
        "carvariations": meta.parse_carvariations(inv.metas.get("carvariations"), report),
        "carcols": meta.parse_carcols(inv.metas.get("carcols"), report),
        "handling": meta.parse_handling(inv.metas.get("handling"), report),
    }
    mod_models = {m["modelName"].lower() for k in metas["carcols"]["kits"].values() for m in k["visibleMods"]}
    mod_models |= {x.lower() for k in metas["carcols"]["kits"].values() for m in k["visibleMods"] for x in m["linkedModels"]}
    if args.vehicle:
        names = [v.lower() for v in args.vehicle]
    else:
        names = [n for n in metas["vehicles"] if find_fragment(inv, n)]
        if not names:
            names = sorted({k[:-3] if k.endswith("_hi") else k for k in inv.yft_xml} - mod_models)
    if not names:
        print("Aucun véhicule trouvé (ni vehicles.meta, ni .yft). Contenu :\n"
              + json.dumps(inv.summary(), indent=2, ensure_ascii=False), file=sys.stderr)
        return 2

    game = None
    if not args.no_game_server:
        if args.game_server_url:
            os.environ["F2R_GAME_SERVER_URL"] = args.game_server_url
        try:
            game = gamelib.GameAssets.discover(report)
        except Exception as exc:  # noqa: BLE001
            report.info(f"Serveur d'assets GTA V indisponible ({exc}).")
        if game is None:
            game = gamelib.GameAssets.offline(report)

    results = []
    try:
        for n in names:
            report.info(f"=== Conversion de {n} ===")
            vout = out / n
            try:
                results.append(convert_one(n, inv, metas, vout, args, report, game))
            except SystemExit as exc:
                report.warn(f"{n} : {exc}")
            write_report(vout, n, results[-1] if results and results[-1]["name"] == n else None, report)
    finally:
        if game is not None:
            game.close()
    print(json.dumps({"vehicles": results, "warnings": report.warnings, "manual_steps": report.manual_steps},
                     indent=2, ensure_ascii=False))
    return 0 if results else 1


def write_report(out: Path, name: str, stats: dict | None, report: Report) -> None:
    out.mkdir(parents=True, exist_ok=True)
    lines = [f"# Conversion FiveM → Roblox : {name}", ""]
    if stats:
        lines += ["## Résultat", "",
                  f"- Pièces (MeshParts) : **{stats['parts']}** — triangles : **{stats['triangles']}**",
                  f"- Mods de custom : **{stats['mods']}** — livrées : **{stats['liveries']}**",
                  f"- Textures converties (≤ {stats.get('max_texture', 2048)} px) : **{stats['textures']}** — manquantes : {stats['missing_textures']}",
                  f"- Fichier 3D : `{Path(stats['glb']).name}` ({stats['glb_mb']} Mo)"]
        if stats.get("game_textures"):
            lines.append(f"- Dont **{stats['game_textures']}** texture(s) reprises du jeu de base "
                         "(vehshare / txdRelationships) via le serveur d'assets GTA V.")
        col = stats.get("collision") or {}
        if col.get("Source") == "gta":
            lines.append(f"- Hitbox : **collision officielle du véhicule** ({col['Pieces']} morceaux, "
                         f"{col['Triangles']} triangles, {len(col.get('Wheels') or {})} roues)")
        else:
            lines.append("- Hitbox : **boîte englobante** (pas de collision dans le .yft, ou --no-collision)")
        if stats.get("game_transfer"):
            lines.append(f"- Transfert depuis le serveur d'assets : {stats['game_transfer']}")
        lines.append("- Son moteur : **" + ("vrai son du jeu (AWC vanilla, découpé en boucles)"
                                            if stats.get("audio_from_game")
                                            else "son du pack, ou synthèse si absent") + "**")
        horn = stats.get("horn_source") or "synthese"
        lines.append("- Klaxon : **" + ("vrai son du jeu" if horn.startswith("jeu") else "synthétisé") + "**")
        if stats.get("siren_source"):
            sir = stats["siren_source"]
            lines.append("- Sirènes : **" + (("reprises du jeu (" + sir[4:] + ")")
                                             if sir.startswith("jeu:") else "synthétisées") + "**")
        lines.append("")
    lines += ["## Installation dans Roblox Studio", "",
              f"1. **Importer 3D** → `{name}.glb` (options par défaut).",
              "2. Uploader les sons de `sounds/` (Creator Hub ou `python scripts/roblox_upload.py`), "
              "puis relancer la conversion avec `--sound-ids sounds/sound_ids.json` "
              "(ou renseigner les SoundId à la main : attribut `SourceFile` sur chaque Sound).",
              "3. Sélectionner le modèle importé → **Modèle › Exécuter un script** → "
              f"`{name}_Setup.lua` (ou coller le fichier dans la barre de commande).",
              "4. Brancher ton moteur physique : lire `FiveMVehicles.VehicleInput.Controls` et "
              "appeler `FiveMVehicles.VehicleRuntime.SetTelemetry(car, {...})` (voir README).", ""]
    if report.manual_steps:
        lines += ["## Étapes manuelles", ""] + [f"- {m}" for m in report.manual_steps] + [""]
    if report.warnings:
        lines += ["## Avertissements", ""] + [f"- {w}" for w in report.warnings] + [""]
    lines += ["## Journal", ""] + [f"- {i}" for i in report.infos]
    (out / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
