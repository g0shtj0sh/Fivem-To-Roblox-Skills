"""Inventaire d'un pack de véhicule FiveM / GTA V une fois extrait."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .util import parse_xml_lenient

META_KINDS = {
    "CVehicleModelInfo__InitDataList": "vehicles",
    "CVehicleModelInfoVarGlobal": "carcols",
    "CVehicleModelInfoVariation": "carvariations",
    "CHandlingDataMgr": "handling",
    "CVehicleMetadataMgr": "layouts",
}

RESOURCE_EXT = (".yft", ".ytd", ".ydr", ".ydd", ".awc", ".rel", ".rpf")


@dataclass
class Inventory:
    root: Path
    binaries: list[Path] = field(default_factory=list)          # ressources RSC7 / RPF à convertir
    yft_xml: dict[str, Path] = field(default_factory=dict)      # "adder_hi" -> adder_hi.yft.xml
    ydr_xml: dict[str, Path] = field(default_factory=dict)
    ytd_xml: dict[str, Path] = field(default_factory=dict)
    awc_xml: list[Path] = field(default_factory=list)
    rel_xml: list[Path] = field(default_factory=list)
    dds: dict[str, Path] = field(default_factory=dict)          # nom de texture -> .dds (le plus grand gagne)
    images: dict[str, Path] = field(default_factory=dict)       # .png/.jpg/.tga déjà fournis
    wavs: list[Path] = field(default_factory=list)
    metas: dict[str, list[Path]] = field(default_factory=dict)
    other_models: list[Path] = field(default_factory=list)      # .fbx/.obj/.glb fournis par l'auteur
    manifest: Path | None = None

    def summary(self) -> dict:
        return {
            "binaires_a_convertir": [str(p.relative_to(self.root)) for p in self.binaries],
            "yft_xml": sorted(self.yft_xml),
            "ydr_xml": sorted(self.ydr_xml),
            "ytd_xml": sorted(self.ytd_xml),
            "awc_xml": [p.name for p in self.awc_xml],
            "textures_dds": len(self.dds),
            "metas": {k: [p.name for p in v] for k, v in self.metas.items()},
            "autres_modeles": [p.name for p in self.other_models],
            "manifest": self.manifest.name if self.manifest else None,
        }


def _strip_ext(name: str, ext: str) -> str:
    return name[: -len(ext)] if name.lower().endswith(ext) else name


def scan(root: Path, include_binaries: bool = True) -> Inventory:
    inv = Inventory(root=root)
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        n = p.name.lower()
        if n.endswith(".yft.xml"):
            inv.yft_xml[_strip_ext(n, ".yft.xml")] = p
        elif n.endswith(".ydr.xml"):
            inv.ydr_xml[_strip_ext(n, ".ydr.xml")] = p
        elif n.endswith(".ytd.xml"):
            inv.ytd_xml[_strip_ext(n, ".ytd.xml")] = p
        elif n.endswith(".awc.xml"):
            inv.awc_xml.append(p)
        elif n.endswith(".rel.xml"):
            inv.rel_xml.append(p)
        elif n.endswith(".dds"):
            key = n[:-4]
            prev = inv.dds.get(key)
            if prev is None or p.stat().st_size > prev.stat().st_size or "+hi" in str(p).lower():
                inv.dds[key] = p
        elif n.endswith((".png", ".jpg", ".jpeg", ".tga", ".bmp")):
            inv.images.setdefault(n.rsplit(".", 1)[0], p)
        elif n.endswith(".wav"):
            inv.wavs.append(p)
        elif n.endswith((".fbx", ".obj", ".glb", ".gltf", ".dae", ".z3d")):
            inv.other_models.append(p)
        elif n in ("fxmanifest.lua", "__resource.lua"):
            inv.manifest = p
        elif n.endswith((".meta", ".xml", ".ymt")):
            el = parse_xml_lenient(p)
            if el is not None and el.tag in META_KINDS:
                inv.metas.setdefault(META_KINDS[el.tag], []).append(p)
        elif include_binaries and n.endswith(RESOURCE_EXT):
            inv.binaries.append(p)
    return inv


def needs_conversion(inv: Inventory) -> bool:
    """Vrai s'il reste des .yft/.ytd binaires sans équivalent XML."""
    for b in inv.binaries:
        n = b.name.lower()
        if n.endswith(".yft") and _strip_ext(n, ".yft") not in inv.yft_xml:
            return True
        if n.endswith(".ytd") and _strip_ext(n, ".ytd") not in inv.ytd_xml:
            return True
        if n.endswith(".rpf"):
            return True
        if n.endswith(".awc") and not inv.awc_xml:
            return True
    return False
