#!/usr/bin/env python3
"""Génère un faux véhicule FiveM ("testcar") au format XML CodeWalker + metas + DDS + WAV,
pour tester le pipeline sans contenu Rockstar. Usage : python make_fixture.py <dossier_sortie>"""
from __future__ import annotations

import math
import sys
import wave
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

# os : (nom, parent, translation GTA x(droite) y(avant) z(haut))
BONES = [
    ("chassis", -1, (0, 0, 0)),
    ("bodyshell", 0, (0, 0, 0)),
    ("wheel_lf", 0, (-0.8, 1.3, -0.2)),
    ("wheel_rf", 0, (0.8, 1.3, -0.2)),
    ("wheel_lr", 0, (-0.8, -1.3, -0.2)),
    ("wheel_rr", 0, (0.8, -1.3, -0.2)),
    ("door_dside_f", 0, (-0.9, 0.6, 0.2)),
    ("door_pside_f", 0, (0.9, 0.6, 0.2)),
    ("bonnet", 0, (0, 0.9, 0.45)),
    ("boot", 0, (0, -1.6, 0.5)),
    ("headlight_l", 0, (-0.6, 2.1, 0.1)),
    ("headlight_r", 0, (0.6, 2.1, 0.1)),
    ("taillight_l", 0, (-0.6, -2.1, 0.2)),
    ("taillight_r", 0, (0.6, -2.1, 0.2)),
    ("indicator_lf", 0, (-0.75, 2.05, 0.05)),
    ("indicator_rf", 0, (0.75, 2.05, 0.05)),
    ("brakelight_l", 0, (-0.5, -2.1, 0.25)),
    ("brakelight_r", 0, (0.5, -2.1, 0.25)),
    ("seat_dside_f", 0, (-0.4, 0.0, 0.1)),
    ("steeringwheel", 0, (-0.4, 0.5, 0.5)),
    ("extra_1", 0, (0, 0, 0.9)),
    ("misc_a", 0, (0, -2.0, 0.6)),
    ("platelight", 0, (0, -2.2, 0.0)),
    ("engine", 0, (0, 1.4, 0.2)),
]
TAGS = {n: 1000 + i for i, (n, _, _) in enumerate(BONES)}


def box(cx, cy, cz, sx, sy, sz):
    """Boîte (positions GTA) -> (P, N, triangles) avec faces CCW vues de l'extérieur."""
    P, N, T = [], [], []
    faces = [((1, 0, 0), (0, 1, 0), (0, 0, 1)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
             ((0, 1, 0), (0, 0, 1), (1, 0, 0)), ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
             ((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (0, 1, 0), (1, 0, 0))]
    half = np.array([sx, sy, sz]) / 2
    for n, u, v in faces:
        n, u, v = map(np.array, (n, u, v))
        base = len(P)
        for du, dv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            P.append(np.array([cx, cy, cz]) + (n + u * du + v * dv) * half)
            N.append(n)
        T += [(base, base + 1, base + 2), (base, base + 2, base + 3)]
    return np.array(P), np.array(N, float), T


def cylinder_x(radius, width, seg=16):
    P, N, T = [], [], []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        y, z = math.cos(a) * radius, math.sin(a) * radius
        for x in (-width / 2, width / 2):
            P.append((x, y, z))
            N.append((0, math.cos(a), math.sin(a)))
    for i in range(seg):
        a0, a1 = 2 * i, 2 * ((i + 1) % seg)
        T += [(a0, a1, a1 + 1), (a0, a1 + 1, a0 + 1)]
    return np.array(P, float), np.array(N, float), T


def vertex_rows(P, N, bone_local=None, colour=None, uv=None, skinned=True):
    rows = []
    for i, (p, n) in enumerate(zip(P, N)):
        parts = [f"{p[0]:.5f} {p[1]:.5f} {p[2]:.5f}"]
        if skinned:
            parts.append("255 0 0 0")
            parts.append(f"{bone_local[i]} 0 0 0")
        parts.append(f"{n[0]:.5f} {n[1]:.5f} {n[2]:.5f}")
        c = colour[i] if colour is not None else (255, 255, 255, 255)
        parts.append(" ".join(str(int(x)) for x in c))
        t = uv[i] if uv is not None else ((p[0] + 1) / 2, (p[1] + 2) / 4)
        parts.append(f"{t[0]:.5f} {t[1]:.5f}")
        parts.append(f"{t[0]:.5f} {t[1]:.5f}")
        rows.append("   ".join(parts))
    return rows


def geometry_xml(shader_index, P, N, tris, bone_ids, bone_local, colour=None, skinned=True):
    layout = ["Position"] + (["BlendWeights", "BlendIndices"] if skinned else []) + \
             ["Normal", "Colour0", "TexCoord0", "TexCoord1"]
    rows = vertex_rows(P, N, bone_local, colour, skinned=skinned)
    idx = " ".join(str(i) for t in tris for i in t)
    lay = "".join(f"<{l} />" for l in layout)
    bid = f"<BoneIDs>{', '.join(map(str, bone_ids))}</BoneIDs>" if skinned else ""
    return (f"<Item><ShaderIndex value=\"{shader_index}\" />{bid}<VertexBuffer><Flags value=\"0\" />"
            f"<Layout type=\"GTAV1\">{lay}</Layout><Data>\n" + "\n".join(rows) +
            f"\n</Data></VertexBuffer><IndexBuffer><Data>{idx}</Data></IndexBuffer></Item>")


def shader(name, textures=None, diffuse_color=None):
    params = ""
    for k, v in (textures or {}).items():
        params += f"<Item name=\"{k}\" type=\"Texture\"><Name>{v}</Name></Item>"
    if diffuse_color:
        x, y, z = diffuse_color
        params += f"<Item name=\"matDiffuseColor\" type=\"Vector\" x=\"{x}\" y=\"{y}\" z=\"{z}\" w=\"1\" />"
    return f"<Item><Name>{name}</Name><FileName>{name}.sps</FileName><RenderBucket value=\"0\" /><Parameters>{params}</Parameters></Item>"


def skeleton_xml(bones):
    items = ""
    for i, (n, parent, t) in enumerate(bones):
        items += (f"<Item><Name>{n}</Name><Tag value=\"{TAGS.get(n, i)}\" /><Index value=\"{i}\" />"
                  f"<ParentIndex value=\"{parent}\" /><SiblingIndex value=\"-1\" /><Flags>None</Flags>"
                  f"<Translation x=\"{t[0]}\" y=\"{t[1]}\" z=\"{t[2]}\" />"
                  f"<Rotation x=\"0\" y=\"0\" z=\"0\" w=\"1\" /><Scale x=\"1\" y=\"1\" z=\"1\" />"
                  f"<TransformUnk x=\"0\" y=\"0\" z=\"0\" w=\"0\" /></Item>")
    return f"<Skeleton><Bones>{items}</Bones></Skeleton>"


def main_yft(out: Path):
    bi = {n: i for i, (n, _, _) in enumerate(BONES)}
    shaders = [
        shader("vehicle_paint1", {"DiffuseSampler": "testcar_generic_dirt"}, (2, 1, 1)),        # 0 primaire
        shader("vehicle_paint3", {"DiffuseSampler2": "testcar_sign_1"}, (2, 2, 2)),            # 1 livrée/secondaire
        shader("vehicle_vehglass", {"DiffuseSampler": "testcar_glass"}),                       # 2
        shader("vehicle_lightsemissive", {"DiffuseSampler": "testcar_lights"}),                # 3
        shader("vehicle_tire", {"DiffuseSampler": "testcar_tyre", "BumpSampler": "testcar_tyre_n"}),  # 4
        shader("vehicle_licenseplate", {"DiffuseSampler": "plate01"}),                          # 5
        shader("vehicle_mesh", {"DiffuseSampler": "testcar_interior"}),                         # 6
    ]
    geoms = []
    used_bones = list(range(len(BONES)))

    def skinned(shader_idx, parts, colours=None):
        P, N, T, BL, C = [], [], [], [], []
        for bone, (p, n, t) in parts:
            base = len(P)
            P += list(p)
            N += list(n)
            T += [(a + base, b + base, c + base) for a, b, c in t]
            BL += [used_bones.index(bi[bone])] * len(p)
        if colours is not None:
            C = colours
        geoms.append(geometry_xml(shader_idx, np.array(P), np.array(N), T, used_bones, BL,
                                  colour=C if colours is not None else None))

    skinned(0, [("bodyshell", box(0, 0, 0.1, 1.8, 4.2, 0.6)),
                ("door_dside_f", box(-0.92, 0.2, 0.25, 0.06, 1.0, 0.5)),
                ("door_pside_f", box(0.92, 0.2, 0.25, 0.06, 1.0, 0.5)),
                ("bonnet", box(0, 1.35, 0.42, 1.6, 1.0, 0.05)),
                ("boot", box(0, -1.8, 0.47, 1.6, 0.6, 0.05)),
                ("misc_a", box(0, -2.0, 0.65, 1.2, 0.2, 0.05)),
                ("extra_1", box(0, 0, 0.95, 0.6, 0.6, 0.1))])
    skinned(1, [("bodyshell", box(0, -0.3, 0.6, 1.6, 2.0, 0.4))])
    skinned(2, [("bodyshell", box(0, 0.75, 0.65, 1.5, 0.05, 0.35)),
                ("door_dside_f", box(-0.93, 0.2, 0.62, 0.03, 0.8, 0.3))])
    # lumières : alpha de Colour0 = ID de lumière
    lp, cols = [], []
    for bone, lid in (("headlight_l", 1), ("headlight_r", 2), ("taillight_l", 3), ("taillight_r", 4),
                      ("indicator_lf", 5), ("indicator_rf", 6), ("brakelight_l", 9), ("brakelight_r", 10)):
        x, y, z = BONES[bi[bone]][2]
        p, n, t = box(x, y, z, 0.3, 0.05, 0.1)
        lp.append(("bodyshell", (p, n, t)))
        cols += [(255, 255, 255, lid)] * len(p)
    skinned(3, lp, cols)
    skinned(5, [("bodyshell", box(0, -2.12, 0.0, 0.5, 0.02, 0.12))])
    skinned(6, [("steeringwheel", box(-0.4, 0.5, 0.5, 0.35, 0.05, 0.35)),
                ("seat_dside_f", box(-0.4, 0.0, 0.1, 0.5, 0.5, 0.5))])
    models = f"<DrawableModelsHigh><Item><RenderMask value=\"255\" /><Flags value=\"0\" /><HasSkin value=\"1\" /><BoneIndex value=\"0\" /><Unknown1 value=\"0\" /><Geometries>{''.join(geoms)}</Geometries></Item></DrawableModelsHigh>"

    wp, wn, wt = cylinder_x(0.33, 0.25)
    wheel_geom = geometry_xml(4, wp, wn, wt, [], None, skinned=False)
    wheel_child = (f"<Item><GroupIndex value=\"0\" /><BoneTag value=\"{TAGS['wheel_lf']}\" /><PristineMass value=\"20\" />"
                   f"<Drawable><Name>wheel_lf</Name><Matrix>1 0 0 0 1 0 0 0 1 0 0 0</Matrix>"
                   f"<DrawableModelsHigh><Item><RenderMask value=\"255\" /><Flags value=\"0\" /><HasSkin value=\"0\" />"
                   f"<BoneIndex value=\"0\" /><Unknown1 value=\"0\" /><Geometries>{wheel_geom}</Geometries></Item>"
                   f"</DrawableModelsHigh></Drawable></Item>")
    # limites articulaires (radians, repère de l'os) : portière conducteur 1,1 rad autour de Z (négatif),
    # capot 0,9 rad autour de X ; la portière passager n'en a pas (heuristique de repli)
    joints = (f"<Joints><RotationLimits>"
              f"<Item><BoneId value=\"{TAGS['door_dside_f']}\" /><UnknownA value=\"0\" />"
              f"<Min x=\"0\" y=\"0\" z=\"-1.1\" /><Max x=\"0\" y=\"0\" z=\"0\" /></Item>"
              f"<Item><BoneId value=\"{TAGS['bonnet']}\" /><UnknownA value=\"0\" />"
              f"<Min x=\"0\" y=\"0\" z=\"0\" /><Max x=\"0.9\" y=\"0\" z=\"0\" /></Item>"
              f"</RotationLimits></Joints>")
    tex_dict = ("<TextureDictionary><Item><Name>testcar_tyre</Name><FileName>testcar_tyre.dds</FileName></Item>"
                "<Item><Name>testcar_tyre_n</Name><FileName>testcar_tyre_n.dds</FileName></Item></TextureDictionary>")
    xml = (f"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Fragment><Name>testcar_hi</Name>"
           f"<Drawable><Name>testcar_hi</Name><ShaderGroup>{tex_dict}<Shaders>{''.join(shaders)}</Shaders></ShaderGroup>"
           f"{skeleton_xml(BONES)}{joints}{models}</Drawable>"
           f"<Physics><LOD1><Archetype><Mass value=\"1400\" /><InertiaTensor x=\"1200\" y=\"450\" z=\"1500\" /></Archetype>"
           f"<Children>{wheel_child}</Children></LOD1></Physics></Fragment>")
    (out / "testcar_hi.yft.xml").write_text(xml, encoding="utf-8")
    d = out / "testcar_hi"
    d.mkdir(exist_ok=True)
    save_dds(d / "testcar_tyre.dds", (30, 30, 30), 2048)
    save_dds(d / "testcar_tyre_n.dds", (128, 128, 255), 512)


def mod_yft(out: Path):
    bones = [("chassis", -1, (0, 0, 0)), ("misc_a", 0, (0, -2.0, 0.6))]
    p, n, t = box(0, -2.05, 0.8, 1.4, 0.3, 0.08)
    g = geometry_xml(0, p, n, t, [0, 1], [1] * len(p))
    xml = (f"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Fragment><Name>testcar_wing_1</Name><Drawable><Name>testcar_wing_1</Name>"
           f"<ShaderGroup><Shaders>{shader('vehicle_paint2', {}, (2, 2, 2))}</Shaders></ShaderGroup>"
           f"{skeleton_xml(bones)}<DrawableModelsHigh><Item><RenderMask value=\"255\" /><Flags value=\"0\" />"
           f"<HasSkin value=\"1\" /><BoneIndex value=\"0\" /><Unknown1 value=\"0\" /><Geometries>{g}</Geometries>"
           f"</Item></DrawableModelsHigh></Drawable></Fragment>")
    (out / "testcar_wing_1.yft.xml").write_text(xml, encoding="utf-8")


def save_dds(path: Path, rgb, size):
    img = Image.new("RGBA", (size, size), (*rgb, 255))
    img.save(path, "DDS")


def ytd(out: Path):
    d = out / "testcar"
    d.mkdir(exist_ok=True)
    items = ""
    for name, rgb, size in (("testcar_sign_1", (200, 20, 20), 2048), ("testcar_sign_2", (20, 20, 200), 1024),
                            ("testcar_glass", (20, 25, 30), 256), ("testcar_lights", (220, 220, 220), 256),
                            ("testcar_interior", (60, 50, 40), 512), ("plate01", (240, 240, 240), 256)):
        img = Image.new("RGBA", (size, size), (*rgb, 255))
        if "sign" in name:  # livrée : bande opaque, reste transparent
            a = np.zeros((size, size, 4), np.uint8)
            a[size // 3: size // 2] = (*rgb, 255)
            img = Image.fromarray(a, "RGBA")
        img.save(d / f"{name}.dds", "DDS")
        items += f"<Item><Name>{name}</Name><FileName>{name}.dds</FileName><Width value=\"{size}\" /><Height value=\"{size}\" /></Item>"
    (out / "testcar.ytd.xml").write_text(f"<?xml version=\"1.0\"?>\n<TextureDictionary>{items}</TextureDictionary>",
                                         encoding="utf-8")


def awc(out: Path):
    d = out / "testcar_sounds"
    d.mkdir(exist_ok=True)
    sr = 32000
    t = np.arange(sr * 4) / sr
    f = 30 + 170 * t / 4  # balayage montée en régime
    sig = np.sin(2 * np.pi * np.cumsum(f) / sr) * 0.6
    with wave.open(str(d / "engine_accel.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((sig * 32767).astype("<i2").tobytes())
    (out / "testcar_sounds.awc.xml").write_text(
        "<?xml version=\"1.0\"?>\n<AudioWaveContainer><Streams><Item><Name>engine_accel</Name>"
        "<FileName>engine_accel.wav</FileName></Item></Streams></AudioWaveContainer>", encoding="utf-8")


METAS = {
    "vehicles.meta": """<?xml version="1.0" encoding="UTF-8"?>
<CVehicleModelInfo__InitDataList><InitDatas><Item>
  <modelName>testcar</modelName><txdName>testcar</txdName><handlingId>TESTCAR</handlingId>
  <gameName>TESTCAR</gameName><vehicleMakeName>F2R</vehicleMakeName><audioNameHash>ADDER</audioNameHash>
  <type>VEHICLE_TYPE_CAR</type><vehicleClass>VC_SUPER</vehicleClass>
  <wheelScale value="0.33" /><wheelScaleRear value="0.33" /><flags>FLAG_SPORTS FLAG_EMERGENCY_SERVICE</flags>
</Item></InitDatas><txdRelationships><Item><parent>vehicles_poltax_interior</parent><child>testcar</child></Item></txdRelationships>
</CVehicleModelInfo__InitDataList>""",
    "carvariations.meta": """<?xml version="1.0" encoding="UTF-8"?>
<CVehicleModelInfoVariation><variationData><Item><modelName>testcar</modelName>
  <colors><Item><indices content="char_array">27 0 4 156 0 0</indices><liveries><Item value="false" /></liveries></Item></colors>
  <kits><Item>999_testcar_modkit</Item></kits><lightSettings value="1" /><sirenSettings value="7" />
</Item></variationData></CVehicleModelInfoVariation>""",
    "carcols.meta": """<?xml version="1.0" encoding="UTF-8"?>
<CVehicleModelInfoVarGlobal><Kits><Item><kitName>999_testcar_modkit</kitName><id value="999" /><kitType>MKT_SPECIAL</kitType>
  <visibleMods><Item><modelName>testcar_wing_1</modelName><modShopLabel>TESTCAR_WING1</modShopLabel><linkedModels />
    <turnOffBones><Item>misc_a</Item></turnOffBones><type>VMT_SPOILER</type><bone>chassis</bone><collisionBone>chassis</collisionBone></Item></visibleMods>
  <statMods><Item><identifier /><modifier value="25" /><audioApply value="1.0" /><weight value="20" /><type>VMT_ENGINE</type></Item></statMods>
</Item></Kits>
<Lights><Item><id value="1" /><headLight><intensity value="1.5" /><falloffMax value="35" /><outerConeAngle value="55" /><color value="0xFFFFF5E0" /></headLight></Item></Lights>
<Sirens><Item><id value="7" /><name>testcar</name><sequencerBpm value="600" />
  <leftHeadLight><sequencer value="2863311530" /></leftHeadLight><rightHeadLight><sequencer value="1431655765" /></rightHeadLight>
  <sirens><Item><rotation><delta value="0" /><start value="0" /><speed value="3" /><sequencer value="0" /><multiples value="1" /><direction value="false" /><syncToBpm value="true" /></rotation>
  <flashiness><delta value="0" /><start value="0" /><speed value="1" /><sequencer value="4042322160" /><multiples value="1" /><direction value="false" /><syncToBpm value="true" /></flashiness>
  <color value="0xFFFF0000" /><intensity value="1" /><rotate value="false" /></Item></sirens></Item></Sirens>
</CVehicleModelInfoVarGlobal>""",
    "handling.meta": """<?xml version="1.0" encoding="UTF-8"?>
<CHandlingDataMgr><HandlingData><Item type="CHandlingData"><handlingName>TESTCAR</handlingName>
  <fMass value="1400.0" /><fInitialDragCoeff value="8.0" /><vecCentreOfMassOffset x="0.0" y="0.0" z="-0.1" />
  <nInitialDriveGears value="6" /><fInitialDriveForce value="0.35" /><fInitialDriveMaxFlatVel value="200.0" />
  <fBrakeForce value="1.0" /><fSteeringLock value="40.0" /><strModelFlags>440010</strModelFlags>
  <fTractionCurveMax value="2.45" /><fTractionCurveMin value="2.15" /><fTractionCurveLateral value="22.5" />
  <fDriveBiasFront value="0.05" /><fClutchChangeRateScaleUpShift value="3.0" />
  <fSuspensionCompDamp value="1.4" /><fSuspensionReboundDamp value="2.2" /><fAntiRollBarForce value="0.8" />
  <fAntiRollBarBiasFront value="0.6" /><strHandlingFlags>20000</strHandlingFlags><strDamageFlags>0</strDamageFlags>
  <SubHandlingData>
    <Item type="CCarHandlingData"><fToeFront value="0.02" /><fCamberFront value="-0.05" /><fCastor value="0.04" />
      <fMaxDriveBiasTransfer value="-1.0" /><strAdvancedFlags>10000</strAdvancedFlags>
      <AdvancedData><Item><Slot value="0" /><Index value="0" /><Value value="1.0" /></Item></AdvancedData></Item>
    <Item type="NULL" /><Item type="NULL" />
  </SubHandlingData>
</Item></HandlingData></CHandlingDataMgr>""",
}


def main(dest: Path) -> Path:
    stream = dest / "testcar" / "stream"
    data = dest / "testcar" / "data"
    stream.mkdir(parents=True, exist_ok=True)
    data.mkdir(parents=True, exist_ok=True)
    main_yft(stream)
    mod_yft(stream)
    ytd(stream)
    awc(stream)
    for name, text in METAS.items():
        (data / name).write_text(text, encoding="utf-8")
    (dest / "testcar" / "fxmanifest.lua").write_text("fx_version 'cerulean'\ngame 'gta5'\n", encoding="utf-8")
    zpath = dest / "testcar.zip"
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for f in (dest / "testcar").rglob("*"):
            if f.is_file():
                z.write(f, f.relative_to(dest))
    return zpath


if __name__ == "__main__":
    print(main(Path(sys.argv[1] if len(sys.argv) > 1 else "fixture")))
