"""Lecture des fichiers .meta d'un véhicule GTA V / FiveM."""
from __future__ import annotations

from pathlib import Path

from .util import (Report, argb_hex_to_rgb, element_to_obj, parse_xml_lenient,
                   xfloat, xval, xvec)

# Types de mods GTA (eVehicleModType) -> nom lisible utilisé dans Roblox
MOD_SLOT_NAMES = {
    "VMT_SPOILER": "Spoiler", "VMT_BUMPER_F": "FrontBumper", "VMT_BUMPER_R": "RearBumper",
    "VMT_SKIRT": "SideSkirt", "VMT_EXHAUST": "Exhaust", "VMT_CHASSIS": "Frame",
    "VMT_GRILL": "Grille", "VMT_BONNET": "Hood", "VMT_WING_L": "LeftFender",
    "VMT_WING_R": "RightFender", "VMT_ROOF": "Roof", "VMT_ENGINE": "Engine",
    "VMT_BRAKES": "Brakes", "VMT_GEARBOX": "Transmission", "VMT_HORN": "Horn",
    "VMT_SUSPENSION": "Suspension", "VMT_ARMOUR": "Armor", "VMT_NITROUS": "Nitrous",
    "VMT_TURBO": "Turbo", "VMT_SUBWOOFER": "Subwoofer", "VMT_TYRE_SMOKE": "TireSmoke",
    "VMT_HYDRAULICS": "Hydraulics", "VMT_XENON_LIGHTS": "XenonLights",
    "VMT_WHEELS": "FrontWheels", "VMT_WHEELS_REAR_OR_HYDRAULICS": "RearWheels",
    "VMT_PLTHOLDER": "PlateHolder", "VMT_PLTVANITY": "VanityPlate",
    "VMT_INTERIOR1": "TrimDesign", "VMT_INTERIOR2": "Ornaments", "VMT_INTERIOR3": "Dashboard",
    "VMT_INTERIOR4": "DialDesign", "VMT_INTERIOR5": "DoorSpeaker", "VMT_SEATS": "Seats",
    "VMT_STEERING": "SteeringWheel", "VMT_KNOB": "ShiftLever", "VMT_PLAQUE": "Plaque",
    "VMT_ICE": "Speakers", "VMT_TRUNK": "Trunk", "VMT_HYDRO": "Hydraulics2",
    "VMT_ENGINEBAY1": "EngineBlock", "VMT_ENGINEBAY2": "AirFilter", "VMT_ENGINEBAY3": "Struts",
    "VMT_CHASSIS2": "ArchCover", "VMT_CHASSIS3": "Aerials", "VMT_CHASSIS4": "Trim2",
    "VMT_CHASSIS5": "Tank", "VMT_DOOR_L": "LeftDoor", "VMT_DOOR_R": "RightDoor",
    "VMT_LIVERY_MOD": "Livery", "VMT_LIGHTBAR": "Lightbar",
}

PERFORMANCE_SLOTS = {"VMT_ENGINE", "VMT_BRAKES", "VMT_GEARBOX", "VMT_SUSPENSION", "VMT_ARMOUR",
                     "VMT_TURBO", "VMT_NITROUS", "VMT_HORN", "VMT_XENON_LIGHTS"}


def _load(paths: list[Path] | None, report: Report):
    for p in paths or []:
        el = parse_xml_lenient(p)
        if el is None:
            report.warn(f"Fichier meta illisible (XML invalide) : {p.name}")
            continue
        yield p, el


# ---------------------------------------------------------------- vehicles.meta

def parse_vehicles(paths, report: Report) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for p, root in _load(paths, report):
        for item in root.iter("Item"):
            model = xval(item, "modelName")
            if not model or item.find("handlingId") is None:
                continue
            flags = (xval(item, "flags") or "").split()
            out[model.lower()] = {
                "modelName": model,
                "txdName": xval(item, "txdName", model),
                "handlingId": xval(item, "handlingId", model),
                "gameName": xval(item, "gameName", model),
                "make": xval(item, "vehicleMakeName", ""),
                "audioNameHash": xval(item, "audioNameHash", ""),
                "layout": xval(item, "layout", ""),
                "type": xval(item, "type", "VEHICLE_TYPE_CAR"),
                "class": xval(item, "vehicleClass", ""),
                "plateType": xval(item, "plateType", ""),
                "wheelScale": xfloat(item, "wheelScale", 0.0),
                "wheelScaleRear": xfloat(item, "wheelScaleRear", 0.0),
                "flags": flags,
                "requiredExtras": (xval(item, "requiredExtras") or "").split(),
                "extraIncludes": [e.text for e in item.findall("extraIncludes/Item") if e.text],
                "dashboardType": xval(item, "dashboardType", ""),
                "steerWheelMult": xfloat(item, "steerWheelMult", 1.0),  # rotation visuelle du volant (×)
                # caméra à la première personne, relative à l'os du siège (GTA : x droite, y avant, z haut, m)
                "povCameraOffset": xvec(item, "PovCameraOffset", (0.0, -0.225, 0.585))[:3],
                "povPassengerCameraOffset": xvec(item, "PovPassengerCameraOffset", (0.0, 0.0, 0.0))[:3],
                "povRearPassengerCameraOffset": xvec(item, "PovRearPassengerCameraOffset", (0.0, 0.0, 0.0))[:3],
                "dependentTxds": [],
                "source": p.name,
            }
        # txdRelationships : textures partagées (ex: "adder" dépend de "vehshare")
        for rel in root.iter("Item"):
            parent, child = xval(rel, "parent"), xval(rel, "child")
            if parent and child and child.lower() in out:
                out[child.lower()]["dependentTxds"].append(parent)
    return out


# ----------------------------------------------------------- carvariations.meta

def parse_carvariations(paths, report: Report) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for p, root in _load(paths, report):
        for item in root.iter("Item"):
            model = xval(item, "modelName")
            if not model or item.find("colors") is None and item.find("kits") is None:
                continue
            colors = []
            for c in item.findall("colors/Item"):
                ind = c.find("indices")
                idx = [int(x) for x in (ind.text or "").split()] if ind is not None else []
                liveries = [ (l.attrib.get("value", "false").lower() == "true")
                             for l in c.findall("liveries/Item") ]
                colors.append({"indices": idx, "liveries": liveries})
            out[model.lower()] = {
                "colors": colors,
                "kits": [k.text.strip() for k in item.findall("kits/Item") if k.text],
                "lightSettings": int(xval(item, "lightSettings", "-1") or -1),
                "sirenSettings": int(xval(item, "sirenSettings", "-1") or -1),
                "windowsWithExposedEdges": [w.text for w in item.findall("windowsWithExposedEdges/Item") if w.text],
            }
    return out


# ------------------------------------------------------------------ carcols.meta

def _parse_light_block(el) -> dict | None:
    if el is None:
        return None
    return {
        "intensity": xfloat(el, "intensity", 1.0),
        "falloffMax": xfloat(el, "falloffMax", 10.0),
        "falloffExponent": xfloat(el, "falloffExponent", 8.0),
        "innerConeAngle": xfloat(el, "innerConeAngle", 20.0),
        "outerConeAngle": xfloat(el, "outerConeAngle", 50.0),
        "color": argb_hex_to_rgb(xval(el, "color")),
        "size": xfloat(el, "size", 0.0),
    }


def _parse_sequencer_block(el) -> dict:
    return {
        "delta": xfloat(el, "delta", 0.0),
        "start": xfloat(el, "start", 0.0),
        "speed": xfloat(el, "speed", 1.0),
        "sequencer": int(float(xval(el, "sequencer", "0") or 0)),
        "multiples": int(float(xval(el, "multiples", "1") or 1)),
        "direction": str(xval(el, "direction", "false")).lower() == "true",
        "syncToBpm": str(xval(el, "syncToBpm", "true")).lower() == "true",
    }


def parse_carcols(paths, report: Report) -> dict:
    kits: dict[str, dict] = {}
    lights: dict[int, dict] = {}
    sirens: dict[int, dict] = {}
    for p, root in _load(paths, report):
        for kit in root.findall("Kits/Item"):
            name = xval(kit, "kitName", "")
            visible = []
            for m in kit.findall("visibleMods/Item"):
                visible.append({
                    "modelName": xval(m, "modelName", ""),
                    "label": xval(m, "modShopLabel", ""),
                    "linkedModels": [x.text.strip() for x in m.findall("linkedModels/Item") if x.text],
                    "turnOffBones": [x.text.strip() for x in m.findall("turnOffBones/Item") if x.text],
                    "type": xval(m, "type", ""),
                    "bone": xval(m, "bone", "chassis"),
                    "collisionBone": xval(m, "collisionBone", ""),
                    "turnOffExtra": str(xval(m, "turnOffExtra", "false")).lower() == "true",
                })
            stat = []
            for m in kit.findall("statMods/Item"):
                stat.append({
                    "identifier": xval(m, "identifier", ""),
                    "modifier": xfloat(m, "modifier", 0.0),
                    "type": xval(m, "type", ""),
                    "audioApply": xfloat(m, "audioApply", 1.0),
                })
            kits[name.lower()] = {
                "kitName": name,
                "id": int(float(xval(kit, "id", "0") or 0)),
                "kitType": xval(kit, "kitType", ""),
                "visibleMods": visible,
                "statMods": stat,
                "slotNames": [{"slot": xval(s, "slot", ""), "name": xval(s, "name", "")}
                              for s in kit.findall("slotNames/Item")],
                "liveryNames": [x.text.strip() for x in kit.findall("liveryNames/Item") if x.text],
            }
        for li in root.findall("Lights/Item"):
            lid = int(float(xval(li, "id", "0") or 0))
            lights[lid] = {
                "id": lid,
                "indicator": _parse_light_block(li.find("indicator")),
                "rearIndicatorCorona": _parse_light_block(li.find("rearIndicatorCorona")),
                "frontIndicatorCorona": _parse_light_block(li.find("frontIndicatorCorona")),
                "tailLight": _parse_light_block(li.find("tailLight")),
                "tailLightCorona": _parse_light_block(li.find("tailLightCorona")),
                "tailLightMiddleCorona": _parse_light_block(li.find("tailLightMiddleCorona")),
                "headLight": _parse_light_block(li.find("headLight")),
                "headLightCorona": _parse_light_block(li.find("headLightCorona")),
                "reversingLight": _parse_light_block(li.find("reversingLight")),
                "reversingLightCorona": _parse_light_block(li.find("reversingLightCorona")),
                "name": xval(li, "name", ""),
            }
        for si in root.findall("Sirens/Item"):
            sid = int(float(xval(si, "id", "0") or 0))
            entries = []
            for s in si.findall("sirens/Item"):
                entries.append({
                    "rotation": _parse_sequencer_block(s.find("rotation")) if s.find("rotation") is not None else None,
                    "flashiness": _parse_sequencer_block(s.find("flashiness")) if s.find("flashiness") is not None else None,
                    "color": argb_hex_to_rgb(xval(s, "color")) or [1, 0, 0],
                    "intensity": xfloat(s, "intensity", 1.0),
                    "lightGroup": int(float(xval(s, "lightGroup", "0") or 0)),
                    "rotate": str(xval(s, "rotate", "false")).lower() == "true",
                    "flash": str(xval(s, "flash", "true")).lower() == "true",
                    "light": str(xval(s, "light", "true")).lower() == "true",
                    "spotLight": str(xval(s, "spotLight", "true")).lower() == "true",
                })
            def seq(tag):
                n = si.find(tag)
                return int(float(xval(n, "sequencer", "0") or 0)) if n is not None else 0
            sirens[sid] = {
                "id": sid,
                "name": xval(si, "name", ""),
                "bpm": xfloat(si, "sequencerBpm", 220.0),
                "falloffMax": xfloat(si, "lightFalloffMax", 30.0),
                "innerConeAngle": xfloat(si, "lightInnerConeAngle", 2.0),
                "outerConeAngle": xfloat(si, "lightOuterConeAngle", 70.0),
                "headLightLeft": seq("leftHeadLight"), "headLightRight": seq("rightHeadLight"),
                "tailLightLeft": seq("leftTailLight"), "tailLightRight": seq("rightTailLight"),
                "useRealLights": str(xval(si, "useRealLights", "true")).lower() == "true",
                "sirens": entries,
            }
    return {"kits": kits, "lights": lights, "sirens": sirens}


# ----------------------------------------------------------------- handling.meta

def parse_handling(paths, report: Report) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for p, root in _load(paths, report):
        for item in root.iter("Item"):
            name = xval(item, "handlingName")
            if not name:
                continue
            data = element_to_obj(item)
            if isinstance(data, dict):
                data.pop("_type", None)
                out[name.lower()] = data
    return out


# Flags documentés (gtamods.com/wiki/Handling.meta, gtacars.net/gta5/glossary) ; les bits non
# documentés sont exportés sous la forme "bit_0x...".
MODEL_FLAGS = {
    0x8: "IS_BIG", 0x10: "ABS_STD", 0x20: "ABS_OPTION", 0x40: "ABS_ALT_STD", 0x80: "ABS_ALT_OPTION",
    0x800: "HAS_TRACKS", 0x10000: "AXLE_F_TORSION", 0x20000: "AXLE_F_SOLID", 0x40000: "AXLE_F_MCPHERSON",
    0x100000: "AXLE_R_TORSION", 0x200000: "AXLE_R_SOLID", 0x400000: "AXLE_R_MCPHERSON",
    0x800000: "DONT_FORCE_GRND_CLEARANCE", 0x2000000: "NO_WHEEL_BURST", 0x4000000: "INDESTRUCTIBLE",
    0x8000000: "DOUBLE_FRONT_WHEELS", 0x20000000: "DOUBLE_REAR_WHEELS", 0x40000000: "NO_WHEEL_BREAK",
    0x80000000: "IS_HATCHBACK",
}
HANDLING_FLAGS = {
    0x1: "SMOOTHED_COMPRESSION", 0x2: "REDUCED_MOD_MASS", 0x4: "HAS_KERS", 0x8: "HAS_RALLY_TYRES",
    0x10: "NO_HANDBRAKE", 0x20: "STEER_REARWHEELS", 0x40: "HANDBRAKE_REARWHEELSTEER", 0x80: "STEER_ALL_WHEELS",
    0x100: "FREEWHEEL_NO_GAS", 0x200: "NO_REVERSE", 0x400: "REDUCED_RIGHTING_FORCE", 0x800: "STEER_NO_WHEELS",
    0x1000: "CVT", 0x10000: "LESS_SNOW_SINK", 0x20000: "TYRES_CAN_CLIP", 0x40000: "REDUCED_DRIVE_OVER_DAMAGE",
    0x100000: "OFFROAD_ABILITIES", 0x200000: "OFFROAD_ABILITIES_X2",
    0x800000: "OFFROAD_INCREASED_GRAVITY_NO_FOLIAGE_DRAG", 0x1000000: "ENABLE_LEAN",
    0x2000000: "FORCE_NO_TC_OR_SC", 0x8000000: "ARMOURED", 0x20000000: "IMPROVED_RIGHTING_FORCE",
    0x40000000: "LOW_SPEED_WHEELIES",
}
DAMAGE_FLAGS = {0x1: "DRIVER_SIDE_FRONT_DOOR", 0x2: "DRIVER_SIDE_REAR_DOOR", 0x4: "PASSENGER_SIDE_FRONT_DOOR",
                0x8: "PASSENGER_SIDE_REAR_DOOR", 0x10: "BONNET", 0x20: "BOOT"}
ADVANCED_FLAGS = {
    0x1: "DIFF_FRONT", 0x2: "DIFF_REAR", 0x4: "DIFF_CENTRE", 0x8: "DIFF_LIMITED_FRONT", 0x10: "DIFF_LIMITED_REAR",
    0x20: "DIFF_LIMITED_CENTRE", 0x40: "DIFF_LOCKING_FRONT", 0x80: "DIFF_LOCKING_REAR", 0x100: "DIFF_LOCKING_CENTRE",
    0x200: "GEARBOX_FULL_AUTO", 0x400: "GEARBOX_MANUAL", 0x800: "GEARBOX_DIRECT_SHIFT", 0x1000: "GEARBOX_ELECTRIC",
    0x2000: "ASSIST_TRACTION_CONTROL", 0x4000: "ASSIST_STABILITY_CONTROL", 0x8000: "ALLOW_REDUCED_SUSPENSION_FORCE",
    0x10000: "HARD_REV_LIMIT", 0x20000: "HOLD_GEAR_WITH_WHEELSPIN", 0x40000: "INCREASE_SUSPENSION_FORCE_WITH_SPEED",
    0x80000: "BLOCK_INCREASED_ROT_VELOCITY_WITH_DRIVE_FORCE", 0x100000: "REDUCED_SELF_RIGHTING_SPEED",
    0x200000: "CLOSE_RATIO_GEARBOX", 0x400000: "FORCE_SMOOTH_RPM", 0x800000: "ALLOW_TURN_ON_SPOT",
    0x1000000: "CAN_WHEELIE", 0x2000000: "ENABLE_WHEEL_BLOCKER_SIDE_IMPACTS", 0x4000000: "FIX_OLD_BUGS",
    0x8000000: "USE_DOWNFORCE_BIAS", 0x10000000: "REDUCE_BODY_ROLL_WITH_SUSPENSION_MODS",
    0x20000000: "ALLOWS_EXTENDED_MODS",
}


def decode_flags(value, table: dict[int, str]) -> dict:
    """'440010' (hexadécimal, comme dans les .meta) -> {"Hex": "0x440010", "Names": [...]}"""
    if value in (None, ""):
        return {"Hex": "0x0", "Names": []}
    try:
        v = int(str(value).strip(), 16) if not isinstance(value, int) else int(str(value), 16)
    except ValueError:
        return {"Hex": str(value), "Names": [], "Invalid": True}
    names = []
    bit = 1
    while bit <= v:
        if v & bit:
            names.append(table.get(bit, f"bit_0x{bit:X}"))
        bit <<= 1
    return {"Hex": f"0x{v:X}", "Names": names}


def _bias(b: float, snap: bool = False) -> tuple[float, float]:
    """Répartition avant/arrière telle que stockée par le jeu : (2b, 2(1-b)). Pour la transmission,
    b < 0.1 => propulsion pure, b > 0.9 => traction pure (chargeur FiveM / éditeur d'ikt)."""
    if snap:
        if b < 0.1:
            return 0.0, 2.0
        if b > 0.9:
            return 2.0, 0.0
    return round(2 * b, 5), round(2 * (1 - b), 5)


def _gta_vec_to_local(v) -> list[float]:
    """Vecteur GTA (x droite, y avant, z haut) -> repère local Roblox (x droite, y haut, z arrière)."""
    x, y, z = (list(v) + [0, 0, 0])[:3] if isinstance(v, (list, tuple)) else (0, 0, 0)
    return [round(float(x), 5), round(float(z), 5), round(-float(y), 5)]


def summarize_handling(h: dict | None) -> dict:
    """Handling complet pour un moteur physique : valeurs du fichier (noms courts), conversions que
    fait le jeu au chargement (unités SI), flags décodés et sous-handling CCarHandlingData.
    Sources des conversions : FiveM handling-loader-five/HandlingLoader.cpp, ikt GTAVHandlingEditor
    HandlingConversion.cpp (voir reports/ et research_notes/ du dépôt)."""
    if not h:
        return {}

    def num(k, d=0.0):
        v = h.get(k, d)
        return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else float(d)

    def vec(k):
        v = h.get(k)
        return [float(x) for x in v[:3]] if isinstance(v, list) and len(v) >= 3 else [0.0, 0.0, 0.0]

    import math
    max_kmh = num("fInitialDriveMaxFlatVel", 150.0)
    gears = int(num("nInitialDriveGears", 6))
    drive_bias = num("fDriveBiasFront", 0.0)
    clutch_up = num("fClutchChangeRateScaleUpShift", 2.0)
    clutch_down = num("fClutchChangeRateScaleDownShift", 2.0)
    steer_deg = num("fSteeringLock", 35.0)
    lat_deg = num("fTractionCurveLateral", 22.5)
    tmax, tmin = num("fTractionCurveMax", 2.0), num("fTractionCurveMin", 1.8)
    out = {
        # --- compatibilité (clés déjà lues par le runtime)
        "MassKg": num("fMass", 1500.0),
        "DragCoeff": num("fInitialDragCoeff", 10.0),
        "CentreOfMassOffset": vec("vecCentreOfMassOffset"),
        "DriveBiasFront": drive_bias,
        "Gears": gears,
        "DriveForce": num("fInitialDriveForce", 0.3),
        "DriveInertia": num("fDriveInertia", 1.0),
        "MaxFlatVelKmh": max_kmh,
        "BrakeForce": num("fBrakeForce", 1.0),
        "BrakeBiasFront": num("fBrakeBiasFront", 0.5),
        "HandBrakeForce": num("fHandBrakeForce", 0.7),
        "SteeringLockDeg": steer_deg,
        "TractionCurveMax": tmax,
        "TractionCurveMin": tmin,
        "SuspensionForce": num("fSuspensionForce", 2.0),
        "SuspensionUpperLimit": num("fSuspensionUpperLimit", 0.1),
        "SuspensionLowerLimit": num("fSuspensionLowerLimit", -0.1),
        "SuspensionRaise": num("fSuspensionRaise", 0.0),
        "ModelFlags": h.get("strModelFlags", ""),
        "HandlingFlags": h.get("strHandlingFlags", ""),
        # --- masse, aéro, flottaison
        "CentreOfMassLocal": _gta_vec_to_local(vec("vecCentreOfMassOffset")),
        "InertiaMultiplier": vec("vecInertiaMultiplier"),
        "InertiaMultiplierLocal": [round(abs(c), 5) for c in _gta_vec_to_local(vec("vecInertiaMultiplier"))],
        "DownforceModifier": num("fDownforceModifier", 0.0),
        "PercentSubmerged": num("fPercentSubmerged", 85.0),
        "DragAccelCoeff": num("fInitialDragCoeff", 10.0) * 1e-4,  # a = k·v² (m/s², v en m/s) — hypothèse
        # --- transmission
        "DriveFront": _bias(drive_bias, snap=True)[0],
        "DriveRear": _bias(drive_bias, snap=True)[1],
        "ClutchChangeRateUp": clutch_up,
        "ClutchChangeRateDown": clutch_down,
        "ShiftTimeUpS": round(0.9 / clutch_up, 4) if clutch_up > 0 else None,
        "ShiftTimeDownS": round(0.9 / clutch_down, 4) if clutch_down > 0 else None,
        "MaxFlatVelMs": round(max_kmh / 3.6, 4),
        "DriveMaxFlatVelMs": round(max_kmh / 3.6 * 1.2, 4),       # vitesse au rupteur pour un rapport de 1.0
        "TopGearRatio": 0.9,                                        # rapport de dernière vitesse par défaut
        "RedlineTopGearKmh": round(max_kmh * 1.2 / 0.9, 2),
        "IdleRpm": 0.2, "RedlineRpm": 1.0,                          # régime normalisé GTA
        # --- freins / direction
        "BrakeFront": _bias(num("fBrakeBiasFront", 0.5))[0],
        "BrakeRear": _bias(num("fBrakeBiasFront", 0.5))[1],
        "SteeringLockRad": round(math.radians(steer_deg), 6),
        # --- adhérence
        "TractionCurveLateralDeg": lat_deg,
        "TractionCurveLateralRad": round(math.radians(lat_deg), 6),
        "TractionSpringDeltaMax": num("fTractionSpringDeltaMax", 0.15),
        "LowSpeedTractionLossMult": num("fLowSpeedTractionLossMult", 1.0),
        "CamberStiffness": num("fCamberStiffnesss", num("fCamberStiffness", 0.0)),
        "TractionBiasFront": num("fTractionBiasFront", 0.5),
        "TractionFront": _bias(num("fTractionBiasFront", 0.5))[0],
        "TractionRear": _bias(num("fTractionBiasFront", 0.5))[1],
        "TractionLossMult": num("fTractionLossMult", 1.0),
        # --- suspension / anti-roulis
        "SuspensionCompDamp": num("fSuspensionCompDamp", 1.0),
        "SuspensionReboundDamp": num("fSuspensionReboundDamp", 1.0),
        "SuspensionCompDampScaled": round(num("fSuspensionCompDamp", 1.0) * 0.1, 6),
        "SuspensionReboundDampScaled": round(num("fSuspensionReboundDamp", 1.0) * 0.1, 6),
        "SuspensionBiasFront": num("fSuspensionBiasFront", 0.5),
        "SuspensionFront": _bias(num("fSuspensionBiasFront", 0.5))[0],
        "SuspensionRear": _bias(num("fSuspensionBiasFront", 0.5))[1],
        "AntiRollBarForce": num("fAntiRollBarForce", 0.0),
        "AntiRollBarBiasFront": num("fAntiRollBarBiasFront", 0.5),  # sens disputé : 1 = avant retenu
        "AntiRollFront": _bias(num("fAntiRollBarBiasFront", 0.5))[0],
        "AntiRollRear": _bias(num("fAntiRollBarBiasFront", 0.5))[1],
        "RollCentreHeightFront": num("fRollCentreHeightFront", 0.0),
        "RollCentreHeightRear": num("fRollCentreHeightRear", 0.0),
        # --- dégâts / divers
        "CollisionDamageMult": num("fCollisionDamageMult", 1.0),
        "WeaponDamageMult": num("fWeaponDamageMult", 1.0),
        "DeformationDamageMult": num("fDeformationDamageMult", 1.0),
        "EngineDamageMult": num("fEngineDamageMult", 1.0),
        "PetrolTankVolume": num("fPetrolTankVolume", 65.0),
        "OilVolume": num("fOilVolume", 5.0),
        "SeatOffsetDist": [num("fSeatOffsetDistX"), num("fSeatOffsetDistY"), num("fSeatOffsetDistZ")],
        "MonetaryValue": int(num("nMonetaryValue", 0)),
        "AIHandling": h.get("AIHandling", ""),
        "Flags": {
            "Model": decode_flags(h.get("strModelFlags"), MODEL_FLAGS),
            "Handling": decode_flags(h.get("strHandlingFlags"), HANDLING_FLAGS),
            "Damage": decode_flags(h.get("strDamageFlags"), DAMAGE_FLAGS),
        },
    }
    # gravité « tout-terrain » (flags) : 9.8 m/s² de base
    hf = out["Flags"]["Handling"]["Names"]
    out["GravityMs2"] = 11.76 if ("OFFROAD_ABILITIES_X2" in hf or
                                  "OFFROAD_INCREASED_GRAVITY_NO_FOLIAGE_DRAG" in hf) else (
        10.78 if "OFFROAD_ABILITIES" in hf else 9.8)

    # --- sous-handling (CCarHandlingData, CBikeHandlingData, CBoatHandlingData...)
    subs = h.get("SubHandlingData")
    subs = subs if isinstance(subs, list) else ([subs] if isinstance(subs, dict) else [])
    for sub in subs:
        if not isinstance(sub, dict) or not sub.get("_type") or sub.get("_type") == "NULL":
            continue
        t = sub["_type"]
        data = {k: v for k, v in sub.items() if k != "_type"}
        if t == "CCarHandlingData":
            def snum(k, d=0.0):
                v = sub.get(k, d)
                return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else float(d)
            car = {
                "BackEndPopUpCarImpulseMult": snum("fBackEndPopUpCarImpulseMult"),
                "BackEndPopUpBuildingImpulseMult": snum("fBackEndPopUpBuildingImpulseMult"),
                "BackEndPopUpMaxDeltaSpeed": snum("fBackEndPopUpMaxDeltaSpeed"),
                "ToeFront": snum("fToeFront"), "ToeRear": snum("fToeRear"),
                "CamberFront": snum("fCamberFront"), "CamberRear": snum("fCamberRear"),
                "Castor": snum("fCastor"),
                "ToeFrontDeg": round(snum("fToeFront") * 45, 4), "ToeRearDeg": round(snum("fToeRear") * 45, 4),
                "CamberFrontDeg": round(snum("fCamberFront") * 22.5, 4),
                "CamberRearDeg": round(snum("fCamberRear") * 22.5, 4),
                "CastorDeg": round(snum("fCastor") * 100, 4),
                "EngineResistance": snum("fEngineResistance"),
                "MaxDriveBiasTransfer": snum("fMaxDriveBiasTransfer", -1.0),
                "JumpForceScale": snum("fJumpForceScale", 1.0),
                "IncreasedRammingForceScale": snum("fIncreasedRammingForceScale", 1.0),
                "AdvancedFlags": decode_flags(sub.get("strAdvancedFlags"), ADVANCED_FLAGS),
                "AdvancedData": [x for x in (sub.get("AdvancedData") or []) if isinstance(x, dict)],
            }
            out["CarHandling"] = car
        else:
            out.setdefault("OtherSubHandling", {})[t] = data
    adv = (out.get("CarHandling") or {}).get("AdvancedFlags", {}).get("Names", [])
    out["Gearbox"] = ("electric" if ("GEARBOX_ELECTRIC" in adv or "CVT" in hf) else
                      "manual" if "GEARBOX_MANUAL" in adv else "auto")
    # valeurs brutes complètes du fichier (rien n'est perdu)
    out["Raw"] = {k: v for k, v in h.items() if k != "SubHandlingData"}
    return out
