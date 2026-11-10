"""Serveur d'assets GTA V â€” cÃ´tÃ© PC, pour le skill fivem-vehicle-to-roblox.

Il expose les ressources du *jeu de base* (textures partagÃ©es, sons de vÃ©hicule)
que les packs FiveM rÃ©utilisent sans les inclure, sous forme d'un **serveur MCP
HTTP** Ã©coutant uniquement sur 127.0.0.1.

Pourquoi MCP : la VM vibestarter ne peut joindre le PC que par la passerelle de
vibestarter (gvproxy n'autorise que ses deux ports). DÃ©clarer ce serveur dans
Â« My MCP servers Â» est donc le seul canal fiable, et il survit aux redÃ©marrages.
Voir docs/transport-tests.md.

Outils exposÃ©s :
    gta_status              Ã©tat du serveur et du jeu dÃ©tectÃ©
    gta_find_textures       quelles textures existent (sans transfert)
    gta_prepare_textures    convertit en PNG <= 1024 px et prÃ©pare un lot
    gta_prepare_audio       extrait le son vanilla d'un audioNameHash
    gta_chunk               rÃ©cupÃ¨re un morceau d'un fichier du lot (base64)
    gta_build_index         construit l'index complet des textures vÃ©hicules

SÃ©curitÃ© : Ã©coute sur 127.0.0.1 seulement ; ne sert que des textures de
dictionnaires de vÃ©hicules et des sons rÃ©fÃ©rencÃ©s par un audioNameHash de
vÃ©hicule ; aucun accÃ¨s Ã  un chemin arbitraire ; GTA V est ouvert en lecture seule.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import sys
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent.parent                     # skills/fivem-vehicle-to-roblox
sys.path.insert(0, str(SKILL / "scripts"))     # pour rÃ©utiliser f2r.textures

import gta_locate                               # noqa: E402
from gta_client import GtaClient, GtaExtractError  # noqa: E402

PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
SERVER_NAME = "gta-asset-server"
SERVER_VERSION = "1.0.0"

# La passerelle vibestarter plafonne un message MCP Ã  ~33 Mo. On reste large :
# 6 Mo de donnÃ©es brutes -> ~8 Mo en base64.
CHUNK_BYTES = 6 * 1024 * 1024

CACHE_ROOT = Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "fivem2roblox" / "asset-server"
BUNDLES = CACHE_ROOT / "bundles"

# Flux moteur / Ã©chappement utiles au pipeline Roblox : audio.py les reconnaÃ®t
# par leur nom (pick_stream) et y dÃ©coupe les boucles par rÃ©gime.
ENGINE_STREAMS = ("engine_accel", "engine_decel", "engine_idle",
                  "exhaust_accel", "exhaust_decel", "exhaust_idle")

# DurÃ©es plausibles, par rÃ´le : Ã©carte un flux manifestement inadaptÃ© (un
# Â« klaxon Â» de 20 ms ou une Â« sirÃ¨ne Â» de 50 ms viennent d'une mauvaise
# rÃ©solution, mieux vaut la synthÃ¨se).
DURATION_BOUNDS = {"horn": (0.08, 5.0), "siren": (0.2, 20.0), "engine": (0.1, 40.0)}


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# --------------------------------------------------------------------- lots

def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def _bundle_dir(kind: str, key: str) -> Path:
    bid = kind + "-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
    return BUNDLES / bid


def _manifest(bundle: Path, entries: list[dict], extra: dict | None = None) -> dict:
    files = []
    for e in entries:
        p = bundle / e["file"]
        if not p.is_file():
            continue
        size = p.stat().st_size
        files.append({**e, "bytes": size, "sha256": _sha256(p),
                      "chunks": max(1, -(-size // CHUNK_BYTES))})
    man = {"bundle": bundle.name, "chunk_bytes": CHUNK_BYTES, "files": files}
    if extra:
        man.update(extra)
    (bundle / "manifest.json").write_text(json.dumps(man, indent=2), encoding="utf-8")
    return man


# ------------------------------------------------------------------ service

class AssetService:
    def __init__(self, game: Path, gen9: bool, exe: Path):
        self.game = game
        self.gen9 = gen9
        self.client = GtaClient(exe, game, gen9, log=log)
        self._lock = threading.Lock()
        BUNDLES.mkdir(parents=True, exist_ok=True)

    # -- textures -----------------------------------------------------------

    def status(self) -> dict:
        out = {"game_folder": str(self.game), "gen9": self.gen9,
               "chunk_bytes": CHUNK_BYTES, "ready": bool(self.client.ready)}
        out.update({k: v for k, v in (self.client.ready or {}).items() if k != "event"})
        out["texture_index_built"] = self.client.index_built
        return out

    def find_textures(self, names: list[str], vehicle: str | None, txds: list[str] | None) -> dict:
        hints = {"vehicle": vehicle or "", "txds": txds or []}
        return self.client.find_textures(names, hints)

    def prepare_textures(self, names: list[str], vehicle: str | None,
                         txds: list[str] | None, max_size: int) -> dict:
        from f2r.textures import resize_for_roblox       # mÃªme code que la VM

        names = [n.lower() for n in names if n and n.strip()]
        key = json.dumps([sorted(set(names)), vehicle, sorted(txds or []), max_size])
        bundle = _bundle_dir("tex", key)
        with self._lock:
            cached = bundle / "manifest.json"
            if cached.is_file():
                try:
                    return json.loads(cached.read_text(encoding="utf-8"))
                except Exception:
                    shutil.rmtree(bundle, ignore_errors=True)
            raw = bundle / "_dds"
            raw.mkdir(parents=True, exist_ok=True)
            hints = {"vehicle": vehicle or "", "txds": txds or []}
            r = self.client.extract_textures(names, raw, hints)

            from PIL import Image
            entries, failed, retry = [], [], []

            def store_png(name: str, img, info: dict) -> None:
                # On garde la RGBA brute (pas de conversion normale/couleur ici) :
                # c'est le pipeline de la VM qui dÃ©cide du rÃ´le de chaque texture.
                img = resize_for_roblox(img.convert("RGBA"), max_size)
                out = bundle / (name.lower() + ".png")
                img.save(out, "PNG", optimize=True)
                entries.append({"name": name.lower(), "file": out.name,
                                "source_ytd": info.get("ytd"),
                                "source": f"{info.get('width')}x{info.get('height')} {info.get('format')}"})

            for name, info in (r.get("found") or {}).items():
                try:
                    img = Image.open(Path(info["dds"]))
                    img.load()
                except Exception as exc:               # noqa: BLE001
                    # Pillow ne gÃ¨re pas tous les formats GTA (A8, L8, BC7...) :
                    # on redemande les pixels dÃ©jÃ  dÃ©compressÃ©s Ã  CodeWalker.
                    retry.append((name, f"{type(exc).__name__}: {exc}"))
                    continue
                try:
                    store_png(name, img, info)
                except Exception as exc:               # noqa: BLE001
                    failed.append({"name": name, "error": f"{type(exc).__name__}: {exc}"})

            if retry:
                rawdir = bundle / "_bgra"
                rawdir.mkdir(parents=True, exist_ok=True)
                try:
                    d = self.client.decode_textures([n for n, _ in retry], rawdir, hints)
                except Exception as exc:               # noqa: BLE001
                    d = {"found": {}}
                    log("[gta] decode_textures indisponible :", exc)
                for name, why in retry:
                    info = (d.get("found") or {}).get(name) or {}
                    blob = info.get("bgra")
                    if not blob or not Path(blob).is_file():
                        failed.append({"name": name, "error": why + " ; dÃ©codage direct : "
                                       + str(info.get("error") or "indisponible")})
                        continue
                    try:
                        data = Path(blob).read_bytes()
                        w, h = int(info["width"]), int(info["height"])
                        img = Image.frombuffer("RGBA", (w, h), data, "raw", "BGRA", 0, 1)
                        store_png(name, img, info)
                    except Exception as exc:           # noqa: BLE001
                        failed.append({"name": name, "error": f"{type(exc).__name__}: {exc}"})
                shutil.rmtree(rawdir, ignore_errors=True)

            shutil.rmtree(raw, ignore_errors=True)
            return _manifest(bundle, entries,
                             {"kind": "textures", "missing": r.get("missing") or [],
                              "failed": failed, "max_size": max_size})

    # -- audio --------------------------------------------------------------

    def prepare_audio(self, audio_name: str) -> dict:
        audio_name = (audio_name or "").strip()
        if not audio_name:
            raise ValueError("audio_name vide")
        bundle = _bundle_dir("aud", audio_name.lower())
        with self._lock:
            cached = bundle / "manifest.json"
            if cached.is_file():
                try:
                    return json.loads(cached.read_text(encoding="utf-8"))
                except Exception:
                    shutil.rmtree(bundle, ignore_errors=True)
            raw = bundle / "_awc"
            raw.mkdir(parents=True, exist_ok=True)
            r = self.client.vehicle_audio(audio_name, raw)
            if r.get("status") != "ok":
                shutil.rmtree(bundle, ignore_errors=True)
                return {"kind": "audio", "status": r.get("status", "error"),
                        "audio_name": audio_name, "error": r.get("error"), "files": []}

            # Nom final de chaque son, tel que f2r/audio.py et le runtime Roblox
            # l'attendent : engine_accelâ€¦, horn, siren_wail / yelp / priority.
            best: dict[str, tuple[float, Path, dict]] = {}
            rejected: list[dict] = []
            for st in r.get("streams") or []:
                if st.get("status") != "ok" or not st.get("wav"):
                    continue
                src = raw / st["wav"]
                if not src.is_file():
                    continue
                # le role peut etre « siren/Main » ou « engine:ChildSound » :
                # on ne garde que la racine.
                role = str(st.get("role") or "").split(":")[0].split("/")[0].lower()
                stream = str(st.get("file") or "").lower()
                secs = float(st.get("seconds") or 0.0)

                if role in ("engine", "exhaust"):
                    # « canon » est le nom donné par gta-extract ; il couvre aussi
                    # les véhicules sans moteur granulaire, dont les flux n'ont
                    # pas de nom parlant.
                    canon = (st.get("canon") or "").lower()
                    name = canon if canon in ENGINE_STREAMS else (
                        stream if stream in ENGINE_STREAMS else None)
                    lo, hi = DURATION_BOUNDS["engine"]
                elif role == "horn":
                    name = "horn"
                    lo, hi = DURATION_BOUNDS["horn"]
                elif role == "siren":
                    kind = st.get("sirenKind")
                    name = f"siren_{kind}" if kind else None
                    lo, hi = DURATION_BOUNDS["siren"]
                else:
                    continue
                if name is None:
                    continue
                if not (lo <= secs <= hi):
                    rejected.append({"name": name, "stream": stream,
                                     "seconds": round(secs, 2), "reason": "duree implausible"})
                    continue
                # Ã  nom Ã©gal, on garde le flux le plus long (son le plus complet)
                prev = best.get(name)
                if prev is None or secs > prev[0]:
                    best[name] = (secs, src, st)

            entries = []
            for name, (secs, src, st) in sorted(best.items()):
                dst = bundle / (name + ".wav")
                shutil.copyfile(src, dst)
                entries.append({"name": name, "file": dst.name, "role": st.get("role"),
                                "stream": st.get("file"), "seconds": round(secs, 2)})
            shutil.rmtree(raw, ignore_errors=True)
            return _manifest(bundle, entries,
                             {"kind": "audio", "status": "ok", "audio_name": audio_name,
                              "engine_kind": r.get("engineKind"),
                              "containers": list(r.get("containers") or []),
                              "rejected": rejected,
                              "unresolved": [st.get("file") for st in (r.get("streams") or [])
                                             if st.get("status") != "ok"]})

    # -- morceaux -----------------------------------------------------------

    def chunk(self, bundle: str, file: str, index: int) -> dict:
        # Validation stricte : pas de traversÃ©e de chemin, et le fichier doit
        # figurer dans le manifeste du lot.
        if not bundle or "/" in bundle or "\\" in bundle or bundle.startswith("."):
            raise ValueError("identifiant de lot invalide")
        bdir = BUNDLES / bundle
        man_path = bdir / "manifest.json"
        if not man_path.is_file():
            raise ValueError("lot inconnu ou expirÃ© : " + bundle)
        man = json.loads(man_path.read_text(encoding="utf-8"))
        entry = next((f for f in man["files"] if f["file"] == file), None)
        if entry is None:
            raise ValueError("fichier absent du lot : " + str(file))
        p = bdir / entry["file"]
        with open(p, "rb") as f:
            f.seek(index * CHUNK_BYTES)
            data = f.read(CHUNK_BYTES)
        if not data and index > 0:
            raise ValueError(f"morceau {index} hors limites")
        return {"bundle": bundle, "file": file, "index": index,
                "chunks": entry["chunks"], "bytes": len(data),
                "last": index >= entry["chunks"] - 1,
                "data": base64.b64encode(data).decode("ascii")}

    def build_index(self) -> dict:
        with self._lock:
            return self.client.build_texture_index()


# ------------------------------------------------------------------- MCP

TOOLS = [
    {
        "name": "gta_status",
        "description": "Ã‰tat du serveur d'assets GTA V : dossier du jeu dÃ©tectÃ©, nombre d'entrÃ©es RPF, "
                       "taille des morceaux de transfert.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "gta_find_textures",
        "description": "Indique lesquelles des textures demandÃ©es existent dans le jeu de base "
                       "(vehshare, dictionnaires de vÃ©hicules) sans rien transfÃ©rer.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "names": {"type": "array", "items": {"type": "string"},
                          "description": "noms de textures GTA, ex. vehicle_generic_detail2"},
                "vehicle": {"type": "string", "description": "nom du modÃ¨le, ex. adder (indice de recherche)"},
                "txds": {"type": "array", "items": {"type": "string"},
                         "description": "dictionnaires parents issus de txdRelationships"},
            },
            "required": ["names"],
        },
    },
    {
        "name": "gta_prepare_textures",
        "description": "Extrait les textures demandÃ©es du jeu, les convertit en PNG (<= max_size px, "
                       "puissance de 2, alpha conservÃ©) et renvoie un manifeste de lot avec taille, "
                       "SHA-256 et nombre de morceaux par fichier. Utiliser ensuite gta_chunk.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "names": {"type": "array", "items": {"type": "string"}},
                "vehicle": {"type": "string"},
                "txds": {"type": "array", "items": {"type": "string"}},
                "max_size": {"type": "integer", "description": "dÃ©faut 1024"},
            },
            "required": ["names"],
        },
    },
    {
        "name": "gta_prepare_audio",
        "description": "Extrait le son vanilla d'un vÃ©hicule Ã  partir de son audioNameHash "
                       "(ex. ADDER) : moteur et Ã©chappement (accel/decel/idle), klaxon, et "
                       "pour un vÃ©hicule d'urgence les sirÃ¨nes (wail / yelp / priority), en .wav. "
                       "Renvoie un manifeste de lot ; utiliser ensuite gta_chunk.",
        "inputSchema": {
            "type": "object",
            "properties": {"audio_name": {"type": "string", "description": "audioNameHash, ex. ADDER"}},
            "required": ["audio_name"],
        },
    },
    {
        "name": "gta_chunk",
        "description": "Renvoie un morceau d'un fichier d'un lot, encodÃ© en base64.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "bundle": {"type": "string"},
                "file": {"type": "string"},
                "index": {"type": "integer", "description": "numÃ©ro de morceau, Ã  partir de 0"},
            },
            "required": ["bundle", "file"],
        },
    },
    {
        "name": "gta_build_index",
        "description": "Construit l'index complet des textures des dictionnaires de vÃ©hicules "
                       "(~30 s). AmÃ©liore la rÃ©solution des textures rares.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


class McpHandler(BaseHTTPRequestHandler):
    server_version = f"{SERVER_NAME}/{SERVER_VERSION}"
    service: AssetService = None          # injectÃ©

    def log_message(self, fmt, *args):    # silence les logs par requÃªte
        pass

    # -- utilitaires HTTP ---------------------------------------------------

    def _send(self, code: int, body: bytes | None = None, ctype="application/json"):
        self.send_response(code)
        if body is None:
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _json(self, code: int, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", "/healthz"):
            self._json(200, {"ok": True, **self.service.status()})
            return
        # Pas de flux SSE : le client doit utiliser POST.
        self._json(405, {"error": "utiliser POST (JSON-RPC MCP)"})

    def do_DELETE(self):
        self._send(204)

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        raw = self.rfile.read(n) if n else b""
        try:
            msg = json.loads(raw or b"{}")
        except json.JSONDecodeError as exc:
            self._json(400, {"jsonrpc": "2.0", "id": None,
                             "error": {"code": -32700, "message": f"JSON invalide : {exc}"}})
            return
        batch = isinstance(msg, list)
        msgs = msg if batch else [msg]
        out = []
        for m in msgs:
            r = self._handle(m)
            if r is not None:
                out.append(r)
        if not out:
            self._send(202)
            return
        self._json(200, out if batch else out[0])

    # -- JSON-RPC -----------------------------------------------------------

    def _handle(self, m: dict):
        if not isinstance(m, dict):
            return {"jsonrpc": "2.0", "id": None,
                    "error": {"code": -32600, "message": "requÃªte invalide"}}
        mid = m.get("id")
        method = m.get("method") or ""
        params = m.get("params") or {}
        is_notification = "id" not in m

        try:
            if method == "initialize":
                want = (params.get("protocolVersion") or "")
                version = want if want in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
                result = {
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                    "instructions": "Ressources du jeu de base GTA V (textures partagÃ©es, sons de "
                                    "vÃ©hicules) pour le skill fivem-vehicle-to-roblox.",
                }
            elif method in ("notifications/initialized", "notifications/cancelled"):
                return None
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                result = self._call_tool(params)
            else:
                if is_notification:
                    return None
                return {"jsonrpc": "2.0", "id": mid,
                        "error": {"code": -32601, "message": "mÃ©thode inconnue : " + method}}
        except Exception as exc:                                  # noqa: BLE001
            log("[erreur]", traceback.format_exc(limit=4))
            if is_notification:
                return None
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32603, "message": f"{type(exc).__name__}: {exc}"}}

        if is_notification:
            return None
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    def _call_tool(self, params: dict):
        name = params.get("name")
        a = params.get("arguments") or {}
        svc = self.service
        if name == "gta_status":
            data = svc.status()
        elif name == "gta_find_textures":
            data = svc.find_textures(a.get("names") or [], a.get("vehicle"), a.get("txds"))
        elif name == "gta_prepare_textures":
            data = svc.prepare_textures(a.get("names") or [], a.get("vehicle"),
                                        a.get("txds"), int(a.get("max_size") or 1024))
        elif name == "gta_prepare_audio":
            data = svc.prepare_audio(a.get("audio_name") or "")
        elif name == "gta_chunk":
            data = svc.chunk(a.get("bundle"), a.get("file"), int(a.get("index") or 0))
        elif name == "gta_build_index":
            data = svc.build_index()
        else:
            return {"isError": True,
                    "content": [{"type": "text", "text": "outil inconnu : " + str(name)}]}
        return {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}]}


# -------------------------------------------------------------------- main

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Serveur d'assets GTA V (MCP, 127.0.0.1)")
    ap.add_argument("--game", help="dossier de GTA V (sinon dÃ©tection automatique)")
    ap.add_argument("--port", type=int, default=27300)
    ap.add_argument("--legacy", action="store_true", help="forcer l'Ã©dition Legacy (non gen9)")
    ap.add_argument("--prewarm", action="store_true", help="charger l'index RPF au dÃ©marrage")
    ap.add_argument("--build-index", action="store_true",
                    help="construire aussi l'index complet des textures au dÃ©marrage (~30 s)")
    args = ap.parse_args(argv)

    if args.game:
        game = Path(args.game)
        if not gta_locate.is_game_folder(game):
            log(f"ERREUR : {game} ne ressemble pas Ã  une installation GTA V "
                "(GTA5_Enhanced.exe / GTA5.exe + x64a.rpf attendus).")
            return 2
        gen9 = not args.legacy and gta_locate.is_gen9(game)
    else:
        game, gen9 = gta_locate.detect()
        if game is None:
            log("ERREUR : GTA V introuvable. Relancez avec --game \"<dossier>\".")
            log("Dossiers testÃ©s :")
            for c in gta_locate.candidates():
                log("   -", c)
            return 2
        if args.legacy:
            gen9 = False
    gta_locate.save(game, gen9)

    exe = SKILL / "tools" / "gta-extract" / "bin" / ("gta-extract.exe" if os.name == "nt" else "gta-extract")
    if not exe.is_file():
        log(f"ERREUR : {exe} absent. Compilez-le d'abord :")
        log(f"   powershell -ExecutionPolicy Bypass -File \"{SKILL / 'tools' / 'gta-extract' / 'build.ps1'}\"")
        return 2

    log(f"GTA V      : {game}")
    log(f"Ã‰dition    : {'Enhanced (gen9)' if gen9 else 'Legacy'}")
    log(f"Extracteur : {exe}")

    svc = AssetService(game, gen9, exe)
    if args.prewarm or args.build_index:
        try:
            svc.client.start()
            if args.build_index:
                log("[gta] construction de l'index complet des textures â€¦")
                log("[gta] " + json.dumps(svc.build_index()))
        except GtaExtractError as exc:
            log("ERREUR au dÃ©marrage de l'extracteur :", exc)
            return 3

    McpHandler.service = svc
    # 127.0.0.1 uniquement : jamais exposÃ© au rÃ©seau local.
    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.port), McpHandler)
    except OSError as exc:
        log(f"ERREUR : impossible d'Ã©couter sur 127.0.0.1:{args.port} ({exc}). "
            "Le port est peut-Ãªtre dÃ©jÃ  pris.")
        return 4
    httpd.daemon_threads = True
    log("")
    log(f"PRÃŠT â€” serveur MCP sur http://127.0.0.1:{args.port}/mcp")
    log("")
    log("Dans vibestarter > ParamÃ¨tres > My MCP servers, ajoutez un serveur HTTP :")
    log(f"    http://127.0.0.1:{args.port}/mcp")
    log("(toute URL de chemin fonctionne : /mcp, /mc, / â€¦)")
    log("Ctrl+C pour arrÃªter.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("\nArrÃªt demandÃ©.")
    finally:
        svc.client.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
