#!/usr/bin/env python3
"""Tests de scripts/f2r/gamelib.py contre le faux serveur d'assets.

    python tests/test_gamelib.py        (ou pytest tests/test_gamelib.py)

Aucun besoin de GTA V ni de vibestarter : fake_asset_server.py rejoue le protocole
MCP du vrai serveur et sait simuler découpage, corruption et pannes.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT / "scripts"))

from f2r import gamelib  # noqa: E402
from f2r.util import Report  # noqa: E402

FAKE = HERE / "fake_asset_server.py"


# --------------------------------------------------------------- utilitaires

class HttpFake:
    """Lance le faux serveur en HTTP et expose son URL."""

    def __init__(self, *extra: str):
        self.proc = subprocess.Popen(
            [sys.executable, str(FAKE), "--http", "0", *extra],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.url = self.proc.stdout.readline().strip()
        assert self.url.startswith("http://"), f"URL inattendue : {self.url!r}"
        for _ in range(100):                       # attend que le port réponde
            try:
                urllib.request.urlopen(self.url, data=b"{}", timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except Exception:
                time.sleep(0.05)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def connect(url: str, report: Report) -> gamelib.GameAssets:
    client = gamelib.McpClient(gamelib.HttpTransport(url))
    client.initialize()
    assert gamelib.MARKER_TOOL in client.tool_names()
    return gamelib.GameAssets(client, report)


# ------------------------------------------------------------------- tests

def test_fetch_textures_and_cache():
    """Récupération, mise en cache, et textures absentes signalées."""
    with tempfile.TemporaryDirectory() as tmp, HttpFake() as srv:
        os.environ["F2R_CACHE_DIR"] = tmp
        rep = Report()
        g = connect(srv.url, rep)
        names = ["vehicle_generic_detail2", "plate01", "pas_dans_le_jeu"]
        got = g.fetch_textures(names, vehicle="adder", txds=["vehshare"])
        assert set(got) == {"vehicle_generic_detail2", "plate01"}, got
        for p in got.values():
            assert p.is_file() and p.stat().st_size > 0
            assert p.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n", "ce n'est pas un PNG"
        assert "pas_dans_le_jeu" in g._neg_tex

        # 2e appel : servi par le cache, sans nouvelle préparation côté serveur
        mtimes = {k: v.stat().st_mtime_ns for k, v in got.items()}
        again = g.fetch_textures(names, vehicle="adder")
        assert set(again) == set(got)
        assert {k: v.stat().st_mtime_ns for k, v in again.items()} == mtimes
        g.close()
        # le cache negatif est persiste
        assert (Path(tmp) / "missing_textures.json").is_file()
    print("OK test_fetch_textures_and_cache")


def test_chunked_transfer():
    """Un fichier plus gros qu'un morceau est réassemblé à l'identique."""
    with tempfile.TemporaryDirectory() as tmp, HttpFake("--chunk-bytes", "4096") as srv:
        os.environ["F2R_CACHE_DIR"] = tmp
        rep = Report()
        g = connect(srv.url, rep)
        got = g.fetch_textures(["grosse_texture"])
        assert set(got) == {"grosse_texture"}
        data = got["grosse_texture"].read_bytes()
        assert len(data) > 4096, f"fichier trop petit pour tester le découpage : {len(data)}"
        assert data[:8] == b"\x89PNG\r\n\x1a\n"
        g.close()
    print("OK test_chunked_transfer")


def test_corrupt_file_rejected():
    """Un SHA-256 qui ne correspond pas : le fichier est refusé, pas livré à moitié."""
    with tempfile.TemporaryDirectory() as tmp, HttpFake("--corrupt", "plate01") as srv:
        os.environ["F2R_CACHE_DIR"] = tmp
        rep = Report()
        g = connect(srv.url, rep)
        got = g.fetch_textures(["vehicle_generic_detail2", "plate01"])
        assert "plate01" not in got, "le fichier corrompu a été accepté"
        assert "vehicle_generic_detail2" in got, "les autres fichiers doivent passer"
        assert any("intégrité" in w for w in rep.warnings), rep.warnings
        assert not (Path(tmp) / "textures" / "1024" / "plate01.png").exists()
        assert not list((Path(tmp) / "textures" / "1024").glob("*.part"))
        g.close()
    print("OK test_corrupt_file_rejected")


def test_audio_fetch():
    """Le son vanilla arrive avec les noms de flux attendus par audio.py."""
    with tempfile.TemporaryDirectory() as tmp, HttpFake() as srv:
        os.environ["F2R_CACHE_DIR"] = tmp
        rep = Report()
        g = connect(srv.url, rep)
        got = g.fetch_audio("ADDER")
        assert "engine_accel" in got and "engine_idle" in got, got
        assert all(p.is_file() and p.read_bytes()[:4] == b"RIFF" for p in got.values())

        # audio.py doit savoir y reconnaître l'accélération et le ralenti
        from f2r.audio import pick_stream
        assert pick_stream(got, ["engine_accel", "accel"]) is not None
        assert pick_stream(got, ["idle"]) is not None

        # audioNameHash inconnu -> pas d'erreur, juste rien
        assert g.fetch_audio("INEXISTANT") == {}
        g.close()
    print("OK test_audio_fetch")


def test_server_failure_is_graceful():
    """Une panne du serveur n'interrompt pas la conversion : on repart sans."""
    with tempfile.TemporaryDirectory() as tmp, HttpFake("--fail-tool", "gta_prepare_textures") as srv:
        os.environ["F2R_CACHE_DIR"] = tmp
        rep = Report()
        g = connect(srv.url, rep)
        assert g.fetch_textures(["vehicle_generic_detail2"]) == {}
        assert any("indisponibles" in w for w in rep.warnings), rep.warnings
        g.close()
    print("OK test_server_failure_is_graceful")


def test_stdio_transport():
    """Le même protocole fonctionne sur stdin/stdout (cas du stub MCP vibestarter)."""
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["F2R_CACHE_DIR"] = tmp
        rep = Report()
        t = gamelib.StdioTransport("faux", sys.executable, [str(FAKE), "--stdio"], None)
        client = gamelib.McpClient(t)
        client.initialize()
        assert gamelib.MARKER_TOOL in client.tool_names()
        g = gamelib.GameAssets(client, rep)
        got = g.fetch_textures(["plate01"])
        assert set(got) == {"plate01"}, got
        g.close()
    print("OK test_stdio_transport")


def test_discover_disabled():
    """F2R_NO_GAME_SERVER coupe toute découverte (mode hors ligne)."""
    old = os.environ.get("F2R_NO_GAME_SERVER")
    os.environ["F2R_NO_GAME_SERVER"] = "1"
    try:
        assert gamelib.GameAssets.discover(Report()) is None
    finally:
        if old is None:
            os.environ.pop("F2R_NO_GAME_SERVER", None)
        else:
            os.environ["F2R_NO_GAME_SERVER"] = old
    print("OK test_discover_disabled")


def test_discover_via_url():
    """Découverte par F2R_GAME_SERVER_URL."""
    with tempfile.TemporaryDirectory() as tmp, HttpFake() as srv:
        os.environ["F2R_CACHE_DIR"] = tmp
        os.environ.pop("F2R_NO_GAME_SERVER", None)
        os.environ["F2R_GAME_SERVER_URL"] = srv.url
        try:
            g = gamelib.GameAssets.discover(Report())
            assert g is not None, "le serveur annoncé par l'URL n'a pas été trouvé"
            assert g.server_status.get("game_folder")
            g.close()
        finally:
            os.environ.pop("F2R_GAME_SERVER_URL", None)
    print("OK test_discover_via_url")


def test_collect_missing_textures():
    """On ne demande au PC que les textures réellement absentes des sources locales."""
    class FauxStore:
        def __init__(self, present):
            self.present = {p.lower() for p in present}

        def find(self, n):
            return Path("x") if n.lower() in self.present else None

    class FauxPart:
        def __init__(self, d=None, n=None, liv=()):
            self.tex_diffuse, self.tex_normal, self.tex_livery = d, n, list(liv)

    parts = [FauxPart("deja_la", "manque_n"),
             FauxPart("manque_d", None, ["liv_1", "deja_la"]),
             FauxPart(None, None)]
    miss = gamelib.collect_missing_textures(parts, FauxStore(["deja_la"]))
    assert miss == ["manque_n", "manque_d", "liv_1"], miss
    print("OK test_collect_missing_textures")


ALL = [test_fetch_textures_and_cache, test_chunked_transfer, test_corrupt_file_rejected,
       test_audio_fetch, test_server_failure_is_graceful, test_stdio_transport,
       test_discover_disabled, test_discover_via_url, test_collect_missing_textures]

if __name__ == "__main__":
    for fn in ALL:
        fn()
    print(f"\n{len(ALL)} tests passés.")
