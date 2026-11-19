"""Alléger un GLB trop lourd pour l'envoi (VibeStarter upload_file refuse ~25 Mo et plus : 413).

Constat (325e, BMW E30 de HRH, 2026-11-19) : GLB de 29,6 Mo (395 000 triangles dont 205 000 de pièces de
custom, 94 textures PNG) refusé par ``upload_file`` (« Upload failed (413) »), alors que 21,4 Mo (rm3e36) et
20,3 Mo (m422) passaient. ``--lod med`` n'y change rien quand le mod n'a pas de vrai LOD moyen, et
``--max-texture 1024`` (25,4 Mo) restait refusé tout en dégradant les textures.

Deux réécritures sans perte visible, appliquées au-delà d'un seuil :
  * index des maillages en uint16 quand la pièce a moins de 65 536 sommets (toutes : une MeshPart Roblox a au plus
    20 000 triangles) : moitié de la place des index (4,7 -> 2,4 Mo sur la 325e) ;
  * textures opaques (alpha partout à 255) en JPEG qualité 92, les autres restent en PNG (14,3 -> 5,7 Mo).
glTF 2.0 accepte ``image/jpeg`` et les index ``UNSIGNED_SHORT``.
"""
from __future__ import annotations

import io
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image

JPEG_QUALITY = 92


def _pad4(data: bytes, fill: bytes = b"\x00") -> bytes:
    return data + fill * ((4 - len(data) % 4) % 4)


def compact_glb(path: Path, jpeg_quality: int = JPEG_QUALITY) -> dict:
    """Réécrit ``path`` sur place. Renvoie {before_mb, after_mb, jpeg, png_kept, indices16}."""
    raw = Path(path).read_bytes()
    jlen = struct.unpack("<I", raw[12:16])[0]
    g = json.loads(raw[20:20 + jlen])
    bin_start = 20 + jlen + 8
    bin_len = struct.unpack("<I", raw[20 + jlen:24 + jlen])[0]
    blob = raw[bin_start:bin_start + bin_len]
    views = g["bufferViews"]
    data = [blob[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]] for v in views]

    jpeg = png_kept = idx16 = 0
    for im in g.get("images", []):
        if "bufferView" not in im or im.get("mimeType") != "image/png":
            continue
        vi = im["bufferView"]
        pic = Image.open(io.BytesIO(data[vi]))
        rgba = pic.convert("RGBA")
        if np.asarray(rgba)[..., 3].min() < 255:
            png_kept += 1
            continue
        out = io.BytesIO()
        rgba.convert("RGB").save(out, "JPEG", quality=jpeg_quality, optimize=True)
        if len(out.getvalue()) < len(data[vi]):
            data[vi] = out.getvalue()
            im["mimeType"] = "image/jpeg"
            jpeg += 1

    index_accessors = {pr["indices"] for m in g.get("meshes", []) for pr in m["primitives"] if "indices" in pr}
    shared = {}
    for a in g["accessors"]:
        shared[a.get("bufferView")] = shared.get(a.get("bufferView"), 0) + 1
    for ai in index_accessors:
        a = g["accessors"][ai]
        vi = a.get("bufferView")
        if a["componentType"] != 5125 or vi is None or shared[vi] != 1 or a.get("byteOffset", 0):
            continue
        arr = np.frombuffer(data[vi], np.uint32, a["count"])
        if arr.size and int(arr.max()) >= 65535:
            continue
        data[vi] = arr.astype(np.uint16).tobytes()
        a["componentType"] = 5123
        views[vi].pop("byteStride", None)
        idx16 += 1

    out_bin = b""
    for vi, v in enumerate(views):
        out_bin = _pad4(out_bin)
        v["byteOffset"] = len(out_bin)
        v["byteLength"] = len(data[vi])
        out_bin += data[vi]
    out_bin = _pad4(out_bin)
    g["buffers"][0]["byteLength"] = len(out_bin)
    js = _pad4(json.dumps(g, separators=(",", ":")).encode("utf-8"), b" ")
    total = 12 + 8 + len(js) + 8 + len(out_bin)
    glb = (struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js
           + struct.pack("<II", len(out_bin), 0x004E4942) + out_bin)
    Path(path).write_bytes(glb)
    return {"before_mb": round(len(raw) / 1e6, 2), "after_mb": round(len(glb) / 1e6, 2),
            "jpeg": jpeg, "png_kept": png_kept, "indices16": idx16}
