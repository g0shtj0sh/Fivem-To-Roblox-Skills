"""Part de chaque optique (pièce kind=light) couverte par son masque d'émission, lue dans le GLB converti.

    python3 tools/light-coverage/coverage.py <sortie>/<nom>      (le dossier qui contient <nom>.glb et emissive/)

Pour chaque nœud *light* : moyenne du masque (0..1) aux centres et sommets de ses triangles, pondérée par l'aire UV.
Sert à choisir entre allumage par la texture (masque clair) et Neon sur la pièce entière (masque sombre).
"""
import json, struct, sys
from pathlib import Path
import numpy as np
from PIL import Image

def load_glb(path):
    b = Path(path).read_bytes()
    jl = struct.unpack_from("<I", b, 12)[0]
    js = json.loads(b[20:20 + jl])
    off = 20 + jl
    bl = struct.unpack_from("<I", b, off)[0]
    return js, b[off + 8: off + 8 + bl]

def accessor(js, buf, i):
    a = js["accessors"][i]
    bv = js["bufferViews"][a["bufferView"]]
    n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[a["type"]]
    dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16}[a["componentType"]]
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    arr = np.frombuffer(buf, dt, a["count"] * n, start)
    return arr.reshape(-1, n) if n > 1 else arr

def coverage(outdir):
    out = Path(outdir)
    glb = next(out.glob("*.glb"))
    js, buf = load_glb(glb)
    masks = {}
    res = {}
    for node in js["nodes"]:
        name = node.get("name", "")
        if "mesh" not in node:
            continue
        for prim in js["meshes"][node["mesh"]]["primitives"]:
            mat = js["materials"][prim["material"]] if "material" in prim else {}
            em = mat.get("emissiveTexture")
            if em is None:
                continue
            img = js["images"][js["textures"][em["index"]]["source"]]
            key = img.get("name") or img.get("uri") or str(em["index"])
            if key not in masks:
                bv = js["bufferViews"][img["bufferView"]]
                data = buf[bv.get("byteOffset", 0): bv.get("byteOffset", 0) + bv["byteLength"]]
                import io
                masks[key] = np.asarray(Image.open(io.BytesIO(data)).convert("L")).astype(np.float32) / 255
            m = masks[key]
            h, w = m.shape
            uv = accessor(js, buf, prim["attributes"]["TEXCOORD_0"]) % 1.0
            idx = accessor(js, buf, prim["indices"]).reshape(-1, 3)
            tri = uv[idx]                                  # (n, 3, 2)
            pts = np.concatenate([tri, tri.mean(1, keepdims=True)], 1).reshape(-1, 2)
            px = np.clip((pts[:, 0] * w).astype(int), 0, w - 1)
            py = np.clip((pts[:, 1] * h).astype(int), 0, h - 1)
            vals = m[py, px].reshape(-1, 4).mean(1)
            e1, e2 = tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0]
            area = np.abs(e1[:, 0] * e2[:, 1] - e1[:, 1] * e2[:, 0]) + 1e-9
            res[name] = float((vals * area).sum() / area.sum())
    return res

if __name__ == "__main__":
    for name, v in sorted(coverage(sys.argv[1]).items()):
        print(f"{v:5.2f}  {name}")
