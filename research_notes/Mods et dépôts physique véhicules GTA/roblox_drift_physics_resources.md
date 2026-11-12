# Roblox open-source car physics beyond a basic chassis: drift, stability, assists, gearboxes, networking

Scope: Roblox-specific open-source resources, DevForum threads and GitHub repos. For each one: what it does, how it is built in Luau, known problems, and what a GTA V-style Luau engine can reuse. That engine is a pure VehicleDynamics module with per-wheel spherecasts, a fixed step, VectorForce + Torque on one chassis, handling.meta parameters, and gravity compensation to 9.8 m/s² at 3.571 studs/m.
Research date: 2026-11-12. DevForum pages were read through the Firecrawl scraper. Some scrapes came back as LLM summaries of the thread. Where a summary looked unreliable (it just repeated my prompt), I cite only the opening post or meta description.

---

## Q0. Annotated catalogue (what exists, how it is built, what to reuse)

### Takeaway
The best Roblox material for a scripted (non-constraint) engine is A-Chassis 1.7.x (MPL-2.0, active in 2025-2026), the "In Depth Scripted Car Physics" tutorial (Sep–Dec 2025), and Roblox's own Server Authority material (2025-2026). Most other "drift" resources are thin: drift usually means cutting rear traction or locking the rear wheels. Almost no Roblox resource publishes measured per-car cost.

### Cited Findings

**1. A-Chassis (official GitHub: lisphm/A-Chassis)**
- What it is: a free, open-source chassis kit for Roblox, "a beginner-friendly, yet scalable starting point" — [GitHub lisphm/A-Chassis](https://github.com/lisphm/A-Chassis)
- Maintainers: lisphm, VanillaEdge, ProfessorSr, thehanslevi. License: **MPL-2.0**. Latest: v1.7.2-stable, "A-Chassis 1.7.2(M) Patch", Mar 19 2026. Open known issues: "Entire car shifts when steering on 'New' steering type"; bike animation breaks layered clothing — [GitHub lisphm/A-Chassis](https://github.com/lisphm/A-Chassis)
- Changes in 1.7(M) (May 23 2025):
  - A G-Force-based Electronic Stability Control (ESC), "only used for stability, not for desired turning radius".
  - A Counter Steer Assist "to help steering by AlignOrientation".
  - Flip moved from BodyGyro to AlignOrientation. Steering can optionally use AlignOrientation, with countersteer and steer-smoothing values.
  - "(NOT Optional) Using VectorForce instead of the deprecated BodyForce".
  - An ABS gradient, and a speed limiter that can apply the brake.
  - A CustomEngine module, plus a barometric formula for engine power loss and aero.
  - A new clutch-dump mechanic that "uses the difference between the RPM of the engine and the RPM of the wheels".
  - Turbo lag that "smoothly interpolates to maximum and minimum boost because I fixed delta-time".
  - RPM management that "no longer glitches when shifting up, over-revving, consistent with high and low FPS".
  - A new Sounds plugin, because "the old sounds plugin caused a lot of problems with internet bandwidth".
  - Source: [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- 1.7.2 (Mar 2026): "Locked update rate to 60Hz to make the math more consistent for people with high FPS"; "Fixed gravcomp force application point being wrong"; CustomSuspensionDensity default changed to 1 "to prevent issues when gravcomp is disabled"; cached value instances moved into a table "to avoid registry limit issues" — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- 1.6.5 (Apr 2025): "Added dt resetter to mitigate physics death". 1.7 Beta 3 (Mar 2024): "Revbounce fixed for non-neutral gears (Caused by goalMax being redline instead of slightly higher)"; the Tires plugin "only changes the part orientation when at speed and when there is tire stress, preventing low-speed physics glitches". Beta 4: "Removed AutoGravComp (It broke everything)" — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- Some components were deleted or limited "due to possible model shadowban" from the Toolbox (SetValue, CustomEngine) — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- Implementation: the GitHub pages I read do not say whether wheels use constraints or raycasts (gap). A-Chassis users tune it for drift. One example is a YouTube tutorial, "Tutorial: Drift Tuning an A-Chassis" — [YouTube](https://www.youtube.com/watch?v=zCcTUlWxc5s)
- **Reuse for us:** the ESC/counter-steer/flip assists as AlignOrientation-style controllers; the 60 Hz lock (the same choice as our fixed step); the RPM-difference clutch dump; dt-correct turbo spool; "dt resetter" protection against a physics blow-up after a frame hitch. Check the MPL-2.0 file-level copyleft before copying any code.

**2. "In Depth Scripted Car Physics" (DevForum Community Tutorial, author bIorbee, Sep 2 2025; steering part Dec 18 2025)**
- Fully scripted car: one `VectorForce` each for Spring, Friction and Motor, plus Welds and Attachments. Loop on `RunService.Heartbeat` with dt — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- Suspension is a damped spring, `F = kx − cv`, with vertical speed taken from `getVelocityAtPoint(body, wheelPos)`. A reply gives a more stable semi-implicit damping term: `dampingForce = (DAMPING / (1 + (DAMPING*dt)/m)) * verticalSpeed` — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- Lateral grip model: `fMax = MU * suspensionMagnitude`, `fDesired = -sidewaysSpeed * AssemblyMass`, `clamp(fDesired, -fMax, fMax)`. In other words, a Coulomb-clamped impulse that kills lateral velocity. Rolling resistance is `ROLLING_MU * N` with a `ROLLING_STOP_SPEED` deadzone. The motor force has a linear drop-off above `THROTTLE_DROP_OFF_START`, and BRAKING_POWER applies when throttle opposes motion — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- "Wheel casting": several rays across the bottom half of the wheel circumference, used because single rays glitch on steep tilts or when the wheel is half off an edge — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- Networking: the server sets `SetNetworkOwner(player)` while someone drives and `SetNetworkOwner(nil)` when the car is empty, and the tutorial avoids `SetNetworkOwnershipAuto`. Shared physics lives in a ModuleScript so server and client run the same code. With nobody driving, the server "will just be simulating the physics and have the throttle and steer values at 0" — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- Known problems the author admits: "Currently the formulas aren't optimized for low and high FPS"; with client ownership, cars can "bounce or shoot into space if FPS drops below 60"; wheel attachments get duplicated when re-entering — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- **Reuse:** the semi-implicit damper (directly applicable to our spherecast springs); the multi-ray "wheel casting" idea, which our spherecast already covers; the clamped lateral impulse as a low-speed fallback below the handling.meta grip curve.

**3. Raycast Suspension Wheel Module (DevForum Community Resource, LeehamsonTheThird, Jan 31 2023; GitHub LeehamsonThe3rd/raycastsuspensionwheel)**
- Each wheel needs an `Attachment`, a `VectorForce` and a `Weld`, plus attributes `SuspensionDamping`, `SuspensionHeight`, `SuspensionSpring`, `Debug` and `RollingResistance`. Horizontal friction relies on CustomPhysicalProperties (friction 1 preferred). API: `Wheel.new(VehicleModel, Part)` and `Wheel:Update()`. The example calls `PrimaryPart:SetNetworkOwner(nil)` and updates on `Heartbeat` — [GitHub README](https://raw.githubusercontent.com/LeehamsonThe3rd/raycastsuspensionwheel/main/README.md)
- No license is stated on the forum page — [DevForum](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)
- Problems reported in replies:
  - the car rolls away at rest (fixed by more rolling friction);
  - it falls through the floor at height or nose-first (the body needs CanCollide);
  - suspension and wheel rotation do not replicate to other clients;
  - it glitches when the player owns the car;
  - drift is described as "disabling the rear wheels' drive", or just rear slip.
  - Source: [DevForum](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)
- **Learn:** relying on Part friction for lateral grip produces wheel creep at rest, so it is better to compute lateral force explicitly with a static-friction deadzone. Wheel visuals must be replicated or simulated on observers (see Q2).

**4. "How to Implement Vehicle Mechanics Using Constraints" (DevForum Community Tutorial, xPoIarity, Mar 27 2025)**
- Built on CylindricalConstraint (two motors: a slider for suspension and a rotation motor for drive), SpringConstraint and HingeConstraint — [DevForum](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
- Gearbox: gears come from a ratio string. Max RPM per gear = engine max RPM / gear ratio / axle ratio. Wheel torque = `Engine.MaxTorque * gearRatio * Axle.Ratio * Wheels.Radius`. Up- and downshifts compare `currentSpeed` with `maxSpeed` and `previousMaxSpeed`. The handbrake sets rear motors to `MotorMaxTorque = brakeForce` and `AngularVelocity = 0` — [DevForum](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
- Anti-flip: "R" teleports the car up and resets its orientation. Problems reported: wobbly steering on bumps and walls, stuck on high-banked corners, grip loss at high speed — [DevForum](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
- **Learn:** a typical constraint-based rear-lock handbrake. Our engine should instead model the handbrake as a rear-wheel brake torque plus a reduced lateral-grip multiplier (handling.meta `fHandBrakeForce` semantics).

**5. NGChassis 1.02 (DevForum Community Resource, agentcodec, Jan 2021, open source, no license name, unmaintained)**
- A 51-line teaching chassis. Drift is a button that "sets the traction for the wheels to 0.01". A reply contrasts NFS-style "rails drifting" (assisted, "harder to spin out") with realistic drifting (tuning, counter-steer, throttle). Known issue: wheels do not self-centre — [DevForum](https://devforum.roblox.com/t/introducing-ngchassis-102-open-source-simple-realistic/986580)
- **Learn:** the "rails drift" vs "sim drift" framing is the design decision we must make for GTA-style arcade drift (GTA V is closer to assisted).

**6. Fan-made open-source drift car system (DevForum Community Resource, Apr 14 2025, uncopylocked place)**
- Per the author, it "uses various methods like drag force formula, vector forces, and angular velocity", and is released uncopylocked, "I'm not sure if I'll update this much". The thread title names the commercial game that inspired it, so I do not repeat it here. The post body did not render in the scrape, so implementation detail, author and license are unverified — [DevForum](https://devforum.roblox.com/t/my-fan-made-mall-drifters-car-system-open-source/3605524)
- **Learn:** arcade drift on Roblox is commonly VectorForce plus direct angular-velocity control on the body (yaw rate control), not tyre-model emergent.

**7. A-Chassis Anti-Loop Plugin (DevForum, Gam3r_Play3r, Sep 2021, old)**
- Fixes the car accelerating endlessly when the driver exits while holding throttle. It works by zeroing the `#AV` wheel `AngularVelocity`/MaxTorque, which is the legacy BodyAngularVelocity, now **deprecated**. It does not work on some versions (e.g. 6.52S2) — [DevForum](https://devforum.roblox.com/t/a-chassis-anti-loop-plugin/1463810)
- **Learn:** on seat exit, always zero the inputs in the simulation. In our engine that means resetting throttle, brake and steer state when the occupant changes.

**8. "Raycast suspension chassis behaving inconsistently on different frame rates" (DevForum, Landersattack, Jun 4 2023)**
- Uses `ApplyImpulseAtPosition` on `Heartbeat`. Below 30 FPS it is "practically unusable" and above 60 it "drives too fast". Replies propose a fixed-timestep accumulator (`fixed_timestep = 1/60`, code given) and physics sub-stepping. The OP's final fix was scaling forces by `delta * 60` — [DevForum](https://devforum.roblox.com/t/raycast-suspension-chassis-behaving-inconsistently-on-different-frame-rates/2405111)
- **Learn:** this confirms our fixed-step design. Scaling impulses by dt is only a partial fix, because spring stiffness stability still depends on the step.

**9. "Raycast Car works at 60Fps but not at 30 or lower" (DevForum, Jolly_JoeGamer, Apr 28 2025)**
- Changing from ApplyImpulse to VectorForces made the car wobble at ≤30 FPS (same Heartbeat loop) — [DevForum](https://devforum.roblox.com/t/raycast-car-works-at-60fps-but-not-at-30-or-lower/3629871). (Replies could not be reliably extracted. The scraper's summary only repeated the prompt, so I give no solution claims.)
- **Learn:** a VectorForce stays applied for every 240 Hz physics sub-step until the script updates it. At low script FPS a stale spring force acts for several steps and overshoots. This is the main hazard for our VectorForce-based design when the owning client's frame rate drops (see Q2 inferences).

**10. Roblox Server Authority: staff "Tech Deep Dive" (DevForum, Khanovich, Roblox staff, May 8 2026) and Creator Docs "Server authority techniques"**
- During resimulation, only `RunService:BindToSimulation` callbacks run; `Heartbeat` and `RenderStepped` do not. Predicted objects must run the same code on client and server — [DevForum staff post](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
- Cost: at 100 ms latency, a misprediction means resimulating 100 ms of physics, "6.25x the simulation load" of a client-authoritative game — [DevForum staff post](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
- Vehicle findings:
  - The Racing Template shows "constant micro-mispredictions—specifically on velocities" that "don't actually reduce the quality of the driving".
  - "Making complex vehicles deterministic involved quantizing positions and velocities. This is currently causing some drift in certain BodyMovers/Constraints."
  - `SetPredictionMode` "will soon-ish set the entire 'StreamingSet' as 'Predicted'… It's hard to predict a car without predicting it's wheels".
  - Colliding with a non-predicted car gives visual jitter, "since your local car prediction will be colliding with a stale version of the car".
  - Users report Studio crashes when sitting in a car and frame dips while driving.
  - Source: [DevForum staff post](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
- The docs show an input-forwarding pattern inside `BindToSimulation`. The server copies each player's InputContext state (e.g. `Throttle`) into attributes, and every peer applies `GetAttribute("Throttle")` to the vehicle in the simulation callback — [Creator Docs](https://create.roblox.com/docs/projects/server-authority/techniques)
- **Reuse:** our pure VehicleDynamics module (no Instance writes, deterministic fixed step) fits a `BindToSimulation` callback. Inputs must come through attributes or InputActions, not RemoteEvents.

**11. Tunneling: "Objects going at fast speeds phase through other objects" (DevForum Engine Bugs, May 27 2025, Roblox staff reply)**
- Staff (ReechaLoo) call it "a known problem innate to the current collision detection system. If you want things to both move fast and collide… make them thick in the direction in which they move, at least for now." They "hope to avoid these problems with a continuous collision detection system, but if and when [it] happens isn't set in stone" — [DevForum](https://devforum.roblox.com/t/objects-going-at-fast-speeds-phase-through-other-objects/3667006)
- A community test in an older thread: Roblox physics steps at 240 Hz; a sphere passed through a 0.1-stud wall at ~950 studs/s; with 2-stud walls it did not tunnel above ~1500 studs/s — [DevForum](https://devforum.roblox.com/t/part-with-fast-speed-goes-through-walls/1867113) (community measurement, not official)

**12. "Car trips over when steering" (DevForum, Mar 9 2021)**
- A constraint car (Cylindrical + Spring) with extra gravity via BodyForce flips when steering. Suggested fixes: lower part density, less wheel friction, BodyGyro (deprecated) leveling. The accepted fix was to make every part Massless except one mass part welded at the centre and lowered below it, i.e. move the centre of mass down — [DevForum](https://devforum.roblox.com/t/car-trips-over-when-steering/1093002)
- **Learn:** the community's standard anti-rollover method is to lower the centre of mass with a single massive part. This maps to handling.meta `vecCentreOfMassOffset`. Moving the point where lateral tyre forces are applied up or down (GTA's `fRollCentreHeightFront/Rear`) is the more faithful equivalent.

**13. Roblox Creator Docs: Network ownership**
- The canonical pattern: on `VehicleSeat` `Occupant` change, `SetNetworkOwner(player)`; when empty, `SetNetworkOwnershipAuto()` — [Creator Docs](https://create.roblox.com/docs/physics/network-ownership). (Tutorial #2 deliberately uses `SetNetworkOwner(nil)` instead of Auto to avoid automatic handoffs — [DevForum](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628).)
- A thread reports a vehicle "switches network ownership from client to the server even though there is a player still" in it — [DevForum](https://devforum.roblox.com/t/network-ownership-randomly-being-switched-to-the-server/2401270) (title/snippet only)

**14. Smaller GitHub repos found by code search (low maturity, 0–2 stars)**
- `shrx74/roblox-raycast-car` (Luau, updated Oct 2026): "A custom raycast-based car chassis… featuring spring suspension, damping, tire friction" — [README](https://raw.githubusercontent.com/shrx74/roblox-raycast-car/main/README.md). No license shown in GitHub search metadata.
- `HassanJN66/roblox-vehicle-framework` (Sep 2026): "arcade-realistic vehicle system… Raycast wheels + soft physics body… FWD/RWD/AWD" — [README](https://raw.githubusercontent.com/HassanJN66/roblox-vehicle-framework/main/README.md). No license shown.
- `DaveInchy/RobloxVehicleSimulation` (May 2025): a Rojo project scaffold only — [README](https://raw.githubusercontent.com/DaveInchy/RobloxVehicleSimulation/main/README.md)
- GitHub search for "roblox drift", "roblox vehicle physics" and "roblox chassis" returned almost nothing substantial; the "drift" hits are script/exploit uploads, not engines (GitHub search via `gh search repos`, 2026-11-12). The code in these repos could not be read because the session's GitHub API access is restricted.

**15. Engine sound threads**
- The DevForum answer to RPM/gear-based engine SFX (Oct 2024) is a crude formula: `sound.PlaybackSpeed = math.clamp(multiplier * speed/12, .7, 1.3)` with a per-gear multiplier (1, 0.7, 0.5…) — [DevForum](https://devforum.roblox.com/t/how-do-i-achieve-this-type-of-engine-sfx-for-my-vehicle/3184012)
- A better non-Roblox reference: record samples every 1000 RPM in two layers (on-throttle and off-throttle). Blend bilinearly by RPM and throttle, e.g. at 4800 RPM and 50% gas, the 5000 RPM clips play at 50%×80% = 40% volume and the 4000 RPM clips at 10%. Pitch-shift toward the exact RPM — [NEODRIVE devlog, itch.io](https://sevencrane.itch.io/neodrive/devlog/1322297/how-to-make-car-sound)

### Inferences
- No Roblox open-source project implements a GTA-style handling.meta model. A-Chassis is the closest thing in feature breadth (clutch, turbo, ESC, counter-steer assist, flip), but it is a sim-style chassis with its own Tune format.
- Most Roblox scripted cars use the same tyre model as tutorial #2: lateral force = clamp(−v_lat·m, ±μN). That is a hard Coulomb clamp with no slip-angle curve, which is why those cars either grip perfectly or spin. GTA's `fTractionCurveMax/Min/Lateral` curve is more sophisticated than anything published for Roblox.

### Gaps
- Could not read source code for A-Chassis wheel physics (constraints vs raycast), the drift system in #6, or the small GitHub repos; GitHub API access was restricted and the forum post body did not render.
- No license file confirmed for the DevForum resources (#2–#6); assume "all rights reserved" unless a license is stated.

---

## Q1. Which Roblox drift systems exist and how do they make drift controllable?

### Takeaway
Published Roblox drift techniques are crude:
- cut rear traction to ~0 (NGChassis);
- lock the rear wheels via motor torque (constraints tutorial);
- disable rear drive (raycast module);
- or drive yaw directly with angular velocity plus VectorForce drag (the fan-made system).

The only published "assist" with real logic is A-Chassis 1.7's counter-steer assist and G-force ESC, both built on AlignOrientation. No resource found publishes a lateral-grip-vs-slip-angle curve for drift.

### Cited Findings
- NGChassis drift: a button sets wheel traction to 0.01 — [DevForum NGChassis](https://devforum.roblox.com/t/introducing-ngchassis-102-open-source-simple-realistic/986580)
- Community framing: "rails drifting" (assist keeps the car on a line, hard to spin) vs realistic drifting (tuning, counter-steer, throttle control) — [DevForum NGChassis](https://devforum.roblox.com/t/introducing-ngchassis-102-open-source-simple-realistic/986580)
- Constraint handbrake: rear `MotorMaxTorque = brakeForce`, `AngularVelocity = 0`. The tutorial says the idea is "to make the rear wheels lose grip so that the rear end of the car can slide around" — [DevForum constraints tutorial](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
- Raycast module: drift happens when rear drive is disabled or the rear wheels slip — [DevForum raycast module](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)
- Arcade drift system: "drag force formula, vector forces, and angular velocity" — [DevForum fan-made drift system](https://devforum.roblox.com/t/my-fan-made-mall-drifters-car-system-open-source/3605524)
- A-Chassis 1.7: "Counter Steer Assist (CS) (To help steering by AlignOrientation…)"; G-force-based ESC "only used for stability"; AlignOrientation steering "with countersteer and steer smoothing values" — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- A-Chassis drift tuning is mainly done through Tune values. There is a YouTube "Drift Tuning an A-Chassis" tutorial (content not reviewed) — [YouTube](https://www.youtube.com/watch?v=zCcTUlWxc5s)
- Tutorial #2 lets "some slip when turning" by changing the lateral friction clamp with steer factors — [DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)

### Inferences
- For a GTA-faithful engine, drift controllability should come from:
  - (a) the handling.meta traction curve: peak at `fTractionCurveLateral` slip angle, then falling to `fTractionCurveMin` beyond it, which gives a controllable plateau rather than the Roblox community's hard clamp;
  - (b) a handbrake that multiplies rear lateral grip down while held, rather than locking rotation;
  - (c) an optional counter-steer assist that adds steer toward the velocity vector, scaled by yaw rate, like the A-Chassis CS idea but computed inside the module as a steering-angle bias rather than an AlignOrientation;
  - (d) yaw damping via our existing Torque mover when the slip angle is past the peak and the driver counter-steers.
- Avoid the "traction = 0.01" approach. It gives an uncontrollable spin, which is exactly the community complaint behind the "rails drifting" debate.

### Gaps
- No Roblox resource found that documents a drift-specific lateral grip curve, an angular damping value, or a published drift-assist tuning table. Drift-game techniques are not published in open source beyond #6, whose code could not be read.

---

## Q2. Solutions for wheel jitter at rest, flipping, curb bounce, tunneling >200 km/h, ownership handoff, low-FPS instability; Server Authority / BindToSimulation

### Takeaway
The community's answers are:
- a fixed timestep or sub-stepping for FPS instability;
- a semi-implicit damper;
- lowering the centre of mass for rollover;
- multi-ray "wheel casting" for edges and curbs;
- rolling-friction deadzones for creep at rest;
- explicit `SetNetworkOwner` rather than Auto.

Roblox staff confirm there is no continuous collision detection yet (thick geometry is the only official advice). Server Authority (client beta, 2026) needs vehicle code in `BindToSimulation`, and staff admit quantization drift in BodyMovers/Constraints for vehicles.

### Cited Findings
- **Low FPS:**
  - A fixed-timestep accumulator at 1/60 and physics sub-stepping were proposed for an ApplyImpulse raycast car that was unusable below 30 FPS — [DevForum](https://devforum.roblox.com/t/raycast-suspension-chassis-behaving-inconsistently-on-different-frame-rates/2405111)
  - A VectorForce raycast car wobbles at 30 FPS but not 60 — [DevForum](https://devforum.roblox.com/t/raycast-car-works-at-60fps-but-not-at-30-or-lower/3629871)
  - A-Chassis locked its update rate to 60 Hz and added a "dt resetter to mitigate physics death" — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- **Spring stability:** use a semi-implicit damping term `(c / (1 + c·dt/m))·v` — [DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- **Bounce or launch at low FPS under client ownership:** "cars [can] bounce or shoot into space if FPS drops below 60" — [DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- **Jitter or creep at rest:** a car "rolling away when not moving" was fixed with more rolling friction — [DevForum raycast module](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837). The tutorial's rolling force returns zero below `ROLLING_STOP_SPEED` — [DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628). A-Chassis's tire-trail logic only acts "when at speed… preventing low-speed physics glitches" — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- **Curbs and edges:** a single ray glitches when a wheel is half off an edge or on steep tilts. Several rays across the lower half-circle ("wheel casting") were used instead — [DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- **Flipping:** lower the centre of mass with one massive part placed low, everything else Massless; high wheel friction also causes trips — [DevForum](https://devforum.roblox.com/t/car-trips-over-when-steering/1093002). A-Chassis flip now uses AlignOrientation (BodyGyro deprecated) — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases). A teleport-up "R" reset appears in the constraints tutorial — [DevForum](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
- **Tunneling:** staff say there is no CCD and to make things "thick in the direction in which they move", with CCD "not set in stone" — [DevForum Engine Bugs](https://devforum.roblox.com/t/objects-going-at-fast-speeds-phase-through-other-objects/3667006). Community test (not official): 240 Hz step; a 0.1-stud wall was passed at ~950 studs/s, and 2-stud walls held at >1500 studs/s — [DevForum](https://devforum.roblox.com/t/part-with-fast-speed-goes-through-walls/1867113). Games with fast objects "may be using raycasting to determine if [an] object is approaching a surface" — [DevForum Engine Bugs](https://devforum.roblox.com/t/objects-going-at-fast-speeds-phase-through-other-objects/3667006)
- **Ownership handoff:**
  - Docs pattern: `SetNetworkOwner(player)` on occupy, `SetNetworkOwnershipAuto()` on exit — [Creator Docs](https://create.roblox.com/docs/physics/network-ownership)
  - The tutorial prefers `SetNetworkOwner(nil)` on exit — [DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
  - Reported bug: ownership randomly switching to the server while occupied — [DevForum](https://devforum.roblox.com/t/network-ownership-randomly-being-switched-to-the-server/2401270)
  - Wheel visuals not replicating to other clients — [DevForum raycast module](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)
- **Server Authority:**
  - Only `BindToSimulation` runs during resimulation; Heartbeat-only loops won't resimulate.
  - Velocity micro-mispredictions in the Racing Template are "innate to the physics engine".
  - Quantization "is currently causing some drift in certain BodyMovers/Constraints".
  - The whole StreamingSet is to become Predicted, so the wheels are predicted along with the car.
  - Colliding with a non-predicted car gives jitter.
  - At 100 ms latency, resimulation costs 6.25× the simulation load.
  - Source: [DevForum staff deep dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
  - Input forwarding via attributes inside `BindToSimulation` (throttle example) — [Creator Docs](https://create.roblox.com/docs/projects/server-authority/techniques)

### Inferences
- **Speed-to-step arithmetic.** 200 km/h = 55.6 m/s ≈ 198 studs/s at 3.571 studs/m. That is ~0.83 studs per 240 Hz physics step, but ~3.3 studs per 60 Hz script step.
  - Chassis-vs-wall tunneling in the solver is unlikely at that speed. The community threshold is ~950 studs/s for a 0.1-stud wall.
  - The script-side wheel spherecasts are the weak point: a curb or kerb edge can sit between two 60 Hz casts.
  - Mitigations: (a) sub-step the wheel solver at 120–240 Hz when speed > ~150 studs/s; or (b) cast from the previous wheel contact position to the current one (a swept cast); and (c) give the chassis collision box an extended thickness.
- **Stale VectorForce at low FPS.** Our VectorForce + Torque design applies the last computed force for every 240 Hz sub-step until the next script tick. At a 20 FPS client that means ~12 sub-steps of a stale spring force, which is the documented wobble or launch mode.
  - Options: run the module in `BindToSimulation` or `PreSimulation` at a fixed rate; clamp spring force by the max compression velocity; switch to `ApplyImpulse` sized for exactly one script step when the measured dt exceeds 1/40 s.
  - This is a design inference, not a sourced claim.
- **Server Authority.** Because our module is pure and fixed-step, it is the right shape for `BindToSimulation`. Two risks: the staff-acknowledged mover quantization drift, and resimulation CPU cost (6.25× at 100 ms), which is significant with many cars.

### Gaps
- No public Roblox data on curb-bounce fixes beyond multi-ray casting. No published experiments on spherecast vs raycast for curbs.
- No source found on `BindToSimulation` tick rate guarantees for vehicles, or on whether `VectorForce` is quantized differently from `ApplyImpulse` under Server Authority.
- A RunService `PreSimulation`-based car example exists only in a secondary guide site ([simplified.media](https://simplified.media/guides/roblox-vehicle-physics), low authority). It is not used as evidence.

---

## Q3. Open-source gearboxes with clutch, RPM-based engine sound, turbo/nitrous, GTA-like arcade assists

### Takeaway
A-Chassis 1.7.x is the only maintained open-source Roblox chassis found with a clutch (an RPM-difference clutch dump), stall, rev-bounce handling, turbo lag with dt-correct interpolation, a park gear, ESC, counter-steer assist, flip and air-pressure power loss. Other resources give simple gear-ratio math or PlaybackSpeed-clamp sounds. No open-source nitrous or GTA-style air-control or auto-righting module was found.

### Cited Findings
- **A-Chassis 1.7 drivetrain features:**
  - clutch dump "uses the difference between the RPM of the engine and the RPM of the wheels";
  - stall setting works;
  - no glitches "when shifting up, over-revving, consistent with high and low FPS";
  - turbo lag interpolation with a dt fix;
  - CustomEngine module;
  - barometric engine power loss;
  - ABS gradient;
  - Park Gear (1.7.1);
  - rev bounce fixed by setting goalMax "slightly higher" than redline.
  - Source: [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- **A-Chassis sound:** the old Sounds plugin "caused a lot of problems with internet bandwidth", so it was replaced. Transmission sounds follow the driven wheels. Tire sounds use a different playback speed and a TremoloSoundEffect — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- **Gear math (constraints tutorial):** max RPM per gear = engine RPM / (gear × axle); wheel torque = `MaxTorque × gear × axle × radius`; speed-threshold up/down shifting — [DevForum](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
- **RPM-based engine SFX on the DevForum** is a speed × gear-multiplier clamp to PlaybackSpeed 0.7–1.3 — [DevForum](https://devforum.roblox.com/t/how-do-i-achieve-this-type-of-engine-sfx-for-my-vehicle/3184012). The better technique is RPM × throttle bilinear crossfade of samples every 1000 RPM — [NEODRIVE devlog](https://sevencrane.itch.io/neodrive/devlog/1322297/how-to-make-car-sound) (non-Roblox)
- **Assists:**
  - A-Chassis flip via AlignOrientation (`Flip.Enabled`) and counter-steer assist — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
  - Teleport-up reset — [DevForum constraints tutorial](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)
  - BodyGyro-based flip attempts (deprecated API) — [DevForum flip system](https://devforum.roblox.com/t/car-flip-system-when-press-v/548839) (title/snippet only)

### Inferences
- **Engine sound.** Play sounds locally on each client, driven from the replicated RPM and throttle (two attributes) rather than from server-side Sound property updates. A-Chassis dropped its server-replicated sound plugin over bandwidth, which supports this.
- **GTA handling.meta gearbox.** `nInitialDriveGears`, `fInitialDriveMaxFlatVel` and `fClutchChangeRateScaleUpShift/DownShift` map naturally onto the A-Chassis ideas: an RPM-difference clutch and a slightly-above-redline limiter target to avoid rev bounce. GTA's auto-gearbox does not need a stall model.
- **Air control and auto-righting.** GTA-style air control, i.e. pitch/yaw torque from steer and throttle input while airborne, can be implemented with our existing Torque mover. AlignOrientation is only needed if we want a constraint-solved righting assist. No Roblox reference implementation exists.

### Gaps
- No open-source Roblox nitrous/NOS module or GTA-style airborne control module found.
- A-Chassis's internal engine curve, clutch and sound code were not read (only release notes).

---

## Q4. Roblox vehicle physics benchmarks (cost per car, number of cars)

### Takeaway
I found no rigorous public benchmark of per-car physics cost on Roblox. What exists is anecdotal numbers in help threads, plus staff statements on Server Authority's resimulation multiplier.

### Cited Findings
- A Jan 2026 thread discusses "50 cars", "20-30 players", "50 baseparts", "20kb/s"–"50kb/s" and "100 ms slower" in the context of server-simulated cars with client-side visual detail. One reply describes a custom replication scheme: cars are parented under the Camera (non-replicated), the driver moves locally, and the server rebroadcasts via FireAllClients. The scraper returned these numbers without context, so treat them as unverified — [DevForum](https://devforum.roblox.com/t/performance-concerns-replication/4269082)
- Server Authority: resimulation at 100 ms latency is 6.25× the simulation load of client-authoritative play. A user reports "pretty bad frame dips when driving around on server authority" — [DevForum staff deep dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
- A-Chassis optimizations: "WheelOutput no longer contains 5 for-loops"; cached instances moved to tables "to avoid registry limit issues"; a Tires plugin value "to change FE rate (This is helpful for lag.)" — [A-Chassis releases](https://github.com/lisphm/A-Chassis/releases)
- Staff reply in a compute thread: "server support… is greatly dependent on your server side logic, especially on per player complex computations, like physics" — [DevForum](https://devforum.roblox.com/t/scale-your-game-performance-with-extended-services-for-compute/4665165) (snippet only)

### Inferences
- We should produce our own benchmark: microseconds per car per step for the pure module (4 spherecasts + force math), with and without the Instance-write stage, and the number of cars at 60 Hz before the server Heartbeat goes over budget. The literature gives nothing to compare against.
- Batch all cars into a single loop and keep visual-only parts (wheels, smoke, sounds) client-side. This is the common community advice, and A-Chassis's FE-rate setting for tires reflects it.

### Gaps
- No published measurements of spherecast cost per wheel, of VectorForce vs ApplyImpulse cost, or of the maximum number of client-owned cars per server.
