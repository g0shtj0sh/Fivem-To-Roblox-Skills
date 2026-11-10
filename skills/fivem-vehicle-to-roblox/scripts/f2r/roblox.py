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
        "Server": (rt / "FiveMVehiclesServer.server.lua").read_text(encoding="utf-8"),
        "Client": (rt / "FiveMVehiclesClient.client.lua").read_text(encoding="utf-8"),
    }


def build_setup(config: dict, parts: dict, sound_ids: dict[str, str]) -> str:
    tpl = (RUNTIME_DIR / "Setup.template.lua").read_text(encoding="utf-8")
    srcs = runtime_sources()
    sources_lua = "{\n" + "".join(f"\t{k} = {long_string(v)},\n" for k, v in srcs.items()) + "}"
    config_source = "-- Généré par fivem-vehicle-to-roblox\nreturn " + to_lua(config)
    repl = {
        "__VEHICLE_NAME__": config["Name"],
        "__CONFIG_TABLE__": to_lua(config),
        "__CONFIG_SOURCE__": long_string(config_source),
        "__PARTS_TABLE__": to_lua(parts),
        "__SOUND_IDS__": to_lua(sound_ids or {}),
        "__RUNTIME_SOURCES__": sources_lua,
    }
    # remplacement en une passe pour ne jamais ré-interpréter le contenu injecté
    pattern = re.compile("|".join(re.escape(k) for k in repl))
    return pattern.sub(lambda m: repl[m.group(0)], tpl)
