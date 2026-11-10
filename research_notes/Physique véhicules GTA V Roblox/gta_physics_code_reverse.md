# Open-source code and reverse-engineering write-ups on GTA V (RAGE) vehicle physics

Scope: code and technical write-ups that show how GTA V computes vehicle dynamics, so it can be rebuilt in Roblox (Luau). Researched 2026-11-10. Every repo below was cloned and its source read directly: FiveM `master` @ 5c3065c (2026-11-06), ikt's Manual Transmission `master` @ 74019c8 (2025-01-10, archived), gta-reversed `master` @ afbc26d (2026-11-04), and alexguirre/rage-parser-dumps `master`.

How much to trust each source. This scale is used throughout:
- **[DECOMP]**: taken from disassembly or decompilation, or from the game's own reflection data (parser structures). Very reliable.
- **[MEM]**: memory offsets plus behaviour seen in mods that read or write game memory. What is read is reliable; what it means is partly interpreted.
- **[MEASURED]**: fitted to in-game tests, for example acceleration runs or Cheat Engine watches.
- **[GUESS]**: community rule of thumb, or the meaning is unclear.

---

## Q1. Are there decompilation-based analyses or reconstructed class layouts of CHandlingData, CTransmission, CWheel and CVehicle physics (FiveM source, RAGE/ScriptHookV docs, "GTA V reversed" projects)?

### Takeaway
Nobody has published a decompiled GTA V wheel, tyre or transmission solver. There is no V equivalent of re3 or gta-reversed for CWheel or CTransmission. What does exist is:
- (a) the full **CHandlingData field layout** and the **load-time unit conversions** (from FiveM's handling loader and from the game's own parser dumps);
- (b) **runtime CVehicle and CWheel field maps**, found with byte patterns (FiveM `VehicleExtraNatives.cpp`, ikt's `VehicleExtensions.cpp`);
- (c) a few formulas taken from disassembly: downforce (GTACars.net), the clutch drop to 0.1 when shifting (the shift patch bytes in Manual Transmission), and the stock torque curve (measured).

To rebuild the model faithfully, you put these pieces together, plus the lineage code from GTA SA (see Q4).

### Cited Findings

**Source catalogue (link, language, coverage, trust):**

| # | Source | Lang | What it covers | Trust |
|---|---|---|---|---|
| 1 | [citizenfx/fivem: handling-loader-five/src/HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp) | C++ | `GET/SET_VEHICLE_HANDLING_FLOAT/INT/VECTOR`. Fields are looked up through RAGE parser reflection. Reproduces the game's load-time conversions (deg to rad, km/h to m/s, ×1.2, bias ×2, 1/x "ratio" fields) | DECOMP |
| 2 | [citizenfx/fivem: extra-natives-five/src/VehicleExtraNatives.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/extra-natives-five/src/VehicleExtraNatives.cpp) | C++ | Pattern-scanned CVehicle offsets (RPM, clutch, gears, gear ratios, turbo, steering, handbrake). CWheel offsets (tyre radius 0x110, rim 0x114, width 0x118, rotation speed, traction vector length, brake pressure, power, health, surface material, flags). Natives such as `GET_VEHICLE_WHEEL_SPEED`, `GET/SET_VEHICLE_GEAR_RATIO` and `GET_VEHICLE_CHEAT_POWER_INCREASE` | MEM/DECOMP |
| 3 | [alexguirre/rage-parser-dumps](https://github.com/alexguirre/rage-parser-dumps) (e.g. `dumps/gta5/b3258.json`) | JSON | The game's own `parStructure` dumps for every build (b323 to b3258+): field offsets, types and init values for CHandlingData and CCarHandlingData. Names are joaat-hashed in the JSON | DECOMP (reflection) |
| 4 | [ikt32/GTAVManualTransmission](https://github.com/ikt32/GTAVManualTransmission) (formerly E66666666; archived; later versions are Patreon-only) | C++ | `Gears/Memory/Offsets.hpp` (CHandlingData and CWheel notes), `VehicleExtensions.cpp` (about 60 pattern-derived offsets), `MemoryPatcher.cpp` (game instructions patched: auto-shift, clutch drop, throttle lift, wheel drive and brake decay, ABS, steering assist), `script.cpp` (clutch, stall, engine braking, rev-matching), `DrivingAssists.cpp` (slip ratio and slip angle, TCS/ESP/LSD), `AWD.cpp` | MEM (+ disassembly in patch comments) |
| 5 | [ikt32/scripts-updates](https://github.com/ikt32/scripts-updates): `handling-guide.md`, `5-ctm-readme.md`, `5-cgr-readme.md`, `5-turbofix-readme.md`, `5-gears-readme.md` | Markdown | Stock torque curve, normalised RPM, top-speed and gear maths, turbo +10%, units for drive force | MEASURED + MEM |
| 6 | [ikt32/GTAVHandlingInfo `notes.json`](https://github.com/ikt32/GTAVHandlingInfo) | JSON | Per-field meaning, formulas and realistic ranges (shown inside the Real Time Handling Editor) | MEASURED/GUESS |
| 7 | [ikt32/GTAVHandlingEditor](https://github.com/ikt32/GTAVHandlingEditor) | C++ | Real-time editor for CHandlingData and all SubHandlingData (Car, Bike, Flying, SpecialFlight, Boat, SeaPlane, Submarine, Trailer) | MEM |
| 8 | [GTACars.net: Downforce mechanics](https://gtacars.net/gta5/downforce) + [Glossary](https://gtacars.net/gta5/glossary) | Web | Per-wheel downforce ("WDV") formulas "taken directly from disassembled game code", with Desmos calculators | DECOMP |
| 9 | [eddlm/Handling-Tools](https://github.com/eddlm/Handling-Tools) ([live](https://eddlm.github.io/Handling-Tools/handling)) | HTML/JS | Handling visualiser: default gear-ratio tables, shift points, approximations for drag, downforce and brakes | MEASURED/GUESS |
| 10 | [gtamods.com wiki: handling.meta](https://gtamods.com/wiki/Handling.meta), [docs.w1tch.net handling](https://docs.w1tch.net/en/latest/things/handling.html) | Web | Field semantics, partly Rockstar's original comments (e.g. "Sets the drag coefficient on the rage physics archetype…"), top-speed formula | Mixed |
| 11 | [gta-reversed/gta-reversed](https://github.com/gta-reversed/gta-reversed) (SA), [re3 mirror](https://github.com/hottabxp/re3) (III/VC) | C++ | Full decompiled cTransmission, cHandlingDataMgr, CVehicle::ProcessWheel, CPhysical springs. Lineage only (see Q4) | DECOMP (older engine) |

**CHandlingData layout (b3258, from the parser dump; names resolved by hashing known field names).** Total size 0x170 (368 B). Key offsets:
- 0x0C fMass, 0x10 fInitialDragCoeff, 0x14 fDownforceModifier, 0x18 fPopUpLightRotation
- 0x20 vecCentreOfMassOffset, 0x30 vecInertiaMultiplier, 0x40 fPercentSubmerged
- 0x48 fDriveBiasFront, 0x50 nInitialDriveGears (uchar), 0x54 fDriveInertia, 0x58/0x5C fClutchChangeRateScaleUp/DownShift, 0x60 fInitialDriveForce, 0x68 fInitialDriveMaxFlatVel
- 0x6C fBrakeForce, 0x74 fBrakeBiasFront, 0x7C fHandBrakeForce, 0x80 fSteeringLock
- 0x88 fTractionCurveMax, 0x90 fTractionCurveMin, 0x98 fTractionCurveLateral, 0xA0 fTractionSpringDeltaMax, 0xA8 fLowSpeedTractionLossMult, 0xAC fCamberStiffnesss, 0xB0 fTractionBiasFront, 0xB8 fTractionLossMult
- 0xBC fSuspensionForce, 0xC0 CompDamp, 0xC4 ReboundDamp, 0xC8 UpperLimit, 0xCC LowerLimit, 0xD0 Raise, 0xD4 SuspensionBiasFront, 0xDC fAntiRollBarForce, 0xE0 AntiRollBarBiasFront, 0xE8/0xEC fRollCentreHeightFront/Rear
- 0x108 fPetrolConsumptionRate (init 0.5), 0x158 SubHandlingData array, 0x168 fWeaponDamageScaledToVehHealthMult (init 0.5)
- Two unnamed floats at 0x11C (init 1.25) and 0x120 (init 70)

CCarHandlingData (size 0x50): 0x14 fToeFront, 0x18 fToeRear, 0x1C fCamberFront, 0x20 fCamberRear, 0x24 fCastor, 0x28 fEngineResistance, 0x2C fMaxDriveBiasTransfer (init −1), 0x30 fJumpForceScale, 0x34 fIncreasedRammingForceScale, 0x38 strAdvancedFlags, 0x40 AdvancedData array. — [rage-parser-dumps b3258](https://github.com/alexguirre/rage-parser-dumps)

Manual Transmission's hand-made map matches this layout. It also names the derived runtime fields that sit between the parsed fields: 0x4C fDriveBiasRear, 0x64 fDriveMaxFlatVel, 0x70 (unknown), 0x78 fBrakeBiasRear, 0x84 fSteeringLockRatio, 0x8C fTractionCurveMaxRatio, 0x94 fTractionCurveRatio, 0x9C fTractionCurveLateralRatio, 0xA4 fTractionSpringDeltaMaxRatio, 0xB4 fTractionBiasRear, 0xD8 fSuspensionBiasRear, 0xE4 fAntiRollBarBiasRear. Flags are at 0x124 (model flags), 0x128 (handling flags) and 0x12C (damage flags), and the AI handling hash is at 0x13C. — [Offsets.hpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/Offsets.hpp)

**Load-time conversions (CHandlingData::ProcessOnLoad equivalent), as reproduced by FiveM's `setFloatField` / `getFloatField`.** Source: [HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp)
- `fInitialDriveMaxFlatVel`: stored = meta / 3.6 (m/s). The field 4 bytes before it, **fDriveMaxFlatVel**, = (meta / 3.6) × **1.2**.
- `fSteeringLock`, `fTractionCurveLateral`: stored in **radians** (`value * 0.017453292f`). The next field holds 1/rad (the "Ratio" field).
- `fTractionCurveMax/Min`: offset 0x8C = `1/fTractionCurveMax` (1e8 if max = 0). Offset 0x94 = `1/(fTractionCurveMax − fTractionCurveMin)`.
- `fTractionSpringDeltaMax`: next field = `1/value`.
- `fInitialDragCoeff`: stored = meta × **0.0001**.
- `fSuspensionCompDamp`, `fSuspensionReboundDamp`: stored = meta × **0.1**.
- `fBrakeBiasFront`, `fSuspensionBiasFront`, `fTractionBiasFront`, `fAntiRollBarBiasFront`: front = v×2 and rear = (1−v)×2. An even 0.5 split therefore gives 1.0/1.0.
- `fDriveBiasFront`: below 0.1 it snaps to (0, 1), i.e. RWD; above 0.9 it snaps to (1, 0), i.e. FWD; otherwise front = v×2 and rear = (1−v)×2.
- `fPercentSubmerged`: the field at +0x44 = 100/value.
- `nInitialDriveGears` is clamped to at most 7 when written through the native.

**Runtime CVehicle fields** (all found by pattern scanning). Sources: [VehicleExtensions.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.cpp), [VehicleExtraNatives.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/extra-natives-five/src/VehicleExtraNatives.cpp)
- Transmission block layout: nextGear (u16), currentGear (u16) at +2, topGear (u8) at +6, then the gear-ratio float array at +8. In FiveM the ratio array moved to +12 from b3095. There are 8 ratio slots up to b1493 (top gear 7) and 11 from b1604 (top gear 10).
- Drive values: driveForce, then initialDriveMaxFlatVel (+4), then driveMaxFlatVel (+8).
- currentRPM, then clutch at +0xC, then throttle at +0x10. Turbo is a separate float, and the arena boost is turbo+0x30.
- Input block: steeringInput, steeringAngle (+8), throttleP (+0x10), brakeP (+0x14). The handbrake is a bit flag.
- Other: wheels pointer, number of wheels, gravity (per vehicle), dash speed, engine temperature, and model type (0 car, 1 plane, … 11 motorcycle, 12 bicycle…).

**Runtime CWheel fields** (b2245-era layout; offsets move between builds).
- Static/geometry: 0x110 TyreRadius, 0x114 RimRadius, 0x118 TyreWidth.
- Pattern-anchored: suspension compression; angular velocity (rad/s) = compression+0xC; overheat (0 to 59; tyre pops at 59) = +0x14.
- Around the steering angle field S: S−0x14 tractionVectorLength, S−0x10 load, S−0x0C/−0x08 traction vector Y/X, S steering angle, S+4 brake pressure, S+8 power (drive).
- Also: health, drive flags (bits for powered and steered), material grip / wet grip / tyre drag / top-speed multiplier (from materials.dat), and downforce.
- Manual Transmission comments: "0x168 rotation speed rad/s, 0x16C slippage y-dir?, 0x170 heating, 0x190 tyre grip, 0x194 wet grip, 0x198 tyre drag, 0x19C top speed mult".
- Sources: [VehicleExtensions.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.cpp), [Offsets.hpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/Offsets.hpp)

**Wheel-level behaviour from Manual Transmission's comments and patches**
- Tyre surface speed = `rotationSpeed[rad/s] * TyreRadius`. Forward rotation is negative ("For forward, use negative speed"). — [VehicleExtensions.cpp/.hpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.hpp)
- Wheel "power" (drive) and "brake pressure" are per-wheel values that the game recomputes, and then **decays every frame**. "Braking/pulling the handbrake just adds to this value". To make a written value stick, MT patches out the instructions that decrease it. — [VehicleExtensions.hpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.hpp), [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)
- ABS is a bit in each wheel's drive flags, set by `or eax,[rbp+04]; mov [rsi+wheelDriveFlags],eax`. MT NOPs this to disable ABS. — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)
- The game has a built-in **countersteer / steering assist** (a conditional jump at `0F 84 D0 01 00 00 0F 28 4B 70…`). MT patches it to a JMP to disable it. — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)

**Natives that expose the model.**
- `MODIFY_VEHICLE_TOP_SPEED` "will initiate transmission setup for the given vehicle so any transmission related changes apply, it will also update the drag coefficient on the vehicle based on the percentage change". Changes to fInitialDriveForce or fInitialDriveMaxFlatVel only take effect after it is called. — [citizenfx/natives ModifyVehicleTopSpeed.md](https://github.com/citizenfx/natives/blob/c00e0ed83d06dcba2457424ba254fbaa7a05bf7e/VEHICLE/ModifyVehicleTopSpeed.md)
- alt:V's HandlingData API exposes the derived fields directly (`tractionCurveMaxRatio`, `tractionCurveLateralRatio`, …). This confirms the same runtime layout. — [docs.altv.mp HandlingData](https://docs.altv.mp/js/api/alt-client.HandlingData.html)

### Inferences
- In-game values are in SI units: m/s, radians, and metres for suspension limits. They are pre-scaled at load. A Luau port should copy the FiveM conversions exactly: ×1.2 for fDriveMaxFlatVel, ×0.0001 for drag, ×0.1 for damping, ×2 for the bias pairs. Without them, tuned handling.meta values will not behave the same.
- The derived 1/(max−min) and 1/max fields suggest the traction curve interpolates linearly from fTractionCurveMax down to fTractionCurveMin as slip grows. The game pre-computes these reciprocals to avoid divisions. This is an inference from the field layout; the curve code itself has not been published.
- The per-wheel quantities exposed (load, traction-vector X/Y/length, power, brake pressure, rotation speed, steering angle, material grip) form the state of a **per-wheel force model**: drive and brake torque set wheel spin, and a load-scaled traction circle produces the force. The Roblox implementation should keep the same per-wheel state.

### Gaps
- No published decompilation of the GTA V functions that turn slip into force (the CWheel friction / "ProcessFriction" path), of CTransmission::Process, or of the anti-roll-bar and roll-centre code. Searching for "GTA V reversed CWheel ProcessFriction" returned nothing. The exact traction-curve shape (where the peak sits, how fast grip falls off), the camber-stiffness force and the anti-roll force law are therefore **unknown** and must be fitted to measurements.
- The CHandlingData floats at 0x11C (1.25) and 0x120 (70.0) have no names in public sources.
- CWheel offsets differ between builds. Those quoted are from roughly b2245 to b2372.

---

## Q2. Which FiveM/ScriptHookV mods expose or modify internal physics in ways that reveal the model (Manual Transmission, Custom Gear Ratios, Custom Torque Map, TurboFix, Realistic Driving V, drift mods), and what do they reveal about RPM, gear ratios, clutch, wheel speed, traction and engine power?

### Takeaway
ikt's suite (Manual Transmission, Custom Gear Ratios, Custom Torque Map, TurboFix, the handling editor and HandlingInfo) is the single best body of evidence. It shows that GTA V's engine is a **normalised-RPM model with no real engine speed** (0.2 = idle, 1.0 = rev limit). Wheel force is roughly `fInitialDriveForce × mass × torqueCurve(rpm) × gearRatio`. The stock torque curve is flat up to 0.8 RPM and then falls linearly to 60 % at 1.0. Gear top speeds are `fDriveMaxFlatVel / ratio`, where `fDriveMaxFlatVel = 1.2 × fInitialDriveMaxFlatVel[m/s]`. A shift drops the clutch to 0.1 and refills it at `fClutchChangeRateScale` per second.

### Cited Findings

**RPM and engine**
- "The game does not seem to have a definition of engine speed, as internal game data only uses engine speed as a ratio of 0.2 (idle) to 1.0 (rev limit)." The final drive "doesn't seem to exist". — [CTM readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md)
- Stock torque curve [MEASURED from in-game acceleration logs]: "Every engine has the exact same torque curve … flat max torque until 80% of the rev limit, then it tapers off to 60% of the max torque at the rev limit. Horsepower peaks at 80% RPM. Except the first gear, which always offers full torque." — [CTM readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md)
- CTM cancels the stock curve with this correction (pseudo-code from the readme):
  ```
  baseMod1 = interp({0:0, 0.8:0, 1.0:0.4}, rpm) * baseDriveForce
  baseMod2 = interp({0:0, 0.8:0, 1.0:2/3}, rpm) * baseDriveForce
  baseMod  = rpm <= 0.8 and 0 or map(rpm, 0.8, 1.0, baseMod1, baseMod2)
  finalForce = baseDriveForce + baseMod
  ```
  The author notes "a slight wobble". — [CTM readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md)
- Units for drive force [MEASURED]: "`fInitialDriveForce * fMass` … assumed to be in Torque in N⋅m" gives realistic acceleration. Rule of thumb: `fInitialDriveForce = torqueNm / curbWeightKg`. — [CTM readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md), [handling-guide.md](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md). The w1tch docs use the variant `TorqueWheelsNm/WeightKg` (torque at the wheels, not the engine). — [docs.w1tch.net](https://docs.w1tch.net/en/latest/things/handling.html)
- Turbo: "The original turbo only adds 10% torque when fully spooled up", and it spools slowly. In TurboFix, `MaxBoost` 1.0 = +10 % power. — [TurboFix readme](https://github.com/ikt32/scripts-updates/blob/master/5-turbofix-readme.md)
- RPM rise with the clutch disengaged (MT's `fakeRev`, which emulates the game): `rpm += throttle * 2 * fDriveInertia * dt` (+ the previous frame's drop, doubled in 1st gear, "For some reason, first gear revs slower"). The result is clamped to [0, 1]. — [script.cpp `fakeRev`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)
- HandlingInfo describes fDriveInertia as "How fast the engine gains and loses revs … while drive is not engaged". The gtamods wiki says it is "a max change rate cap for the rpm of the engine, and will not increase your rate of forward acceleration under normal circumstances". — [GTAVHandlingInfo notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json), [gtamods wiki](https://gtamods.com/wiki/Handling.meta)

**Gears, ratios and top speed**
- Comment in the MT code: "Divide GetDriveMaxFlatVel by the values in this thing [gear-ratio array] to get the top speed for the gear." The code uses `maxSpeed = mDriveMaxFlatVel / mGearRatios[gear]` and `expectedSpeed = rpm * DriveMaxFlatVel / ratio[gear]`. **Road speed is linear in normalised RPM.** — [VehicleExtensions.hpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.hpp), [script.cpp `functionClutchCatch` / `functionLimiter`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)
- "There is a 1.2 factor between `fInitialDriveMaxFlatVel` and an internal top speed variable. On top of that, the top gear ratio is usually 0.9." Rule of thumb: `fInitialDriveMaxFlatVel = topGearMaxSpeedKph * 0.75`. — [handling-guide.md](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md). The same formula, `TopSpeedKph = (fInitialDriveMaxFlatVel * 1.2) / 0.9`, appears in the [gtamods wiki](https://gtamods.com/wiki/Handling.meta) and [w1tch docs](https://docs.w1tch.net/en/latest/things/handling.html).
- Default ratio tables used by Eddlm's tool [MEASURED from memory]:
  - 1 gear: 0.9
  - 2 gears: 3.33 / 0.9
  - 3 gears: 3.33 / 1.565 / 0.9
  - 4 gears: 3.33 / 1.826 / 1.222 / 0.9
  - 5 gears: 3.33 / 1.934 / 1.358 / 1.054 / 0.9
  - 6 gears: 3.333 / 1.949 / 1.392 / 1.095 / 0.946 / 0.9
  - Auto-upshift points (% of top speed), 6 gears: 0, 22, 45, 60, 76, 88.
  - Source: [Handling-Tools handling.html `gearRatios` / `gearShiftPoints`](https://github.com/eddlm/Handling-Tools/blob/master/handling.html)
- Gear count: top gear is 7 up to b1493 and 10 from b1604. "Vehicles have shorter gears for gears 7 and up" and "can't properly downshift from 8th gear and up". — [GTAVHandlingInfo notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)
- Custom Gear Ratios writes the per-vehicle ratio array and DriveMaxVel. `DriveMaxVel` in m/s is "more or less the final drive modifier". Example: an AE86 with DriveMaxVel 48.07, ratios R −3.484, 3.587, 2.022, 1.384, 1.000, 0.861. Recipe: V1 = redline speed in a theoretical 1.0 gear; `fInitialDriveMaxFlatVel = V1*0.75`; `DriveMaxVel = V1/3.6`. Gearbox tuning and `MODIFY_VEHICLE_TOP_SPEED` overwrite the ratios. — [CGR readme](https://github.com/ikt32/scripts-updates/blob/master/5-cgr-readme.md), [handling-guide.md](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md)
- The game's automatic gearbox upshifts at high RPM and speed, and downshifts at low RPM. MT patches both shift instructions out (`66 89 13 …` = writes to the gear field). — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)

**Clutch and shifting**
- "When a shift is initiated, the clutch drops to 0.1 and then rises at fClutchChangeRateScale<Up/Down>Shift per second until it's 1.0 again … A shift takes 0.9/fClutchChangeRateScale seconds." The transmission upgrade multiplies the rate by `map(modVal, 0..100, 1..2)`. — [script.cpp `getShiftTime`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)
- This is confirmed at the instruction level: the clutch-low-RPM and rev-limit patches both match `C7 43 40 CD CC CC 3D`, i.e. `mov dword [rbx+40h], 0x3DCCCCCD` (= 0.1f). The game also drops the clutch to 0.1 at the rev limiter and at low RPM, and lifts the throttle during shifts. — [MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)
- "Game doesn't rev on disengaged clutch in any gear but 1. Default: clutch >= 0.6: Normal, clutch < 0.6: Nothing happens." MT therefore remaps pedal input onto clutch values 1.0 to 0.6. Writing a negative clutch (−0.5, or −5 at a near stop) emulates neutral. — [script.cpp `handleRPM`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)

**Wheel speed, traction, engine braking and stalling (MT's own model, layered on the game)**
- Speed of the driven wheels = the average of `rotationSpeed*TyreRadius` over the driven wheels ("DiffSpeed").
- Stalling: it builds up when the clutch is engaged, `rpm <= 0.201`, and `|DiffSpeed| < StallingRPM * DriveMaxFlatVel/ratio`.
- Engine braking: `force = EngBrakePower*(1-throttle)*(1-clutch)*(rpm-thr)/(1-thr)`, applied as negative wheel power on the driven wheels.
- Mis-shift lockup: if `speed > 1.15*gearMax + 3.334`, apply wheel power −60 and traction length 60.
- Source: [script.cpp `functionEngStall`/`functionEngBrake`/`functionEngLock`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)
- Brakes per wheel, as MT reproduces them: `brake = fBrakeForce * input * (front ? fBrakeBiasFront : fBrakeBiasRear)`. These use the runtime ×2 bias values, so a 0.5 meta value gives 1.0 per axle. Handbrake = `fHandBrakeForce*input` on the rear wheels only (wheel offset y < 0). — [script.cpp `GetInputBrakes`/`GetHandBrakeVals`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)
- Slip angle: MT compares each wheel's slip angle (radians) with the runtime `fTractionCurveLateral` (radians) as the "optimal slip angle". Above it, understeer is detected. TCS slip = tyre speed / wheel longitudinal velocity. — [DrivingAssists.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/DrivingAssists.cpp), [WheelInput.cpp `CalculateSlipInfo`](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/WheelInput.cpp)
- AWD: the runtime drive bias is stored ×2 (`driveBiasF * 2.0f` is written back), and MT changes the torque split live from grip, under- and oversteer. The adaptive AWD feature requires the Handling Replacement library, since the handling data is shared per model. — [AWD.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/AWD.cpp), [changelog.md 5.0.0](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md)

**Realistic grip and slip-angle values (validated against real cars)**
- `fTractionCurveMax` "1.0 allows for about 1g of cornering grip". Typical values:
  - 90's tyres 1.15, eco 1.22, street 1.28, semi-slick 1.37, slicks 1.55 to 1.60.
  - `fTractionCurveMin` about 10 % lower.
- `fTractionCurveLateral` (optimal slip angle, degrees): street 8.5 to 9.3, semi-slick 7.5, slick 6.0. GTA defaults are about 22.5 ("too high").
- Sources: [GTAVHandlingInfo notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json), [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md)
- Validation example: an R32 GT-R handling tuned to the real 0-100/150/200 km/h times (5.2 / 11.5 / 22 s) within about 1 s, with grip of about 1.3 g sustained and a Nordschleife lap of 7:56 (BTG). — [GTAVHandlingPack y97y-BNR32 README](https://github.com/ikt32/GTAVHandlingPack/blob/master/y97y-BNR32/README.md)
- ikt's recommended realism changes:
  - lower fInitialDragCoeff
  - `fLowSpeedTractionLossMult = 0.0`
  - the `FREEWHEEL_NO_GAS` flag, so cars don't slow excessively off-throttle
  - `TYRES_CAN_CLIP`, to simulate tyre compression
  - `strHandlingFlags 20100`
  - Sources: [handling-guide.md](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md), [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md)
- Other mods named as realistic handling packs (handling.meta data only, no code): Realistic Driving V (killatomate), Aquaphobic's packs, Eddlm's Realish / Lore-Friendly packs, and Project Skill Issue. — [5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md)

### Inferences
Assembled from the cited findings (not decompiled; check against measurements). A Luau drivetrain that reproduces stock GTA V would look like this:
```
-- load
driveMaxFlatVel = (fInitialDriveMaxFlatVel/3.6)*1.2         -- m/s
gearTop[g]      = driveMaxFlatVel / ratio[g]                -- per-gear speed at rpm 1.0
-- runtime (clutch engaged)
rpm   = clamp(wheelSpeed / gearTop[g], 0.2, 1.0)            -- normalised; road speed linear in rpm
tq    = (g==1 or rpm<=0.8) and 1.0 or lerp(1.0, 0.6, (rpm-0.8)/0.2)
tq   *= (1 + 0.1*turboBoost) * cheatPowerIncrease
Fdrive_total = fInitialDriveForce * fMass * tq * ratio[g] * throttle * clutch   -- ~N at the contact patch ("torque Nm" × ratio, with wheel radius abstracted)
Fwheel_i = Fdrive_total * (front and driveBiasFront or driveBiasRear)/nPoweredOnAxle   -- bias stored x2 at runtime
-- shift: clutch = 0.1, then clutch += fClutchChangeRateScale*dt until 1.0 (throttle lifted meanwhile)
-- clutch disengaged/airborne: rpm += throttle*2*fDriveInertia*dt
```
- Whether `ratio[g]` multiplies the force exactly as written (Eddlm's tool assumes `power * gearRatio`) or is normalised against the top gear is **not confirmed**. Calibrate it with an acceleration test against known GTA V times, e.g. Broughy1322 / GTACars lap and speed data.
- Because the RPM is normalised and there is no final drive, a Roblox port can drop real engine RPM entirely and keep `rpm ∈ [0.2, 1]`. For sound, map it to an arbitrary real range with `RealRPM = idle + (rpm-0.2)/(0.8)*(limit-idle)`.

### Gaps
- No public code shows how the game splits drive force between the wheels of one axle (open differential versus equal split). MT adds an LSD itself, using brakes.
- The exact low-speed traction-loss formula: GTACars gives "approx `1/(1+fLowSpeedTractionLossMult)`" at low speed, with no speed range. — [gtacars glossary](https://gtacars.net/gta5/glossary)
- The "Realistic Driving V", "GT Handling" and drift-mod pages were not opened. They are handling.meta datasets, not code, so they reveal no internals.

---

## Q3. Are there ports or re-implementations of GTA-style handling in Unity, Unreal, Godot or Roblox?

### Takeaway
None found. Searches for Unity, Godot, Roblox and Luau re-implementations of GTA V handling.meta physics returned only generic vehicle-physics projects and FiveM tooling. The closest re-implementations are offline **calculators and visualisers** that encode GTA V formulas in JavaScript (Eddlm's Handling-Tools, GTACars' Desmos downforce calculators), plus data repositories.

### Cited Findings
- Eddlm's Handling-Tools (HTML/JS) is an interactive visualiser of handling.meta. Approximations in its code:
  - drag `GetDragCoeffGs = exp(ms * mod * 0.001)`, with a top-speed loop that compares `power*gearRatio` with `sqrt(spd/5)/100*drag`
  - downforce: rises from 0 to `0.035*fDownforceModifier` at 90 % of fInitialDriveMaxFlatVel; minimum 0.035; 0.0105 if the modifier > 100
  - brake g = `fBrakeForce*9.8`
  - These are **approximations** and partly contradict GTACars' disassembled formulas for the >100 case.
  - Sources: [eddlm/Handling-Tools handling.html](https://github.com/eddlm/Handling-Tools/blob/master/handling.html), [live tool](https://eddlm.github.io/Handling-Tools/handling)
- GTACars.net Desmos calculators for regular, old-style, new-style and open-wheel downforce are "mathematically identical to how the game calculates wheel downforce values". — [gtacars.net/gta5/downforce](https://gtacars.net/gta5/downforce)
- Data sources for a port:
  - [zfbx/GTA5-Handling-Meta](https://github.com/zfbx/GTA5-Handling-Meta): every vanilla and DLC handling.meta in its latest version.
  - [kerminal/vehicleDebug](https://github.com/kerminal/vehicleDebug): a FiveM live handling editor with top-speed and acceleration statistics. Useful for capturing reference curves.
  - [GTACars glossary](https://gtacars.net/gta5/glossary): field semantics, e.g. "fMass … only impacts collisions … does not impact performance", and shift time 1 → 0.9 s.
  - Search: [firecrawl results](https://github.com/zfbx/GTA5-Handling-Meta)
- Other multiplayer frameworks expose the same handling struct, for example the alt:V `HandlingData` class with `tractionCurveMaxRatio`, `tractionCurveLateralRatio`… — [docs.altv.mp](https://docs.altv.mp/js/api/alt-client.HandlingData.html)
- Full engine re-implementations exist only for older GTAs: re3/reVC (III/VC) and gta-reversed (SA). [SanAndreasUnity](https://github.com/GTA-ASM/SanAndreasUnity) is a Unity remake of SA. **It was not opened in this session**, so its physics fidelity is unverified. — [re3 mirror](https://github.com/hottabxp/re3), [gta-reversed](https://github.com/gta-reversed/gta-reversed)

### Inferences
- A Roblox port will be original work, built from this file's formulas and ideally a Roblox constraint/raycast wheel model. No existing Unity or Roblox code can be lifted.
- The cheapest way to check fidelity is to log speed against time in FiveM (`GET_VEHICLE_CURRENT_RPM`, `GET_VEHICLE_WHEEL_SPEED`, `GET_VEHICLE_WHEEL_TRACTION_VECTOR_LENGTH`) and compare it with the Luau sim. FiveM exposes all of these per-wheel values through natives.

### Gaps
- No public Unity, Unreal, Godot or Roblox project was found that claims to simulate GTA V handling.meta. GitHub-wide code search was not available in this session (the `gh` token was invalid), so a small, obscure project could have been missed.

---

## Q4. What does the GTA IV handling.dat → GTA V handling.meta lineage tell us (older SA/IV formulas that still apply)?

### Takeaway
GTA V's handling fields are direct descendants of IV's handling.dat, which itself evolved from SA's. The fully decompiled SA code (gta-reversed) shows the **design patterns** that V's fields still carry:
- a 1.2 factor between "flat" and "max" velocity
- bias pairs stored as 2·v and 2·(1−v)
- an adhesion-limited "traction circle" per wheel, with a traction-loss multiplier once skidding
- spring force ∝ compression × mass × force level × bias, with damping clamped relative to spring force
- automatic gear ratios derived from max velocity

Use these as a structural template. They are not V's exact code.

### Cited Findings
- GTA IV handling.dat already contained `fTractionCurveMax` ("formerly fTractionMult"; cornering grip as a multiplier of tyre/surface friction), `fTractionCurveMin` ("formerly fTractionLoss"), `fTractionCurveLateral` ("Shape of lateral traction curve (peak traction position in degrees)"), `fTractionCurveLongitudinal` (dropped in V) and `fTractionSpringDeltaMax`, plus the same suspension fields. "Some of these attributes are the same as GTA SA." — [gtamods wiki: handling.dat](https://gtamods.com/wiki/Handling.dat)
- V's wiki keeps the same lineage text. **There is a conflict over where the peak sits**: gtamods says "peak traction position in degrees sideways = fTractionCurveLateral / 2", and Eddlm says "the vehicle will tend to stay below half of this value". ikt's code and notes, by contrast, treat fTractionCurveLateral itself as the optimal slip angle. — [gtamods wiki handling.meta](https://gtamods.com/wiki/Handling.meta), [Eddlm Handling-Tools](https://eddlm.github.io/Handling-Tools/handling); contradicted by [GTAVHandlingInfo notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json) / [DrivingAssists.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/DrivingAssists.cpp)
- **SA cTransmission (decompiled).** Source: [gta-reversed cTransmission.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/cTransmission.cpp)
  - `InitGearRatios`: per-gear MaxVelocity is spread linearly: `MaxVel_i = i*(Vmax - 0.5*Vmax/N)/N + 0.5*Vmax/N`.
  - Shift-up point = previous gear max + 0.6667·Δ. Shift-down point = previous gear max + 0.42·Δ.
  - `CalculateDriveAcceleration`: `accel = (1 + 3*(1-(g-1)/(N-1))^2) * EngineAcceleration * 0.4 * gas * dt`. The 3 becomes 4 or 5 with the 2G/1G_BOOST flags; reverse uses 4.5.
  - Inertia smoothing: `acc = clamp(1 - (ratio - prevRatio)*EngineInertia, 0.1, 1)`.
  - Force fades to 0 within 0.05 above gear max velocity.
  - V's normalised-RPM engine is a different design, but it keeps the "inertia" (fDriveInertia) and gear-max-velocity concepts.
- **SA handling load (decompiled).** Source: [gta-reversed cHandlingDataMgr.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/cHandlingDataMgr.cpp)
  - Unit constants: `ACCEL_CONST = 1/50²`, `VELOCITY_CONST = 0.277778/50`.
  - Top speed is solved iteratively against drag: `v²·drag/2/1000 <= accel/6`.
  - Then `m_MaxVelocity = maxVelocity * 1.2f; m_MaxFlatVelocity = maxVelocity`. This is the same **1.2 flat-to-max factor** V applies between fInitialDriveMaxFlatVel and fDriveMaxFlatVel.
  - Reverse speed = `min(-0.3·v, -0.2)`. EngineAcceleration is divided by 4 (4WD) or 2.
- **SA wheel force (decompiled `CVehicle::ProcessWheel`).** Source: [gta-reversed Vehicle.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/Entity/Vehicle/Vehicle.cpp)
  - Contact velocity is projected onto the wheel's forward and right axes. Lateral correction `right = -vRight/wheelsOnGround`, clamped to ±adhesion.
  - Drive sets `fwd = thrust`. With no throttle, rolling friction = `fWheelFriction/mass`.
  - If `fwd² + right² > adhesion²`, the wheel state becomes SPINNING (driving and `|fwd| > limit·adhesion`) or SKIDDING. Both components are then scaled by `adhesion/|slip|`, times `fTractionLoss` if already slipping (the traction circle).
  - Forces are applied as `ApplyMoveForce(moveVec*mass*speed)` plus a turn force at the contact point.
- **SA adhesion per wheel (decompiled).** Source: [gta-reversed Automobile.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/Entity/Vehicle/Automobile.cpp)
  - `traction = fTractionMultiplier/250`
  - `adhesion = surfaceAdhesiveLimit * traction * wetMult * min(suspBias*fSuspensionForce*4*(1-compression), 2) * 2·tractionBias` (or 2−2·bias at the rear)
  - So grip already scales with suspension load, as V's per-wheel "load" field suggests.
- **SA springs (decompiled).** Source: [gta-reversed Physical.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/Entity/Physical.cpp)
  - `ApplySpringCollisionAlt`: `F = (1 - springLength) * dt * mass * fSuspensionForceLevel * bias * 0.016`, along the ground normal.
  - `ApplySpringDampening`: damping speed = `-(dt*fDampingLevel*dot(contactVel,dir))`, clamped so it never reverses the contact velocity, then limited by `DAMPING_LIMIT_OF_SPRING_FORCE` × spring force.
- Rockstar's original description of V's `fSuspensionForce` ("1 / (Force * NumWheels) = Lower limit for zero force at full extension") is consistent with an SA-style spring scaled by mass, where the force level is dimensionless. — [gtamods wiki handling.meta](https://gtamods.com/wiki/Handling.meta), [GTAVHandlingInfo notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)

**Other V-specific formulas worth keeping** (from disassembly or measurement)
- **Downforce [DECOMP]**: per-wheel "WDV".
  - Regular cars: flat 0.035; 0.07 with a custom spoiler.
  - Old-style (modifier ≤ 100): rises from 0 at standstill to `fDownforceModifier*0.035` at ≥ 90 % of fInitialDriveMaxFlatVel. ×1.25 with a spoiler. A modifier ≤ 1 falls back to regular.
  - New-style (> 100): `(mod/100)*0.035*0.3` at ≤ 40 %, rising to `(mod/100)*0.035*0.86` at ≥ 90 %. Skipped in SP.
  - Open-wheel (advanced flag `1<<27`): `mod*0.07*0.3 + 0.035` rising to `mod*0.07 + 0.035` at 95 %. Wing multipliers apply; ÷5 if a wing is broken.
  - Source: [gtacars.net/gta5/downforce](https://gtacars.net/gta5/downforce)
- **Brakes [MEASURED/GUESS]**: "To use all of a vehicle's traction for braking fBrakeForce must be higher than fTractionCurveMax / 4 (only tested with cars)." — [gtamods wiki](https://gtamods.com/wiki/Handling.meta)
- **Steering lock [GUESS]**: a good value is `fTractionCurveLateral*1.25 + 10`. The game's speed-sensitive steering assist "uses a percentage of the original steering lock". — [gtamods wiki](https://gtamods.com/wiki/Handling.meta)
- **Mass**: fMass "does not impact performance or handling behaviour", and is used for collisions. — [GTACars glossary](https://gtacars.net/gta5/glossary), [GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json). This fits with drive force being specified per kg (`fInitialDriveForce` ≈ N·m/kg), so acceleration does not depend on mass.
- **Drag**: "Sets the drag coefficient on the rage physics archetype of the vehicle (proportional to velocity squared)". The stored value is meta × 0.0001. HandlingInfo: `fInitialDragCoeff ≈ Cd/10` ("formula uncertain"). — [gtamods wiki](https://gtamods.com/wiki/Handling.meta), [HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp), [GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)
- **Anti-roll and roll centre [GUESS, no formula published]**: the anti-roll bar is "spring constant that is transmitted to the opposite wheel when under compression". The roll-centre height (m from the model bottom) moves the point the roll moment acts about; above the centre of mass it gives negative body roll. — [gtamods wiki](https://gtamods.com/wiki/Handling.meta), [GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)
- **Damping guidance [MEASURED]**: setting CompDamp or ReboundDamp to `fSuspensionForce/2` "perfectly cancels the compression/rebound in 1 bounce"; Comp + Rebound = Force gives a stable ride. — [GTACars glossary](https://gtacars.net/gta5/glossary), [GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)

### Inferences
- A faithful-enough Luau model can use the SA ProcessWheel structure (traction circle with friction scaled by adhesion and load) and replace SA's constant adhesion with a V-style slip curve:
  - grip peaks at `fTractionCurveMax` near the slip angle `fTractionCurveLateral` (or `/2`; calibrate, see the conflict above)
  - grip falls to `fTractionCurveMin` beyond it, using the pre-computed `1/(max−min)` slope
  - grip is scaled by `fTractionBias(×2)`, surface `materials.dat` grip × `fTractionLossMult`, the load from the spring, and the WDV downforce
- `fTractionCurveMax ≈ 1 g` means the per-wheel friction limit ≈ `fTractionCurveMax × Normal load`.
- SA multiplies forces by `CTimer::GetTimeStep()` in 1/50 s units (ACCEL_CONST = 1/50²). When porting SA-style formulas to Roblox's fixed 60 Hz `Stepped`/`Heartbeat` loop, convert to per-second SI units first.

### Gaps
- No primary source gives the V tyre curve shape (linear, Pacejka-like or piecewise), the longitudinal slip definition, the camber-stiffness force law, the anti-roll-bar force law or the roll-centre implementation. These need either a fresh decompilation (none is public) or black-box measurement in FiveM using the per-wheel natives listed above.
- The GTA IV handling.dat column semantics came only from the gtamods wiki excerpt. No decompiled GTA IV vehicle code was found.
- The SanAndreasUnity physics and the original re3 repository (removed by DMCA, so a mirror is cited) were not opened in this session.
