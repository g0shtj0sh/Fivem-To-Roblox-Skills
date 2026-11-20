#!/usr/bin/env python3
"""Zips de véhicules du dossier « Cars » du PC, servis à la VM par le serveur d'assets.

Contourne la limite de téléversement de la VM (100 Mo) : le zip arrive en morceaux de 6 Mo,
vérifié par SHA-256 et mis en cache (un zip inchangé n'est transféré qu'une fois).

    python scripts/cars.py list [mots]            # ex. list skyline r34
    python scripts/cars.py get <catégorie>/<zip>  # affiche le chemin local du zip reçu

En général on ne s'en sert que pour chercher : convert_vehicle.py accepte directement
« cars:<catégorie>/<zip> » comme entrée.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from f2r import gamelib  # noqa: E402
from f2r.util import Report  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list")
    ls.add_argument("words", nargs="*")
    get = sub.add_parser("get")
    get.add_argument("path")
    get.add_argument("--retry", action="store_true")
    args = ap.parse_args(argv)

    report = Report()
    g = gamelib.GameAssets.discover(report)
    if g is None:
        print("Serveur d'assets injoignable (start-server.bat lancé sur le PC ?).", file=sys.stderr)
        return 2
    try:
        if args.cmd == "list":
            cars = g.list_cars(" ".join(args.words))
            for c in cars:
                print(f"{c['bytes'] / 1e6:8.0f} Mo  {c['path']}")
            print(f"{len(cars)} véhicule(s)", file=sys.stderr)
            return 0
        got = g.fetch_car(args.path, retry=args.retry)
        if got is None:
            return 1
        print(json.dumps({"path": str(got), "transfer": g.transfer_summary()}, ensure_ascii=False))
        return 0
    finally:
        g.close()


if __name__ == "__main__":
    sys.exit(main())
