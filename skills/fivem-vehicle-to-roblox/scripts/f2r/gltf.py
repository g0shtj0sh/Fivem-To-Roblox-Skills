"""Écriture d'un fichier GLB (glTF 2.0 binaire) sans dépendance externe.

Chaque pièce = un nœud + un mesh (une primitive) portant le même nom, positionné en
coordonnées absolues (transformations de nœud identité) pour que l'importeur 3D de
Roblox Studio conserve la disposition et crée un MeshPart par nœud.
"""
from __future__ import annotations

import json
import struct
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

ARRAY_BUFFER = 34962
ELEMENT_ARRAY_BUFFER = 34963
FLOAT = 5126
UINT32 = 5125


@dataclass
class GMaterial:
    name: str
    base_color: list[float] = field(default_factory=lambda: [1, 1, 1, 1])
    color_png: Path | None = None
    normal_png: Path | None = None
    alpha: str = "OPAQUE"      # OPAQUE / BLEND / MASK
    metallic: float = 0.0
    roughness: float = 0.6
    emissive: list[float] | None = None
    double_sided: bool = False

    def key(self):
        return (tuple(round(c, 4) for c in self.base_color), str(self.color_png), str(self.normal_png),
                self.alpha, self.metallic, self.roughness, tuple(self.emissive or ()), self.double_sided)


class GlbWriter:
    def __init__(self) -> None:
        self.bin = bytearray()
        self.gltf: dict = {
            "asset": {"version": "2.0", "generator": "fivem-vehicle-to-roblox"},
            "scene": 0, "scenes": [{"nodes": []}],
            "nodes": [], "meshes": [], "accessors": [], "bufferViews": [],
            "materials": [], "textures": [], "images": [], "samplers": [
                {"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        }
        self._mat_index: dict = {}
        self._img_index: dict[str, int] = {}

    def _view(self, data: bytes, target: int | None = None) -> int:
        while len(self.bin) % 4:
            self.bin.append(0)
        off = len(self.bin)
        self.bin.extend(data)
        view = {"buffer": 0, "byteOffset": off, "byteLength": len(data)}
        if target:
            view["target"] = target
        self.gltf["bufferViews"].append(view)
        return len(self.gltf["bufferViews"]) - 1

    def _accessor(self, arr: np.ndarray, gltf_type: str, comp: int, target: int, minmax=False) -> int:
        view = self._view(arr.tobytes(), target)
        acc = {"bufferView": view, "componentType": comp, "count": int(arr.shape[0]), "type": gltf_type}
        if minmax:
            acc["min"] = arr.min(axis=0).astype(float).tolist()
            acc["max"] = arr.max(axis=0).astype(float).tolist()
        self.gltf["accessors"].append(acc)
        return len(self.gltf["accessors"]) - 1

    def _image(self, png: Path) -> int:
        key = str(png)
        if key not in self._img_index:
            view = self._view(png.read_bytes())
            self.gltf["images"].append({"bufferView": view, "mimeType": "image/png", "name": png.stem})
            self.gltf["textures"].append({"sampler": 0, "source": len(self.gltf["images"]) - 1})
            self._img_index[key] = len(self.gltf["textures"]) - 1
        return self._img_index[key]

    def material(self, m: GMaterial) -> int:
        k = m.key()
        if k in self._mat_index:
            return self._mat_index[k]
        pbr: dict = {"baseColorFactor": [float(c) for c in m.base_color],
                     "metallicFactor": m.metallic, "roughnessFactor": m.roughness}
        if m.color_png:
            pbr["baseColorTexture"] = {"index": self._image(m.color_png)}
        mat: dict = {"name": m.name, "pbrMetallicRoughness": pbr, "alphaMode": m.alpha,
                     "doubleSided": m.double_sided}
        if m.normal_png:
            mat["normalTexture"] = {"index": self._image(m.normal_png)}
        if m.emissive:
            mat["emissiveFactor"] = m.emissive[:3]
        self.gltf["materials"].append(mat)
        self._mat_index[k] = len(self.gltf["materials"]) - 1
        return self._mat_index[k]

    def add_mesh(self, name: str, pos: np.ndarray, nrm: np.ndarray, uv: np.ndarray, idx: np.ndarray,
                 material: GMaterial) -> None:
        attrs = {
            "POSITION": self._accessor(np.ascontiguousarray(pos, np.float32), "VEC3", FLOAT, ARRAY_BUFFER, True),
            "NORMAL": self._accessor(np.ascontiguousarray(nrm, np.float32), "VEC3", FLOAT, ARRAY_BUFFER),
            "TEXCOORD_0": self._accessor(np.ascontiguousarray(uv, np.float32), "VEC2", FLOAT, ARRAY_BUFFER),
        }
        ind = self._accessor(np.ascontiguousarray(idx, np.uint32), "SCALAR", UINT32, ELEMENT_ARRAY_BUFFER)
        self.gltf["meshes"].append({"name": name, "primitives": [
            {"attributes": attrs, "indices": ind, "material": self.material(material), "mode": 4}]})
        self.gltf["nodes"].append({"name": name, "mesh": len(self.gltf["meshes"]) - 1})
        self.gltf["scenes"][0]["nodes"].append(len(self.gltf["nodes"]) - 1)

    def save(self, path: Path) -> None:
        for key in ("textures", "images", "materials"):
            if not self.gltf[key]:
                del self.gltf[key]
        if "textures" not in self.gltf:
            self.gltf.pop("samplers", None)
        while len(self.bin) % 4:
            self.bin.append(0)
        self.gltf["buffers"] = [{"byteLength": len(self.bin)}]
        js = json.dumps(self.gltf, separators=(",", ":")).encode("utf-8")
        while len(js) % 4:
            js += b" "
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A))
            f.write(js)
            f.write(struct.pack("<II", len(self.bin), 0x004E4942))
            f.write(self.bin)


def quad(size: float = 0.01, at=(0.0, -50.0, 0.0)):
    """Petit carré (pour transporter une texture de livrée jusque dans Studio)."""
    x, y, z = at
    s = size
    pos = np.array([[x - s, y, z - s], [x + s, y, z - s], [x + s, y, z + s], [x - s, y, z + s]], np.float32)
    nrm = np.tile(np.array([0, 1, 0], np.float32), (4, 1))
    uv = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
    idx = np.array([0, 2, 1, 0, 3, 2], np.uint32)
    return pos, nrm, uv, idx
