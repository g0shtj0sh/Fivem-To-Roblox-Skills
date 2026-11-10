"""Client du mode « game-serve » de gta-extract.

gta-extract garde l'index des RPF de GTA V en mémoire (~8 s de scan au démarrage) et
répond à des commandes JSON sur stdin/stdout. Ce module encapsule ce dialogue et
redémarre le processus s'il meurt.

Tout est en LECTURE SEULE : aucune écriture n'est faite dans le dossier du jeu.
"""
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from pathlib import Path


class GtaExtractError(RuntimeError):
    pass


class GtaClient:
    def __init__(self, exe: Path, game_folder: Path, gen9: bool = True, log=print):
        self.exe = Path(exe)
        self.game_folder = Path(game_folder)
        self.gen9 = gen9
        self.log = log
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()
        self._id = 0
        self.ready: dict = {}
        self.index_built = False

    # ------------------------------------------------------------ processus

    def start(self) -> dict:
        with self._lock:
            return self._start_locked()

    def _start_locked(self) -> dict:
        if self._proc is not None and self._proc.poll() is None:
            return self.ready
        args = [str(self.exe), "game-serve", "-g", str(self.game_folder)]
        if self.gen9:
            args.append("--gen9")
        self.log(f"[gta] démarrage de l'index RPF ({self.game_folder}) …")
        t0 = time.time()
        self._proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0,
        )
        msg = self._read_locked()
        if msg.get("event") != "ready":
            raise GtaExtractError(f"gta-extract n'a pas démarré : {msg}")
        self.ready = msg
        self.index_built = False
        self.log(f"[gta] prêt en {time.time() - t0:.1f} s — "
                 f"{msg.get('entries')} entrées, {msg.get('vehicleYtds')} .ytd véhicules, "
                 f"{msg.get('awcContainers')} conteneurs audio")
        return msg

    def stop(self) -> None:
        with self._lock:
            p, self._proc = self._proc, None
            if p is None or p.poll() is not None:
                return
            try:
                p.stdin.write('{"cmd":"quit"}\n')
                p.stdin.flush()
                p.wait(timeout=5)
            except Exception:
                p.kill()

    # -------------------------------------------------------------- dialogue

    def _read_locked(self) -> dict:
        while True:
            line = self._proc.stdout.readline()
            if not line:
                err = ""
                try:
                    err = self._proc.stderr.read() or ""
                except Exception:
                    pass
                raise GtaExtractError("gta-extract s'est arrêté. " + err[-1500:])
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("event") == "index_progress":
                self.log(f"[gta] index textures {msg['done']}/{msg['total']}")
                continue
            return msg

    def call(self, cmd: str, **kw) -> dict:
        with self._lock:
            if self._proc is None or self._proc.poll() is not None:
                self._start_locked()
            self._id += 1
            req = {"id": self._id, "cmd": cmd, **kw}
            try:
                self._proc.stdin.write(json.dumps(req) + "\n")
                self._proc.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                raise GtaExtractError(f"écriture impossible vers gta-extract : {exc}") from exc
            resp = self._read_locked()
        if resp.get("status") == "error":
            raise GtaExtractError(resp.get("error", "erreur inconnue"))
        return resp

    # ------------------------------------------------------------- commandes

    def status(self) -> dict:
        return self.call("status")

    def find_textures(self, names: list[str], hints: dict | None = None) -> dict:
        return self.call("find_textures", names=names, hints=hints or {})

    def extract_textures(self, names: list[str], out_dir: Path, hints: dict | None = None) -> dict:
        return self.call("extract_textures", names=names, out=str(out_dir), hints=hints or {})

    def decode_textures(self, names: list[str], out_dir: Path, hints: dict | None = None) -> dict:
        """Repli : pixels BGRA deja decompresses, pour les formats que Pillow refuse."""
        return self.call("decode_textures", names=names, out=str(out_dir), hints=hints or {})

    def vehicle_audio(self, audio_name: str, out_dir: Path) -> dict:
        return self.call("vehicle_audio", audioName=audio_name, out=str(out_dir))

    def build_texture_index(self) -> dict:
        r = self.call("build_texture_index")
        self.index_built = True
        return r
