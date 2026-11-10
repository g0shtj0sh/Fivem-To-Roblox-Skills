# Roblox (Luau) vehicle physics architectures, for a GTA V handling.meta-driven engine

Research date: 2026-11-10. Sources: Roblox Creator Docs, Roblox DevForum (read through a scraping proxy; direct WebFetch to devforum.roblox.com was blocked in this sandbox), GitHub. DevForum posts are community opinion unless they come from Roblox staff. Where a claim is my own inference or arithmetic, it is listed under "Inferences".

---

## 1. Existing Roblox chassis and vehicle systems, and how they work

### Takeaway
Roblox vehicle systems fall into two families:
- **Constraint chassis.** A-Chassis, Roblox's Racing template buggy and MotorVehicle use physical wheel parts with Spring/Cylindrical/Hinge constraints and motor torque.
- **Raycast chassis.** Jailbreak (reportedly) and many DevForum kits use one rigid body. They raycast down per wheel and apply spring, damper, friction and drive forces at the contact points through VectorForce or impulses.

Raycast chassis offer the per-wheel force control needed to reproduce GTA handling.meta. Until 2025-2026, though, they suffered from frame-rate dependence because Luau had no fixed-step callback.

### Cited Findings
**A-Chassis (constraint-based, open source)**
- A-Chassis is a free, open-source (MPL-2.0) chassis kit, "used by hundreds of experiences". Its official GitHub page is lisphm/A-Chassis. The latest release is 1.7.2(M), dated Mar 19 2026, and it ships a car and a bike variant. The code is 100% Luau and it has a plugin system — [GitHub lisphm/A-Chassis](https://github.com/lisphm/A-Chassis)
- Known issues listed in the README: "Entire car shifts when steering on 'New' steering type" and "Bike animation breaks layered clothing" — [GitHub lisphm/A-Chassis](https://github.com/lisphm/A-Chassis)
- The A-Chassis Tune module is a plain ModuleScript of assignments. Suspension values map onto SpringConstraint properties, e.g. `Tune.FSusDamping = 500 -- Spring Dampening`, `Tune.FSusStiffness = 9000 -- Spring Force`, `Tune.FAntiRoll = 50 -- Anti-Roll (Gyro Dampening)` — [DevForum "A Chassis max speed"](https://devforum.roblox.com/t/a-chassis-max-speed/3503053); [DevForum "Wierd glitch"](https://devforum.roblox.com/t/wierd-glitch-can-someone-help-me/613186)
- The top speed per gear is derived from the Tune: a leaked drive-script excerpt shows `_spLimit = (_Tune.Redline+100)/(fFDr*_Tune.Ratios[_CGear+2])`. The Tune therefore uses Redline, a gear `Ratios` table and a final drive, and top speed comes out of gearing rather than a direct setting. This comes from a Scribd copy, which is a low-quality secondary source — [Scribd "Pitstop" chassis script](https://www.scribd.com/document/904586645/Pitstop)
- Users report that top speed cannot be set directly; you change Horsepower and gearing instead. Changing Tune values at runtime can fail, and replies suggest exposing them through NumberValues — [DevForum "How to change A chassis tune speed"](https://devforum.roblox.com/t/how-to-change-a-chassis-tune-speed-and-aceleration/602602); [DevForum "script changing horsepower of A-Chassis"](https://devforum.roblox.com/t/how-to-have-a-script-changing-the-horsepower-of-an-a-chassis-car/2875908)

**Roblox official Racing template (Jan 2024) and Server Authority Racing template (2026)**
- Roblox released a "modernized Racing template" on 2024-01-23 with an updated "endorsed dune buggy". "The car can be easily tuned by adjusting various attributes on its components." It includes Nitro, and its client logic lives in `Car.Scripts.Client.ClientController` — [DevForum "New Studio Racing Template!"](https://devforum.roblox.com/t/new-studio-racing-template/2805745)
- Developer feedback on that template:
  - "The car has some instability issues with the aerodynamics beta enabled which cause it to fling out of the world occasionally."
  - At max speed, crashing made the character and buggy teleport "millions of studs away and back".
  - "nitro consumption is based on client, so have to fire a remote, which can be exploited."
  
  Source: [DevForum "New Studio Racing Template!"](https://devforum.roblox.com/t/new-studio-racing-template/2805745)
- A Server Authority version, "Racing – Server Authority Template", is linked from the official server-authority docs as an example project — [Creator Docs: Server authority model](https://create.roblox.com/docs/projects/server-authority); [Roblox game page](https://www.roblox.com/games/134686834388911/Racing-Server-Authority-Template)
- Roblox staff pointed beta testers to the "Server Authority Racing Template to see how to make a custom seat that works" — [DevForum Studio Beta thread p.15](https://devforum.roblox.com/t/studio-beta-build-fair-responsive-games-with-server-authority/4139157?page=15)

**MotorVehicle (Daw588), a constraint-driving logic library**
- MotorVehicle is a pure logic library. It outputs `angularVelocity`, `angle`, `motorMaxTorque` and `motorMaxAngularAcceleration` for the developer to feed into constraints. Config covers the engine (`torque`, `gearRatios`), suspension (`height`, `stiffness`, `damping`) and wheels (`radius`, `friction`, `maxSteerAngle`). The source is at github.com/Daw588/motor-vehicle — [DevForum MotorVehicle](https://devforum.roblox.com/t/motorvehicle-chassis-programming-made-easy/2136669)
- The author says it is not meant for realistic racing games. The constraint chassis is FPS-independent "because it's relying on Roblox's constraints". The author abandoned the planned raycast chassis because "raycast chassis just doesn't work on Roblox well". It was "tied to framerate, not the physics step… Roblox doesn't provide a way to tie something to physics" (2023 statement, written before `BindToSimulation` existed) — [DevForum MotorVehicle](https://devforum.roblox.com/t/motorvehicle-chassis-programming-made-easy/2136669)

**Raycast community kits**
- *Raycast Suspension Wheel Module (2023).* "The car shoots a raycast down onto the floor and depending on how close that ray is to the floor the more suspension force is applied upwards"; damping was added to stop oscillation. Stated limitations: "if all the vehicle wheels aren't level it will cause problems, the friction forces also aren't perfect." Replies reported:
  - cars falling through the floor without a CanCollide body;
  - "glitching if player Owner of Network Ownership";
  - wheel visuals and suspension not replicating, which was solved by computing wheel visuals on every client via CollectionService tags.
  
  Source: [DevForum Raycast Suspension Wheel Module](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)
- *"In Depth Scripted Car Physics" tutorial (2025-09).*
  - Rays and contact: a ray of length `REST_LENGTH + WHEEL_RADIUS` from each wheel attachment, plus optional "wheel casting" of 10 rays over π radians to follow the tyre shape and avoid snapping.
  - Forces: three world-relative `VectorForce`s per wheel (`Spring`, `Friction`, `Motor`) with `RelativeTo = World`. Spring is F = kx − cv, using the point velocity at the wheel.
  - Grip: lateral grip is `clamp(-sidewaysSpeed*AssemblyMass, -μN, μN)`. Rolling resistance is μ_roll·N, and it is zeroed below `ROLLING_STOP_SPEED` as the low-speed anti-jitter fix.
  - Drive: drive force is throttle×power with a linear drop-off near max speed. There is no gearbox or Pacejka model.
  - Loop and ownership: the update runs on `RunService.Heartbeat`. Ownership goes to the driver via `SetNetworkOwner(player)` and back to the server with `SetNetworkOwner(nil)` on exit; `SetNetworkOwnershipAuto` is advised against.
  - Fixes from replies: the naive damper made stiffness frame-rate dependent, and a semi-implicit form was offered, `dampingForce = (DAMPING / (1 + (DAMPING*dt)/m)) * verticalSpeed`. Drive force must use the steered wheel's LookVector. Massless meshes kill body roll. Forces must be reset (`ResetForces()`) when ownership changes, to avoid server/client force fights.
  
  Source: [DevForum In Depth Scripted Car Physics](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- *Pacejka + raycast + gearbox chassis (2023).* It uses raycast Hooke's-law suspension and a Pacejka curve on slip angle, `D*sin(C*atan(B*x - E*(B*x - atan(B*x))))` with B=1, C=2.8, D=1.6, E=1.2. It raises tyre load with spring compression, which enables "inertia drift". The gear is chosen from wheel rotation rate. The author abandoned it: "I couldn't get the car to have consistent physics across varied frame rates (30-240)… the 'sway bars'… were fine in 40-60 frames but anything not in that range would cause the car to jitter/shake/vibrate." Advice from replies:
  - use a single-part body ("physics sometimes got weird" with 2 parts);
  - add automatic counter-steer for young players;
  - port Unity tutorials, because Roblox ones are "extremely basic".
  
  Source: [DevForum Pacejka chassis](https://devforum.roblox.com/t/a-vehicle-chassis-with-the-pacejka-friction-circle-raycast-suspension-gearbox/2400821)
- *"Trying to create Ray-cast Suspension… (7th attempt)" (2025-02).*
  - On movers: "Impulse Sucks, Vector Forces do nothing but are the best way to go and Body Velocities/Gyros are deprecated (buggy)."
  - On timing: it "needs to have access to the internal 240hz physics refresh rate, but the RunService.Stepped function… only fires at 60hz."
  - On damping: changeable damping "breaks the system completely".
  - Outcome: a reply (dthecoolest) suggested sub-stepping "which will make the suspensions more stable at lower fps and for higher spring stiffness values". The author eventually pivoted to SpringConstraints, rods and "Brush Tire model principles".
  
  Source: [DevForum 7th-attempt thread](https://devforum.roblox.com/t/trying-to-create-ray-cast-suspension-editable-open-stable-and-optimized/3494597)
- *Raycast vehicle movement thread.* Prefer force instances over `:ApplyImpulse()`, since "your code runs at a different rate/timestep than the roblox physics", and the solver iterates "2x / 4x more often than Heartbeat" — [DevForum Raycast vehicle movement](https://devforum.roblox.com/t/raycast-vehicle-movement/3640420)
- *StarryDrive 2.0* is a plugin that claims to make most vehicle models drivable and stable without manual constraint tuning. Its licence and openness were not verified — [DevForum StarryDrive 2.0](https://devforum.roblox.com/t/starrydrive-20-build-stable-vehicles-in-minutes/4750344)

**Big games (Jailbreak, Driving Empire, Greenville, SWFL)**
- A 2023 DevForum question says Jailbreak "doesn't use physics for their cars, they use raycasting". Community replies say Jailbreak cars use BodyMovers plus raycasting. No Badimo developer confirmation was found — [DevForum "How does jailbreak do their cars?"](https://devforum.roblox.com/t/2501259); [DevForum "How to make a jailbreak type car"](https://devforum.roblox.com/t/how-to-make-a-jailbreak-type-car-by-scripting/1456531)

### Inferences
- A GTA handling.meta port needs raycast-style per-wheel force synthesis. GTA's model is per-wheel traction curves, suspension force/damping/raise, anti-roll, drive bias and CoM offset. A-Chassis's constraint model exposes SpringConstraint stiffness/damping and motor torque but not slip-based tyre force, so it can only approximate GTA traction semantics.
- The main historical reason raycast kits failed on Roblox was frame-rate-dependent force integration on Heartbeat/Stepped. The physics model itself was not the problem. Section 3 shows this is now addressable with `RunService:BindToSimulation()`.
- No community resource shows full Pacejka with slip ratio and a friction circle at production quality. Each kit implements a subset.

### Gaps
- I did not find primary documentation or developer talks for Driving Empire, Greenville, Southwest Florida, NCS/Novena or "Endorsed" vehicle internals.
- I did not read the A-Chassis source directly, which ships as .rbxm, so I could not cite exact Tune field names for torque curve and tyre friction (PeakRPM, curve shape, `FWheelFriction` etc.).
- I could not verify the exact constraint types in the 2024 Racing template buggy, or the car implementation in the Server Authority Racing template. Both are Roblox place files, so they need to be opened in Studio.

---

## 2. Raycast vs constraint suspension and tyres: stability, determinism, performance, units

### Takeaway
- **Constraint chassis** run inside the 240 Hz solver. That makes them frame-rate independent and stable at high stiffness, but harder to map to GTA's tyre semantics, and prone to flinging on crashes.
- **Raycast chassis** give full control but must integrate forces at a fixed rate, ideally `BindToSimulation` or sub-stepped. Otherwise stiffness and anti-roll vary with FPS.
- **Units:** Roblox length is 0.28 m/stud and mass is 21.952 kg/RMU, but default gravity (196.2 studs/s²) is not 9.81 m/s² in those units. GTA values must be converted deliberately.

### Cited Findings
- The physics solver runs at up to 240 Hz with adaptive timestepping. Parts are assigned to solver islands at 240 Hz ("1dt"), 120 Hz ("2dt") or 60 Hz ("4dt"). "Parts assigned to the 240 Hz island include assemblies with high velocity values, high acceleration values, and complex mechanisms that are hard to solve." — [Creator Docs: Adaptive timestepping](https://create.roblox.com/docs/physics/adaptive-timestepping)
- Adaptive mode "can improve physics performance by up to 2.5 times". However, "racing games, 'destruction' simulations, or games featuring complex mechanisms like tanks" should use Fixed mode (240 Hz) via `Workspace.PhysicsSteppingMethod`. "When 240 Hz islands interact with islands of different frequencies… those islands are converted to 240 Hz with an overhead." — [Creator Docs: Adaptive timestepping](https://create.roblox.com/docs/physics/adaptive-timestepping)
- Units: 1 stud = 28 cm, and 1 RMU (Roblox Mass Unit) = 21.952 kg — [Creator Docs: Roblox units](https://create.roblox.com/docs/physics/units)
- `Workspace.Gravity` is "measured in studs per second squared and by default is set to 196.2 studs/second²" — [Creator Docs: Workspace](https://create.roblox.com/docs/reference/engine/classes/Workspace)
- Current mover constraints are VectorForce, Torque, LinearVelocity, AngularVelocity, AlignPosition, AlignOrientation and LineForce. Legacy BodyMovers are deprecated, each with a replacement:

  | Deprecated | Replacement |
  |---|---|
  | BodyPosition | AlignPosition |
  | BodyGyro | AlignOrientation |
  | BodyVelocity | LinearVelocity |
  | BodyAngularVelocity | AngularVelocity |
  | BodyForce, BodyThrust | VectorForce |
  | RocketPropulsion | LineForce / AlignOrientation |

  VectorForce's `RelativeTo` lets force be applied at an attachment offset, like `BodyThrust.Location`. LinearVelocity and AlignPosition support `ForceLimitMode` PerAxis — [Creator Docs: Mover constraints](https://create.roblox.com/docs/physics/mover-constraints)
- In raycast kits, impulses applied from Luau are not synchronized with the solver substeps ("your code runs at a different rate/timestep than the roblox physics"), so force instances are preferred — [DevForum Raycast vehicle movement](https://devforum.roblox.com/t/raycast-vehicle-movement/3640420); [DevForum 7th-attempt thread](https://devforum.roblox.com/t/trying-to-create-ray-cast-suspension-editable-open-stable-and-optimized/3494597)
- Raycast instability is driven by frame rate. Sway bars jittered outside 40-60 FPS — [DevForum Pacejka chassis](https://devforum.roblox.com/t/a-vehicle-chassis-with-the-pacejka-friction-circle-raycast-suspension-gearbox/2400821). Spring stiffness also varied with FPS until a semi-implicit damper was used — [DevForum In Depth Scripted Car Physics](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- A constraint chassis is FPS-independent because it relies on the engine's constraints — [DevForum MotorVehicle](https://devforum.roblox.com/t/motorvehicle-chassis-programming-made-easy/2136669)
- Single-ray suspension can snap on edges and miss on steep tilts. Multi-ray "wheel casting" across the tyre arc and caching `lastWheelCenter` were the fixes reported — [DevForum In Depth Scripted Car Physics](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- Massless parts: "if you make everything massless, physics likes to bug out" (community) — [DevForum "How to make a jailbreak type car"](https://devforum.roblox.com/t/how-to-make-a-jailbreak-type-car-by-scripting/1456531). Massless meshes also remove natural body roll — [DevForum In Depth Scripted Car Physics](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- High-speed collisions in the constraint-based template caused extreme teleport and fling glitches, and the aerodynamics (FluidForces) beta caused flings — [DevForum Racing Template](https://devforum.roblox.com/t/new-studio-racing-template/2805745)

### Inferences
- **Gravity mismatch (arithmetic).**
  - 196.2 studs/s² × 0.28 m/stud ≈ 54.9 m/s², about 5.6 g, not 9.81 m/s².
  - 9.81 m/s² is about 35.0 studs/s² at 0.28 m/stud.
  - So 196.2 matches the legacy 1 stud = 5 cm convention, since 9.81/0.05 = 196.2.
  
  A faithful GTA port has two options. (a) Set `Workspace.Gravity ≈ 35` and convert GTA metres at 1/0.28. Or (b) keep 196.2 and treat 1 stud = 5 cm, which makes cars appear tiny or very fast. Either way, every GTA value with length in it must use the same scale: `fSuspensionRaise`, `fSuspensionUpperLimit`, `vecCentreOfMassOffset`, `fInitialDriveMaxFlatVel` in km/h, and so on. Option (a) conflicts with character jump tuning; it may need per-character `JumpPower`/`JumpHeight` tuning, or custom gravity for the vehicle via a counter-VectorForce.
- **Mass and force units (arithmetic).**
  - 1 RMU = 21.952 kg = (0.28)³ × 1000 kg, i.e. a cubic stud of water.
  - A 1500 kg GTA `fMass` is ≈ 68.3 RMU.
  - The force unit RMU·stud/s² ≈ 21.952 × 0.28 ≈ 6.15 N.
  
  The solver does not care about units as long as they are consistent. A custom tyre model can work internally in SI and convert at the API boundary.
- **Tunnelling at GTA top speeds.** At 0.28 m/stud, 300 km/h ≈ 298 studs/s, which is ≈ 1.24 studs per 240 Hz step or ≈ 5 studs per 60 Hz step. Thin walls and kerbs can be missed by single-point rays at 60 Hz. Suspension rays should start above the wheel and be at least travel + radius + v·dt long, or use `Shapecast`/`Spherecast`. This is inference; I did not find a Roblox doc on CCD for vehicles.
- **Recommended hybrid.** Use a single rigid chassis part, or a welded assembly with explicit mass and CoM via `CustomPhysicalProperties` and `Massless` children. Add raycast or shapecast wheels with the tyre force model in Luau, and apply the result through per-wheel VectorForce (`RelativeTo = World`) at the contact attachment. Visual wheels are non-colliding, CFrame-driven meshes. Keep a low-friction collision hull for crashes and let the engine resolve body-to-world contacts at 240 Hz.

### Gaps
- I found no benchmark numbers comparing per-car CPU cost of raycast vs constraint chassis with many cars (e.g. 30+ AI/traffic cars).
- There is no official Roblox doc on continuous collision detection or tunnelling for fast assemblies.

---

## 3. Networking: ownership, server authority, timing, sub-stepping

### Takeaway
Until mid-2026 the standard pattern was:
1. driver client owns the assembly (`SetNetworkOwner(driver)`);
2. vehicle forces computed on the client;
3. server sanity checks.

That pattern is responsive but exploitable. Roblox has since shipped **Server Authority** (full release 2026-07-09). It runs a fixed-step simulation (`UseFixedSimulation`, `RunService:BindToSimulation`) with client prediction, rollback and resimulation, and explicitly lists vehicles and racing as targets. This finally gives raycast chassis a fixed-step callback, at the cost of higher server and client CPU and some known mover bugs.

### Cited Findings
**Classic network ownership**
- The engine auto-assigns ownership based on proximity and hardware. `BasePart:SetNetworkOwner()` sets it from the server, and `SetNetworkOwnershipAuto()` reverts it. In the docs' vehicle example, a passenger who sat first owns the whole vehicle, so "the driver will have to wait several network cycles before their input is recognized" — hence the driver should be set as owner explicitly — [Creator Docs: Network ownership](https://create.roblox.com/docs/physics/network-ownership)
- Security: "Roblox cannot verify physics calculations when a client has ownership over a BasePart. Clients can exploit this… teleporting the BasePart, making it go through walls or fly around." Touched events are also client-fired for owned parts. `SetNetworkOwner(nil)` on gameplay-critical objects "may result in jittery physics interactions for clients" — [Creator Docs: Network ownership](https://create.roblox.com/docs/physics/network-ownership)
- Community practice is to give ownership only while seated, validate on the server, and accept that server ownership makes input feel laggy. Exploiters can insert movers client-side that replicate — [DevForum Exploit Prevention with Vehicles?](https://devforum.roblox.com/t/exploit-prevention-with-vehicles/203654); [DevForum anti-exploit for a car system](https://devforum.roblox.com/t/how-would-i-go-about-making-an-anti-exploit-for-a-car-system/1521175)
- Physics replication improvements (`Workspace.ImprovedPhysicsReplication`) rolled out from 2026-06-15, with "eventual consistency" so updates are not lost to packet drops. Staff acknowledged and fixed freeze/stutter on ownership change — [DevForum Upcoming Improvements to Physics Replication](https://devforum.roblox.com/t/upcoming-improvements-to-physics-replication/4675512)

**RunService timing**
- `PreSimulation` fires "prior to the physics simulation" and supersedes `Stepped`. `PostSimulation` fires after it. `Heartbeat` fires after physics, and its dt is time since the previous frame. `PreRender` supersedes `RenderStepped` — [Creator Docs: RunService](https://create.roblox.com/docs/reference/engine/classes/RunService)
- `RunService:BindToSimulation(function, frequency: Enum.StepFrequency, priority)` "binds a custom function to be called at a fixed frequency which is independent of the frame rate. In the server authority model, bound functions will also get called when the client needs to resimulate." It requires `Workspace.UseFixedSimulation` — [Creator Docs: RunService](https://create.roblox.com/docs/reference/engine/classes/RunService); [Creator Docs: Workspace](https://create.roblox.com/docs/reference/engine/classes/Workspace)
- Server-authority deep dive (staff) cites `Enum.StepFrequency.Hz60` as the simulation frequency in examples — [DevForum Server Authority Tech Deep Dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)

**Server Authority (2026)**
- Setup:
  - `Workspace.AuthorityMode = Server`
  - `NextGenerationReplication` enabled
  - `PlayerScriptsUseInputActionSystem` enabled
  - `SignalBehavior = Deferred`
  - `UseFixedSimulation` enabled
  - `StreamingEnabled` enabled
  
  Gameplay logic goes in `BindToSimulation` functions in a ModuleScript run on both client and server. Inputs must use the Input Action System (`InputAction`/`InputContext`), not `UserInputService.InputBegan`. Time must use `time()`, not `tick()`/`os.clock()`. "Cars and other gameplay-critical objects can remain server-owned without incurring input latency costs" — [Creator Docs: Server authority model](https://create.roblox.com/docs/projects/server-authority)
- Prediction, misprediction and rollback: the client predicts ahead, compares against the authoritative state, and on mismatch resets to the server state and resimulates with re-applied inputs. Prediction applies to whole assemblies, including constraint-connected parts — [Creator Docs: Server authority model](https://create.roblox.com/docs/projects/server-authority)
- Full release was 2026-07-09: "consistent, fair physics for character movement, vehicles, and sports". Racing, Soccer and Laser Tag templates are provided. "You will see increased server utilization." Remote events are not synchronized with the shared timeline. Attributes are limited to 64 per instance with limited string size. A top reply warns that systems "using physics mover instances (e.g. Constraints, or even legacy BodyMovers) might need a bit of rework" — [DevForum Full Release: Server Authority](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993)
- Engineering details from the staff deep dive:
  - **Rollback scope.** Rollback resimulates "EVERYTHING that was predicted on the Client"; there are no prediction islands yet.
  - **Cost.** A misprediction at 100 ms latency means resimulating 100 ms of physics, "6.25x the simulation load of a standard Client-Authoritative game".
  - **Non-determinism.** The engine is non-deterministic, so positions are quantized and only a ≥0.1-stud difference counts as a misprediction. That quantization "is currently causing some drift in certain BodyMovers/Constraints".
  - **VectorForce.** "Vector forces appear to be bugged and applying too much force compared to non-server authority games."
  - **Other cars.** Colliding with a non-predicted car gives visual jitter against a stale copy. Racing games should call `RunService:SetPredictionMode` on every player's car, wheels and hitboxes.
  - **Touched events.** They can misfire during rollbacks; use `GetTouchingParts()`.
  
  Source: [DevForum Server Authority Tech Deep Dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
- A community report says a server-authority vehicle "floats up and down repeatedly" on live servers while working in Studio — [DevForum Multiple server authority game breaking bugs](https://devforum.roblox.com/t/multiple-server-authority-game-breaking-bugs/4738901)
- Before BindToSimulation, developers asked Roblox for manual physics stepping for rollback anti-exploit — [DevForum feature request: manually step the physics simulation](https://devforum.roblox.com/t/anti-exploit-security-rollback-allow-us-to-manually-step-the-physics-simulation/1772729/7)

### Inferences
- **Recommended timing.**
  - New project: `UseFixedSimulation = true`, with the vehicle force calculation in `RunService:BindToSimulation(fn, Enum.StepFrequency.Hz60 or higher if available, priority)`. This removes the frame-rate dependence that killed earlier raycast chassis.
  - Within each 60 Hz tick, sub-step the stiff parts (wheel spin and slip integration, suspension damper) internally, e.g. 4×, to approximate 240 Hz. Then write the averaged force into the VectorForce, which the solver holds constant across its 240 Hz substeps.
  - Without server authority, use `PreSimulation` rather than `Heartbeat`, so forces are set before the step, and still sub-step internally using `deltaTimeSim`.
- **Two viable networking modes.**
  - *Mode A, client-owned (classic).* The driver owns the assembly and runs the force model. Other clients see engine-replicated interpolation; visual wheel and suspension state is recomputed locally from replicated chassis CFrame and velocity, or sent through attributes. The server validates speed vs handling.meta top speed, position deltas, and seat occupancy. Lowest server cost; weakest anti-cheat.
  - *Mode B, Server Authority.* The car is server-owned and predicted. The same Luau force model runs in `BindToSimulation` on both sides, and inputs travel as InputActions. This gives cheat resistance, but adds server CPU and client resimulation cost. Known VectorForce over-force and constraint drift bugs must be tested against. Applying `SetPredictionMode` to all nearby cars multiplies resimulation cost in traffic.
  - A GTA-style open world with many AI/traffic cars probably needs Mode A for traffic, or simplified kinematic traffic, even if player cars use Mode B.
- **Vehicle-model state in server authority.** Tyre slip state, wheel angular velocities, gear and RPM all affect simulation. They should live in rollback-safe storage: attributes within the 64-per-instance limit, or deterministically re-derivable state. Hidden Luau upvalues would not roll back.

### Gaps
- I could not confirm which `Enum.StepFrequency` values exist (Hz30 and Hz60 are referenced; whether Hz120/Hz240 exist is unverified).
- I found no official guidance on interpolation buffer length for remote vehicles under ImprovedPhysicsReplication.
- I could not inspect the Server Authority Racing template's car code to see whether Roblox itself uses raycast or constraint wheels there.

---

## 4. Pacejka and slip-based tyre models in Luau; low-speed jitter, sleeping, drift

### Takeaway
Community Luau implementations range from clamp-to-μN lateral friction (stable and simple) to a slip-angle-only Pacejka curve (drift-capable but frame-rate sensitive). None of those found implement a full combined-slip friction circle with a proper low-speed blend. GTA's own model (traction curve max/min and lateral curve) is closer to a simplified slip curve than to full Pacejka.

### Cited Findings
- **Clamp model.** Lateral force = `clamp(-v_lat * m, -μN, μN)` with N = suspension force. Rolling resistance is zeroed below a stop-speed threshold to prevent creeping and jitter at rest — [DevForum In Depth Scripted Car Physics](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)
- **Pacejka on slip angle in degrees** (B=1, C=2.8, D=1.6, E=1.2), with load scaled by spring compression to allow "inertia drift". Its inconsistency across 30-240 FPS led to abandonment — [DevForum Pacejka chassis](https://devforum.roblox.com/t/a-vehicle-chassis-with-the-pacejka-friction-circle-raycast-suspension-gearbox/2400821)
- **Brush tyre model principles** were adopted by the 7th-attempt thread author in the final pivot (details not published) — [DevForum 7th-attempt thread](https://devforum.roblox.com/t/trying-to-create-ray-cast-suspension-editable-open-stable-and-optimized/3494597)
- **Simple drift hack:** "disable the rear wheels drive component" or reduce rear grip — [DevForum Raycast Suspension Wheel Module](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)
- **Auto counter-steer** was recommended for accessibility, since young players spin out — [DevForum Pacejka chassis](https://devforum.roblox.com/t/a-vehicle-chassis-with-the-pacejka-friction-circle-raycast-suspension-gearbox/2400821)

### Inferences
- **Low-speed handling.** For low-speed stability in a slip model, compute slip angle with a velocity floor, e.g. `atan2(v_lat, max(|v_long|, v_min))`. Below ~1-2 m/s (≈ 4-7 studs/s), blend to the clamp/impulse-style "kill lateral velocity" force — the clamp model above is effectively this. Brake holding at rest should use a static-friction-style clamp rather than a slip curve.
- **Sleeping.** Roblox assemblies can sleep. Continuous VectorForce writes each tick may keep them awake, so zero forces when the car is at rest with no input. This is unverified against docs.
- **GTA mapping.** handling.meta's `fTractionCurveMax/Min`, `fTractionCurveLateral` (degrees to peak) and `fTractionCurveLateral`/longitudinal shape map naturally onto a piecewise or simplified slip-angle curve. Peak μ = CurveMax at the lateral angle, falling to CurveMin when sliding. That fits better than full Pacejka B/C/D/E, which would need fitting.

### Gaps
- I found no public Luau library implementing combined-slip Pacejka '89/'94 or a friction ellipse with slip ratio from wheel angular velocity, and no measured performance numbers for one.

---

## 5. Roblox projects replicating GTA-style handling or reading handling.meta

### Takeaway
I found **no** public Roblox or Luau project that parses or replicates GTA V `handling.meta`. The GTA-side references describe handling.meta as the XML file controlling mass, drag, drive force, brake bias, steering lock, traction curves, suspension and damage (~70+ params). Any Roblox port would be novel work.

### Cited Findings
- Searches for "roblox handling.meta GTA vehicle physics port luau" returned only FiveM/GTA modding tools, with no Roblox results. handling.meta "controls all vehicle physics in GTA 5, including mass, speed, traction, suspension, braking, and aerodynamics" — [FiveM handling.meta Editor](https://xgamingserver.com/tools/fivem/handling-meta); [Handling Tools guide](https://eddlm.github.io/Handling-Tools/guide); [GrandTheftWiki: Handling](https://www.grandtheftwiki.com/Handling)
- Jailbreak-style arcade cars on Roblox are reportedly raycast plus movers with heavy hand-tuning; "a car built using a similar approach won't drive like the Jailbreak cars" — [DevForum "How to make a jailbreak type car"](https://devforum.roblox.com/t/how-to-make-a-jailbreak-type-car-by-scripting/1456531)

### Inferences
- **Recommended architecture**, from the evidence above:
  1. **Data layer.** Parse handling.meta, either converted offline to a Luau table or parsed at runtime from a string. Convert to Roblox units with one explicit scale constant set (stud = 0.28 m, RMU = 21.952 kg) and a chosen gravity strategy (Section 2).
  2. **Simulation layer.** A pure-Luau, instance-free `VehicleSim.step(state, input, dt)` module that does the following:
     - Per wheel, shapecast/raycast for contact.
     - Suspension spring and damper from `fSuspensionForce`, `fSuspensionCompDamp`/`ReboundDamp`, `fSuspensionUpperLimit`/`LowerLimit` and `fSuspensionRaise`, with anti-roll from `fAntiRollBarForce`/`BiasFront`.
     - Drive from `fInitialDriveForce`, `nInitialDriveGears`, `fDriveInertia`, `fInitialDriveMaxFlatVel` and `fDriveBiasFront`.
     - Brakes from `fBrakeForce` and `fBrakeBiasFront`.
     - Tyre forces from the traction curve, `fTractionBiasFront` and `fTractionLossMult`.
     - Drag from `fInitialDragCoeff`.
     
     Run it in `BindToSimulation` at a fixed tick with internal sub-steps. Being pure, it is testable offline and rollback-safe.
  3. **Actuation layer.** Write the resulting forces into VectorForces at wheel attachments (`RelativeTo = World`) on a single chassis body with `CustomPhysicalProperties` mass matching `fMass` and the CoM shifted per `vecCentreOfMassOffset` (via massless children plus a ballast part, or `AssemblyCenterOfMass` adjustment).
  4. **Visual layer.** On `PreRender`, run per-client cosmetic wheel spin, steer and compression on all nearby cars, driven from replicated chassis state.
  5. **Network layer.** Choose Mode A (client-owned plus server validation against handling.meta limits) or Mode B (Server Authority with prediction); see Section 3.

### Gaps
- No precedent exists in the Roblox ecosystem to validate how faithful a handling.meta port can be. Accuracy and feel would need to be validated against GTA V/FiveM recordings.
