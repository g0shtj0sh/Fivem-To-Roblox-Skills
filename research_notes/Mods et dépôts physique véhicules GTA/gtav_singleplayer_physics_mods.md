# GTA V single-player mods that change, improve or expose vehicle physics (gta5-mods.com, GTAForums, GitHub, Nexus)

Scope: ScriptHookV / ScriptHookVDotNet / data-file mods for GTA V story mode. FiveM resources appear only where a single-player mod has a FiveM port that exposes its algorithm.

Companion note: `research_notes/Physique véhicules GTA V Roblox/gta_physics_code_reverse.md` (Q2) already holds the drivetrain formulas taken from ikt's Manual Transmission, Custom Torque Map, Custom Gear Ratios and TurboFix code: normalised RPM, the torque curve, clutch 0.1 on shift, gear top speed = DriveMaxFlatVel/ratio. They are **not repeated** here, only referenced. This note adds the rest of the mod catalogue, the hidden-assist evidence and the handling packs.

Legend:
- **[DOC/CODE]** = read in source code or the author's technical README.
- **[MEASURED]** = the author states the value was measured in game.
- **[OPINION]** = the author's design opinion or marketing claim.
- **[INFERENCE]** = my reading.

---

## Q0. Annotated catalogue: which mods are most relevant, who made them, are they open source, what do they change and how?

### Takeaway
About 25 relevant mods were found. Only a few are both open source and technically revealing:
- **ikt's Manual Transmission (MT)**: C++, GitHub, with memory patches of the game's steering assist, auto-shift, clutch, ABS, throttle and brake.
- **ikt's Handling Replacement / Real Time Handling Editor / GTAVHandlingInfo**: handling memory layout and parameter semantics.
- **Eddlm's Autosport Racing System**: C#, GitHub.
- **InversePower**: the logic is visible through a Lua port.

Everything else is either:
- a handling.meta / materials.dat data pack (Realistic Driving V, Drive V, Project Skill Issue, Eddlm's packs, Surface Traction Overhaul, deformation packs), or
- a small closed .NET/ASI script built on a handful of natives:
  - `SET_VEHICLE_REDUCE_GRIP`
  - `SET_VEHICLE_CHEAT_POWER_INCREASE` (= FiveM `SetVehicleEngineTorqueMultiplier`)
  - `MODIFY_VEHICLE_TOP_SPEED` (= FiveM `SetVehicleEnginePowerMultiplier`)
  - `APPLY_FORCE_TO_ENTITY(_CENTER_OF_MASS)`
  - disabling the `VehicleMoveLeftRight`/`VehicleMoveUpDown` controls

### Cited Findings

#### A. Open-source script mods (highest value for re-implementation)

1. **Manual Transmission & Steering Wheel Support**: ikt (GitHub `ikt32`, formerly `E66666666`)
   - Open source, C++: https://github.com/ikt32/GTAVManualTransmission. Docs: [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).
   - Changes: manual or sequential gearbox, clutch, stalling, engine braking, and the following driving assists [DOC] — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md):
     - ABS
     - Traction Control
     - Stability Control: "detects understeer and oversteer and smartly applies individual brakes"
     - Launch Control
     - LSD ("sends more power to the slower wheel")
     - Adaptive AWD
     - Cruise Control
     - custom steering
   - How, memory patches [CODE] — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp). Each patch is commented in source:
     - "When disabled, shift-up doesn't trigger" / "shift-down doesn't trigger"
     - "clutch doesn't disengage on low RPMs" / "on redline"
     - "game doesn't lift throttle during shifts"
     - "drive @ wheel doesn't decrease"
     - "brake pressure doesn't decrease"
     - "ABS doesn't trigger (all vehicles/wheels (?))"
     - "**Disables countersteer/steering assist**"
     - "Disables user steering input for total script control"
   - How, natives: `APPLY_FORCE_TO_ENTITY_CENTER_OF_MASS` for its "hill gravity" assist; `PAD::DISABLE_CONTROL_ACTION` on `ControlVehicleMoveLeftRight/UpDown` to remove "magic movements" — [script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp), [CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp).
   - Teaches: see Q2/Q3. The existence of a game steering-assist branch, the in-air/burnout "magic" torques tied to the left/right and up/down inputs, and the game's built-in ABS flag path.

2. **Handling Replacement library**: ikt, open source — https://github.com/ikt32/GTAVHandlingReplacement
   - "clones the handling of a vehicle, and assign the copy to the vehicle, so only that vehicle is affected by changes to its handling data". Needed because CHandlingData is **shared per model**.
   - Usage: write a float at `handlingDataReplace + fInitialDriveForceOffset`.
   - Credits FiveM for "how to properly replace/clone subhandlingdata, and the rage alloc/free" [DOC] — [README](https://github.com/ikt32/GTAVHandlingReplacement/blob/master/README.md).

3. **Real Time Handling Editor** and **GTAVHandlingInfo**: ikt, open source — https://github.com/ikt32/GTAVHandlingEditor, https://github.com/ikt32/GTAVHandlingInfo
   - Live editing of the CHandlingData fields, including the sub-handling classes `CCarHandlingData` (incl. AdvancedData), `CBikeHandlingData`, `CFlyingHandlingData` and others.
   - Draws the COM and roll-centre heights [DOC] — [README](https://github.com/ikt32/GTAVHandlingEditor/blob/master/README.md).
   - Parameter semantics are in `notes.json` (see Q1/Q3) — [notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json).

4. **Autosport Racing System (ARS)**: Eddlm, open source C# — https://github.com/Eddlm/autosport-racing-system-gta
   - Custom racing AI ("Native AI is off"), optional nitrous for everyone.
   - Credits MT: "Referencing Manual Transmission helped me inmensely … to control the cars and read/apply raw data to memory" [DOC] — [README](https://github.com/Eddlm/autosport-racing-system-gta/blob/master/README.md).
   - [INFERENCE] Its AI vehicle-control code is a second open-source reader of the same memory offsets. Not inspected in detail here.

5. **InversePower**: ikt (v2.0.0, Aug 2021) — [gta5-mods page](https://www.gta5-mods.com/scripts/inversepower)
   - Purpose: "counteracts vehicles in GTA V seeming to lose power when the vehicle is sliding … The lower the speed and the higher your angle, the more power is added".
   - Pinned author comment: v2 removed the "power" part because it "actually also changed top speeds when called" and "just changes torque".
   - Source of the original: not located. The algorithm of the v1 logic is open in the FiveM Lua port [CODE] — [InversePower-FiveM/InversePower.lua](https://github.com/Blumlaut/InversePower-FiveM/blob/master/InversePower.lua):
     - `angle = acos(vRel.y / speed)` in degrees (the slip angle of the body)
     - `speed_mult = (35 - speed)/35`
     - `mult = 1 + adj * ((angle/90)*angle_impact + (angle/90)*speed_mult*speed_impact)`
     - applied via `SetVehicleEngineTorqueMultiplier` and `SetVehicleEnginePowerMultiplier`
     - only when `deadzone < angle < 80°` and the throttle exceeds the brake
     - deadzone presets 25°, 15° or 10°
   - Port README: "InversePower tries to counteract the fact that GTA V cuts off power when your car starts gliding" — [README](https://github.com/Blumlaut/InversePower-FiveM/blob/master/README.md).
   - [OPINION/claim, not measured in the source]: that GTA cuts power while sliding.

#### B. ikt's closed-source (Patreon-distributed) scripts with public technical READMEs
Details of these three are in the companion note.

6. **Custom Gear Ratios (CGR)** — [readme](https://github.com/ikt32/scripts-updates/blob/master/5-cgr-readme.md). Writes the per-vehicle gear ratio array and DriveMaxVel in memory.
7. **Custom Torque Map (CTM)** — [readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md). Replaces the game's hard-coded flat-then-60 % torque curve.
8. **TurboFix** — [readme](https://github.com/ikt32/scripts-updates/blob/master/5-turbofix-readme.md):
   - "The original turbo only adds 10% torque when fully spooled up" and "takes a very long time to spool up".
   - Adds configurable boost, spool and anti-lag. Supports NPC vehicles [DOC].

#### C. Handling / data packs (no code; they change handling.meta, materials.dat, wheelfx.dat). See Q1.

9. **Realistic Driving V**: Killatomate (v2.5, 645k downloads) — [page](https://www.gta5-mods.com/vehicles/realistic-driving-v).
10. **Drive V (Realistic Driving / Handling & Damage)**: PermissionToLand — [page](https://www.gta5-mods.com/vehicles/drive-v-realistic-driving-car-handling). FiveM port: https://github.com/Weilher420/Drive-V-Fivem-port.
11. **"Project Skill Issue" handling overhaul**: ikt — [readme](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md). Handling.meta plus materials.dat plus CTM/CGR/TurboFix configs.
12. **Eddlm's Realish / Lore-Friendly handling packs** and **TheNewHandlingProject**:
    - The packs are listed as recommended in the [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).
    - TheNewHandlingProject is an open data repo: https://github.com/Eddlm/TheNewHandlingProject ("GTA V handling project to make the vehicles' behavior more coherent overall"). Its README describes a data-only FiveM resource loading `data/handling_*.meta` — [README](https://github.com/Eddlm/TheNewHandlingProject/blob/master/README.md).
    - Eddlm's **Handling-Tools guide and editor** are the documentation companion — https://eddlm.github.io/Handling-Tools/guide.
13. **Surface Traction Overhaul (realistic road grip and braking)**: Impactjunky — [page](https://www.gta5-mods.com/misc/realistic-road-grip-and-braking):
    - Edits **materials.dat** (surface grip) plus a matching **wheelfx.dat** ("for accurate tire mark length").
    - Presets of −20 % and −30 % road grip.
    - Claim: "this could be solved with no handling changes at all by simply decreasing surface traction to more realistic levels closer to what they were in GTAIV" [OPINION].
14. **Realistic Vehicle Deformation Damage** (author not shown on the scraped page) — [page](https://www.gta5-mods.com/misc/realistic-vehicle-deformation-damage). "multiplies vehicle deformation damage x2.25 and engine damage x2.33" (handling.meta damage multipliers) "(like GTA IV)".
15. **Drift Handling Pack**: alex20121981 — [page](https://www.gta5-mods.com/vehicles/drift-handling-pack). Per-car RWD/4WD "arcade drift" handlings. The search snippet notes: "Centre of gravity can be moved front & rear to reduce or increase rear tyre grip" — [search excerpt](https://www.gta5-mods.com/vehicles/drift-handling-pack).

#### D. Closed script mods that change physics live (from descriptions)

16. **Drift on Demand 2.0**: Eddlm — [page](https://www.gta5-mods.com/scripts/drift-on-demand)
    - "This script abuses SET_VEHICLE_REDUCE_GRIP by turning it on and off every 10 ticks, reducing the vehicle's grip for 10 ticks, then letting it have its normal grip for another 10 ticks".
    - The mouse wheel "finetune[s] the sliding multiplier".
    - The page links source on pastebin (http://pastebin.com/gEKg3tU5) [DOC].
17. **Drift Assist**: InfamousSabre — [gta5-mods](https://www.gta5-mods.com/scripts/drift-assist) (page content did not render). Mirror text: "This script simply gives your car a little more power during a slide, enabling you to maintain speed and angle" — [gta5mod.net mirror](https://gta5mod.net/gta-5-mods/scripts/drift-assist-1-1/). InversePower credits it as the inspiration — [InversePower](https://www.gta5-mods.com/scripts/inversepower).
18. **Drift V – Realistic Drifting and Countersteer Drift Assist**: cooleo987, Nexus (GTA V Enhanced) — [page](https://www.nexusmods.com/gta5enhanced/mods/1868):
    - "automatic countersteering, yaw stabilization, adjustable steering lock" (100–135 %)
    - "seven tire-grip presets ranging from -3 to +3", "Rebalances GTA's existing tire grip"
    - torque ×1…×1000, default ×3
    - a G-meter with sideslip angle
    - "modifies GTA V's existing handling and adds scripted steering and yaw assistance"
    - Source: not found.
19. **Drift Mod (hold Shift)**: AntonioMontanaGTA — [page](https://www.gta5-mods.com/scripts/drift-mod-for-gta-5-legacy-version-2026). Swaps to drift handling at runtime; "Release it and the vehicle instantly snaps back to stock handling nothing is written to handling.meta". Native ASI build. [INFERENCE] It writes CHandlingData in memory.
20. **Brake To Drift** — [page](https://www.gta5-mods.com/scripts/brake-to-drift). The page returned 502. Search excerpt only: "drift script that reduces tire grip. Drift forces fade as grip returns, allowing the car to carry its momentum through the corner". Author and method not verified.
21. **Traction Control System** (.NET, v1.0, 2018; author not shown in the scrape; credits Eddlm for a brake-light fix) — [page](https://uk.gta5-mods.com/scripts/traction-control-system):
    - "does NOT cheat … does not modify any handling and/or grip characteristics, nor does it modify physics … it analyzes forward wheel slip and makes millisecond adjustments to the user's input to compensate".
    - Exposes a public `TCSactive` variable [DOC].
22. **Mid-Air AutoCorrection disabler** (`NoMidAirControl.dll`, 2016; author not captured) — [page](https://www.gta5-mods.com/scripts/mid-air-autocorrection-aftertouch-control-disabler). See Q3. Contrasted with **ZiPPO RAID's "Disable Mid-Air Vehicle Control"**, which disables controls — [link](https://es.gta5-mods.com/scripts/disable-mid-air-vehicle-control).
23. **ARAC (Anti Rollover And Air Control) 1.0.1**: IAmJFry — [mirror](https://gta5mod.net/gta-5-mods/scripts/arac-anti-rollover-and-air-control-1-0-1/). "disables the ability to roll your car back over if it's upside down and disables the ability to control your vehicle while in air". Has an ini toggle for each feature.
24. **No Car Rolling 1.0** (MBs) — [page](https://www.gta5-mods.com/scripts/mbs-no-car-rolling). The page returned 502. Search excerpt of a user comment: "when you land upside down the vehicles horn is disabled and you lose air control".
25. **True Realistic Driving V (RealisticMass)**: any333, V5.5 — [page](https://www.gta5-mods.com/scripts/true-realistic-driving-v-realistic-mass-v0-1-beta):
    - "GTA V doesn't take vehicle mass into account for its car physics - this mod tries to mitigate that by adding inertia forces based on acceleration … Both linear and rotational inertia".
    - V5: "Calculation of forces is now handled by the game engine"; added "RealisticGravity … You might want to increase fSuspensionForce for this".
    - Built from ikt's Real Time Handling Editor.
    - [OPINION, contestable]: the "mass not taken into account" claim. See Q3 Gaps.
26. **Realistic Nitro 1.7.1** (author not captured; source on pastebin http://pastebin.com/faud6jwS) — [page](https://www.gta5-mods.com/scripts/realistic-nitro):
    - "'Realistic', as in, no magic pushing your car, this script actually makes the car have more engine power … reaching top speed in no time and probably going over it".
    - Has an `EngineMultiplier` setting and optional engine damage.
    - [INFERENCE] It uses the engine power/torque multiplier natives rather than `APPLY_FORCE_TO_ENTITY`.
27. **Race Boost For All Vehicles [ASI] (Enhanced) 1.3** — [page excerpt](https://www.gta5-mods.com/scripts/race-boost-for-all-vehicles-asi-enhanced): "enables race boost for all vehicles … customize the boost settings inside the .ini". [INFERENCE] It uses the game's own nitrous system; see the `SET_OVERRIDE_NITROUS_LEVEL` native in Q2.
28. **ACSPatch (Auto Center Steering Patch)** — recommended by MT for "Keep wheels turned when exiting cars" — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md). It is a memory patch of the game's steering auto-centre on exit.

### Inferences
- The only places where GTA's internal vehicle code is shown at the instruction level are ikt's open-source MT patches and the FiveM-derived handling-clone code. Every other script mod uses a handful of public natives, so its physics knowledge is empirical.
- For a Roblox port, the reusable logic is:
  - MT's assists: ABS / TCS / ESC / LSD / adaptive AWD.
  - MT's custom steering: countersteer plus speed-sensitive reduction.
  - InversePower's slip-angle-based torque boost.

### Gaps
- No source found for Drift Assist (InfamousSabre), Drift V (cooleo987), Brake To Drift, Traction Control System, ARAC, No Car Rolling, Mid-Air AutoCorrection disabler or RealisticMass. The two pastebin links (Drift on Demand, Realistic Nitro) were not opened.
- Authors of the deformation mod, the TCS mod, the mid-air disabler and Realistic Nitro are not confirmed: the scraped page content did not include the uploader.
- The "Vehicle Gravity / Better Airtime" mods named in the brief were not found as distinct gta5-mods entries. The searches returned gravity guns and handling packs instead.

---

## Q1. Which handling packs are the most respected, and what systematic changes do they make to handling.meta values (and why)?

### Takeaway
The respected realism packs are Realistic Driving V, Drive V, ikt's Project Skill Issue, Eddlm's Realish / Lore-Friendly, and Aquaphobic's packs. They converge on the same systematic edits:
1. lower grip (`fTractionCurveMax` ≈ 1.2–1.6 g) and much lower optimal slip angle (`fTractionCurveLateral` ≈ 6–9° vs the vanilla ≈ 22.5°)
2. `fLowSpeedTractionLossMult = 0`
3. remove gravity-boosting off-road flags and the dirt-road speed cap
4. realistic power, set as torque/mass
5. calmer yaw (inertia), plus roll-centre / COM work for weight transfer
6. brake-bias correction and per-car ABS flags
7. `FREEWHEEL_NO_GAS`
8. more deformation

### Cited Findings

**Endorsements**
- ikt's MT readme lists, as "essential for playing with a wheel": Project Skill Issue, Realistic Driving V (killatomate), Aquaphobic's Realistic Handling Pack, Eddlm's Lore Friendly and Realish packs. Its reason: "The default grip levels cause the wheel to bounce left and right because they're too grippy" [OPINION] — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).

**Realistic Driving V (Killatomate)**
- Claims [MEASURED, per author] "Every single change made by this mod has been MEASURED INGAME and CONFIRMED"; 357 vehicles, about 3.5 h each.
- Systematic changes listed in the v2.0 changelog:
  - "rework of all driveable surfaces (grip and properties)"
  - "removed 130kph speed cap on dirt roads"
  - "curbs and small bumps have increased effect on handling"
  - "improved weight transfer and vehicle rollover"
  - "new tires physics allow for less understeer"
  - "drifting requires active countersteer"
  - "Introduction of proper downforce"
  - "Introduction of non-ABS cars"
  - "automated brakes have been disabled for every single vehicle"
  - a "Scaled Topspeed" variant "offering speed governor and brake assist"
- It ships "more realistic InversePower settings".
- Warns that custom models "have completely different center of mass and wheelbase".
- Source: [page](https://www.gta5-mods.com/vehicles/realistic-driving-v).

**Drive V (PermissionToLand)**
- "5 years and over 2,000 hours".
- "The most critical change I felt was needed was the **Z-axis rotation**, which is what made the vanilla cars feel so darty with every flick of the w[heel]". [INFERENCE] This is `vecInertiaMultiplier.z`, i.e. yaw inertia.
- Power matched to real cars, including converting SAE gross to net hp.
- "Off-road traction has been overhauled".
- "Damage/deformation has been increased to a realistic level, similar to GTAIV".
- "Downforce has been removed from everything except supercars".
- Ride heights raised.
- Removed "the advanced flag that significantly lowers grip artificially" for the new Drift cars.
- Source: [page](https://www.gta5-mods.com/vehicles/drive-v-realistic-driving-car-handling).

**Project Skill Issue (ikt)**
Source for everything below: [readme](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md).
- "Realistic traction values …, removal of unrealistic low-speed traction loss, allow tire deformation".
- "Uses inertia, suspension and traction balance changes to allow weight transfer, keeps vehicle responsive despite realistically low grip values".
- "Braking bias correction to reduce unrealistic rear-wheel brake locking, disable ABS for appropriate vehicles".
- "Reduce excessive off-throttle slowing".
- "**Remove the artificial dirt-road speed cap** and increase surface drag instead".
- "**Remove off-road flags, which artificially boosted gravity**".
- Powertrain via CTM / CGR / TurboFix, including "CVT simulation".
- It was built from "archetypes based on vanilla handling values" with AI assistance [DOC].

**ikt's handling guide** — [handling-guide.md](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md)
- Vanilla's two main issues: "Slip angles are too high … even causes significant delay between the front wheels turning and the car changing direction … like using soft balloons as tires" and "Grip levels are too high".
- Edits he always makes:
  - reduce `fInitialDragCoeff`
  - `fLowSpeedTractionLossMult` = 0
  - `FREEWHEEL_NO_GAS`
  - `TYRES_CAN_CLIP` "to simulate tire compression"
  - check the ABS flags

**Grip and slip-angle targets** [DOC] — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md)
- `fTractionCurveLateral`: street 9.3–8.5°, semi-slick 7.5°, slick 6.0°, "not exceed 12.5 degrees".
- `fTractionCurveMax/Min` ≈ g at neutral load.
- Assetto Corsa references: 1.21 to 1.58 g.
- "Most handlings use a high value (sometimes paired with **flags that increase gravity**) … I recommend running `strHandlingFlags` with `20100`, which does not enable gravity-modifying flags".

**Eddlm's guide**
Source for everything below: [Handling-Tools guide](https://eddlm.github.io/Handling-Tools/guide).
- [DOC/OPINION] Grip, torque, braking and drag are all expressed in g.
- "fBrakeForce applies **per wheel** … use about a 1/4" of the traction value.
- `fBrakeBiasFront` 0.5 = equal; "usually between 0.55 and 0.7".
- "V simulates grip gains (and loses) from suspension pressure", most visible on FWD launches.
- "The car will pivot around the CoM while mid-air, but pivot around fRollCentreHeight while on the ground".
- Weight transfer = the lever between CoM Z and the roll centre.
- "the rim size on the model does not affect acceleration or speed".
- First and last gear ratios are "always 3.33 and 0.9".
- Downforce:
  - base 0.035 g, ×2 with a spoiler
  - for `fDownforceModifier` 1.01 to 99.99, "0Gs as the car is stopped, which ramps up to 0.035Gs as the car reaches its top speed", multiplied by the modifier
  - active spoilers ignore the modifier
- Deformation: `damageMapScale` = dent precision, `damageOffsetScale` = depth (vehicles.meta), `fDeformationDamageMult` = speed scaling.
- vecInertiaMultiplier "is responsible for the overall stability of the car".

**Downforce formula conflicts with Eddlm's**
- GTAVHandlingInfo gives: "No spoiler: Downforce = fDownforceModifier * 0.035", "Spoiler: … * 1.25", "Downforce tops out at 90% of fInitialDriveMaxFlatVel" — [notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json).
- This **conflicts** with Eddlm's "×2 with spoiler" — [guide](https://eddlm.github.io/Handling-Tools/guide). Both are unverified.

**Surface packs**
- Impactjunky lowers every drivable surface's grip in materials.dat (−20 % / −30 % presets) and loosens dirt and underwater sand — [Surface Traction Overhaul](https://www.gta5-mods.com/misc/realistic-road-grip-and-braking).
- Realistic Driving V and Project Skill Issue also ship materials.dat edits — [RDV](https://www.gta5-mods.com/vehicles/realistic-driving-v), [PSI readme](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md).

**Damage packs**
- Deformation ×2.25, engine damage ×2.33 "like GTA IV" — [page](https://www.gta5-mods.com/misc/realistic-vehicle-deformation-damage).

**Drift handling packs (data)**
- RX-7 Drift Handling: "Reworked the suspension, aimed to take more angle; improved the steering angle; raise the acceleration grip at the start" — [search excerpt](https://www.gta5-mods.com/vehicles/rx-7-drift-handling).
- Hoonigan Mustang: "Higher Grip (when the tire does not spin…) Higher Handbreak Force" — [search excerpt](https://www.gta5-mods.com/vehicles/ford-mustang-hoonigan-drift-handling).
- [INFERENCE] Drift packs raise `fSteeringLock` and handbrake force and move the COM rearward, rather than lowering grip globally.

**LS Tuners low-grip ("drift") tyres**
- Exposed only via natives from b2372: `SET_DRIFT_TYRES` / `GET_DRIFT_TYRES_SET` (0x5AC79C98C5C17F05), `SET_REDUCED_SUSPENSION_FORCE` ("Only works for vehicles that have strAdvancedFlags 0x8000 and 0x4000000 set"); and from b3095 `_SET_DRIFT_SLIP_ANGLE_LIMITS(veh, durationScalar, amplitudeScalar, slipAngleLimit)` ("First two floats relate to rumble, the last is a threshold") — [alloc8or nativedb natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json).
- Drive V removed "the advanced flag that significantly lowers grip artificially" from the drift cars — [Drive V](https://www.gta5-mods.com/vehicles/drive-v-realistic-driving-car-handling).

### Inferences
- The consensus "realism delta" from vanilla is directly portable as a Roblox tuning profile:
  - `fTractionCurveLateral` 22.5° → about 8°
  - `fTractionCurveMax` → about 1.25–1.4
  - `fLowSpeedTractionLossMult` → 0
  - no gravity-boost flags
  - lower yaw rate (inertia Z up)
  - per-wheel brake force about 1/4 of grip
- To reproduce **vanilla** GTA feel faithfully, do the opposite and keep the arcade values: a high slip-angle peak, high grip, low-speed traction loss, and the off-road gravity boost.

### Gaps
- No pack publishes a numeric table of its systematic before/after values. The figures above are the authors' prose. A diff of vanilla vs pack handling.meta would be needed.
- Aquaphobic's packs, "GT Handling" and "Realism Handling" pages were not opened.
- The exact gravity multiplier of the off-road flags (OFFROAD_ABILITIES / _X2) was not found in readable form. The GTACars glossary scrape was garbled and the entries could not be reliably attributed.

---

## Q2. Which script mods change physics live, and what do their READMEs/source say about GTA's internal model?

### Takeaway
- Live physics mods fall into four patterns:
  - (a) toggling or levelling `SET_VEHICLE_REDUCE_GRIP(_LEVEL)` (drift mods)
  - (b) scaling engine output with `SET_VEHICLE_CHEAT_POWER_INCREASE` / `MODIFY_VEHICLE_TOP_SPEED` (InversePower, nitro, Drift V)
  - (c) adding forces with `APPLY_FORCE_TO_ENTITY(_CENTER_OF_MASS)` (MT hill gravity, RealisticMass)
  - (d) memory writes to CHandlingData / CVehicle / CWheel / CTransmission fields (MT, CGR, CTM, TurboFix, Handling Replacement, Drift Mod)
- MT's source is the richest description of how the game's own assists and transmission are wired.

### Cited Findings

**Native semantics (alloc8or nativedb, SP)**
Source for this list: [natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json).
- `SET_VEHICLE_REDUCE_GRIP(veh, bool)` (0x222FF6A823D122E2): "Reduces grip significantly so it's hard to go anywhere".
- `SET_VEHICLE_REDUCE_GRIP_LEVEL(veh, int 0-3)` (b1604): "Often used in conjunction with SET_VEHICLE_REDUCE_GRIP".
- `SET_VEHICLE_CHEAT_POWER_INCREASE(veh, float)`:
  - "<1.0 decreased torque … >1.0 increased torque"
  - "Negative values will cause the vehicle to go backwards"
  - "between 0.2 and 1.8 in the decompiled scripts"
  - "needs to be called every frame".
- `MODIFY_VEHICLE_TOP_SPEED` (0x93A3996368C94158) has no description. It is the hash FiveM calls `SetVehicleEnginePowerMultiplier`, matching ikt's note that "power" "also changed top speeds" — [InversePower](https://www.gta5-mods.com/scripts/inversepower). [INFERENCE] This hash identity is from memory; check it against FiveM docs.
- `SET_VEHICLE_MAX_SPEED` (b1103): "set the speed value to 0.0 or lower" to reset.
- `APPLY_FORCE_TO_ENTITY`:
  - forceFlags: bit 0 = "Strong force flag, factor 100"; 0/1 = weak/strong force; 4/5 = weak/strong momentum
  - `isMassRel` "multiplied with the objects mass"
  - links GTAForums threads [885669](https://gtaforums.com/topic/885669-precisely-define-object-physics/) and [887362](https://gtaforums.com/topic/887362-apply-forces-and-momentums-to-entityobject/).
- `SET_VEHICLE_GRAVITY(veh, bool)` exists in SP. **No `SET_VEHICLE_GRAVITY_AMOUNT` exists in the SP nativedb.** [INFERENCE] It is a CitizenFX/FiveM extension, so SP mods must write memory or use forces.
- `SET_VEHICLE_FRICTION_OVERRIDE`: "Seems to be related to the metal parts, not tyres".
- `SET_CAR_HIGH_SPEED_BUMP_SEVERITY_MULTIPLIER(float)` exists. [INFERENCE] It is relevant to curb and bump response.
- `SET_TYRE_MAXIMUM_GRIP_DIFFERENCE_DUE_TO_WEAR_RATE`: Open-Wheel tyre compounds soft 0.05 / medium 0.45 / hard 0.8.
- `_SET_OVERRIDE_TRACTION_LOSS_MULTIPLIER(veh, float)` (b3095).
- `SET_OVERRIDE_NITROUS_LEVEL(veh, toggle, level, power, rechargeTime, disableSound)` (b1604), plus the b3095 nitrous natives.
- `GET_VEHICLE_HAS_KERS`: "HF_HAS_KERS (strHandlingFlags 0x4)".
- `SET_VEHICLE_ENGINE_HEALTH`:
  - "1000 is max", "Begins leaking gas at around 650"
  - "0 and below: Engine catches fire"
  - "300: Engine is smoking and losing functionality"
  - "-4000: Engine is destroyed"
- `SET_VEHICLE_STRONG`: "will not take crash damage".
- `SET_VEHICLE_HAS_STRONG_AXLES`: "axles won't bend".
- `SET_VEHICLE_STEER_BIAS`: "Locks the vehicle's steering … Requires to be called onTick".

**Drift via grip toggling**
- Eddlm's Drift on Demand pulses `SET_VEHICLE_REDUCE_GRIP` 10 ticks on / 10 off, with a mouse-wheel multiplier — [page](https://www.gta5-mods.com/scripts/drift-on-demand).
- [INFERENCE] This pulsing implies the native is a binary low-grip mode, too strong to hold continuously. The b1604 `_LEVEL` variant (0–3) is the graduated replacement.

**Torque boost while sliding**
- InversePower (above) and Drift Assist ("a little more power during a slide") — [mirror](https://gta5mod.net/gta-5-mods/scripts/drift-assist-1-1/).
- Drift V adds "automatic countersteering, yaw stabilization", grip presets and torque ×3 by default — [Nexus](https://www.nexusmods.com/gta5enhanced/mods/1868).

**MT custom steering (open source, re-implementable)**
Source for this list: [CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp).
- Speed-sensitive reduction, using the local forward speed v (m/s):
  - when v > 3: `mult = 0.15 + 0.9^(|v| − 7.2)`, floored to 3 decimals, clamped ≤ 1
  - then `mult = 1 + (mult − 1)·SteeringReduction`
- Countersteer assist:
  - `travelDir = atan2(vel.y, vel.x) − π/2` (the slip angle of the velocity), wrapped to ±π/2 and sign-corrected for reverse
  - scaled by `CountersteerMult/SteeringMult`, clamped to ±CountersteerLimit
  - `finalReduction = map(|travelDir|, 0, limit, reduction, 1)`
  - `steer = travelDir + input·finalReduction·maxSteer`, clamped to ±maxSteer
- These are MT's own (user-tunable) model, written to replace the game's countersteer after patching it out. [INFERENCE] They are not proven to be the game's formula.
- Options: "disable steering reduction on handbrake" — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).
- Steering is written either through natives or "setting the value directly in memory after some patches" — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).

**MT assists**
- TCS/LC "use relative slip" — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).
- Priorities: "Burnout -> Engine lock -> ABS -> Traction Control -> Engine braking" — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).
- ESC uses individual brakes, "also use rear wheels at large corrections" — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).
- FFB "Response normalized for excessive fTractionCurve values GTA uses normally" — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).
- FFB force "is proportional to the optimal wheel slip angle, as defined by `fTractionCurveLateral`" — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).
- Slip-angle and understeer detection compare against `fTractionCurveLateral`. See the companion note's citation of [DrivingAssists.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/DrivingAssists.cpp).

**Live handling writes**
- CHandlingData is shared per model, hence the Handling Replacement clone for per-vehicle live changes such as the variable `fDriveBiasFront` — [README](https://github.com/ikt32/GTAVHandlingReplacement/blob/master/README.md).
- Drift Mod swaps handling in memory and reverts on key release — [page](https://www.gta5-mods.com/scripts/drift-mod-for-gta-5-legacy-version-2026).

**Nitro**
- Realistic Nitro raises engine power (no push force) via an `EngineMultiplier` — [page](https://www.gta5-mods.com/scripts/realistic-nitro).
- Vanilla turbo = +10 % torque at full spool — [TurboFix readme](https://github.com/ikt32/scripts-updates/blob/master/5-turbofix-readme.md).

**Mass and gravity**
- RealisticMass adds linear and rotational inertia forces from acceleration, plus a RealisticGravity option — [page](https://www.gta5-mods.com/scripts/true-realistic-driving-v-realistic-mass-v0-1-beta).
- MT hill gravity, when speed < 2 m/s, all wheels are on the ground and no brake or handbrake is applied, adds `APPLY_FORCE_TO_ENTITY_CENTER_OF_MASS(flag 1, y = −(pitch/150)·1.1·clutchNeutral)` and, for pitch > 10°, `−(pitch/90)·0.35·clutchNeutral` (local frame). Its comment reads "TODO: Needs improvement/proper fix" — [script.cpp `functionHillGravity`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp).

**Frame-rate coupling**
- "GTA V's physics and scripting engine is coupled to the frame rate. Playing the game at a higher framerate results in more accurate force feedback" — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).

### Inferences
- The hill-gravity assist exists because a stopped GTA car on a slope does not roll back naturally in neutral. [INFERENCE] There is likely a low-speed hold, friction or sleep threshold in the game. A Roblox port with honest friction will roll back unless it adds a similar hold.
- That "nothing written to handling.meta" drift mods work at all confirms CHandlingData is read live every frame. A Roblox port can expose the same parameters as runtime attributes.
- InversePower, Drift Assist and Drift V all add torque in proportion to slip angle. This suggests the stock model loses net drive force in slides: the friction circle saturates and [unverified] power may also be cut. A faithful port should **not** add InversePower-style boosts if the goal is vanilla feel.

### Gaps
- Whether GTA actually "cuts power when sliding" (InversePower's premise) or merely saturates the combined traction is not proven by any source found.
- The source of RealisticMass and its force formulas was not available.
- The FiveM/SP identity of `MODIFY_VEHICLE_TOP_SPEED` ↔ `SetVehicleEnginePowerMultiplier` was not re-verified against FiveM docs in this session.

---

## Q3. What is known from these mods about GTA's built-in arcade assists (in-air rotation, self-righting, curb boost, steering assist, low-speed traction loss, handbrake boost)?

### Takeaway
Mods document six hidden assists:
1. A **steering / countersteer assist**: a game code branch that ikt patches out with a JE→JMP.
2. **In-air and burnout "magic" torques** driven by the left/right and up/down vehicle inputs, plus an automatic **mid-air self-righting**.
3. A **roll-back-over** ability when upside down.
4. **Low-speed traction loss** (`fLowSpeedTractionLossMult`).
5. **Gravity-boosting off-road flags** and a **130 km/h dirt-road speed cap**.
6. **Suspension-compression speed gain** ("curb boost").

Most are documented qualitatively only. No mod publishes the internal formulas for the in-air or self-righting torques.

### Cited Findings

**Steering assist**
- MT patch comment "Disables countersteer/steering assist". The byte pattern `45 84 ED | 0F 84 D0 01 00 00 | 0F 28 4B 70 …` (test r13l; je …) is turned into `E9 D1 01 00 00 90` (JMP + NOP), i.e. the assist block is skipped unconditionally. Validity is noted per build (b791 to b1493, b1604 variant).
- The pattern is credited to InfamousSabre.
- Source: [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp).
- InfamousSabre also authored "Custom Steering" (listed as conflicting with MT's steering patching) — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).

**In-air and burnout control ("magic movements")**
- MT disables `ControlVehicleMoveLeftRight` and `ControlVehicleMoveUpDown` to "Only disable the 'magic' movements, such as burnout or in-air acrobatics".
- Exceptions:
  - bikes ("Should be able to pitch … shift weight")
  - wet amphibious vehicles
  - hovering vehicles
  - tow arm / forklift / scoop up-down while all wheels are on the ground
- Source: [CustomSteering.cpp `disableControls`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp).
- [INFERENCE] The game applies yaw torque from left/right during burnouts, and pitch/roll torque in the air, from these two inputs.

**Mid-air self-righting (automatic)**
- "This script disables the mid-air adjustments (self-righting) the game does to your vehicle to help you land on your wheels … the game shouldn't [rotate a truck], either (because, believe me, it tries to)".
- It disables the "ability to rotate your vehicle while in mid-air", "while stuck/upside down", and "to adjust your vehicle's heading when doing a burnout".
- It "doesn't disable any controls, but the ability itself … all the magic forces, including the game-induced ones, are gone".
- Side effects: horn disabled, no control while free-aiming, NPCs can't drive. Helicopters, planes, boats, quads, bikes and bicycles are unaffected.
- Source: [Mid-Air AutoCorrection disabler](https://www.gta5-mods.com/scripts/mid-air-autocorrection-aftertouch-control-disabler).
- [INFERENCE] The horn side effect suggests it manipulates a vehicle/driver state flag rather than an input.

**Roll-back-over when upside down**
- ARAC "disables the ability to roll your car back over if it's upside down" — [mirror](https://gta5mod.net/gta-5-mods/scripts/arac-anti-rollover-and-air-control-1-0-1/).
- No Car Rolling user comment: horn disabled and air control lost after landing upside down — [excerpt](https://www.gta5-mods.com/scripts/mbs-no-car-rolling).

**Low-speed traction loss**
- "Artificial grip loss at low speeds. 0.0 gives no grip loss. Mostly noticeable when accelerating from a stop. Advice: Turn this off (0.0)" — [GTAVHandlingInfo notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json).
- Project Skill Issue: "removal of unrealistic low-speed traction loss" — [readme](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md).

**Other hidden lateral and drive forces (GTAVHandlingInfo)**
Source for this list: [notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json).
- `fTractionSpringDeltaMax`: "Max distance of the lateral sidewall travel … Noticeable when vehicle is coming to a stop from a slide … results in a small force pulling the vehicle into the cornering direction".
- `fCamberStiffnesss`: "Lateral force pushing vehicle towards its roll direction, when tires are on ground. Negative: Uphill force … Positive: Downhill force".
- `fTractionBiasFront`: "1.0 or 0.0 cause wheels to disappear"; about 0.48 is balanced.
- Suspension rules of thumb:
  - "CompDamp + ReboundDamp = SuspensionForce gives a stable ride"
  - Rockstar's own doc line "1 / (Force * NumWheels) = Lower limit for zero force at full extension" ("unclear").

**Off-road gravity boost and dirt-road speed cap**
- "Remove off-road flags, which artificially boosted gravity" and "Remove the artificial dirt-road speed cap" — [PSI readme](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md).
- "removed 130kph speed cap on dirt roads" — [RDV](https://www.gta5-mods.com/vehicles/realistic-driving-v).
- "flags that increase gravity" — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).

**Curb boost**
- Players describe "the speed boost you get from curb boosting is directly caused by suspension compression" — [r/gtaonline](https://www.reddit.com/r/gtaonline/comments/60ydr2/curb_boosting_and_tire_types/) [community, not measured].
- "intentionally drive over curbs and bumps to compress the springs … that increases the [speed]" — [GameFAQs](https://gamefaqs.gamespot.com/boards/805602-grand-theft-auto-online/76458775).
- A FiveM physics script advertises removing "speed gained from bumps and brake boosting" — [YouTube description](https://www.youtube.com/watch?v=NMIaNcNNzZY) (secondary).
- RDV makes "curbs and small bumps have increased effect on handling" — [page](https://www.gta5-mods.com/vehicles/realistic-driving-v).
- [INFERENCE] `SET_CAR_HIGH_SPEED_BUMP_SEVERITY_MULTIPLIER` is the only native that touches this area — [nativedb](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json).

**Handbrake boost and gearbox flags**
- The GTACars glossary contains an advanced-flag description: "applies a hard speed limit per gear like a real life gearbox. For vehicles in the Tuners sub-class, this flag only limits the speed in the last two gears (**allowing handbrake boosting**)" — [glossary](https://gtacars.net/gta5/glossary).
- The scrape garbled which flag name this belongs to. Visible flag names include `gearbox_direct_shift (11)`, `assist_traction_control (13)`, `assist_stability_control (14)`, `block_increased_rot_velocity_with_drive_force (19)`, `fix_old_bugs (26)` and the meta flag `increase_low_speed_torque` ("Torque is increased at low speed to aid getting up hills").
- [INFERENCE] `block_increased_rot_velocity_with_drive_force` implies the stock game **adds rotational (yaw) velocity proportional to drive force**, i.e. a power-oversteer / turn-in assist.

**Built-in ABS, TCS and ESC**
- The game has its own ABS (MT: "Fix ABS UI not coming up for GTA's ABS") — [changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md).
- The ABS patch NOPs an `or eax,[rbp+04]` into a wheel drive-flags field ("When disabled, ABS doesn't trigger") — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp).
- Realistic Driving V "disabled automated brakes for every single vehicle" — [RDV](https://www.gta5-mods.com/vehicles/realistic-driving-v).

**Automatic transmission behaviour (assists to replicate)**
- The game drops the clutch at low RPM and at the rev limit, lifts the throttle during shifts, and auto-upshifts and downshifts. Each is a separate patchable site — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp).
- From v1.0.2545.0, "pressing throttle turns on the engine regardless of script settings … hardcoded" — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md).

**Power loss in slides**
- Claimed by InversePower: "GTA V cuts off power when your car starts gliding" [OPINION] — [InversePower-FiveM README](https://github.com/Blumlaut/InversePower-FiveM/blob/master/README.md).

**Mass**
- Claimed by RealisticMass: "GTA V doesn't take vehicle mass into account for its car physics" [OPINION].
- This contradicts ikt's measured `fInitialDriveForce × fMass` ≈ torque relationship, see the companion note, and Eddlm's per-wheel force-in-g model — [RealisticMass](https://www.gta5-mods.com/scripts/true-realistic-driving-v-realistic-mass-v0-1-beta); [handling-guide](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md).
- [INFERENCE] Grip, drive and brake are mass-normalised (expressed in g), so changing fMass mostly affects collisions, not acceleration. That is the likely source of the "mass ignored" perception.

### Inferences
Checklist of arcade layers a faithful Roblox port of **vanilla** GTA V should implement as explicit, tunable systems on top of base tyre physics. Each should be toggleable, since the realism mods prove players notice each one.
1. **Steering assist / auto-countersteer**: MT's `calculateDesiredHeading` is a usable model. Velocity slip angle is added to the steer command, clamped, with speed-sensitive reduction `0.15 + 0.9^(v−7.2)`.
2. **In-air control**: pitch/roll torque from the up/down and left/right inputs while airborne. Disabled for bikes in MT's logic only because bikes legitimately lean.
3. **Auto self-right in mid-air** plus **flip-back when upside down**.
4. **Burnout yaw control**: left/right yaw torque during a burnout.
5. **Low-speed traction loss** scaled by `fLowSpeedTractionLossMult`.
6. **Off-road flags**: extra gravity and power, plus a 130 km/h cap on dirt-road materials.
7. **Suspension-compression forward impulse** (curb boost).
8. **Lateral sidewall spring** (`fTractionSpringDeltaMax`) and **camber force** (`fCamberStiffnesss`).
9. **Downforce as grip**: 0.035 g × modifier, speed-ramped.
10. **Built-in ABS** per the handling flag.
11. **Auto-gearbox clutch drops and throttle lift**.

### Gaps
- Magnitudes are unknown for the in-air rotation torque, the self-righting torque, curb-boost impulse size, and the dirt-road cap mechanism (material property vs handling). No mod or README found gives them. Measure in game: record angular velocity under in-air input with ScriptHookV, or use FiveM getters.
- The exact low-speed traction-loss curve (speed range and shape) is not published. See also the gap in the companion note.
- No mod was found that patches or documents a "handbrake boost" force. It appears to be an emergent gearbox/speed-limit interaction per the GTACars glossary text, but the flag attribution is unverified.
- GTAForums threads for Realistic Driving V and the mid-air mods were not read. Their page-5 discussion (https://gtaforums.com/topic/804249-vrel-realistic-driving-v/page/5/) may hold measured values.
