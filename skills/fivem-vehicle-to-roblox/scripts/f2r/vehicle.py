"""Assemblage d'un véhicule GTA V en pièces prêtes pour Roblox.

Repère local utilisé partout en sortie (identique à Roblox, en MÈTRES) :
    X = droite du véhicule, Y = haut, Z = arrière   (l'avant est donc -Z, comme LookVector)
Repère GTA : X = droite, Y = avant, Z = haut  ->  local = (x, z, -y)
"""
from __future__ import annotations

import math
import re
from dataclasses import dataclass, field

import numpy as np

from .cwxml import Bone, Drawable, Fragment, Shader
from .util import Report

GTA2L = np.array([[1.0, 0.0, 0.0], [0.0, 0.0, 1.0], [0.0, -1.0, 0.0]])

# ID de lumière = canal alpha de Colour0 sur le shader vehicle_lightsemissive (cf. Sollumz)
LIGHT_IDS = {
    0: "always_on", 1: "headlight_l", 2: "headlight_r", 3: "taillight_l", 4: "taillight_r",
    5: "indicator_lf", 6: "indicator_rf", 7: "indicator_lr", 8: "indicator_rr",
    9: "brakelight_l", 10: "brakelight_r", 11: "brakelight_m",
    12: "reversinglight_l", 13: "reversinglight_r",
    14: "extralight_1", 15: "extralight_2", 16: "extralight_3", 17: "extralight_4",
}
LIGHT_BONES = [v for k, v in LIGHT_IDS.items() if k > 0]

# Couche de peinture = matDiffuseColor (x == 2, y == z == id) (cf. Sollumz)
PAINT_LAYERS = {1: "Primary", 2: "Secondary", 3: "Pearlescent", 4: "Wheel", 5: "Default",
                6: "InteriorTrim", 7: "Dashboard"}

WHEEL_BONES = ["wheel_lf", "wheel_rf", "wheel_lm1", "wheel_rm1", "wheel_lm2", "wheel_rm2",
               "wheel_lm3", "wheel_rm3", "wheel_lr", "wheel_rr"]
DOOR_BONES = ["door_dside_f", "door_pside_f", "door_dside_r", "door_pside_r"]
HINGED_BONES = DOOR_BONES + ["bonnet", "boot", "boot_2"]
STEERING_BONES = ["steeringwheel", "steering_wheel", "steeringw"]
SEAT_BONES = ["seat_dside_f", "seat_pside_f", "seat_dside_r", "seat_pside_r",
              "seat_dside_r1", "seat_pside_r1", "seat_dside_r2", "seat_pside_r2"]
WINDOW_RE = re.compile(r"^window_[lr][fmr]\d?$|^windscreen(_r)?$")
EXTRA_RE = re.compile(r"^extra_(\d+)$")
SIREN_RE = re.compile(r"^siren(\d+)$")
SIREN_GLASS_RE = re.compile(r"^siren_glass(\d+)$")


@dataclass
class Part:
    name: str
    bone: str
    owner: str
    shader: Shader
    kind: str
    paint: str | None
    custom_color: list[float] | None
    light: str | None
    pos: np.ndarray
    nrm: np.ndarray
    uv: np.ndarray
    idx: np.ndarray
    livery: bool = False
    mod: dict | None = None
    extra: int | None = None
    window: str | None = None
    siren: int | None = None
    tex_diffuse: str | None = None
    tex_normal: str | None = None
    tex_livery: list[str] = field(default_factory=list)

    @property
    def tri_count(self) -> int:
        return len(self.idx) // 3

    def bbox(self):
        return self.pos.min(axis=0), self.pos.max(axis=0)

    def center(self) -> np.ndarray:
        lo, hi = self.bbox()
        return (lo + hi) / 2


# ------------------------------------------------------------------ squelette

def quat_to_mat(q) -> np.ndarray:
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def compute_world(bones: list[Bone]) -> dict[int, np.ndarray]:
    by_index = {b.index: b for b in bones}
    cache: dict[int, np.ndarray] = {}

    def world(i: int, depth=0) -> np.ndarray:
        if i in cache:
            return cache[i]
        b = by_index[i]
        local = np.eye(4)
        local[:3, :3] = quat_to_mat(b.rotation) @ np.diag(b.scale)
        local[:3, 3] = b.translation
        if b.parent >= 0 and b.parent in by_index and depth < 256:
            m = world(b.parent, depth + 1) @ local
        else:
            m = local
        cache[i] = m
        return m

    for b in bones:
        b.world = world(b.index)
    return cache


class Skeleton:
    def __init__(self, bones: list[Bone]):
        self.bones = bones
        self.worlds = compute_world(bones) if bones else {}
        self.by_index = {b.index: b for b in bones}
        self.by_name = {b.name: b for b in bones}
        self.by_tag = {b.tag: b for b in bones}
        self.root_name = bones[0].name if bones else "chassis"

    def name_of(self, idx: int) -> str:
        b = self.by_index.get(int(idx))
        return b.name if b else self.root_name

    def parent_name(self, name: str) -> str | None:
        b = self.by_name.get(name)
        if not b or b.parent < 0:
            return None
        p = self.by_index.get(b.parent)
        return p.name if p else None

    def ancestors(self, name: str):
        cur = name
        seen = 0
        while cur is not None and seen < 256:
            yield cur
            cur = self.parent_name(cur)
            seen += 1

    def world_pos_local(self, name: str) -> np.ndarray | None:
        b = self.by_name.get(name)
        if b is None or b.world is None:
            return None
        return GTA2L @ b.world[:3, 3]

    def world_axes_local(self, name: str) -> np.ndarray:
        """Axes X/Y/Z de l'os (colonnes) exprimés dans le repère local Roblox."""
        b = self.by_name.get(name)
        if b is None or b.world is None:
            return np.eye(3)
        r = b.world[:3, :3]
        r = r / np.maximum(np.linalg.norm(r, axis=0), 1e-9)
        return GTA2L @ r


# ------------------------------------------------------------------ shaders

def classify_shader(sh: Shader) -> tuple[str, str | None, list[float] | None]:
    """-> (kind, paint_layer, custom_color)"""
    n = sh.name
    if "lightsemissive_siren" in n:
        kind = "siren"
    elif "lightsemissive" in n or n == "vehicle_lights":
        kind = "light"
    elif "vehglass" in n:
        kind = "glass"
    elif "tire" in n or "track" in n:
        kind = "tire"
    elif "licenseplate" in n:
        kind = "plate"
    elif "badges" in n or "decal" in n:
        kind = "decal"
    elif "emissive" in n:
        kind = "emissive"
    elif "paint" in n:
        kind = "paint"
    elif "interior" in n:
        kind = "interior"
    elif "blurredrotor" in n:
        kind = "rotor"
    else:
        kind = "mesh"
    paint = None
    custom = None
    md = sh.vectors.get("matDiffuseColor")
    if md is not None:
        if abs(md[0] - 2.0) < 1e-3 and abs(md[1] - md[2]) < 1e-3 and int(round(md[1])) in PAINT_LAYERS:
            paint = PAINT_LAYERS[int(round(md[1]))]
        else:
            custom = [max(0.0, min(1.0, c)) for c in md[:3]]
    return kind, paint, custom


def shader_textures(sh: Shader) -> tuple[str | None, str | None, str | None]:
    diffuse = normal = livery = None
    for k, v in sh.textures.items():
        kl = k.lower()
        if kl in ("diffusesampler", "platebgsampler", "diffusetex") and not diffuse:
            diffuse = v
        elif kl in ("bumpsampler", "platebgbumpsampler", "bumptex") and not normal:
            normal = v
        elif kl in ("diffusesampler2", "diffuseextrasampler", "diffusetex2") and not livery:
            livery = v
    if diffuse is None:
        for k, v in sh.textures.items():
            if "diffuse" in k.lower() or "texturesampler" == k.lower():
                diffuse = v
                break
    return diffuse, normal, livery


# ------------------------------------------------------------------ géométrie

def _geometry_vertices(model, geom, skel: Skeleton, forced_bone: str | None):
    a = geom.attrs
    P = a["Position"][:, :3].astype(np.float64)
    N = a["Normal"][:, :3].astype(np.float64) if "Normal" in a else np.zeros_like(P)
    nv = len(P)
    if forced_bone is not None:
        b = skel.by_name.get(forced_bone)
        M = skel.worlds.get(b.index) if b else np.eye(4)
        vb = np.array([forced_bone] * nv, dtype=object)
        P = (M[:3, :3] @ P.T).T + M[:3, 3]
        N = (M[:3, :3] @ N.T).T
    elif model.has_skin and "BlendIndices" in a:
        bi = a["BlendIndices"].astype(int)
        bw = a.get("BlendWeights")
        k = np.argmax(bw, axis=1) if bw is not None and bw.shape == bi.shape else np.zeros(nv, int)
        local = bi[np.arange(nv), k]
        if geom.bone_ids:
            ids = np.array(geom.bone_ids)
            local = np.where(local < len(ids), ids[np.clip(local, 0, len(ids) - 1)], local)
        vb = np.array([skel.name_of(i) for i in local], dtype=object)
    else:
        M = skel.worlds.get(model.bone_index, np.eye(4))
        P = (M[:3, :3] @ P.T).T + M[:3, 3]
        N = (M[:3, :3] @ N.T).T
        vb = np.array([skel.name_of(model.bone_index)] * nv, dtype=object)
    P = P @ GTA2L.T
    N = N @ GTA2L.T
    lens = np.linalg.norm(N, axis=1, keepdims=True)
    N = np.where(lens > 1e-8, N / np.maximum(lens, 1e-8), np.array([0.0, 1.0, 0.0]))
    uv0 = a["TexCoord0"][:, :2] if "TexCoord0" in a else np.zeros((nv, 2))
    uv1 = a["TexCoord1"][:, :2] if "TexCoord1" in a else None
    col = a.get("Colour0")
    return P, N, uv0, uv1, col, vb


@dataclass
class _Bucket:
    shader: Shader
    kind: str
    paint: str | None
    custom: list | None
    light: str | None
    group_bone: str
    pos: list = field(default_factory=list)
    nrm: list = field(default_factory=list)
    uv: list = field(default_factory=list)
    idx: list = field(default_factory=list)
    count: int = 0
    livery: bool = False

    def add(self, P, N, UV, tris):
        used, inv = np.unique(tris.ravel(), return_inverse=True)
        self.pos.append(P[used])
        self.nrm.append(N[used])
        self.uv.append(UV[used])
        self.idx.append(inv.reshape(-1).astype(np.int64) + self.count)
        self.count += len(used)


class VehicleBuilder:
    def __init__(self, frag: Fragment, report: Report, *, max_tris: int = 19000,
                 keep_bones: set[str] | None = None, livery_uv: str = "auto"):
        self.frag = frag
        self.report = report
        self.max_tris = max_tris
        self.skel = Skeleton(frag.main.bones)
        self.keep = set(keep_bones or set())
        self.livery_uv = livery_uv
        self.parts: list[Part] = []
        self._names: set[str] = set()
        self.has_bone = lambda n: n in self.skel.by_name

        for b in self.skel.bones:
            n = b.name
            if (n in WHEEL_BONES or n in HINGED_BONES or n in STEERING_BONES or WINDOW_RE.match(n)
                    or EXTRA_RE.match(n) or SIREN_RE.match(n) or SIREN_GLASS_RE.match(n)):
                self.keep.add(n)

    # -- hiérarchie
    def owner_of(self, bone: str) -> str:
        for a in self.skel.ancestors(bone):
            if a in WHEEL_BONES or a in HINGED_BONES or a in STEERING_BONES or SIREN_RE.match(a):
                return a
        return self.skel.root_name

    def group_of(self, bone: str) -> str:
        for a in self.skel.ancestors(bone):
            if a in self.keep:
                return a
        return self.skel.root_name

    def _unique(self, base: str) -> str:
        base = re.sub(r"[^A-Za-z0-9_]+", "_", base)[:90]
        name, i = base, 2
        while name in self._names:
            name = f"{base}_{i}"
            i += 1
        self._names.add(name)
        return name

    # -- extraction
    def collect(self, drawable: Drawable, skel: Skeleton | None = None, *, forced_bone: str | None = None,
                mod: dict | None = None, shaders: list[Shader] | None = None,
                offset: np.ndarray | None = None, bone_remap=None) -> list[Part]:
        skel = skel or self.skel
        shaders = shaders or drawable.shaders
        buckets: dict[tuple, _Bucket] = {}
        for model in drawable.models:
            for geom in model.geometries:
                if len(geom.indices) < 3:
                    continue
                if geom.shader_index >= len(shaders):
                    self.report.warn(f"{drawable.name}: shader {geom.shader_index} introuvable, ignoré")
                    continue
                sh = shaders[geom.shader_index]
                kind, paint, custom = classify_shader(sh)
                P, N, uv0, uv1, col, vb = _geometry_vertices(model, geom, skel, forced_bone)
                if offset is not None:
                    P = P + offset
                if bone_remap is not None:
                    vb = np.array([bone_remap(b) for b in vb], dtype=object)
                _, _, tex_livery = shader_textures(sh)
                livery = bool(tex_livery)
                uv = uv0
                if livery and (self.livery_uv == "uv1" or (self.livery_uv == "auto" and uv1 is not None)):
                    uv = uv1 if uv1 is not None else uv0
                tris = geom.indices[: len(geom.indices) // 3 * 3].reshape(-1, 3).astype(np.int64)
                tris = tris[(tris < len(P)).all(axis=1)]
                tri_bone = vb[tris[:, 0]]
                if kind == "light":
                    if col is not None and col.shape[1] >= 4:
                        tri_light = np.rint(col[tris[:, 0], 3]).astype(int)
                    else:
                        tri_light = self._nearest_light_ids(P, tris)
                else:
                    tri_light = np.full(len(tris), -1)
                ub, binv = np.unique(tri_bone.astype(str), return_inverse=True)
                groups = np.array([self.group_of(b) if mod is None else b for b in ub], dtype=object)
                tri_group = groups[binv.reshape(-1)]
                combo = np.array([f"{g}|{l}" for g, l in zip(tri_group, tri_light)])
                ukeys, kinv = np.unique(combo, return_inverse=True)
                kinv = kinv.reshape(-1)
                for ki, k in enumerate(ukeys):
                    gb, lid_s = k.rsplit("|", 1)
                    lid = int(lid_s)
                    light = LIGHT_IDS.get(lid, "always_on") if kind == "light" else None
                    key = (gb, id(sh), light)
                    bk = buckets.get(key)
                    if bk is None:
                        bk = buckets[key] = _Bucket(sh, kind, paint, custom, light, gb, livery=livery)
                    bk.add(P, N, uv, tris[kinv == ki])
        out = []
        for bk in buckets.values():
            out.extend(self._bucket_to_parts(bk, mod))
        return out

    def _nearest_light_ids(self, P, tris):
        names = [(lid, self.skel.world_pos_local(n)) for lid, n in LIGHT_IDS.items() if lid > 0]
        names = [(lid, p) for lid, p in names if p is not None]
        if not names:
            return np.zeros(len(tris), int)
        cents = P[tris].mean(axis=1)
        pts = np.array([p for _, p in names])
        d = np.linalg.norm(cents[:, None, :] - pts[None, :, :], axis=2)
        return np.array([names[i][0] for i in np.argmin(d, axis=1)])

    def _bucket_to_parts(self, bk: _Bucket, mod: dict | None) -> list[Part]:
        P = np.concatenate(bk.pos)
        N = np.concatenate(bk.nrm)
        UV = np.concatenate(bk.uv)
        I = np.concatenate(bk.idx)
        tris = I.reshape(-1, 3)
        diffuse, normal, livery_tex = shader_textures(bk.shader)
        parts = []
        chunks = [tris[i:i + self.max_tris] for i in range(0, len(tris), self.max_tris)]
        for ci, ch in enumerate(chunks):
            used, inv = np.unique(ch.ravel(), return_inverse=True)
            label = bk.light if bk.light else bk.shader.name.replace("vehicle_", "") or bk.kind
            base = f"{bk.group_bone}__{label}"
            if mod:
                base = f"mod_{mod['slot']}_{mod['index']}__{base}"
            if len(chunks) > 1:
                base += f"__{ci + 1}"
            gb = bk.group_bone
            m_extra = EXTRA_RE.match(gb)
            m_siren = SIREN_RE.match(gb) or SIREN_GLASS_RE.match(gb)
            parts.append(Part(
                name=self._unique(base), bone=gb,
                owner=self.owner_of(gb) if self.has_bone(gb) else self.skel.root_name,
                shader=bk.shader, kind=bk.kind, paint=bk.paint, custom_color=bk.custom, light=bk.light,
                pos=P[used].astype(np.float32), nrm=N[used].astype(np.float32),
                uv=UV[used].astype(np.float32), idx=inv.reshape(-1).astype(np.uint32),
                livery=bk.livery, mod=mod,
                extra=int(m_extra.group(1)) if m_extra else None,
                window=gb if WINDOW_RE.match(gb) else None,
                siren=int(m_siren.group(1)) if m_siren else None,
                tex_diffuse=diffuse, tex_normal=normal,
                tex_livery=[livery_tex] if livery_tex else [],
            ))
        return parts

    # -- étapes
    def build_main(self):
        self.parts.extend(self.collect(self.frag.main))
        bones_with_geo = {p.bone for p in self.parts}
        for child in self.frag.children:
            b = self.skel.by_tag.get(child.bone_tag)
            if b is None:
                continue
            if b.name in bones_with_geo and b.name not in WHEEL_BONES:
                continue  # déjà présent dans le drawable principal
            shaders = child.shaders or self.frag.main.shaders
            self.parts.extend(self.collect(child, forced_bone=b.name, shaders=shaders))

    def instance_wheels(self, rear_scale: float = 1.0):
        by_owner: dict[str, list[Part]] = {}
        for p in self.parts:
            if p.owner in WHEEL_BONES and p.mod is None:
                by_owner.setdefault(p.owner, []).append(p)
        if not by_owner:
            self.report.warn("Aucune géométrie de roue trouvée (wheel_lf). Les roues seront absentes.")
            return
        front_src = "wheel_lf" if "wheel_lf" in by_owner else next(iter(by_owner))
        rear_src = "wheel_lr" if "wheel_lr" in by_owner else front_src
        for wb in WHEEL_BONES:
            if wb not in self.skel.by_name or wb in by_owner:
                continue
            is_front = wb in ("wheel_lf", "wheel_rf")
            src = front_src if is_front else rear_src
            scale = rear_scale if (not is_front and src == front_src) else 1.0
            src_c = self.skel.world_pos_local(src)
            dst_c = self.skel.world_pos_local(wb)
            flip = ("_l" in src) != ("_l" in wb)
            for sp in by_owner[src]:
                P = (sp.pos.astype(np.float64) - src_c) * scale
                N = sp.nrm.astype(np.float64)
                if flip:  # rotation de 180° autour de l'axe vertical
                    P = P * np.array([-1.0, 1.0, -1.0])
                    N = N * np.array([-1.0, 1.0, -1.0])
                P = P + dst_c
                self.parts.append(Part(
                    name=self._unique(sp.name.replace(src, wb, 1)), bone=wb, owner=wb, shader=sp.shader,
                    kind=sp.kind, paint=sp.paint, custom_color=sp.custom_color, light=None,
                    pos=P.astype(np.float32), nrm=N.astype(np.float32), uv=sp.uv.copy(), idx=sp.idx.copy(),
                    tex_diffuse=sp.tex_diffuse, tex_normal=sp.tex_normal,
                ))
        self.report.info(f"Roues : géométrie source {front_src}/{rear_src}, instanciée sur "
                         f"{[w for w in WHEEL_BONES if w in self.skel.by_name]}")

    def add_mod(self, frag: Fragment, mod: dict, attach_bone: str):
        mskel = Skeleton(frag.main.bones) if frag.main.bones else self.skel
        attach = attach_bone if attach_bone in self.skel.by_name else self.skel.root_name

        def remap(name):
            return name if name in self.skel.by_name and name != self.skel.root_name else attach
        parts = self.collect(frag.main, mskel, mod=mod, bone_remap=remap)
        for child in frag.children:
            b = mskel.by_tag.get(child.bone_tag)
            parts.extend(self.collect(child, mskel, forced_bone=b.name if b else None, mod=mod,
                                      shaders=child.shaders or frag.main.shaders, bone_remap=remap))
        if not parts:
            return 0
        # Heuristique : si la pièce a été modélisée relativement à son os d'attache, on la replace.
        body = [p for p in self.parts if p.mod is None]
        if body:
            lo = np.min([p.bbox()[0] for p in body], axis=0) - 0.75
            hi = np.max([p.bbox()[1] for p in body], axis=0) + 0.75
            c = np.mean([p.center() for p in parts], axis=0)
            bone_pos = self.skel.world_pos_local(attach)
            if np.any(c < lo) or np.any(c > hi):
                if bone_pos is not None and np.linalg.norm(bone_pos) > 0.05:
                    for p in parts:
                        p.pos = (p.pos + bone_pos).astype(np.float32)
                    self.report.warn(f"Mod {mod['model']} : géométrie hors carrosserie, recalée sur l'os {attach}.")
        self.parts.extend(parts)
        return len(parts)

    # -- infos pour la config Roblox
    def bounds(self):
        body = [p for p in self.parts if p.mod is None]
        lo = np.min([p.bbox()[0] for p in body], axis=0)
        hi = np.max([p.bbox()[1] for p in body], axis=0)
        return lo, hi

    def wheel_info(self) -> dict:
        out = {}
        for wb in WHEEL_BONES:
            c = self.skel.world_pos_local(wb)
            if c is None:
                continue
            geo = [p for p in self.parts if p.owner == wb and p.mod is None]
            radius = width = 0.0
            if geo:
                P = np.concatenate([p.pos for p in geo]).astype(np.float64) - c
                radius = float(np.max(np.sqrt(P[:, 1] ** 2 + P[:, 2] ** 2)))
                width = float(P[:, 0].max() - P[:, 0].min())
            out[wb] = {"Position": c.round(4).tolist(), "Radius": round(radius, 4), "Width": round(width, 4),
                       "Front": wb in ("wheel_lf", "wheel_rf"), "Left": "_l" in wb,
                       "Steer": wb in ("wheel_lf", "wheel_rf")}
        return out

    def hinge_info(self, defaults: dict[str, float]) -> dict:
        out = {}
        for hb in HINGED_BONES:
            if hb not in self.skel.by_name:
                continue
            pivot = self.skel.world_pos_local(hb)
            axes = self.skel.world_axes_local(hb)
            geo = [p for p in self.parts if p.owner == hb and p.mod is None]
            if not geo:
                continue
            center = np.mean([p.center() for p in geo], axis=0)
            if hb.startswith("door"):
                axis = axes[:, 2]  # Z de l'os (vertical)
                side = 1.0 if (center[0] if abs(center[0]) > 1e-3 else pivot[0]) >= 0 else -1.0
                # la portière doit s'écarter vers l'extérieur du véhicule (et non traverser l'habitacle)
                test = lambda v: side * (pivot[0] + v[0]) - side * center[0]  # noqa: E731
            else:
                axis = axes[:, 0]  # X de l'os (latéral)
                test = lambda v: v[1] - (center - pivot)[1]  # noqa: E731
            axis = axis / (np.linalg.norm(axis) or 1.0)
            moved = _rotate(center - pivot, axis, 0.6)
            sign = 1.0 if test(moved) >= 0 else -1.0
            out[hb] = {"Pivot": pivot.round(4).tolist(), "Axis": (axis * sign).round(5).tolist(),
                       "OpenAngle": defaults.get(hb.split("_")[0] if hb.startswith("door") else hb, 60.0)}
        return out

    def bones_info(self) -> dict:
        out = {}
        for b in self.skel.bones:
            p = self.skel.world_pos_local(b.name)
            ax = self.skel.world_axes_local(b.name)
            out[b.name] = {"Position": p.round(4).tolist(),
                           "Parent": self.skel.parent_name(b.name),
                           "Right": ax[:, 0].round(4).tolist(), "Up": ax[:, 2].round(4).tolist(),
                           "Forward": ax[:, 1].round(4).tolist()}
        return out


def _rotate(v, axis, angle):
    k = axis
    return v * math.cos(angle) + np.cross(k, v) * math.sin(angle) + k * np.dot(k, v) * (1 - math.cos(angle))
