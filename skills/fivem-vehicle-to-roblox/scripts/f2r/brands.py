"""Marques : reconnaître la marque réelle d'un mod et la remplacer par la marque du jeu.

Table : ``brands/brands.json`` du skill (ou ``--brands <json>``). Une marque réelle n'apparaît jamais
dans le véhicule converti : nom de marque, nom de modèle, logos (voir ``rebadge.py``).
"""
from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

DEFAULT_TABLE = Path(__file__).resolve().parents[2] / "brands" / "brands.json"
YEAR = re.compile(r"^(19|20)\d\d$")


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", s)


def tokens(s: str) -> list[str]:
    """'bmw_2022_bmw_m4_competition' -> [bmw, 2022, bmw, m4, competition] ; 'GT-R' reste un mot."""
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode()
    return [t for t in re.split(r"[\s_./\\()\[\]]+", s) if t]


@dataclass
class Brand:
    brolver: str
    slug: str
    real: list[str]
    aliases: list[str]
    models: dict
    labels: dict
    logo: Path | None
    avoid: str = ""


@dataclass
class Naming:
    brand: Brand | None
    real_make: str          # ce qui a été reconnu (pour le rapport seulement, jamais dans Roblox)
    found_in: str           # 'vehicles.meta', 'nom du dossier'…
    model: str              # nom de modèle du jeu
    model_provisional: bool  # True : à confirmer (mot non traduisible automatiquement)
    real_model: str


class BrandTable:
    def __init__(self, path: Path | None = None):
        path = Path(path) if path else DEFAULT_TABLE
        doc = json.loads(path.read_text(encoding="utf-8"))
        self.path = path
        self.generic = {g.lower() for g in doc.get("generic_words", [])}
        self.brands: list[Brand] = []
        for r in doc["brands"]:
            logo = (path.parent / r["logo"]) if r.get("logo") else None
            self.brands.append(Brand(r["brolver"], r["slug"], r["real"], r.get("aliases", []),
                                     r.get("models", {}), r.get("labels", {}),
                                     logo if logo and logo.exists() else None, r.get("avoid", "")))
        self._by_alias: dict[str, Brand] = {}
        for b in self.brands:
            for a in [*b.real, *b.aliases]:
                self._by_alias.setdefault(norm(a), b)
        self._own = {norm(b.brolver): b for b in self.brands}

    def lookup(self, name: str) -> Brand | None:
        n = norm(name)
        return self._by_alias.get(n) if n else None

    def is_own(self, name: str) -> Brand | None:
        return self._own.get(norm(name))

    def find_in_tokens(self, toks: list[str]) -> tuple[Brand, int, int] | None:
        """Cherche une marque (1 à 3 mots consécutifs) ; renvoie (marque, début, fin)."""
        low = [norm(t) for t in toks]
        for size in (3, 2, 1):
            for i in range(len(low) - size + 1):
                b = self._by_alias.get("".join(low[i:i + size]))
                if b and (size > 1 or len(low[i]) >= 2):
                    return b, i, i + size
        return None

    # ------------------------------------------------------------------ nom de modèle

    def rename_model(self, brand: Brand | None, words: list[str]) -> tuple[str, bool]:
        """Traduit les mots du modèle réel : table de la marque, labels sportifs, mots génériques,
        désignations lettres+chiffres décalées (M4 -> N4), nombres +30 (911 -> 941). Un mot inconnu
        (Mustang, Supra…) ne peut pas être traduit sans l'utilisateur : il est remplacé par « ??? »."""
        models = {norm(k): v for k, v in (brand.models if brand else {}).items()}
        labels = {norm(k): v for k, v in (brand.labels if brand else {}).items()}
        out: list[str] = []
        provisional = False
        i = 0
        while i < len(words):
            # désignations sur deux mots (« Range Rover », « Type R »)
            two = norm(words[i] + (words[i + 1] if i + 1 < len(words) else ""))
            if i + 1 < len(words) and (two in models or two in labels):
                out.append(models.get(two) or labels[two])
                i += 2
                continue
            w = words[i]
            n = norm(w)
            i += 1
            if not n:
                continue
            if n in models:
                out.append(models[n])
            elif n in labels:
                out.append(labels[n])
            elif n in self.generic:
                out.append(w.upper() if len(n) <= 3 else w.capitalize())
            else:
                m = re.match(r"^([A-Za-z]+)(-?)(\d+[A-Za-z]*)$", w)
                if m:
                    pre, dash, num = m.groups()
                    if norm(pre) in labels:
                        out.append(labels[norm(pre)] + dash + num.upper())
                    else:
                        out.append(_shift(pre).upper() + dash + num.upper())
                elif re.fullmatch(r"\d+", w):
                    out.append(str(int(w) + 30))
                else:
                    out.append("???")
                    provisional = True
        return " ".join(out).strip(), provisional


def _shift(letters: str) -> str:
    c = letters[0].upper()
    nxt = "A" if c == "Z" else chr(ord(c) + 1)
    return nxt + letters[1:]


def resolve(table: BrandTable, vinfo: dict, hints: list[str], forced_brand: str | None = None,
            forced_model: str | None = None) -> Naming:
    """Marque réelle -> marque du jeu, et nom de modèle traduit.

    Ordre : ``--brand`` ; ``vehicleMakeName`` de vehicles.meta ; noms de dossier / d'archive / gameName."""
    brand: Brand | None = None
    real_make, found_in = "", ""
    words: list[str] = []
    if forced_brand:
        brand = table.is_own(forced_brand) or table.lookup(forced_brand)
        real_make, found_in = forced_brand, "--brand"
    make = vinfo.get("make") or ""
    if brand is None and make:
        brand = table.lookup(make) or table.is_own(make)
        if brand:
            real_make, found_in = make, "vehicles.meta (vehicleMakeName)"
    # mots du modèle : premier indice qui contient la marque (dossier « bmw_2022_bmw_m4_competition »)
    for h in hints:
        toks = tokens(h)
        hit = table.find_in_tokens(toks)
        if hit is None:
            continue
        b, s, e = hit
        if brand is None:
            brand, real_make, found_in = b, " ".join(toks[s:e]), f"nom « {h} »"
        if b is brand:
            rest = [t for j, t in enumerate(toks) if not (s <= j < e)]
            rest = [t for t in rest if not YEAR.match(t) and not table.lookup(t)]
            if rest:
                words = rest
                break
    if not words and brand is not None and hints:
        # marque connue par vehicles.meta, absente du nom de dossier (« mustang_gt_2018 »)
        words = [t for t in tokens(hints[0]) if not YEAR.match(t) and not table.lookup(t)]
    if not words:
        gn = vinfo.get("gameName") or ""
        gn = re.sub(r"^(19|20)\d\d", "", gn)
        words = [w for w in re.findall(r"[A-Z]+[a-z]*|\d+|[a-z]+", gn) if not table.lookup(w)] if gn else []
    real_model = " ".join(words)
    if forced_model:
        return Naming(brand, real_make, found_in, forced_model, False, real_model)
    model, provisional = table.rename_model(brand, words)
    if not model:
        model, provisional = "???", True
    return Naming(brand, real_make, found_in, model, provisional, real_model)
