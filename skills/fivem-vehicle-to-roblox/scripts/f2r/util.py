"""Utilitaires communs."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

# --------------------------------------------------------------------------- log

class Report:
    """Collecte les infos / avertissements pour le rapport final (report.md)."""

    def __init__(self) -> None:
        self.infos: list[str] = []
        self.warnings: list[str] = []
        self.manual_steps: list[str] = []

    def info(self, msg: str) -> None:
        self.infos.append(msg)
        print(f"[info] {msg}", file=sys.stderr)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        print(f"[ATTENTION] {msg}", file=sys.stderr)

    def manual(self, msg: str) -> None:
        self.manual_steps.append(msg)


# ------------------------------------------------------------------------- joaat

def joaat(text: str) -> int:
    """Hash Jenkins one-at-a-time utilisé par GTA V (insensible à la casse)."""
    h = 0
    for ch in text.lower().encode("utf-8"):
        h = (h + ch) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h ^= h >> 6
    h = (h + (h << 3)) & 0xFFFFFFFF
    h ^= h >> 11
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h


_KNOWN_NAMES: dict[int, str] = {}


def register_names(names) -> None:
    for n in names:
        _KNOWN_NAMES[joaat(n)] = n


def resolve_hash_name(name: str | None) -> str:
    """Convertit 'hash_C3071C42' en nom connu si possible."""
    if not name:
        return ""
    m = re.fullmatch(r"hash_([0-9A-Fa-f]{8})", name.strip())
    if m:
        return _KNOWN_NAMES.get(int(m.group(1), 16), name.strip())
    return name.strip()


# ------------------------------------------------------------------- archives

ARCHIVE_EXT = (".zip", ".tar", ".tar.gz", ".tgz")


def _safe_target(root: Path, member: str) -> Path | None:
    member = member.replace("\\", "/")
    target = (root / member).resolve()
    if not str(target).startswith(str(root.resolve()) + os.sep) and target != root.resolve():
        return None  # tentative de zip-slip : ignoré
    return target


def extract_archive(archive: Path, dest: Path, report: Report, depth: int = 0) -> None:
    """Extrait un zip/tar (et les archives imbriquées) en se protégeant du zip-slip."""
    dest.mkdir(parents=True, exist_ok=True)
    name = archive.name.lower()
    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                target = _safe_target(dest, info.filename)
                if target is None:
                    report.warn(f"Entrée d'archive ignorée (chemin dangereux) : {info.filename}")
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with zf.open(info) as src, open(target, "wb") as dst:
                    shutil.copyfileobj(src, dst)
    elif name.endswith((".tar", ".tar.gz", ".tgz")):
        with tarfile.open(archive) as tf:
            for m in tf.getmembers():
                if not m.isfile():
                    continue
                target = _safe_target(dest, m.name)
                if target is None:
                    report.warn(f"Entrée d'archive ignorée (chemin dangereux) : {m.name}")
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with tf.extractfile(m) as src, open(target, "wb") as dst:  # type: ignore[union-attr]
                    shutil.copyfileobj(src, dst)
    elif name.endswith((".rar", ".7z")):
        seven = shutil.which("7z") or shutil.which("7za")
        if seven:
            subprocess.run([seven, "x", "-y", f"-o{dest}", str(archive)],
                           stdout=subprocess.DEVNULL, check=False)
        else:
            report.warn(f"Archive {archive.name} : format .rar/.7z non géré sans 7-Zip. "
                        "Ré-emballez en .zip ou installez 7z puis relancez.")
    else:
        raise ValueError(f"Format d'archive inconnu : {archive}")

    if depth < 3:  # archives imbriquées (fréquent : zip contenant le dossier de la ressource + un zip "replace")
        for nested in list(dest.rglob("*")):
            if nested.is_file() and nested.name.lower().endswith(ARCHIVE_EXT + (".rar", ".7z")):
                sub = nested.with_name(nested.name + "_extrait")
                try:
                    extract_archive(nested, sub, report, depth + 1)
                except Exception as exc:  # noqa: BLE001
                    report.warn(f"Archive imbriquée illisible {nested.name} : {exc}")


# ------------------------------------------------------------------------- XML

def parse_xml_lenient(path: Path) -> ET.Element | None:
    """Les .meta de mods sont souvent mal formés (BOM, & non échappés, balises dupliquées)."""
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "utf-16", "latin-1"):
        try:
            text = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    else:
        return None
    text = text.lstrip("﻿").strip()
    attempts = [
        text,
        re.sub(r"&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)", "&amp;", text),
    ]
    # Supprime une éventuelle seconde déclaration XML / texte parasite après la racine
    attempts.append(re.sub(r"<\?xml[^>]*\?>", "", attempts[1]).strip())
    for candidate in attempts:
        try:
            return ET.fromstring(candidate)
        except ET.ParseError:
            continue
    return None


def xval(el: ET.Element | None, tag: str, default=None):
    """Lit <tag value="x"/> ou <tag>x</tag>."""
    if el is None:
        return default
    child = el.find(tag)
    if child is None:
        return default
    if "value" in child.attrib:
        return child.attrib["value"]
    if child.text is not None and child.text.strip():
        return child.text.strip()
    return default


def xfloat(el, tag, default=0.0) -> float:
    v = xval(el, tag)
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def xvec(el, tag, default=(0.0, 0.0, 0.0, 0.0)):
    if el is None:
        return list(default)
    child = el.find(tag)
    if child is None:
        return list(default)
    out = []
    for i, k in enumerate(("x", "y", "z", "w")):
        if k in child.attrib:
            out.append(float(child.attrib[k]))
        elif i < len(default):
            out.append(float(default[i]))
    return out


def element_to_obj(el: ET.Element):
    """Conversion générique XML -> dict/list/valeur (pour exporter handling/carcols tels quels)."""
    children = list(el)
    attrs = dict(el.attrib)
    if not children:
        if "value" in attrs and len(attrs) == 1:
            return _num(attrs["value"])
        if attrs and set(attrs) <= {"x", "y", "z", "w"}:
            return [_num(attrs[k]) for k in ("x", "y", "z", "w") if k in attrs]
        text = (el.text or "").strip()
        if attrs.get("content") in ("char_array", "int_array", "float_array", "short_array"):
            return [_num(t) for t in text.split()]
        return _num(text) if text else (attrs or "")
    if all(c.tag == "Item" for c in children):
        return [element_to_obj(c) for c in children]
    out: dict = {}
    for c in children:
        val = element_to_obj(c)
        if c.tag in out:
            if not isinstance(out[c.tag], list) or not out.get("__multi_" + c.tag):
                out[c.tag] = [out[c.tag]]
                out["__multi_" + c.tag] = True
            out[c.tag].append(val)
        else:
            out[c.tag] = val
    for k in [k for k in out if k.startswith("__multi_")]:
        del out[k]
    if el.attrib.get("type"):
        out["_type"] = el.attrib["type"]
    return out


def _num(s: str):
    s = s.strip()
    if s.lower() in ("true", "false"):
        return s.lower() == "true"
    try:
        if s.lower().startswith("0x"):
            return int(s, 16)
        if re.fullmatch(r"-?\d+", s):
            return int(s)
        return float(s)
    except ValueError:
        return s


def argb_hex_to_rgb(value) -> list[float] | None:
    """'0xFFFF7300' -> [1.0, 0.45, 0.0]"""
    if value is None:
        return None
    try:
        v = int(str(value), 16) if isinstance(value, str) else int(value)
    except ValueError:
        return None
    return [((v >> 16) & 255) / 255.0, ((v >> 8) & 255) / 255.0, (v & 255) / 255.0]


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
