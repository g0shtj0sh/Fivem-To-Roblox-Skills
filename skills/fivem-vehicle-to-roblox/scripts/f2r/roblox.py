"""Génération du script d'installation Luau (Setup) et du module VehicleConfig."""
from __future__ import annotations

import math
import re
from pathlib import Path

RUNTIME_DIR = Path(__file__).resolve().parents[2] / "roblox"

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_LUA_KEYWORDS = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
                 "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
                 "continue", "type", "export"}


def lua_string(s: str) -> str:
    s = str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\r", "")
    return f'"{s}"'


def long_string(s: str) -> str:
    level = 1
    while f"]{'=' * level}]" in s:
        level += 1
    eq = "=" * level
    return f"[{eq}[\n{s}]{eq}]"


def to_lua(v, indent: int = 0) -> str:
    pad = "\t" * (indent + 1)
    end = "\t" * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if math.isnan(v) or math.isinf(v):
            return "0"
        r = round(v, 5)
        return str(int(r)) if r == int(r) and abs(r) < 1e15 else repr(r)
    if isinstance(v, str):
        return lua_string(v)
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        if all(isinstance(x, (int, float, bool)) for x in v) and len(v) <= 16:
            return "{ " + ", ".join(to_lua(x) for x in v) + " }"
        return "{\n" + "".join(f"{pad}{to_lua(x, indent + 1)},\n" for x in v) + end + "}"
    if isinstance(v, dict):
        items = [(k, x) for k, x in v.items() if x is not None]
        if not items:
            return "{}"
        out = []
        for k, x in items:
            if isinstance(k, int):
                key = f"[{k}]"
            elif _IDENT.match(str(k)) and str(k) not in _LUA_KEYWORDS:
                key = str(k)
            else:
                key = f"[{lua_string(k)}]"
            out.append(f"{pad}{key} = {to_lua(x, indent + 1)},\n")
        return "{\n" + "".join(out) + end + "}"
    return lua_string(str(v))


def runtime_sources() -> dict[str, str]:
    rt = RUNTIME_DIR / "runtime"
    return {
        "VehicleRuntime": (rt / "VehicleRuntime.lua").read_text(encoding="utf-8"),
        "VehicleCustomization": (rt / "VehicleCustomization.lua").read_text(encoding="utf-8"),
        "VehicleInput": (rt / "VehicleInput.lua").read_text(encoding="utf-8"),
        "VehicleAccess": (rt / "VehicleAccess.lua").read_text(encoding="utf-8"),
        "VehicleDynamics": (rt / "VehicleDynamics.lua").read_text(encoding="utf-8"),
        "VehicleDrive": (rt / "VehicleDrive.lua").read_text(encoding="utf-8"),
        "VehicleSeatFit": (rt / "VehicleSeatFit.lua").read_text(encoding="utf-8"),
        "VehicleLights": (rt / "VehicleLights.lua").read_text(encoding="utf-8"),
        "VehicleCollision": (rt / "VehicleCollision.lua").read_text(encoding="utf-8"),
        "VehicleDashboard": (rt / "VehicleDashboard.lua").read_text(encoding="utf-8"),
        "VehiclePose": (rt / "VehiclePose.lua").read_text(encoding="utf-8"),
        "VehicleCamera": (rt / "VehicleCamera.lua").read_text(encoding="utf-8"),
        "Server": (rt / "FiveMVehiclesServer.server.lua").read_text(encoding="utf-8"),
        "Client": (rt / "FiveMVehiclesClient.client.lua").read_text(encoding="utf-8"),
    }


def runtime_version() -> str:
    """Empreinte courte des sources runtime : le Setup « studio/ » vérifie qu'elles sont installées."""
    import hashlib
    h = hashlib.sha256()
    for k, v in sorted(runtime_sources().items()):
        h.update(k.encode() + b"\0" + v.encode("utf-8"))
    return h.hexdigest()[:12]


def build_setup(config: dict, parts: dict, sound_ids: dict[str, str], *,
                include_runtime: bool = True, include_config_source: bool = True) -> str:
    """Setup complet (Modèle › Exécuter un script) ; variante compacte pour execute_luau avec
    include_runtime=False (runtime posé par build_runtime_install) et include_config_source=False
    (VehicleConfig sérialisé dans Studio depuis CONFIG)."""
    tpl = (RUNTIME_DIR / "Setup.template.lua").read_text(encoding="utf-8")
    srcs = runtime_sources()
    sources_lua = ("{\n" + "".join(f"\t{k} = {long_string(v)},\n" for k, v in srcs.items()) + "}"
                   if include_runtime else "nil")
    config_source = "-- Généré par fivem-vehicle-to-roblox\nreturn " + to_lua(config)
    repl = {
        "__VEHICLE_NAME__": config["Name"],
        "__CONFIG_TABLE__": to_lua(config),
        "__CONFIG_SOURCE__": long_string(config_source) if include_config_source else "nil",
        "__PARTS_TABLE__": to_lua(parts),
        "__SOUND_IDS__": to_lua(sound_ids or {}),
        "__RUNTIME_SOURCES__": sources_lua,
        "__RUNTIME_VERSION__": lua_string(runtime_version()),
    }
    # remplacement en une passe pour ne jamais ré-interpréter le contenu injecté
    pattern = re.compile("|".join(re.escape(k) for k in repl))
    return pattern.sub(lambda m: repl[m.group(0)], tpl)


def build_runtime_install() -> str:
    """Installe / met à jour les modules runtime seuls (une fois par place)."""
    srcs = runtime_sources()
    body = "{\n" + "".join(f"\t{k} = {long_string(v)},\n" for k, v in srcs.items()) + "}"
    return (RUNTIME_DIR / "RuntimeInstall.template.lua").read_text(encoding="utf-8") \
        .replace("__RUNTIME_VERSION__", lua_string(runtime_version())) \
        .replace("__RUNTIME_SOURCES__", body)


def split_for_execute_luau(source: str, key: str, max_bytes: int = 20000) -> list[str]:
    """Découpe un gros script en appels execute_luau : chaque morceau s'ajoute à
    _G.F2R_BUF[key] ; le dernier l'assemble et l'exécute avec loadstring, et renvoie
    son résultat. Coupé sur des fins de ligne (jamais au milieu d'un caractère UTF-8)."""
    lines = source.splitlines(keepends=True)
    chunks, cur, size = [], [], 0
    for ln in lines:
        b = len(ln.encode("utf-8"))
        if cur and size + b > max_bytes:
            chunks.append("".join(cur))
            cur, size = [], 0
        cur.append(ln)
        size += b
    if cur:
        chunks.append("".join(cur))
    out = []
    n = len(chunks)
    for i, c in enumerate(chunks, 1):
        head = ("_G.F2R_BUF = _G.F2R_BUF or {}\n"
                + (f"_G.F2R_BUF[{lua_string(key)}] = {{}}\n" if i == 1 else "")
                + f"table.insert(_G.F2R_BUF[{lua_string(key)}], {long_string(c)})\n")
        if i < n:
            out.append(head + f"return \"{key} {i}/{n}\"\n")
        else:
            out.append(head + f"local src = table.concat(_G.F2R_BUF[{lua_string(key)}])\n"
                       f"_G.F2R_BUF[{lua_string(key)}] = nil\n"
                       f"local fn, err = loadstring(src, {lua_string('=' + key)})\n"
                       "assert(fn, err)\nreturn fn()\n")
    return out
