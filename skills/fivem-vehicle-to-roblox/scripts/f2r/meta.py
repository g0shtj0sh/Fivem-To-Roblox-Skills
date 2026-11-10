"""Lecture des fichiers .meta d'un véhicule GTA V / FiveM."""
from __future__ import annotations

from pathlib import Path

from .util import (Report, argb_hex_to_rgb, element_to_obj, parse_xml_lenient,
                   xfloat, xval)

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


def summarize_handling(h: dict | None) -> dict:
    """Valeurs clés utiles à un moteur physique custom (+ estimations régime moteur)."""
    if not h:
        return {}
    def num(k, d=0.0):
        v = h.get(k, d)
        return v if isinstance(v, (int, float)) else d
    max_kmh = num("fInitialDriveMaxFlatVel", 150.0)
    return {
        "MassKg": num("fMass", 1500.0),
        "DragCoeff": num("fInitialDragCoeff", 10.0),
        "CentreOfMassOffset": h.get("vecCentreOfMassOffset", [0, 0, 0]),
        "DriveBiasFront": num("fDriveBiasFront", 0.0),
        "Gears": int(num("nInitialDriveGears", 6)),
        "DriveForce": num("fInitialDriveForce", 0.3),
        "DriveInertia": num("fDriveInertia", 1.0),
        "MaxFlatVelKmh": max_kmh,
        "BrakeForce": num("fBrakeForce", 1.0),
        "BrakeBiasFront": num("fBrakeBiasFront", 0.5),
        "HandBrakeForce": num("fHandBrakeForce", 0.7),
        "SteeringLockDeg": num("fSteeringLock", 35.0),
        "TractionCurveMax": num("fTractionCurveMax", 2.0),
        "TractionCurveMin": num("fTractionCurveMin", 1.8),
        "SuspensionForce": num("fSuspensionForce", 2.0),
        "SuspensionUpperLimit": num("fSuspensionUpperLimit", 0.1),
        "SuspensionLowerLimit": num("fSuspensionLowerLimit", -0.1),
        "SuspensionRaise": num("fSuspensionRaise", 0.0),
        "ModelFlags": h.get("strModelFlags", ""),
        "HandlingFlags": h.get("strHandlingFlags", ""),
    }
