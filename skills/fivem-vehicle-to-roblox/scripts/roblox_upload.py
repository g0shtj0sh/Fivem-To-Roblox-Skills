#!/usr/bin/env python3
"""Upload des sons d'un véhicule converti vers Roblox via l'API Open Cloud (Assets v1).

Pré-requis : une clé API Open Cloud (Creator Hub > Clés API) avec la permission
« Assets : read + write », et l'ID de l'utilisateur ou du groupe propriétaire.

    export ROBLOX_API_KEY=...            # ne jamais la mettre dans un fichier versionné
    python roblox_upload.py out/adder/sounds --user-id 123456
    python roblox_upload.py out/adder/sounds --group-id 7890

Produit sounds/sound_ids.json ({fichier: "rbxassetid://..."}). Relancer ensuite
convert_vehicle.py avec --sound-ids <ce fichier> pour régénérer le Setup avec les SoundId.
"""
from __future__ import annotations

import argparse
import json
import mimetypes
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

API = "https://apis.roblox.com/assets/v1"
TYPES = {".ogg": "audio/ogg", ".mp3": "audio/mpeg", ".wav": "audio/wav", ".flac": "audio/flac"}


def multipart(fields: dict[str, tuple[str | None, bytes, str]]) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    body = bytearray()
    for name, (filename, data, ctype) in fields.items():
        body += f"--{boundary}\r\n".encode()
        disp = f'form-data; name="{name}"' + (f'; filename="{filename}"' if filename else "")
        body += f"Content-Disposition: {disp}\r\nContent-Type: {ctype}\r\n\r\n".encode()
        body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    return bytes(body), f"multipart/form-data; boundary={boundary}"


def call(req: urllib.request.Request) -> dict:
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} : {e.read().decode(errors='replace')[:500]}") from None


def upload(path: Path, key: str, creator: dict, prefix: str) -> str:
    request = {"assetType": "Audio", "displayName": f"{prefix}{path.stem}"[:50],
               "description": "Son de véhicule converti (fivem-vehicle-to-roblox)",
               "creationContext": {"creator": creator}}
    body, ctype = multipart({
        "request": (None, json.dumps(request).encode(), "application/json"),
        "fileContent": (path.name, path.read_bytes(), TYPES.get(path.suffix.lower(), mimetypes.guess_type(path.name)[0] or "application/octet-stream")),
    })
    op = call(urllib.request.Request(f"{API}/assets", data=body, method="POST",
                                     headers={"x-api-key": key, "Content-Type": ctype}))
    op_id = op.get("operationId") or op.get("path", "").split("/")[-1]
    for _ in range(60):
        if op.get("done"):
            break
        time.sleep(2)
        op = call(urllib.request.Request(f"{API}/operations/{op_id}", headers={"x-api-key": key}))
    asset = (op.get("response") or {}).get("assetId")
    if not asset:
        raise RuntimeError(f"upload non terminé / refusé : {json.dumps(op)[:400]}")
    return f"rbxassetid://{asset}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sounds_dir")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--user-id")
    g.add_argument("--group-id")
    ap.add_argument("--prefix", default="", help="préfixe des noms d'assets (ex: 'adder_')")
    args = ap.parse_args()
    key = os.environ.get("ROBLOX_API_KEY")
    if not key:
        print("Variable d'environnement ROBLOX_API_KEY manquante.", file=sys.stderr)
        return 2
    creator = {"userId": str(args.user_id)} if args.user_id else {"groupId": str(args.group_id)}
    d = Path(args.sounds_dir)
    out = d / "sound_ids.json"
    ids = json.loads(out.read_text(encoding="utf-8")) if out.exists() else {}
    files = sorted(p for p in d.iterdir() if p.suffix.lower() in TYPES)
    # si .ogg et .wav coexistent, on n'envoie que le .ogg (plus léger)
    stems_ogg = {p.stem for p in files if p.suffix == ".ogg"}
    files = [p for p in files if not (p.suffix == ".wav" and p.stem in stems_ogg)]
    for p in files:
        if p.name in ids:
            continue
        try:
            ids[p.name] = upload(p, key, creator, args.prefix)
            print(f"OK   {p.name} -> {ids[p.name]}")
        except Exception as exc:  # noqa: BLE001
            print(f"ÉCHEC {p.name} : {exc}", file=sys.stderr)
        out.write_text(json.dumps(ids, indent=2), encoding="utf-8")
    print(f"\n{len(ids)} son(s) dans {out}. Relancez convert_vehicle.py avec --sound-ids {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
