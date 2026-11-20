"""Zips du dossier Cars servis par le serveur d'assets (vrai code serveur, HTTP local) :
liste, transfert en plusieurs morceaux vérifié par SHA-256, cache, refus hors du dossier."""
import hashlib
import os
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tools" / "gta-asset-server"))


def test_cars_transfer():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        os.environ["LOCALAPPDATA"] = str(tmp / "pc")          # cache du serveur
        os.environ["F2R_CACHE_DIR"] = str(tmp / "vm")         # cache de la VM
        import importlib
        import server
        importlib.reload(server)
        server.CHUNK_BYTES = 3 * 1024 * 1024                  # plusieurs morceaux pour 8 Mo
        cars = tmp / "Cars"
        (cars / "sport").mkdir(parents=True)
        blob = os.urandom(8 * 1024 * 1024 + 123)
        (cars / "sport" / "nissan_test.zip").write_bytes(blob)
        (tmp / "secret.zip").write_bytes(b"x")
        server.CARS_ROOT = cars.resolve()
        svc = server.AssetService.__new__(server.AssetService)
        svc._lock = threading.Lock()
        server.BUNDLES.mkdir(parents=True, exist_ok=True)
        server.McpHandler.service = svc
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.McpHandler)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        os.environ["F2R_GAME_SERVER_URL"] = f"http://127.0.0.1:{httpd.server_address[1]}/mcp"
        try:
            from f2r import gamelib
            from f2r.util import Report
            rep = Report()
            g = gamelib.GameAssets.discover(rep)
            assert g is not None, rep.infos
            assert [c["path"] for c in g.list_cars("nissan")] == ["sport/nissan_test.zip"]
            got = g.fetch_car("sport/nissan_test.zip")
            assert got is not None and hashlib.sha256(got.read_bytes()).digest() == hashlib.sha256(blob).digest()
            assert g.stats["cars"]["chunks"] == 3
            again = g.fetch_car("sport/nissan_test.zip")
            assert again == got and g.stats["cars"]["cached"] == 1 and g.stats["cars"]["chunks"] == 3
            for bad in ("../secret.zip", "sport/absent.zip", str(tmp / "secret.zip")):
                assert g.fetch_car(bad) is None, bad
            g.close()
        finally:
            httpd.shutdown()


if __name__ == "__main__":
    test_cars_transfer()
    print("ok")
