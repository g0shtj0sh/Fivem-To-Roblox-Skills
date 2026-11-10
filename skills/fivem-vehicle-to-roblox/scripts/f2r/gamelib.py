"""gamelib — récupère dans l'installation GTA V de l'utilisateur (sur son PC) les
ressources du *jeu de base* absentes du pack : textures partagées (vehshare,
txdRelationships, vehicle_generic_*) et son vanilla d'un audioNameHash.

Architecture
------------
Le pipeline tourne dans la VM Linux (vibestarter) ; GTA V est sur le PC Windows.
La VM ne peut joindre le PC que par la passerelle de vibestarter, donc le PC
expose un petit serveur MCP sur 127.0.0.1 (tools/gta-asset-server) et ce module
le consomme :

  1. ``F2R_GAME_SERVER_URL`` défini  -> HTTP direct (tests, ou port redirigé) ;
  2. sinon, un connecteur MCP de vibestarter, lancé par nous-mêmes
     (``node ~/.vibestarter/mcp-stub.cjs``) : on n'a donc PAS besoin que l'agent
     ait le serveur dans son contexte. Marche pour Claude, Codex, ou un script.

Si rien n'est joignable, ``discover()`` renvoie ``None`` et le pipeline garde son
comportement actuel (couleur unie / son synthétisé) avec un message clair.

Les fichiers reçus sont vérifiés par SHA-256 et mis en cache dans
``~/.cache/fivem2roblox/`` (ou ``$F2R_CACHE_DIR``).
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

from .util import Report

MARKER_TOOL = "gta_prepare_textures"      # outil qui identifie notre serveur
# Version du schema du cache audio : a incrementer quand les noms de fichiers
# renvoyes par le serveur changent, pour invalider les anciens caches.
AUDIO_CACHE_VERSION = "v2"
CALL_TIMEOUT = float(os.environ.get("F2R_GAME_TIMEOUT") or 240)
PROTOCOL_VERSION = "2025-06-18"


class GameLibError(RuntimeError):
    pass


# --------------------------------------------------------------- transports

class _Transport:
    def request(self, body: dict) -> dict | None:
        raise NotImplementedError

    def close(self) -> None:
        pass

    @property
    def label(self) -> str:
        return "?"


class HttpTransport(_Transport):
    """Serveur MCP joignable directement en HTTP (tests, port redirigé)."""

    def __init__(self, url: str):
        self.url = url

    @property
    def label(self) -> str:
        return f"http {self.url}"

    def request(self, body: dict) -> dict | None:
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(self.url, data=data, headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        })
        with urllib.request.urlopen(req, timeout=CALL_TIMEOUT) as r:
            raw = r.read()
        if not raw:
            return None
        return json.loads(raw)


class StdioTransport(_Transport):
    """Serveur MCP parlé en JSON-RPC sur stdin/stdout (le stub vibestarter)."""

    def __init__(self, name: str, command: str, args: list[str], env: dict[str, str] | None):
        self.name = name
        self.command = command
        self.args = list(args or [])
        self.env = dict(os.environ)
        if env:
            self.env.update({k: str(v) for k, v in env.items()})
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()

    @property
    def label(self) -> str:
        return f"mcp:{self.name}"

    def _ensure(self) -> subprocess.Popen:
        if self._proc is not None and self._proc.poll() is None:
            return self._proc
        self._proc = subprocess.Popen(
            [self.command, *self.args], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", errors="replace", bufsize=1,
            env=self.env,
        )
        return self._proc

    def request(self, body: dict) -> dict | None:
        with self._lock:
            p = self._ensure()
            try:
                p.stdin.write(json.dumps(body) + "\n")
                p.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                raise GameLibError(f"{self.label} : écriture impossible ({exc})") from exc
            if "id" not in body:
                return None                       # notification : pas de réponse
            deadline = time.time() + CALL_TIMEOUT
            while time.time() < deadline:
                line = p.stdout.readline()
                if not line:
                    raise GameLibError(f"{self.label} : le serveur s'est arrêté")
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(msg, dict) and msg.get("id") == body["id"]:
                    return msg
                # messages de service (logs, notifications) : ignorés
            raise GameLibError(f"{self.label} : délai dépassé ({CALL_TIMEOUT:.0f} s)")

    def close(self) -> None:
        p, self._proc = self._proc, None
        if p is None or p.poll() is not None:
            return
        try:
            p.stdin.close()
            p.wait(timeout=5)
        except Exception:
            p.kill()


# ------------------------------------------------------------- client MCP

class McpClient:
    def __init__(self, transport: _Transport):
        self.t = transport
        self._id = 0
        self._initialised = False

    @property
    def label(self) -> str:
        return self.t.label

    def _next(self) -> int:
        self._id += 1
        return self._id

    def _rpc(self, method: str, params: dict | None = None) -> dict:
        body = {"jsonrpc": "2.0", "id": self._next(), "method": method}
        if params is not None:
            body["params"] = params
        resp = self.t.request(body)
        if resp is None:
            raise GameLibError(f"{self.label} : réponse vide pour {method}")
        if "error" in resp:
            err = resp["error"]
            raise GameLibError(f"{self.label} : {method} -> {err.get('message')}")
        return resp.get("result") or {}

    def _notify(self, method: str, params: dict | None = None) -> None:
        body = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            body["params"] = params
        try:
            self.t.request(body)
        except Exception:
            pass

    def initialize(self) -> dict:
        if self._initialised:
            return {}
        r = self._rpc("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "fivem-vehicle-to-roblox", "version": "1.0"},
        })
        self._notify("notifications/initialized", {})
        self._initialised = True
        return r

    def tool_names(self) -> set[str]:
        return {t.get("name") for t in (self._rpc("tools/list").get("tools") or [])}

    def call(self, name: str, **arguments):
        r = self._rpc("tools/call", {"name": name, "arguments": arguments})
        if r.get("isError"):
            texts = [c.get("text", "") for c in (r.get("content") or [])]
            raise GameLibError(f"{name} : " + " ".join(texts)[:400])
        for c in r.get("content") or []:
            if c.get("type") == "text":
                try:
                    return json.loads(c["text"])
                except json.JSONDecodeError:
                    return {"text": c["text"]}
        return {}

    def close(self) -> None:
        self.t.close()


# ------------------------------------------------- découverte des connecteurs

def _walk_mcp_servers(obj, out: dict):
    """Cherche récursivement toutes les sections « mcpServers » d'un JSON."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("mcpServers", "mcp_servers") and isinstance(v, dict):
                for name, cfg in v.items():
                    if isinstance(cfg, dict) and name not in out:
                        out[name] = cfg
            else:
                _walk_mcp_servers(v, out)
    elif isinstance(obj, list):
        for v in obj:
            _walk_mcp_servers(v, out)


def _from_claude_json() -> dict:
    out: dict = {}
    for p in (Path.home() / ".claude.json", Path.home() / ".claude" / "settings.json"):
        try:
            _walk_mcp_servers(json.loads(p.read_text(encoding="utf-8")), out)
        except Exception:
            continue
    return out


def _from_codex_toml() -> dict:
    p = Path.home() / ".codex" / "config.toml"
    try:
        text = p.read_text(encoding="utf-8")
    except Exception:
        return {}
    try:
        import tomllib
        data = tomllib.loads(text)
        servers = data.get("mcp_servers") or data.get("mcpServers") or {}
        return {k: v for k, v in servers.items() if isinstance(v, dict)}
    except Exception:
        pass
    # Repli minimal sans tomllib : [mcp_servers.<nom>] command/args/env
    out: dict = {}
    cur = None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r"^\[mcp_servers\.([^\]\.]+)\]$", line)
        if m:
            cur = {}
            out[m.group(1)] = cur
            continue
        m = re.match(r"^\[mcp_servers\.([^\]\.]+)\.env\]$", line)
        if m:
            cur = out.setdefault(m.group(1), {}).setdefault("env", {})
            continue
        if cur is None or "=" not in line or line.startswith("#"):
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        try:
            cur[k] = json.loads(v)
        except Exception:
            cur[k] = v.strip('"')
    return out


def _candidate_transports(report: Report) -> list[_Transport]:
    out: list[_Transport] = []
    url = os.environ.get("F2R_GAME_SERVER_URL")
    if url:
        out.append(HttpTransport(url))
    servers = {**_from_claude_json(), **_from_codex_toml()}
    preferred = (os.environ.get("F2R_GAME_CONNECTOR") or "").lower()

    def score(item):
        name = item[0].lower()
        if preferred and preferred in name:
            return 0
        return 1 if ("gta" in name or "asset" in name) else 2

    for name, cfg in sorted(servers.items(), key=score):
        if cfg.get("type") in ("http", "sse") or cfg.get("url"):
            u = cfg.get("url")
            if u:
                out.append(HttpTransport(u))
            continue
        cmd = cfg.get("command")
        if not cmd:
            continue
        out.append(StdioTransport(name, cmd, cfg.get("args") or [], cfg.get("env")))
    return out


# -------------------------------------------------------------------- cache

def cache_root() -> Path:
    """Racine du cache. Lue a chaque appel pour rester testable (F2R_CACHE_DIR)."""
    return Path(os.environ.get("F2R_CACHE_DIR") or (Path.home() / ".cache" / "fivem2roblox"))


def _cache_dir(kind: str) -> Path:
    d = cache_root() / kind
    d.mkdir(parents=True, exist_ok=True)
    return d


def _read_json(p: Path, default):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return default


# ---------------------------------------------------------------- GameAssets

class GameAssets:
    """Accès aux ressources du jeu de base, via le serveur d'assets du PC."""

    def __init__(self, client: McpClient, report: Report):
        self.client = client
        self.report = report
        self.server_status: dict = {}
        self._neg_file = cache_root() / "missing_textures.json"
        self._neg_tex: set[str] = set(_read_json(self._neg_file, []))
        # Mesures du transfert PC -> VM (rapportées dans report.md).
        self.stats: dict[str, dict] = {
            k: {"prepare_s": 0.0, "download_s": 0.0, "files": 0, "chunks": 0, "bytes": 0, "cached": 0}
            for k in ("textures", "audio")}

    # -- cycle de vie -------------------------------------------------------

    @classmethod
    def discover(cls, report: Report, *, quiet: bool = False) -> "GameAssets | None":
        """Essaie chaque transport ; renvoie None si aucun serveur d'assets."""
        if os.environ.get("F2R_NO_GAME_SERVER"):
            return None
        tried: list[str] = []
        for t in _candidate_transports(report):
            client = McpClient(t)
            try:
                client.initialize()
                names = client.tool_names()
            except Exception as exc:                            # noqa: BLE001
                tried.append(f"{t.label} ({type(exc).__name__})")
                client.close()
                continue
            if MARKER_TOOL not in names:
                tried.append(f"{t.label} (outil {MARKER_TOOL} absent)")
                client.close()
                continue
            inst = cls(client, report)
            try:
                inst.server_status = client.call("gta_status")
            except Exception:
                inst.server_status = {}
            report.info(f"Serveur d'assets GTA V trouvé via {t.label} — "
                        f"jeu : {inst.server_status.get('game_folder', '?')}")
            return inst
        if tried and not quiet:
            report.info("Aucun serveur d'assets GTA V joignable (" + " ; ".join(tried[:4]) + ").")
        return None

    def close(self) -> None:
        self.client.close()
        try:
            self._neg_file.parent.mkdir(parents=True, exist_ok=True)
            self._neg_file.write_text(json.dumps(sorted(self._neg_tex)), encoding="utf-8")
        except Exception:
            pass

    # -- transfert ----------------------------------------------------------

    def transfer_summary(self) -> str:
        """Une ligne lisible : durée et volume transférés par catégorie."""
        parts = []
        for kind, st in self.stats.items():
            if not (st["files"] or st["cached"] or st["prepare_s"]):
                continue
            mb = st["bytes"] / 1e6
            dl = st["download_s"]
            rate = f", {mb / dl:.2f} Mo/s" if dl > 0 and mb > 0 else ""
            parts.append(f"{kind} : {st['files']} fichier(s), {mb:.2f} Mo en {st['chunks']} morceau(x), "
                         f"préparation PC {st['prepare_s']:.1f} s + transfert {dl:.1f} s{rate}"
                         + (f", {st['cached']} déjà en cache" if st["cached"] else ""))
        return " ; ".join(parts) or "aucun transfert"

    def _download(self, manifest: dict, entry: dict, dest: Path, kind: str = "textures") -> Path | None:
        """Récupère un fichier du lot morceau par morceau et vérifie son SHA-256."""
        st = self.stats[kind]
        t0 = time.monotonic()
        tmp = dest.with_suffix(dest.suffix + ".part")
        h = hashlib.sha256()
        got = 0
        try:
            with open(tmp, "wb") as f:
                for i in range(entry["chunks"]):
                    c = self.client.call("gta_chunk", bundle=manifest["bundle"],
                                         file=entry["file"], index=i)
                    blob = base64.b64decode(c["data"])
                    st["chunks"] += 1
                    st["bytes"] += len(blob)
                    f.write(blob)
                    h.update(blob)
                    got += len(blob)
        except Exception as exc:                                # noqa: BLE001
            tmp.unlink(missing_ok=True)
            st["download_s"] += time.monotonic() - t0
            self.report.warn(f"Transfert de {entry['file']} interrompu : {exc}")
            return None
        st["download_s"] += time.monotonic() - t0
        if got != entry["bytes"] or h.hexdigest() != entry["sha256"]:
            tmp.unlink(missing_ok=True)
            self.report.warn(f"Contrôle d'intégrité échoué pour {entry['file']} "
                             f"({got} octets reçus sur {entry['bytes']}) : fichier ignoré.")
            return None
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp.replace(dest)
        st["files"] += 1
        return dest

    # -- textures -----------------------------------------------------------

    def fetch_textures(self, names, *, vehicle: str = "", txds=None,
                       max_size: int = 1024, retry: bool = False) -> dict[str, Path]:
        """Renvoie {nom de texture: PNG local} pour celles trouvées dans le jeu."""
        wanted = sorted({n.lower() for n in names if n and n.strip()})
        if not wanted:
            return {}
        cdir = _cache_dir(f"textures/{max_size}")
        out: dict[str, Path] = {}
        todo: list[str] = []
        for n in wanted:
            p = cdir / f"{n}.png"
            if p.is_file():
                out[n] = p
                self.stats["textures"]["cached"] += 1
            elif n in self._neg_tex and not retry:
                continue                     # déjà connue comme absente du jeu
            else:
                todo.append(n)
        if not todo:
            return out

        t0 = time.monotonic()
        try:
            man = self.client.call("gta_prepare_textures", names=todo, vehicle=vehicle or "",
                                   txds=list(txds or []), max_size=max_size)
        except Exception as exc:                                # noqa: BLE001
            self.stats["textures"]["prepare_s"] += time.monotonic() - t0
            self.report.warn(f"Textures du jeu de base indisponibles : {exc}")
            return out

        self.stats["textures"]["prepare_s"] += time.monotonic() - t0
        by_file = {f["file"]: f for f in man.get("files") or []}
        for entry in by_file.values():
            name = entry.get("name") or Path(entry["file"]).stem
            dest = cdir / f"{name}.png"
            if self._download(man, entry, dest, "textures") is not None:
                out[name] = dest
                self._neg_tex.discard(name)
        for miss in man.get("missing") or []:
            self._neg_tex.add(str(miss).lower())
        for bad in man.get("failed") or []:
            self.report.warn(f"Texture {bad.get('name')} illisible côté PC : {bad.get('error')}")
        return out

    # -- audio --------------------------------------------------------------

    def fetch_audio(self, audio_name: str, *, retry: bool = False) -> dict[str, Path]:
        """Renvoie {nom de flux: wav local} pour le son vanilla du véhicule."""
        audio_name = (audio_name or "").strip()
        if not audio_name:
            return {}
        cdir = _cache_dir(f"audio/{AUDIO_CACHE_VERSION}/{audio_name.lower()}")
        done = cdir / ".complete"
        if done.is_file() and not retry:
            cached = {p.stem: p for p in sorted(cdir.glob("*.wav"))}
            self.stats["audio"]["cached"] += len(cached)
            return cached

        t0 = time.monotonic()
        try:
            man = self.client.call("gta_prepare_audio", audio_name=audio_name)
        except Exception as exc:                                # noqa: BLE001
            self.stats["audio"]["prepare_s"] += time.monotonic() - t0
            self.report.warn(f"Son vanilla « {audio_name} » indisponible : {exc}")
            return {}
        self.stats["audio"]["prepare_s"] += time.monotonic() - t0
        if man.get("status") != "ok":
            self.report.info(f"Le jeu ne définit pas de son pour « {audio_name} » "
                             f"({man.get('error') or man.get('status')}).")
            return {}

        out: dict[str, Path] = {}
        for entry in man.get("files") or []:
            name = entry.get("name") or Path(entry["file"]).stem
            dest = cdir / f"{name}.wav"
            if dest.is_file() and not retry:
                out[name] = dest
                continue
            if self._download(man, entry, dest, "audio") is not None:
                out[name] = dest
        if out:
            done.write_text(time.strftime("%Y-%m-%d %H:%M:%S"), encoding="utf-8")
        return out


# ------------------------------------------------------------------- helpers

def collect_missing_textures(parts, store) -> list[str]:
    """Noms de textures référencés par le modèle et absents des sources locales."""
    missing: list[str] = []
    seen: set[str] = set()
    for p in parts:
        cands = [p.tex_diffuse, p.tex_normal, *(p.tex_livery or [])]
        for name in cands:
            if not name:
                continue
            n = name.lower()
            if n in seen:
                continue
            seen.add(n)
            if store.find(n) is None:
                missing.append(n)
    return missing
