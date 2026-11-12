# Open-source vehicle physics engines and reference write-ups (non-GTA, non-Roblox) to port to a GTA V-like Luau car engine

Scope: tyre models, drift handling, speed/drag, suspension, anti-roll, airtime control, stability assists, fixed-step stability tricks, arcade assists. Roblox-specific material is excluded. Code was read directly from the raw source files where possible; line-level claims cite the repository file.

## Q1. Which open-source projects / write-ups are reference-quality, and what do they model? (annotated list, 16 entries)

### Takeaway
The most directly portable references are small, readable, permissively licensed raycast-car implementations: **SergeyMakeev/ArcadeCarPhysics (MIT, C#)**, **spacejack/carphysics2d (MIT, JS, Marco Monster model)**, **Bullet btRaycastVehicle (zlib-style, C++)** and its derivatives **Godot VehicleBody3D (MIT)** and **SuperTuxKart btKart (GPLv3: study only, do not copy)**. For the tyre curve itself, **NWH WheelController3D docs** (commercial product, public docs) give the clearest Pacejka B/C/D/E tuning guidance and the best documented low-speed/static-friction scheme; **Vehicle Physics Pro (Edy) docs** give the best documented driving-aid designs (steering limit, steering help, TCS, drift convergence). VDrift (GPLv3) is the best open simulation-grade Pacejka + combined-slip reference.

### Cited Findings

**1. ArcadeCarPhysics — Sergey Makeev** — https://github.com/SergeyMakeev/ArcadeCarPhysics — License: MIT; Language: C# (Unity).
- Stated goal: "fun vehicle physics and arcade control ... This approach can be used for games like GTA, Rocket League or Flatout." Key features: speed curve instead of engine settings, stable suspension, stabilizer-bar forces, Ackermann steering, downforce, "normalized tire lateral friction", handbrakes, in-flight vehicle stabilization — [README](https://github.com/SergeyMakeev/ArcadeCarPhysics)
- License is MIT (repo sidebar) — [GitHub](https://github.com/SergeyMakeev/ArcadeCarPhysics)
- Acceleration: `accelerationCurve` maps time→speed (km/h); each step it inverts the curve (binary search) to find the "time" matching current speed, evaluates the curve at `t+dt`, and applies `force = mass * (speedDesired - speedNow)/3.6` clamped ≥ 0 — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines ~335-378)
- Suspension: raycast length `lengthRelaxed + radius`; `compression = 1 - clamp01(len/lengthRelaxed)`; `spring = compression * -stiffness`; `damper = -(compression - compressionPrev)/dt * damping`; force applied at contact point. When the wheel loses contact the compression relaxes over time (`compression -= dt*relaxSpeed`) instead of snapping — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines ~900-968)
- Lateral friction ("perfect static friction"): `slideVel = (latVel + fwdVel)*0.5` in contact basis; `slidingForce = slideVel*mass/dt / wheelCount`; `friction = -slidingForce * lateralFriction * slipperyK`; the component along the wheel's rolling direction is removed (replaced by brake/rolling resistance) — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines ~977-1056)
- Timed "slippery" multipliers: after landing (`afterFlightSlipperyK=0.02`, 1 s), after hitting brakes (`brakeSlipperyK=0.5`, 1 s), handbrake (`handBrakeSlipperyK=0.01`, `handBrakeSlipperyTime=2.2 s`), each lerped back to 1 and combined with `min()` — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines 142-149, 201-202, 518-527, 1000-1022)
- Anti-roll: `antiRollForce = (travelL - travelR) * axle.antiRollForce` (default 10000), pushed down on one wheel and up on the other, only if grounded — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines 119, 1122-1137)
- Speed-sensitive steering: `steerAngleLimit` curve (deg vs km/h), `steeringSpeed` curve (Linear 2.0→0.5 deg/frame from 0→100 km/h), `steeringResetSpeed` curve (EaseInOut 30→10 deg/s); handbrake widens steering via `GetSteeringHandBrakeK()` — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines 176-187, 287-291, 417-424, 552-570)
- Downforce: `AddForce(carDown * mass * downForceCurve(kmh)/100 * downForce)` with `downForceCurve` Linear 0→100% over 0→200 km/h, `downForce=5` — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines 207-212, 667-677)
- In-air stabilization (ported from SuperTuxKart): when all wheels are airborne, `axis = cross(carUp, worldUp)` (unnormalized, so magnitude grows with tilt), `AddTorque(axis * flightStabilizationForce * mass)` (default 8), plus optional damping of pitch/roll angular velocity (y kept) — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs) (lines 195-199, 630-664)
- The README also curates a reading list (STK, Bullet vehicle, Space Dust Racing, Marco Monster, Edy anti-roll/Pacejka posts, PsRealVehicle, Beckman, RVP, Skylanders/Uncharted 4/Criterion/Saints Row GDC talks, OpenC1, PhysX Vehicles guide, Rocket League GDC) — [README](https://github.com/SergeyMakeev/ArcadeCarPhysics)

**2. carphysics2d — spacejack (JS port of Marco Monster "Car Physics for Games")** — https://github.com/spacejack/carphysics2d — License: MIT; Language: JavaScript (+ Marco's original C demo archived in repo).
- "Javascript adaptation of the ideas found in Marco Monster's often-referenced car physics paper and demo"; adds Siorki's front/rear CG distances and yaw-rate contribution to wheel velocity; license MIT — [README](https://github.com/spacejack/carphysics2d)
- Bicycle model per axle: axle loads with longitudinal weight transfer `Wf = m*(ratioF*g - wt*ax*hcg/L)`, `Wr = m*(ratioR*g + wt*ax*hcg/L)`; slip angles `αf = atan2(vy + ωr*a, |vx|) - sign(vx)*δ`, `αr = atan2(vy - ωr*b, |vx|)`; lateral force `Fy = clamp(-Cα*α, -grip, grip) * W`; rear grip reduced by e-brake `grip*(1 - ebrake*(1-lockGrip))`; drag `-Crr*v - Cdrag*v*|v|` per axis; yaw torque `(Fyf)*a - Fyr*b` — [Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Low-speed fix: "Sim gets unstable at very slow speeds, so just stop the car": if `|v| < 0.5 m/s` and no throttle, zero velocity and yaw rate — [Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Speed-sensitive steering ("safe steer"): `steer = input * (1 - min(|v|,250)/280)` — [Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Marco Monster's original paper is mirrored at asawicki.info (link given in README); the mirror sat behind a bot-verification wall during this research so its text was not re-read here — [README](https://github.com/spacejack/carphysics2d)

**3. Bullet Physics btRaycastVehicle (Erwin Coumans)** — https://github.com/bulletphysics/bullet3/tree/master/src/BulletDynamics/Vehicle — License: permissive zlib-style ("Permission to use, copy, modify, distribute and sell ... granted without fee"); Language: C++.
- License header — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)
- Suspension relative velocity uses `denominator = contactNormal·wheelDir`; if `denominator >= -0.1` (contact nearly perpendicular) suspension velocity is forced to 0, avoiding blow-ups on steep contacts; suspension force clamped to `m_maxSuspensionForce` — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp) (lines 210-235, 300-302)
- Side friction solved as an impulse constraint (`resolveSingleBilateral`) per wheel; friction circle in impulse space: `maximp = suspensionForce*dt*frictionSlip`; if `x²+y² > maximp²` (x = forward impulse, y = side impulse) both are scaled by `skidInfo = maximp/sqrt(x²+y²)` — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp) (lines 530-617)
- Roll-over hack: side impulse application point is moved toward the CoM height by `m_rollInfluence` (`rel_pos -= up*(up·rel_pos)*(1-rollInfluence)`), reducing body roll torque — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp) (lines 640-650)
- Rocket League shipped on Bullet ("Open-source: debuggable, modifiable") at a fixed 120 Hz tick — [Cone, GDC 2018 slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)

**4. Godot VehicleBody3D / VehicleWheel3D** — https://github.com/godotengine/godot/blob/master/scene/3d/physics/vehicle_body_3d.cpp — License: MIT (Godot Engine contributors); Language: C++.
- MIT header; exposes the Bullet-style `friction_slip`, `roll_influence`, `get_skidinfo()` and `m_sideImpulse` per wheel (i.e. a port of the btRaycastVehicle algorithm) — [vehicle_body_3d.cpp](https://raw.githubusercontent.com/godotengine/godot/master/scene/3d/physics/vehicle_body_3d.cpp)

**5. SuperTuxKart btKart** — https://github.com/supertuxkart/stk-code/blob/master/src/physics/btKart.cpp — License: GPLv3 or later (code); Language: C++.
- "free software ... GNU General Public License ... version 3 ... or (at your option) any later version" — [COPYING](https://raw.githubusercontent.com/supertuxkart/stk-code/master/COPYING)
- Flying stabilization: when no wheel is on the ground, zero X/Z angular velocity, `axis = cross(kartUp, -gravity.normalized)`, `applyTorqueImpulse(axis * smoothFlyingImpulse)`. Comment: axis length grows with tilt "resulting in fast changes when the kart is on its side, but not overcompensating (and therefore shaking) when the kart is not much away from being upright" — [btKart.cpp](https://raw.githubusercontent.com/supertuxkart/stk-code/master/src/physics/btKart.cpp) (lines 436-460)
- Speed-proportional downward impulse when all 4 wheels are grounded: `f = -|speed| * downwardImpulseFactor` applied as central impulse along kart-down; extra gravity while flying so jumps behave — [btKart.cpp](https://raw.githubusercontent.com/supertuxkart/stk-code/master/src/physics/btKart.cpp) (lines 491-500, 604-605)
- Note: GPL means algorithms may be re-implemented but code should not be copied into a non-GPL project (inference from license terms).

**6. VDrift** — https://github.com/VDrift/vdrift — License: GPLv3; Language: C++.
- "open source driving simulation made with drift racing in mind. It is released under the GNU General Public License (GPL) v3" — [README](https://raw.githubusercontent.com/VDrift/vdrift/master/README.md)
- Slip computation with denominator floor: `rvlon = 1/max(|vlon|, 1e-3)`; `slip_ratio = (ωr - vlon)*rvlon`; `slip_angle = -atan(vlat*rvlon)` — [cartirebase.h](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartirebase.h)
- Full Pacejka '94-style Fx/Fy/Mz with load (Fz in kN clamped to 30) and camber; combined slip via weighting functions `Gx = sqrt(c/(c+b²))` with `a=p3*σ, b=p2*α, c=a²+1` (and symmetric Gy); precomputes a 20-entry LUT of "ideal" (peak) slip ratio and slip angle vs load by solving `π/2 = C·atan(BS − E(BS − atan BS))` — [cartire1.cpp](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp), [cartirebase.h](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartirebase.h)

**7. PsRealVehicle (Pushkin Studio)** — https://github.com/PushkinStudio/PsRealVehicle — License: MIT (© 2016 Vladimir Alyamkin); Language: C++ (UE4 plugin). Described as "simple force-driven vehicle simulation" — [LICENSE](https://raw.githubusercontent.com/PushkinStudio/PsRealVehicle/master/LICENSE), [ArcadeCarPhysics README](https://github.com/SergeyMakeev/ArcadeCarPhysics). (Source not read in detail.)

**8. Randomation Vehicle Physics (JustInvoke)** — https://github.com/JustInvoke/Randomation-Vehicle-Physics — Language: C# (Unity). "aims to achieve semi-realistic, general-purpose driving mechanics. This was originally sold on the asset store as Randomation Vehicle Physics 2.0"; manual in `Assets/RVP_Manual.pdf` — [README](https://raw.githubusercontent.com/JustInvoke/Randomation-Vehicle-Physics/master/README.md). License: NOT verified (no LICENSE / LICENSE.md file found at repo root; README does not state one) — see Gaps.

**9. NWH Vehicle Physics 2 / WheelController3D documentation** — https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html — License: proprietary commercial Unity asset; docs are public (use for algorithms/values, not code).
- Pacejka BCDE semantics: B "stiffness" (higher = peak at lower slip = spins out more easily), C "shape" (knee pointiness), D "peak" (grip), E "falloff" (E≈1 → almost flat after peak; low E → slide once traction lost) — [FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- Shipped presets (long B,C,D,E | lat B,C,D,E): Asphalt 12,1.9,1.15,0.97 | 12,1.8,1.1,0.75; Generic 10,1.9,1.0,0.97 | 11,1.8,1.0,0.8; **Arcade 14,1.7,1.15,0.98 | 12,1.8,1.15,0.9**; Gravel 8,1.7,0.74,0.85; Grass 6.5,1.85,0.45,0.8; Snow 4,2.0,0.32,0.7; Ice 10,1.9,0.12,1.0. "Shape above roughly 3, or falloff above 1, pushes the Magic Formula past the point where it still describes a tire" — [FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- Per-wheel `Grip` (long/lat multipliers), `Stiffness` (slip sensitivity, default lat 0.8), `Load Sensitivity` (default 0.85/0.8; <1 = diminishing returns) — [FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- Static-friction / low-speed scheme detailed in Q3 below — [FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)

**10. Vehicle Physics Pro (Edy) documentation** — https://vehiclephysics.com/advanced/misc-topics-explained/ — License: proprietary product (a free "Community Edition" exists, not verified here); docs public.
- Solver sub-steps per vehicle (1 = traffic; 2 = minimum for player; 4-8 good; 20 max = 1000 Hz at 50 Hz base); "More than 20 substeps ... numerical oscillations can get magnified" — [misc topics](https://vehiclephysics.com/advanced/misc-topics-explained/)
- Driving aids (TCS, Steering Limit, Steering Help, drift convergence) — detailed in Q4 — [misc topics](https://vehiclephysics.com/advanced/misc-topics-explained/)
- Edy's blog posts (anti-roll bars exposed, stabilizer bars, Pacejka '94 parameters guide, "Facts and myths on the Pacejka curves") are linked from ArcadeCarPhysics' reading list — [ArcadeCarPhysics README](https://github.com/SergeyMakeev/ArcadeCarPhysics); the "Facts and myths" page was fetched but the extractor returned no usable body text — [edy.es](https://www.edy.es/dev/2011/12/facts-and-myths-on-the-pacejka-curves/)

**11. Rocket League GDC 2018 — Jared Cone, "It IS Rocket Science!"** — https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf — Talk slides (proprietary game; ideas only).
- Bullet engine, discrete collision, fixed 120 Hz tick; "Slower rate = larger steps = larger penetrations = inconsistent hits" — [slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- "Reduce complexity": no transmission ("Use force/accel curve instead"), keep mass constant and "Ignore when applying forces", "Can live without longitudinal friction", "Simplify lateral friction" — [slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- Simple friction: `Ratio = SideSpeed/(SideSpeed+ForwardSpeed)`; `SlideFriction = Curve(Ratio)`; `GroundFriction = Curve(GroundNormal.Z)`; `Friction = SlideFriction*GroundFriction`; `Impulse = Constraint*Friction` — [slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- Rollover workarounds: "Lower friction", "Limit steer angles", "'Stay upright' constraint", "Apply forces at CM height"; separate physics presets (wheel positions/radii, collision box) from visuals; "Stability Forces" — [slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)

**12. Criterion (Burnout/NFS) GDC 2018 — Matthew Harris, "Vehicle Feel Masterclass: Balancing Arcade Accessibility with Simulation Depth"** — https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf — slides; GDC Vault page https://www.gdcvault.com/play/1025295/Vehicle-Feel-Masterclass-Balancing-Arcade
- Places games on an Arcade ↔ Sim-cade ↔ Simulation axis (Mario Kart 8 Deluxe, Burnout 3, Forza Horizon 3, Forza Motorsport, iRacing); input-layer structure "Input Layer → Assists → Simulation → Assists"; assist categories "Player Intention, Driver, Physical, Real World, Feedback"; drift assists "Brake Tap to Enter Drift", "Want a deep, stable Drift", "Turn off ABS during drift, Reactivate ABS when Straightening up", "Maintain Speed Force (Maintain speed force %, Degrees from Ideal Drift Angle)", "Yaw Torque During a Drift"; tyre model shown as Pacejka (slip ratio / slip angle normalized force) — [slides](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf) (content extracted via automated PDF query; wording may be paraphrased in places)

**13. Toyful Games — "Deep Dive: Custom Car Physics" (Very Very Valet)** — https://www.toyfulgames.com/blog/deep-dive-car-physics — Video (no code license). Custom Unity car physics "breaking down seemingly complicated forces into more understandable steps"; benefits: tuning "for maximum fun" and "a plethora of optimization options" — [Toyful blog](https://www.toyfulgames.com/blog/deep-dive-car-physics). The page is a video embed; algorithm details were not extractable as text (see Gaps).

**14. Rem Voorhuis — "How to program realistic vehicle physics for realtime environments / games, Part I" (2025)** — https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa — blog with C++ snippets (no explicit code license).
- MF code: `D*sin(C*atan(B*s - E*(B*s - atan(B*s)))) + V` with horizontal shift H; `slip_ratio = (r*ω - vx)/|vx|`; `slip_angle = -atan2(vy, |vx|)`; four combined-slip techniques (longitudinal priority; Beckman friction-circle scaling; MF 5.2 weighting functions; MSC ADAMS combined slip with code) — [Medium](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa)
- Low-speed problem list and fixes (see Q3) — [Medium](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa)

**15. Other references listed (not fetched in depth this round, links verified only via the ArcadeCarPhysics/carphysics2d READMEs):** Brian Beckman "The Physics of Racing" http://phors.locost7.info/contents.htm; OpenC1 (Carmageddon remake) physics https://github.com/jeff-1amstudios/OpenC1/tree/master/OpenC1/Physics; SimpleRaycastVehicle-Unity https://github.com/unity-car-tutorials/SimpleRaycastVehicle-Unity/; NVIDIA PhysX Vehicles guide; Skylanders "Supercharged!" GDC; Uncharted 4 "Science of Off-Roading" GDC; "The Physics of Fun: The Vehicles of Saints Row"; Space Dust Racing UE4 arcade vehicle tour (blog domain no longer resolves; video https://www.youtube.com/watch?v=LG1CtlFRmpU) — [ArcadeCarPhysics README](https://github.com/SergeyMakeev/ArcadeCarPhysics), [carphysics2d README](https://github.com/spacejack/carphysics2d)

**16. Gaffer On Games — "Fix Your Timestep!"** — https://gafferongames.com/post/fix_your_timestep/ — accumulator loop: `accumulator += frameTime; while (accumulator >= dt) { integrate(state, t, dt); accumulator -= dt }` — [Gaffer](https://gafferongames.com/post/fix_your_timestep/); cited as a resource in the Rocket League talk — [slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)

### Inferences
- License tiers for adaptation: **copy/adapt freely with attribution** → ArcadeCarPhysics (MIT), carphysics2d (MIT), Godot (MIT), PsRealVehicle (MIT), Bullet (zlib-style). **Read for algorithms only, re-implement** → SuperTuxKart, VDrift (GPLv3). **Docs only, no code** → NWH, VPP/Edy, GDC slides, Toyful video.
- ArcadeCarPhysics is the closest single open codebase to the "GTA-feel" target (its author explicitly names GTA), but its lateral friction is "kill all sideways velocity × coefficient" with no slip-angle peak, so it must be combined with a curve-based tyre (NWH-style BCDE or a GTA-style traction curve) to reproduce GTA V's peak/drop behaviour.

### Gaps
- Randomation Vehicle Physics license could not be confirmed (no root LICENSE file found; GitHub API blocked from this environment). Verify on the repo page before copying code.
- Unreal Chaos Vehicle (ChaosVehicles plugin / SimpleWheel): not researched this round; its source is available only under the Unreal Engine EULA (source-available, not OSI open source) — this licensing statement is from background knowledge, not a fetched source.
- TORCS / Speed Dreams (simuv2/simuv4) source and "Racer" (Ruud van Gaal) docs: not fetched (search returned no usable primary pages in budget). Both TORCS and Speed Dreams are generally known to be GPL, but this was not verified here.
- Live for Speed / BeamNG / Assetto Corsa tyre-model modding docs: not researched (proprietary; out of budget).
- Marco Monster's original text and Beckman's chapters were not re-read (mirror behind bot verification); formulas above come from the MIT JS port.

## Q2. Which formulas are most portable for a cheap per-wheel model (friction circle, brush, simplified Pacejka from grip max/min + peak slip angle)?

### Takeaway
For a cheap per-wheel Luau model, the most portable pipeline is: (1) raycast spring-damper per wheel, (2) slip angle `α = atan2(vLat, max(|vLong|, ε))`, (3) a normalized lateral grip curve μ(α) defined either by a 3-segment GTA-style curve (linear rise to peak at α_peak with μ_max, fall to μ_min) or a Pacejka `D·sin(C·atan(B·x − E(B·x − atan(B·x))))` with B,C,D,E derived from the same three numbers, (4) force = μ·Fz, (5) a friction-circle clamp combining longitudinal + lateral (Bullet-style scaling). This is what Bullet, carphysics2d, VDrift and NWH do at different fidelity levels.

### Cited Findings
- Linear-then-saturating lateral force (the cheapest "tyre"): `Fy = clamp(-Cα·α, -μ, μ) · Fz_axle` — [carphysics2d Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Friction circle in impulse space: scale forward & side impulses by `maximp/sqrt(x²+y²)` when `x²+y² > maximp²`, with `maximp = Fz·dt·frictionSlip` — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)
- Ratio-based slide friction (no slip angle needed): `ratio = |vSide|/(|vSide|+|vFwd|)`, `μ = Curve(ratio) * Curve(groundNormal.Z)` — [Rocket League slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- Magic Formula and its parameter meaning: B=stiffness, C=shape, D=peak, E=falloff; "The grip capacity the solver actually uses ... is the true maximum of the generated curve, not D. The two are the same for a shape factor between 1 and 2" — [NWH FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- Peak location of MF: solve `π/2 = C·atan(B·S − E(B·S − atan(B·S)))` (VDrift's `FindPacejkaMax`) — [VDrift cartire1.cpp](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp)
- Combined slip options: longitudinal-priority cut; Beckman friction-circle scaling; MF 5.2 weighting functions; MSC/ADAMS combined slip — [Voorhuis](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa). VDrift's cheap weighting function: `Gx = sqrt((a²+1)/((a²+1)+b²))` with `a = p3·σ, b = p2·α` — [VDrift cartire1.cpp](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp)
- Load sensitivity: effective μ falls as load rises (NWH default exponent-like factor 0.85 long / 0.8 lat) — [NWH FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- Drag: `F = -Crr·v - Cdrag·v·|v|` per axis (rolling + aero) — [carphysics2d Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Speed-curve drive force instead of engine model: `F = m·(curve(t(v)+dt) − v)/dt`-style target-speed force (ArcadeCarPhysics uses /3.6 conversion and clamps ≥0) — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs); Rocket League likewise "Use force/accel curve instead" of a transmission — [slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- Weight transfer (longitudinal): `ΔW = (hcg/L)·m·ax` added to rear / removed from front — [carphysics2d Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Anti-roll bar: `F = (travelL − travelR)·k_ar`, applied opposite on the two wheels of an axle — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)

### Inferences (portable pseudo-code; derived from the cited sources, not copied from GTA)
Per-wheel step (Luau-flavoured pseudo-code):
```
-- suspension (ArcadeCarPhysics / Bullet style)
hit = raycast(mount, -up, restLen + radius)
if hit then
  comp  = 1 - clamp((hit.dist - radius)/restLen, 0, 1)
  vComp = (comp - w.compPrev)/dt ; w.compPrev = comp
  Fz    = max(0, comp*k - vComp*c)            -- no pulling into ground
  Fz    = min(Fz, FzMax)                       -- Bullet m_maxSuspensionForce
  applyForceAt(hit.normal*Fz, hit.pos)
end
-- contact frame velocities
v      = pointVelocity(hit.pos)
vLong  = dot(v, wheelFwd) ; vLat = dot(v, wheelRight)
alpha  = atan2(vLat, max(abs(vLong), 0.5))     -- VDrift-style floor (VDrift uses 1e-3; games use larger)
mu     = gripCurve(abs(alpha)) * surfaceMul    -- see below
FyMax  = mu * Fz * latMul
FxReq  = driveForce + brakeForce               -- per-wheel drive/brake bias already applied
-- friction circle (Bullet)
FyReq  = -sign(alpha) * FyMax                  -- or blend with "kill side velocity" impulse at low α
mag    = sqrt(FxReq^2 + FyReq^2) ; lim = muPeak*Fz
if mag > lim then s = lim/mag ; FxReq*=s ; FyReq*=s end
applyForceAt(wheelFwd*FxReq + wheelRight*FyReq, hit.pos + up*rollInfluenceOffset)
```
GTA-style 3-parameter curve (μ_max, μ_min, α_peak) — cheapest option:
```
gripCurve(a): if a <= aPeak then return muMax * (a/aPeak)          -- linear rise (or sin(π/2·a/aPeak))
              else return lerp(muMax, muMin, clamp((a-aPeak)/aFall, 0, 1)) end
```
Deriving Pacejka B,C,D,E from the same numbers (approximation, inference): set `D = μ_max`; choose `C` from the plateau ratio using the MF asymptote `μ(∞) ≈ D·sin(C·π/2)` (for E=0), i.e. `C = 1 + (2/π)·acos(μ_min/μ_max)` gives `D·sin(Cπ/2) = μ_min` for 1<C<2; then solve `B` so the peak lands at `α_peak` — with E=0 the peak is where `B·α_peak = tan(π/(2C))`, so `B = tan(π/(2C))/α_peak`. Keep E in [−1, 1) for extra fall-off shaping. (Check numerically; NWH warns C above ~3 or E above 1 is non-physical.)

### Gaps
- No published source was found that explicitly maps GTA V's `fTractionCurveMax/Min/Lateral` to Pacejka B,C,D,E; the mapping above is my derivation and must be validated numerically.
- Brush-model closed forms were not fetched this round (no primary source retrieved).

## Q3. Stability tricks for fixed-step real-time simulation (low-speed slip, relaxation length, sub-stepping, no jitter when stopped)

### Takeaway
Every reference handles the `v→0` singularity explicitly: floor the slip denominator (VDrift, NWH), fade lateral force with lateral speed (Voorhuis), hard-stop below a threshold (carphysics2d), or switch to a spring-damper "static friction anchor" with hysteresis (NWH). Use a fixed step (Gaffer accumulator; Rocket League 120 Hz) and, for the tyre, either sub-steps (VPP: 2–8) or impulse-based friction that cannot overshoot (Bullet, ArcadeCarPhysics `-v·m/dt` limited by μ).

### Cited Findings
- Singularity: "slip quantity inputs ... have the longitudinal velocity of the tire in their denominator ... when the vehicle speed approaches zero, the outputs will become numerically unstable"; proposed fixes: Lagged Slip Ratio (Bernard & Clover, SAE 950311), Advanced Slip Ratio (Jung et al. 2018), ALSR (Jung et al. 2020) — [Voorhuis](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa)
- Lateral oscillation at standstill: at low speed |α|→±90° and "generates significant lateral forces, continuously oscillating the vehicle"; fix `lateral_slip_factor = min(|vLat|*3 + |steer|/maxSteer, 1)` multiplying lateral force — [Voorhuis](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa)
- Relaxation length = "the delay between when a slip angle is introduced and when the cornering force reaches its" steady value — [Wikipedia](https://en.wikipedia.org/wiki/Relaxation_length). (Typical game implementation as a first-order lag `α_eff += (α − α_eff)·min(1, |v|·dt/L)` is an inference; the lagged-slip papers above are the formal versions.)
- NWH static friction: below `0.4 m/s` wheel speed switch from slip-based friction to a spring-damper anchor; exit at `0.4×1.5` (hysteresis "Prevents mode flapping"); critical damping 1.0; break when force > 1.15× peak grip; re-entry cooldown 10 ms; anchor relax rate 0.02; slope compensation so cars park on hills — [NWH FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- NWH low-speed ramps: slip scaling ramps to full by 1.0 m/s ("Ramping rather than switching prevents jerky starts"); slip denominator floor ε = 0.3 m/s ("Raising it too far saturates lateral grip at low speed and can leave a stationary vehicle sliding sideways"); brake direction blended below 0.5 rad/s wheel speed instead of `sign(ω)` "which would otherwise flip back and forth as the wheel stops"; ABS pulse 20 Hz — [NWH FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- NWH troubleshooting "Vehicle Jitters When Stopped": ensure static friction on, increase its damping, check suspension damping — [NWH FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- carphysics2d: below 0.5 m/s with no throttle, zero velocity and yaw rate — [Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- VDrift: `1/max(|vlon|, 1e-3)` floor and early-out when `Fz·μ < 1e-6` — [cartirebase.h](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartirebase.h), [cartire1.cpp](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp)
- Bullet: suspension velocity zeroed when contact normal is near-perpendicular (`n·dir >= -0.1`); max suspension force clamp — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)
- VPP sub-steps: 2 minimum for player cars, 4–8 recommended, ≤20; tyre "impulse ratio" too high "overshoots the adherent state ... causing a noticeable shaking" → reduce it; damper rule of thumb "rigidbody.mass*2"; damping ratio <0.3 safe, 0.3–1.0 "glued", >1.6 unstable; "Low side deflection rates at high speeds can enter in resonance" — [VPP misc topics](https://vehiclephysics.com/advanced/misc-topics-explained/)
- Fixed tick: Rocket League runs 120 Hz fixed; "Higher rate = consistency" at CPU/network cost — [Cone slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf); accumulator loop — [Gaffer](https://gafferongames.com/post/fix_your_timestep/)
- ArcadeCarPhysics friction is an exact velocity-cancelling force `−v_slide·m/dt/N × μ` (cannot overshoot when μ≤1) and the suspension relaxes gradually when airborne — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)

### Inferences
- Recommended Luau recipe: run vehicle logic in a fixed-step accumulator (e.g. 120 Hz or 2–4 sub-steps of the engine's physics step), compute `α` with a floor of ~0.3–0.5 m/s, cap lateral force at `min(μ·Fz, |vLat|·m_wheel/dt)` so it never reverses sideways velocity within a step, fade lateral force in with `min(1, |vLat|·k)` and add a hysteretic "parked" mode (<0.4 m/s enter, >0.6 m/s exit) that holds the car with a critically damped spring instead of tyre forces.

### Gaps
- No primary source fetched giving numeric relaxation-length values for games.

## Q4. How are arcade assists implemented, and how do arcade games (GTA, NFS/Burnout, Forza Horizon, Rocket League) design drift and stability?

### Takeaway
Arcade assists sit in an input/assist layer around a (simplified) physical sim: speed-limited steering, steering help toward the slide direction (counter-steer), drift entry triggers (brake tap / handbrake → temporary rear-grip reduction), drift sustain (maintain-speed force, yaw torque), in-air self-levelling torque proportional to tilt, speed-scaled downforce, and traction control that targets peak slip. Published talks from Criterion and Psyonix confirm these patterns; no first-party GTA/Forza Horizon technical talk was found.

### Cited Findings
- Input layer → assists → simulation → assists; assist categories Player Intention / Driver / Physical / Real World / Feedback — [Harris, Criterion GDC 2018](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf)
- Drift (Criterion/Burnout lineage): "Brake Tap to Enter Drift", "deep, stable Drift", disable ABS during drift and re-enable when straightening, "Maintain Speed Force" parameterised by "% " and "Degrees from Ideal Drift Angle", "Yaw Torque During a Drift" — [Harris slides](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf)
- Handbrake drift via timed grip loss: lateral friction × 0.01 for up to 2.2 s, steering range widened while handbraking, braking briefly lowers grip to 0.5 — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs); e-brake lowers rear grip `grip*(1 − ebrake*(1−lockGrip))` — [carphysics2d](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)
- Counter-steer assist (VPP "Steering Help"): "Automatically moves the steering wheel to the direction that keeps the vehicle controlled under lateral sliding. The user's steer input is applied as offset"; Help Ratio 0.8–0.9 for keyboard/touch, 0.4–0.6 for wheels; priority modes "Prefer Drifting" vs "Prefer Go Straight"; with Steering Limit + Help + Limit Proportionality 0.6 the car "converge[s] itself to stable drifting without applying any steering input, just throttle" — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)
- Speed-sensitive steering: VPP Steering Limit (Street = no front slide; Sport = angle of max lateral grip; Custom slip), relaxed in the counter-steer direction during slides so "the vehicle can be recovered from losing the rear end even at high speeds" — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/); ArcadeCarPhysics steer-limit & steer-speed curves vs km/h — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs); carphysics2d `1 − v/280` scaling — [Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js); Rocket League "Limit steer angles" — [Cone](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- Traction control: VPP TCS "Limits the engine throttle so the drive wheels produce a limited amount of slip" — Street (no slip), Sport (peak slip), Custom — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/); VDrift precomputes ideal (peak) slip per load — a natural TCS/ABS target — [VDrift](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp)
- Drift balance (sim side): rear-biased AWD torque splitter (default stiffness 0.25), 52/48 F/R weight, locked/clutch-pack diff, rev limiter to cap wheelspin — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)
- Brake bias: front-biased balance → understeer, rear → oversteer — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)
- Downforce: speed-curve downforce (ArcadeCarPhysics) — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs); speed-proportional downward impulse only when all wheels grounded (STK) — [btKart.cpp](https://raw.githubusercontent.com/supertuxkart/stk-code/master/src/physics/btKart.cpp); front vs rear aero balance changes high-speed under/oversteer — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)
- In-air rotation control / auto-levelling: torque along `cross(up, worldUp)` scaled by tilt + damp pitch/roll rate — [btKart.cpp](https://raw.githubusercontent.com/supertuxkart/stk-code/master/src/physics/btKart.cpp), [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs); post-landing grip reduction for 1 s (`afterFlightSlipperyK`) — [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)
- Anti-rollover / auto-righting: "'Stay upright' constraint", "Apply forces at CM height", "Stability Forces" (Rocket League) — [Cone](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf); Bullet `rollInfluence` lowers the tyre-force application point — [btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)
- Arcade grip expectations: real road tyre ≈1.0–1.1 g; "Casual players usually find this VERY low" (Stefano Casillo, Assetto Corsa, quoted by Edy) — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)

### Inferences (assist pseudo-code)
```
-- counter-steer help (VPP-style)
slip   = atan2(vLatBody, max(vFwdBody, 1))            -- body sideslip
assist = clamp(-slip * kHelp, -maxSteer, maxSteer)     -- steer into the slide
steer  = clamp(assist*helpRatio + input*steerLimit(speed), -maxSteer, maxSteer)
-- drift sustain (Criterion-style)
if drifting then
  err = idealDriftAngle - abs(slip)
  addForce(fwd * maintainSpeedPct * dragAndFrictionLoss)  -- keep speed in slide
  addTorque(up * sign(slip) * kYaw * err)                 -- hold angle
end
-- in-air leveling (STK)
if wheelsOnGround == 0 then
  axis = up:Cross(worldUp)                -- not normalized: grows with tilt
  angVel = angVel - (angVel - up*up:Dot(angVel)) * clamp(kDamp*dt,0,1)
  addTorque(axis * kLevel * mass)
end
```
- GTA V-like feel (inference): GTA's "handbrake → long slide, throttle catches it" maps to ArcadeCarPhysics' timed rear-grip reduction + a curve with μ_min/μ_max ≈ 0.8–0.9 (gentle drop past the peak), plus a VPP-style steering help at a low ratio.

### Gaps
- No first-party technical talk/postmortem from Rockstar (GTA), Playground (Forza Horizon) or Ghost/Criterion NFS on drift internals was found in this research round; Burnout lineage is covered only via Harris's slides.
- The Toyful Games and Saints Row talks are video-only; contents not extracted.

## Q5. Which references best fit GTA V's model (traction curve max/min + slip-angle peak, per-wheel drive/brake bias, normalized RPM 0.2–1.0, flat torque to 80% RPM)?

### Takeaway
Best fit: **ArcadeCarPhysics (MIT)** for architecture (raycast wheels, anti-roll, downforce curve, in-air leveling, handbrake grip timers, speed-curves for steering) + **a GTA-style 3-point traction curve or NWH-style BCDE curve** for lateral grip + **Bullet's friction-circle clamp (zlib)** for combined slip + **NWH's static-friction/low-speed scheme** and **VPP's steering-help/TCS** designs for stability. carphysics2d (MIT) is the best minimal reference for weight transfer, drag and slip-angle math. Use VDrift/STK (GPL) only as algorithm references.

### Cited Findings
- ArcadeCarPhysics explicitly targets GTA/Rocket League/Flatout-style handling and is MIT — [README](https://github.com/SergeyMakeev/ArcadeCarPhysics)
- Slip-angle-based grip with peak and post-peak falloff controlled by B/C/D/E and per-wheel grip multipliers (front/rear balance) — [NWH](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)
- Friction-circle combination — [Bullet](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)
- Force/acceleration curve instead of a full drivetrain is an accepted arcade simplification (Rocket League) — [Cone](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)
- Brake balance shifts under/oversteer — [VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)

### Inferences
- Engine: GTA's normalized RPM (0.2 idle → 1.0 redline) with flat torque to 0.8 then falloff can be expressed as `torqueMul(r) = r <= 0.8 and 1 or lerp(1, k, (r-0.8)/0.2)`; drive force per wheel = `driveForce * torqueMul * gearRatio_i/gearRatio_top * driveBias_wheel`. This replaces ArcadeCarPhysics' speed curve while keeping its "force applied at contact point, clamped by tyre limit" structure. (Derived; no external source for GTA specifics in this file — see the sibling GTA handling notes.)
- Per-wheel brake/drive bias: compute per-axle share (front = bias, rear = 1−bias) before the friction-circle clamp, so excess brake on the rear produces lock/slide naturally (matches VPP's statement that rear brake bias → oversteer).
- Lateral grip: use `μ_max` (curve max), `μ_min` (curve min) and `α_peak` (lateral curve) directly in the 3-segment curve from Q2; optional Pacejka equivalent via the B,C derivation in Q2.

### Gaps
- No open-source project was found that explicitly re-implements GTA V's handling.meta semantics outside GTA/Roblox; the mapping is inferential and should be validated against the in-game handling research in the sibling notes.
