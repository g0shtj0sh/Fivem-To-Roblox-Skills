"""Lecture du format XML de CodeWalker / Sollumz (.yft.xml, .ydr.xml, .ytd.xml, .awc.xml).

Format de référence : CodeWalker.Core (Drawable.cs / Frag.cs / Texture.cs / AwcFile.cs).
  * Sommets : une ligne par sommet, les attributs (Position, Normal, Colour0, TexCoord0...)
    séparés par TROIS espaces, les composantes d'un attribut par un espace. L'ordre des
    attributs est celui des balises enfants de <Layout>.
  * Indices : entiers séparés par des espaces / retours à la ligne.
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .util import resolve_hash_name

LOD_TAGS = {
    "high": ["DrawableModelsHigh", "DrawableModels/High"],
    "med": ["DrawableModelsMedium", "DrawableModels/Medium", "DrawableModels/Med"],
    "low": ["DrawableModelsLow", "DrawableModels/Low"],
    "vlow": ["DrawableModelsVeryLow", "DrawableModels/VeryLow"],
}


@dataclass
class Shader:
    name: str
    filename: str
    textures: dict[str, str] = field(default_factory=dict)       # param -> nom de texture
    vectors: dict[str, list[float]] = field(default_factory=dict)  # param -> [x,y,z,w]


@dataclass
class Bone:
    name: str
    index: int
    parent: int
    tag: int
    translation: np.ndarray
    rotation: np.ndarray  # quaternion x y z w
    scale: np.ndarray
    world: np.ndarray | None = None  # matrice 4x4 (espace GTA)


@dataclass
class Geometry:
    shader_index: int
    bone_ids: list[int]
    attrs: dict[str, np.ndarray]   # "Position" -> (N,3) ...
    indices: np.ndarray            # (M,) uint32


@dataclass
class Model:
    bone_index: int
    has_skin: bool
    geometries: list[Geometry]


@dataclass
class Drawable:
    name: str
    shaders: list[Shader]
    bones: list[Bone]
    models: list[Model]
    embedded_textures: list[str]
    bone_tag: int | None = None      # pour les enfants physiques (roues...)


@dataclass
class Fragment:
    name: str
    main: Drawable
    children: list[Drawable]   # drawables des enfants physiques (roues, etc.)
    source: Path


# ----------------------------------------------------------------- helpers

def _text(el, tag, default=""):
    c = el.find(tag) if el is not None else None
    if c is None:
        return default
    if "value" in c.attrib:
        return c.attrib["value"]
    return (c.text or default).strip()


def _vec(el, tag, n=3):
    c = el.find(tag) if el is not None else None
    if c is None:
        return np.zeros(n)
    keys = ("x", "y", "z", "w")[:n]
    return np.array([float(c.attrib.get(k, 0.0)) for k in keys])


def _find_first(el, paths):
    for p in paths:
        r = el.find(p)
        if r is not None:
            return r
    return None


# ----------------------------------------------------------------- parsing

def parse_shaders(drawable_el) -> tuple[list[Shader], list[str]]:
    shaders: list[Shader] = []
    embedded: list[str] = []
    sg = drawable_el.find("ShaderGroup")
    if sg is None:
        return shaders, embedded
    for tex in sg.findall("TextureDictionary/Item"):
        embedded.append(_text(tex, "Name").lower())
    for item in sg.findall("Shaders/Item"):
        name = resolve_hash_name(_text(item, "Name")).lower()
        fname = resolve_hash_name(_text(item, "FileName")).lower()
        if not name and fname:
            name = fname.replace(".sps", "")
        sh = Shader(name=name, filename=fname)
        for p in item.findall("Parameters/Item"):
            pname = p.attrib.get("name", "")
            ptype = p.attrib.get("type", "")
            if ptype == "Texture":
                tname = _text(p, "Name")
                if tname:
                    sh.textures[pname] = tname.lower()
            elif ptype == "Vector":
                sh.vectors[pname] = [float(p.attrib.get(k, 0.0)) for k in ("x", "y", "z", "w")]
        shaders.append(sh)
    return shaders, embedded


def parse_bones(drawable_el) -> list[Bone]:
    bones: list[Bone] = []
    sk = drawable_el.find("Skeleton")
    if sk is None:
        return bones
    for i, b in enumerate(sk.findall("Bones/Item")):
        idx = int(_text(b, "Index", str(i)) or i)
        bones.append(Bone(
            name=_text(b, "Name", f"bone_{i}").lower(),
            index=idx,
            parent=int(_text(b, "ParentIndex", "-1") or -1),
            tag=int(_text(b, "Tag", "0") or 0),
            translation=_vec(b, "Translation", 3),
            rotation=_vec(b, "Rotation", 4) if b.find("Rotation") is not None else np.array([0, 0, 0, 1.0]),
            scale=_vec(b, "Scale", 3) if b.find("Scale") is not None else np.ones(3),
        ))
    # certains exports ont un Scale à 0 : on corrige
    for b in bones:
        if not np.any(b.scale):
            b.scale = np.ones(3)
        if not np.any(b.rotation):
            b.rotation = np.array([0, 0, 0, 1.0])
    return bones


_TRIPLE = re.compile(r" {3,}|\t")


def parse_vertex_buffer(vb_el) -> dict[str, np.ndarray]:
    layout_el = vb_el.find("Layout")
    if layout_el is None:
        return {}
    semantics = [c.tag for c in layout_el]
    data_el = vb_el.find("Data")
    if data_el is None or not (data_el.text or "").strip():
        data_el = vb_el.find("Data2")
    if data_el is None or not data_el.text:
        return {}
    rows = [r.strip() for r in data_el.text.strip().splitlines() if r.strip()]
    cols: dict[str, list[list[float]]] = {s: [] for s in semantics}
    for row in rows:
        groups = _TRIPLE.split(row)
        if len(groups) != len(semantics):
            # format inattendu : on tente de redécouper avec les tailles du premier sommet
            raise ValueError(f"Ligne de sommet inattendue ({len(groups)} groupes pour {len(semantics)} attributs) : {row[:80]}")
        for s, g in zip(semantics, groups):
            cols[s].append([float(v) for v in g.split()])
    return {s: np.asarray(v, dtype=np.float64) for s, v in cols.items()}


def parse_index_buffer(ib_el) -> np.ndarray:
    data_el = ib_el.find("Data") if ib_el is not None else None
    if data_el is None or not data_el.text:
        return np.zeros(0, dtype=np.uint32)
    return np.array(data_el.text.split(), dtype=np.int64).astype(np.uint32)


def parse_models(drawable_el, lod: str) -> list[Model]:
    models_el = _find_first(drawable_el, LOD_TAGS.get(lod, LOD_TAGS["high"]))
    if models_el is None and lod != "high":
        models_el = _find_first(drawable_el, LOD_TAGS["high"])
    if models_el is None:
        return []
    models: list[Model] = []
    for m in models_el.findall("Item"):
        geoms = []
        for g in m.findall("Geometries/Item"):
            vb = g.find("VertexBuffer")
            if vb is None:
                continue
            attrs = parse_vertex_buffer(vb)
            if "Position" not in attrs:
                continue
            bone_ids_txt = _text(g, "BoneIDs", "")
            bone_ids = [int(x) for x in re.split(r"[,\s]+", bone_ids_txt) if x.strip()] if bone_ids_txt else []
            geoms.append(Geometry(
                shader_index=int(_text(g, "ShaderIndex", "0") or 0),
                bone_ids=bone_ids,
                attrs=attrs,
                indices=parse_index_buffer(g.find("IndexBuffer")),
            ))
        models.append(Model(
            bone_index=int(_text(m, "BoneIndex", "0") or 0),
            has_skin=(_text(m, "HasSkin", "0") not in ("0", "", "false", "False")),
            geometries=geoms,
        ))
    return models


def parse_drawable(el, lod: str, name: str = "") -> Drawable:
    shaders, embedded = parse_shaders(el)
    return Drawable(
        name=_text(el, "Name", name) or name,
        shaders=shaders,
        bones=parse_bones(el),
        models=parse_models(el, lod),
        embedded_textures=embedded,
    )


def parse_fragment(path: Path, lod: str = "high") -> Fragment:
    root = ET.parse(path).getroot()
    if root.tag == "Fragment":
        dr_el = root.find("Drawable")
        if dr_el is None:
            arr = root.find("DrawableArray/Item")
            dr_el = arr
        if dr_el is None:
            raise ValueError(f"{path.name} : aucun <Drawable> dans le fragment")
        main = parse_drawable(dr_el, lod, _text(root, "Name"))
        children: list[Drawable] = []
        for child in root.findall("Physics/LOD1/Children/Item"):
            d_el = child.find("Drawable")
            if d_el is None:
                continue
            d = parse_drawable(d_el, lod)
            d.bone_tag = int(_text(child, "BoneTag", "0") or 0)
            if any(m.geometries for m in d.models):
                children.append(d)
        return Fragment(name=_text(root, "Name") or path.stem, main=main, children=children, source=path)
    if root.tag == "Drawable":  # .ydr.xml (pièces de mods parfois livrées en ydr)
        main = parse_drawable(root, lod, path.name.split(".")[0])
        return Fragment(name=main.name, main=main, children=[], source=path)
    raise ValueError(f"{path.name} : racine XML inattendue <{root.tag}>")


# ----------------------------------------------------------------- textures

@dataclass
class TextureInfo:
    name: str
    filename: str
    width: int
    height: int
    fmt: str


def parse_ytd(path: Path) -> list[TextureInfo]:
    root = ET.parse(path).getroot()
    out = []
    for t in root.iter("Item"):
        name = _text(t, "Name")
        if not name:
            continue
        out.append(TextureInfo(
            name=name.lower(),
            filename=_text(t, "FileName", name + ".dds"),
            width=int(_text(t, "Width", "0") or 0),
            height=int(_text(t, "Height", "0") or 0),
            fmt=_text(t, "Format", ""),
        ))
    return out


# ----------------------------------------------------------------- audio

@dataclass
class AwcStream:
    name: str
    filename: str
    wav: Path | None


def parse_awc(path: Path) -> list[AwcStream]:
    root = ET.parse(path).getroot()
    folder = path.parent / path.name[: -len(".awc.xml")]
    out = []
    for s in root.iter("Item"):
        fn = _text(s, "FileName")
        if not fn:
            continue
        name = resolve_hash_name(_text(s, "Name", fn))
        wav = folder / fn
        out.append(AwcStream(name=name.lower(), filename=fn, wav=wav if wav.exists() else None))
    return out
