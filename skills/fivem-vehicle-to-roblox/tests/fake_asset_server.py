#!/usr/bin/env python3
"""Faux serveur d'assets GTA V, pour tester scripts/f2r/gamelib.py sans GTA V.

Reproduit le protocole MCP du vrai serveur (tools/gta-asset-server/server.py) avec
des textures et des sons générés, et sait simuler des pannes.

    python tests/fake_asset_server.py --stdio
    python tests/fake_asset_server.py --http 0        (port libre, affiché sur stdout)

Options de simulation :
    --chunk-bytes N   force le découpage (défaut 6 Mio)
    --corrupt NOM     annonce un SHA-256 faux pour ce fichier
    --missing NOM     déclare cette texture absente du « jeu »
    --fail-tool NOM   fait échouer cet outil MCP
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import struct
import sys
import tempfile
import wave
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROTOCOL = "2025-06-18"

TOOLS = [
    {"name": "gta_status", "description": "etat", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "gta_find_textures", "description": "existence",
     "inputSchema": {"type": "object", "properties": {"names": {"type": "array"}}, "required": ["names"]}},
    {"name": "gta_prepare_textures", "description": "lot de textures",
     "inputSchema": {"type": "object", "properties": {"names": {"type": "array"}}, "required": ["names"]}},
    {"name": "gta_prepare_audio", "description": "lot de sons",
     "inputSchema": {"type": "object", "properties": {"audio_name": {"type": "string"}},
                     "required": ["audio_name"]}},
    {"name": "gta_chunk", "description": "morceau",
     "inputSchema": {"type": "object", "properties": {"bundle": {"type": "string"}},
                     "required": ["bundle", "file"]}},
    {"name": "gta_build_index", "description": "index", "inputSchema": {"type": "object", "properties": {}}},
]


def _png(width: int, height: int, seed: int = 0) -> bytes:
    """PNG RGBA minimal, sans dépendance à Pillow."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            row += bytes(((x * 7 + seed) & 255, (y * 5 + seed) & 255, (x ^ y) & 255, 255))
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 6)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


def _wav(path: Path, seconds: float = 0.4, sr: int = 22050) -> None:
    n = int(sr * seconds)
    frames = bytearray()
    for i in range(n):
        v = int(12000 * ((i % 64) / 64 - 0.5))
        frames += struct.pack("<h", v)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(bytes(frames))


class FakeService:
    # Ce que le « jeu » contient.
    TEXTURES = {
        "vehicle_generic_detail2": (256, 256),
        "vehicle_generic_glasswindows2": (128, 128),
        "plate01": (64, 32),
        "grosse_texture": (512, 512),
    }
    # {audioName: {nom de fichier: duree en secondes}} — les durees imitent
    # celles du vrai jeu : klaxon court, wail long, yelp / priority courts.
    AUDIO = {
        "adder": {
        "engine_accel": 0.40, "engine_decel": 0.45, "engine_idle": 0.30,
        "exhaust_accel": 0.40, "exhaust_decel": 0.45, "exhaust_idle": 0.30,
            "horn": 0.30,
        },
        "police": {
        "engine_accel": 0.40, "engine_decel": 0.45, "engine_idle": 0.30,
        "exhaust_accel": 0.40, "exhaust_decel": 0.45, "exhaust_idle": 0.30,
            "horn": 0.35,
            "siren_wail": 6.30, "siren_yelp": 0.35, "siren_priority": 0.30,
        },
        "firetruk": {            # pas de moteur granulaire : seulement des boucles
            "horn": 1.20,
            "siren_wail": 6.30, "siren_yelp": 6.25, "siren_priority": 0.35,
        },
        "brokensiren": {         # sirene trop courte : doit etre refusee
        "engine_accel": 0.40, "engine_decel": 0.45, "engine_idle": 0.30,
        "exhaust_accel": 0.40, "exhaust_decel": 0.45, "exhaust_idle": 0.30,
            "horn": 0.02, "siren_wail": 0.02,
        },
    }

    def __init__(self, root: Path, chunk_bytes: int, corrupt: set[str],
                 missing: set[str], fail_tool: set[str]):
        self.root = root
        self.chunk_bytes = chunk_bytes
        self.corrupt = corrupt
        self.missing = missing
        self.fail_tool = fail_tool
        self.calls: dict[str, int] = {}

    # -- helpers -----------------------------------------------------------

    def _manifest(self, bundle: Path, entries: list[dict], extra: dict) -> dict:
        files = []
        for e in entries:
            p = bundle / e["file"]
            data = p.read_bytes()
            sha = hashlib.sha256(data).hexdigest()
            if e["name"] in self.corrupt:
                sha = "0" * 64
            files.append({**e, "bytes": len(data), "sha256": sha,
                          "chunks": max(1, -(-len(data) // self.chunk_bytes))})
        man = {"bundle": bundle.name, "chunk_bytes": self.chunk_bytes, "files": files, **extra}
        (bundle / "manifest.json").write_text(json.dumps(man), encoding="utf-8")
        return man

    # -- outils ------------------------------------------------------------

    def call(self, name: str, a: dict):
        self.calls[name] = self.calls.get(name, 0) + 1
        if name in self.fail_tool:
            raise RuntimeError(f"panne simulee de {name}")
        if name == "gta_status":
            return {"game_folder": "C:/Faux/GTA V", "gen9": True,
                    "chunk_bytes": self.chunk_bytes, "ready": True, "entries": 42}
        if name == "gta_build_index":
            return {"status": "ok", "textures": len(self.TEXTURES)}
        if name == "gta_find_textures":
            found, miss = {}, []
            for n in a.get("names") or []:
                k = n.lower()
                if k in self.TEXTURES and k not in self.missing:
                    w, h = self.TEXTURES[k]
                    found[k] = {"ytd": "faux.ytd", "width": w, "height": h, "format": "D3DFMT_DXT1"}
                else:
                    miss.append(k)
            return {"status": "ok", "found": found, "missing": miss}
        if name == "gta_prepare_textures":
            names = [n.lower() for n in (a.get("names") or [])]
            bundle = self.root / ("tex-" + hashlib.sha256(
                json.dumps(sorted(names)).encode()).hexdigest()[:12])
            bundle.mkdir(parents=True, exist_ok=True)
            entries, miss = [], []
            for i, n in enumerate(names):
                if n not in self.TEXTURES or n in self.missing:
                    miss.append(n)
                    continue
                w, h = self.TEXTURES[n]
                f = bundle / (n + ".png")
                f.write_bytes(_png(w, h, i))
                entries.append({"name": n, "file": f.name, "source_ytd": "faux.ytd",
                                "source": f"{w}x{h} D3DFMT_DXT1"})
            return self._manifest(bundle, entries,
                                  {"kind": "textures", "missing": miss, "failed": [],
                                   "max_size": int(a.get("max_size") or 1024)})
        if name == "gta_prepare_audio":
            an = (a.get("audio_name") or "").lower()
            if an not in self.AUDIO:
                return {"kind": "audio", "status": "not_found", "audio_name": an,
                        "error": "aucun reglage audio", "files": []}
            bundle = self.root / ("aud-" + an)
            bundle.mkdir(parents=True, exist_ok=True)
            entries = []
            for name, secs in self.AUDIO[an].items():
                role = ("siren" if name.startswith("siren")
                        else "horn" if name == "horn"
                        else "exhaust" if name.startswith("exhaust") else "engine")
                f = bundle / (name + ".wav")
                _wav(f, secs)
                entries.append({"name": name, "file": f.name, "role": role,
                                "seconds": round(secs, 2)})
            return self._manifest(bundle, entries,
                                  {"kind": "audio", "status": "ok", "audio_name": an,
                                   "engine_kind": "granular" if an != "firetruk" else "loops",
                                   "containers": [], "unresolved": []})
        if name == "gta_chunk":
            b = a.get("bundle") or ""
            if "/" in b or "\\" in b or b.startswith("."):
                raise ValueError("identifiant de lot invalide")
            bundle = self.root / b
            man = json.loads((bundle / "manifest.json").read_text(encoding="utf-8"))
            entry = next((f for f in man["files"] if f["file"] == a.get("file")), None)
            if entry is None:
                raise ValueError("fichier absent du lot")
            idx = int(a.get("index") or 0)
            data = (bundle / entry["file"]).read_bytes()[idx * self.chunk_bytes:(idx + 1) * self.chunk_bytes]
            return {"bundle": b, "file": entry["file"], "index": idx, "chunks": entry["chunks"],
                    "bytes": len(data), "last": idx >= entry["chunks"] - 1,
                    "data": base64.b64encode(data).decode("ascii")}
        raise ValueError("outil inconnu : " + str(name))


def handle(svc: FakeService, m: dict):
    mid = m.get("id")
    method = m.get("method") or ""
    params = m.get("params") or {}
    notif = "id" not in m
    try:
        if method == "initialize":
            result = {"protocolVersion": PROTOCOL, "capabilities": {"tools": {}},
                      "serverInfo": {"name": "fake-gta-asset-server", "version": "1.0"}}
        elif method.startswith("notifications/"):
            return None
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOLS}
        elif method == "tools/call":
            data = svc.call(params.get("name"), params.get("arguments") or {})
            result = {"content": [{"type": "text", "text": json.dumps(data)}]}
        else:
            if notif:
                return None
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32601, "message": "methode inconnue"}}
    except Exception as exc:  # noqa: BLE001
        if notif:
            return None
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32603, "message": f"{type(exc).__name__}: {exc}"}}
    if notif:
        return None
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def serve_stdio(svc: FakeService) -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            continue
        r = handle(svc, m)
        if r is not None:
            sys.stdout.write(json.dumps(r) + "\n")
            sys.stdout.flush()
    return 0


def make_http_handler(svc: FakeService):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            try:
                m = json.loads(self.rfile.read(n) or b"{}")
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            r = handle(svc, m)
            if r is None:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps(r).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    return H


def build_service(args, root: Path) -> FakeService:
    return FakeService(root, args.chunk_bytes, set(args.corrupt or []),
                       set(args.missing or []), set(args.fail_tool or []))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdio", action="store_true")
    ap.add_argument("--http", type=int)
    ap.add_argument("--root")
    ap.add_argument("--chunk-bytes", type=int, default=6 * 1024 * 1024)
    ap.add_argument("--corrupt", action="append")
    ap.add_argument("--missing", action="append")
    ap.add_argument("--fail-tool", action="append")
    args = ap.parse_args(argv)
    root = Path(args.root) if args.root else Path(tempfile.mkdtemp(prefix="fake-gta-"))
    root.mkdir(parents=True, exist_ok=True)
    svc = build_service(args, root)
    if args.http is not None:
        httpd = ThreadingHTTPServer(("127.0.0.1", args.http), make_http_handler(svc))
        print(f"http://127.0.0.1:{httpd.server_address[1]}/mcp", flush=True)
        httpd.serve_forever()
        return 0
    return serve_stdio(svc)


if __name__ == "__main__":
    sys.exit(main())
