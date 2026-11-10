"""Détection automatique d'une installation GTA V (Enhanced ou Legacy).

Ordre : fichier de config déjà enregistré, variable GTAV_FOLDER, registre Rockstar,
bibliothèques Steam, manifestes Epic, puis chemins usuels.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path

CONFIG = Path.home() / ".fivem2roblox" / "gta-server.json"

# Un dossier GTA V valide contient l'exécutable ET les archives de base.
EXES = {"GTA5_Enhanced.exe": True, "GTA5.exe": False}   # -> gen9 ?


def is_game_folder(p: Path) -> bool:
    try:
        if not (p / "x64a.rpf").is_file():
            return False
        return any((p / e).is_file() for e in EXES)
    except OSError:
        return False


def is_gen9(p: Path) -> bool:
    return (p / "GTA5_Enhanced.exe").is_file()


# ------------------------------------------------------------------ sources

def _from_config() -> list[Path]:
    try:
        d = json.loads(CONFIG.read_text(encoding="utf-8"))
        v = d.get("game_folder")
        return [Path(v)] if v else []
    except Exception:
        return []


def _from_env() -> list[Path]:
    v = os.environ.get("GTAV_FOLDER")
    return [Path(v)] if v else []


def _from_registry() -> list[Path]:
    out: list[Path] = []
    if os.name != "nt":
        return out
    try:
        import winreg
    except ImportError:
        return out
    keys = [
        r"SOFTWARE\WOW6432Node\Rockstar Games\Grand Theft Auto V Enhanced",
        r"SOFTWARE\WOW6432Node\Rockstar Games\Grand Theft Auto V",
        r"SOFTWARE\Rockstar Games\Grand Theft Auto V Enhanced",
        r"SOFTWARE\Rockstar Games\Grand Theft Auto V",
        r"SOFTWARE\WOW6432Node\Rockstar Games\GTAV",
    ]
    for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
        for key in keys:
            for value in ("InstallFolder", "InstallFolderEnhanced", "InstallLocation"):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        v, _ = winreg.QueryValueEx(k, value)
                    if v:
                        out.append(Path(v))
                except OSError:
                    continue
    return out


def _steam_libraries() -> list[Path]:
    libs: list[Path] = []
    roots = []
    if os.name == "nt":
        try:
            import winreg
            for hive, key in ((winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam"),
                              (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Valve\Steam")):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        v, _ = winreg.QueryValueEx(k, "InstallPath")
                    roots.append(Path(v))
                except OSError:
                    continue
        except ImportError:
            pass
        roots += [Path(r"C:\Program Files (x86)\Steam")]
    else:
        roots += [Path.home() / ".steam/steam", Path.home() / ".local/share/Steam"]
    for root in roots:
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if not vdf.is_file():
            continue
        try:
            text = vdf.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in re.finditer(r'"path"\s+"([^"]+)"', text):
            libs.append(Path(m.group(1).replace("\\\\", "\\")))
        libs.append(root)
    return [lib / "steamapps" / "common" / "Grand Theft Auto V" for lib in libs] + \
           [lib / "steamapps" / "common" / "Grand Theft Auto V Enhanced" for lib in libs]


def _epic_manifests() -> list[Path]:
    out: list[Path] = []
    d = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "Epic" / "EpicGamesLauncher" / "Data" / "Manifests"
    if not d.is_dir():
        return out
    for item in d.glob("*.item"):
        try:
            man = json.loads(item.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            continue
        name = (man.get("DisplayName") or "") + " " + (man.get("AppName") or "")
        if "grand theft auto" in name.lower() or "gta" in name.lower():
            loc = man.get("InstallLocation")
            if loc:
                out.append(Path(loc))
    return out


def _common_paths() -> list[Path]:
    names = ["Grand Theft Auto V Enhanced", "Grand Theft Auto V", "GTAV"]
    bases = []
    for drive in "CDEFGHW":
        root = Path(f"{drive}:\\")
        if not root.exists():
            continue
        bases += [root / "Program Files" / "Rockstar Games", root / "Rockstar Games",
                  root / "Games" / "Rockstar Games", root / "Jeux" / "Rockstar Games",
                  root / "Program Files (x86)" / "Rockstar Games"]
    return [b / n for b in bases for n in names]


# -------------------------------------------------------------------- API

def candidates() -> list[Path]:
    seen: set[str] = set()
    out: list[Path] = []
    for src in (_from_config, _from_env, _from_registry, _steam_libraries, _epic_manifests, _common_paths):
        for p in src():
            key = str(p).rstrip("\\/").lower()
            if key in seen:
                continue
            seen.add(key)
            out.append(p)
    return out


def detect() -> tuple[Path | None, bool]:
    """Renvoie (dossier, gen9) ou (None, False). L'édition Enhanced est préférée."""
    found = [p for p in candidates() if is_game_folder(p)]
    if not found:
        return None, False
    found.sort(key=lambda p: 0 if is_gen9(p) else 1)
    return found[0], is_gen9(found[0])


def save(folder: Path, gen9: bool) -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps({"game_folder": str(folder), "gen9": gen9}, indent=2),
                      encoding="utf-8")


if __name__ == "__main__":
    f, g = detect()
    if f:
        print(f"GTA V trouvé : {f}  (gen9/Enhanced={g})")
    else:
        print("GTA V introuvable. Candidats testés :")
        for c in candidates():
            print("  -", c)
