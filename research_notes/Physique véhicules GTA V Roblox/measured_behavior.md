# Measured GTA V vehicle behaviour: calibration targets for a Roblox re-implementation

Scope note: most "hard" numbers below come from three community sources. **gtacars.net** is Broughy1322's site; its metadata glossary was written by the testing community and draws partly on disassembly. **Eddlm's Handling-Tools**, whose maths the author says was "confirmed ingame, in Singleplayer" through SHVDN memory reads. **gtamods.com wiki**. Rockstar publishes none of this, so every formula is reverse-engineered and should be treated as a strong approximation. Each item is marked **[measured]** (in-game timing or test), **[datamined/derived]** (formula from game code or memory inspection) or **[opinion/claim]**.

---

## 1. Top speed, acceleration and the effect of handling.meta values (fInitialDriveMaxFlatVel, drag, gears, drive force)

### Takeaway
`fInitialDriveMaxFlatVel` (km/h-ish units) sets the redline speed in top gear. The documented relationship is `TopSpeed_kmh ≈ fInitialDriveMaxFlatVel × 1.2 / 0.9 (= ×1.333)`, where 0.9 is the default top-gear ratio. Measured fully-upgraded top speeds land between about 1.25× and 1.41× flatVel depending on engine power and drag. `fInitialDriveForce` is roughly the acceleration in g, multiplied by the current gear ratio. Torque is flat to 80% RPM and then drops to 60%.

### Cited findings
- **[datamined/derived]** `fInitialDriveMaxFlatVel` "Determines the speed at redline in top gear; Controls the final drive of the vehicle's gearbox. Setting this value does not guarantee the vehicle will reach this speed." Formula: `TopSpeedKph = (fInitialDriveMaxFlatVel * 1.2) / 0.9`. Multiply by 0.82 for mph or 1.32 for km/h. "GTA V uses a ratio of 0.9 for the top gear by default"; per-gear top speeds come from replacing 0.9 with that gear's ratio. — [GTAMods wiki handling.meta](https://gtamods.com/wiki/Handling.meta)
- **[derived]** Eddlm's metrics table gives `fInitialDriveMaxFlatVel / 0.75` km/h (the same ×1.333). It describes the value as "Maximum engine top speed. Over this speed, the engine power will degrade greatly. Keep in mind that gearing will stretch over this 'length'." — [Eddlm Handling-Tools](https://eddlm.github.io/Handling-Tools/handling)
- **[datamined]** `fInitialDriveForce`: "baseline acceleration of approximately `10 * InitialDriveForce` m/s2 (with upgrades, gear ratios, drag, etc. affecting this further)… `baseTorqueNm = fInitialDriveForce * fMass`. Due to GTA 5's torque curve being flat until 80% RPM (then dropping to 60% torque), higher values here also allow longer/more acceleration and increase top speed." — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[derived]** Eddlm: drive force "dictates the target acceleration the engine is aiming for, measured in G-Forces"; in-game acceleration = `fInitialDriveForce * Ratio of Current Gear`. — [Eddlm Handling-Tools](https://eddlm.github.io/Handling-Tools/handling)
- **[derived]** Electric vehicles "bypass this entirely, starting with x5 torque which drains to x1 at the top speed." — [Eddlm Handling-Tools](https://eddlm.github.io/Handling-Tools/handling)
- **[derived]** Drag: Eddlm gives air resistance (G) = `(Speed_mps * (fInitialDragCoeff * 0.0001))^2`. It adds: "Drag works against Torque. Both are measured in G-Forces, the speed at which they even out is the vehicle's top speed… The tug of war between Torque and Drag is not very strong. Your vehicle can easily go over this speed on downhill or under performance upgrades, though not very far." — [Eddlm Handling-Tools](https://eddlm.github.io/Handling-Tools/handling). (Caveat: plugging real values into this formula gives a tiny drag force, so the scaling as transcribed looks incomplete. See Gaps.)
- **[datamined]** `fInitialDragCoeff`: higher values mean "lower a maximum speed". `fMass` "only impacts collisions… It does not impact performance or handling behaviour in any way." — [gtacars.net glossary](https://gtacars.net/gta5/glossary); Eddlm agrees ("Mass is not at all related to physical agility") — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[datamined]** `nInitialDriveGears`: "All transmission upgrades increase this value by 1. Newer builds (after 1604) support 10 forward gears, with older builds supporting 7." — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** `fDriveInertia`: "How fast the vehicle's engine will rev… Low values reduce acceleration, but high values may not increase acceleration beyond fInitialDriveForce capability." — [gtacars.net glossary](https://gtacars.net/gta5/glossary). Eddlm: idle-to-redline time ≈ `1 / fDriveInertia` s at full throttle. — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[measured] Data points from Broughy1322 testing (fully upgraded, flat road), with handling values from gtacars.net:**

| Car | fInitialDriveMaxFlatVel | Drag | DriveForce stock → maxed | Gears (stock) | Measured top speed | Measured / flatVel |
|---|---|---|---|---|---|---|
| Blista | 135 | 8.0 | 0.23 → 0.276 | 5 | 168.98 km/h | 1.252 |
| Adder | 160 | 7.8 | 0.32 → 0.384 | 6 | 203.18 km/h | 1.270 |
| Pariah | 155.1 | 9.1 | 0.321 → 0.5778 | 6 | 218.87 km/h | 1.411 |

  Sources: [gtacars Blista](https://gtacars.net/gta5/blista), [gtacars Adder](https://gtacars.net/gta5/adder), [gtacars Pariah](https://gtacars.net/gta5/pariah). Lap times on Broughy's GP track: Blista 1:15.993, Adder 1:04.365, Pariah 1:00.644 (same pages).
- **[measured] Top speed methodology:** top speed is "the highest constant speed a vehicle can achieve after acceleration has stopped", timed between two checkpoints on a flat, straight, smooth regular road and rounded to 0.25 mph. Maximum variance was 4 frames (max SD 0.25 mph). Example: X80 Proto, 5 runs of 5.606–5.622 s → 128.25 mph. Non-digital in-game speedometers and menu stats "either don't work or at the very least are inaccurate". Completely flat stunt road pieces give lower top speeds than regular roads. Testing is on Expanded & Enhanced, "where fps has no impact on performance". — [gtacars.net Top Speed methodology](https://gtacars.net/gta5/topspeed)

### Inferences
- Stock-power cars top out **below** the theoretical redline-in-top-gear speed (1.333 × flatVel). Blista and Adder, with ×1.2 power, reach about 1.25–1.27×, so drag (or the 80%-RPM torque drop) limits them first. The Pariah, with ×1.8 power, reaches 1.41×, **above** 1.333. That fits Eddlm's note that a car "can easily go over this speed… under performance upgrades": top-gear redline is not a hard cap unless `hard_rev_limit` is set (see §3).
- A practical calibration target for a clone: with the same upgrade state, simulated top speed on flat ground should sit around 1.25–1.30 × flatVel for typical stock-ish cars and around 1.4 × for heavily upgraded high-power cars.
- Because mass has no effect on acceleration or braking, a faithful clone should use per-unit-mass forces (accelerations in g) for drive, brake and grip, and use real mass only for collisions.

### Gaps
- I found no complete published list of the default gear ratios for gears 1..N, beyond "top gear = 0.9" and the CVT range of 5.0 → 0.9.
- Eddlm's drag formula as transcribed does not reproduce the measured top speeds (it gives about 0.002 g at 200 km/h for drag 7.8), so an unseen scaling constant is probably missing. The exact drag formula is still unverified.
- In the Eddlm editor, the example "flatVel 200 → last gear tops at 115.99 mph" contradicts its own `/0.75` formula (that would be about 166 mph). The slider's displayed value may not have been 200 when scraped. Treat that example as unreliable.
- I could not get 0–60 or 0–100 acceleration time tables. Broughy publishes only lap times and top speeds.

---

## 2. Mod-shop upgrade effects (engine, transmission, turbo, brakes, tyres, suspension, spoilers, wheels)

### Takeaway
An engine upgrade multiplies `fInitialDriveForce` by `1 + 0.2 × (modifier/100)`. A "100" upgrade gives ×1.2; Pariah's "400" gives ×1.8. Transmission upgrades each add one gear and cut shift delay. A spoiler adds a fixed amount of wheel downforce, which means grip, but not top speed. Most body mods only move the centre of mass.

### Cited findings
- **[datamined]** carcols `statMods` modifier: "Value of how much a mod adds to a stat, in %. (for VMT_ENGINE, modifier value="100" adds 20% of the initialDriveForce value found in handling.meta)". — [GTAMods wiki Carcols.ymt](https://gtamods.com/wiki/Carcols.ymt)
- **[datamined, consistent with above]** gtacars "Max Engine Upgrade / Engine (Maxed)": Adder 100 → 0.32 to 0.384 (×1.2); Blista 100 → 0.23 to 0.276 (×1.2); Pariah 400 → 0.321 to 0.5778 (×1.8). — [Adder](https://gtacars.net/gta5/adder), [Blista](https://gtacars.net/gta5/blista), [Pariah](https://gtacars.net/gta5/pariah)
- **[opinion/claim, Broughy, backed by his testing]** "Engine - Higher levels increase engine power, resulting in better acceleration & top speed. Transmission - All add an extra gear. Higher levels reduce the delay between gear shifts. Turbo - Adding turbo increases engine power… Even if the stat bars are already full in Los Santos Customs you'll still gain a benefit from maxing out these upgrades." — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)
- **[measured]** Spoilers: any non-stock spoiler gives the same grip increase ("larger spoilers aren't any better than smaller"), and "Spoilers also have no effect on top speed". Active spoilers (T20, Furia) give the grip by default, and the car loses grip if the spoiler breaks. — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)
- **[datamined]** Wheel downforce (WDV) values: regular car stock 0.035, custom spoiler 0.07 (flat, independent of speed). Old-style `fDownforceModifier ≤ 100`: WDV rises from 0 at standstill, "exponentially", to a cap of `fDownforceModifier × 0.035` above 90% of flatVel, ×1.25 with a spoiler. New-style (>100): flat `(DF/100)×0.035×0.3` up to 40% of flatVel, rising to `(DF/100)×0.035×0.86` above 90%, ×1.25 with a spoiler, and skipped in single player. Open-wheel: `(DF×0.07×0.3)+0.035` at rest up to `(DF×0.07)+0.035` above 95% of flatVel. A broken wing divides DF by 5. — [gtacars.net Downforce](https://gtacars.net/gta5/downforce) (formulas "taken directly from disassembled game code"; Desmos calculators linked there)
- **[datamined]** Active spoiler special cases: Nero raised 0.07625; XA-21/Virtue 0.075; Hotring Hellfire roof flaps 0.229 under braking; X80 Proto 0.042 straight, up to 0.07 turning/braking; Comet S2, Itali RSX, 10F and others stuck at 0.035. — [gtacars.net Downforce](https://gtacars.net/gta5/downforce)
- **[derived]** Eddlm: "fDownforceModifier 5 → 0.14 Gs of additional grip at 60 mph"; the resulting value "is added to the wheel grip, multiply by the four wheels". — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[measured/claim]** Suspension height doesn't change speed in general. Exception: cars with advanced flag `reduce_body_roll_with_suspension_mods` (Tuners and others) gain traction when lowered. — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)
- **[measured/claim]** Off-road wheels make cars with handling flag `tyres_can_clip` (and without `fix_old_bugs`) smoother over kerbs. Lower-sidewall wheels (High End) give "a bigger kerb boost… while sacrificing stability". — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)
- **[claim]** Brakes: higher levels mean more brake force. Cars with model flags `abs_alt_std`/`abs_alt_option` lock up more easily, and max brakes make that worse. — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)
- **[claim]** Low-grip tyres (LS Car Meet) cut traction for drifting, are always slower for lap time, and once raised top speed until a patch fixed it. Armour upgrades have zero performance effect. Carbon parts aren't lighter. Body mods don't add grip, except where the "Adds traction like a spoiler" category applies (e.g. the Dubsta). — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)
- **[claim, Broughy setups]** Body mods, neons and suspension move the centre of mass (COM). Front bumpers move it forward. Rear bumpers and spoilers move it rearward. Side skirts "decrease body roll at high speed". Neons shift the COM toward the light "by a pretty significant amount" and lower it. Lower suspension lowers the COM, which adds stability but makes steering feel heavier. Wheels change traction bias, slip angle and anti-roll by small amounts (Fujiwara biases grip rearward; Rally Master biases it forward and adds slip angle). — [gtacars.net Setups](https://gtacars.net/gta5/setups)
- **[datamined]** Handling flag `reduced_mod_mass` "Reduces mass added from upgrades". — [gtacars.net glossary](https://gtacars.net/gta5/glossary)

### Inferences
- The clone's upgrade system can be modelled as: driveForce × (1 + 0.002 × Σengine-modifier%), +1 gear per transmission level (with a faster clutch), and wheel downforce 0.035 → 0.07 for a spoiler. Turbo's exact modifier isn't documented here. It is probably also a carcols `statMods` modifier on drive force.
- "Engine (Maxed)" on gtacars probably reflects only the summed engine-type modifier. Whether turbo is included in the "400" isn't stated.

### Gaps
- No per-level numbers for transmission clutch-rate increases, turbo % or brake % were found in the sources fetched.
- I found no measured lap-time or top-speed deltas per individual upgrade level.

---

## 3. Automatic transmission, RPM, rev limiter, engine braking

### Takeaway
Shift time ≈ 0.9 s / `fClutchChangeRateScaleUpShift` (gtacars) or 1 / value (Eddlm). Top gear ratio is 0.9. Normalized RPM never falls below 0.2 (idle) and redline is 1.0. Without the `hard_rev_limit` flag, gears have no hard speed cap. Engine braking is on by default, and the `freewheel_no_gas` flag disables it.

### Cited findings
- **[datamined]** `fClutchChangeRateScaleUpShift`/`DownShift`: "A value of 1 means the gear will take 0.9 seconds to shift up, with a value of 0.5 meaning it will take 1.8 seconds, a value of 2 taking 0.45 seconds". — [gtacars.net glossary](https://gtacars.net/gta5/glossary); GTAMods agrees: "A value of 1 = 0.9 seconds to shift gears… Recommended to not go over 13." — [GTAMods](https://gtamods.com/wiki/Handling.meta). **Conflict:** Eddlm uses `1 / fClutchChangeRateScaleUpShift` s (10 → 0.1 s, though the page shows "0.5s"). — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[datamined]** Typical values: Pariah up/down 3.4 (≈0.26 s), Adder 3.0 (≈0.30 s), Blista 1.7 (≈0.53 s). — [Pariah](https://gtacars.net/gta5/pariah), [Adder](https://gtacars.net/gta5/adder), [Blista](https://gtacars.net/gta5/blista)
- **[datamined]** CVT handling flag (`00001000`): "starts with a gear ratio of 5.0 when standing still and decreases as speed increases, ending at a ratio of 0.9 when at 90% of the vehicle's fInitialDriveMaxFlatVel." — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** Advanced flag `hard_rev_limit` (`00010000`): "changes gear shift behaviour to upshift earlier and applies a hard speed limit per gear like a real life gearbox. This stops the vehicle from being able to handbrake boost and from going over the intended top speed of each gear… For vehicles in the Tuners sub-class, this flag only limits the speed in the last two gears." — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** `hold_gear_with_wheelspin` (`00020000`): "shift later than normal, causing the engine to bounce off the rev limiter before changing gear". `close_ratio_gearbox` (`00200000`) gives longer gear ratios and slower acceleration. `force_smooth_rpm` (`00400000`) smooths revving in 1st gear. `gearbox_manual` (`00000400`) "Sets the clutch value to 0.0 when idling." — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** Handling flag `freewheel_no_gas` (`00000100`) "Disables engine-braking when no throttle is applied." This implies engine braking on throttle-off is default behaviour. — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[measured, user report]** RPM via `GET_VEHICLE_CURRENT_RPM`: "the RPM's always match the Clutch reading, but never fall below 0.2". — [Cfx.re forum thread](https://forum.cfx.re/t/getvehiclecurrentrpm-not-working-since-last-client-update/1093214) (search snippet)
- **[claim, Broughy]** "the speed of cars in GTA Online is all based on the engine revs… Anything you can do to get those revs to increase quicker (or go higher still if you're already at top speed) will make the car quicker." — [Kotaku, 2018](https://kotaku.com/gta-onlines-car-exploit-is-still-polarizing-players-1824264759)

### Inferences
- In GTA the wheel speed is driven toward RPM × gear ratio × flatVel. Revs are the primary state variable, and anything that spikes RPM (airborne wheels, suspension compression, handbrake) adds speed. A clone that wants GTA "feel", including handbrake boost and curb boost, should model an RPM state that drives the wheels, not a pure torque → wheel-acceleration model.
- Reasonable default automatic gearbox: upshift near redline (RPM ≈ 1.0), clutch disengaged for 0.9 / clutchRate s, idle RPM 0.2.

### Gaps
- I found no source giving exact automatic upshift and downshift RPM thresholds for the default (non-flagged) gearbox.
- No measured reverse top speed or reverse gear ratio was found.

---

## 4. Arcade assists and GTA-specific "feel" mechanics (curb boost, burnout, handbrake, traction/stability assists, in-air, gravity, self-righting)

### Takeaway
The main GTA-specific artificial mechanics are:
- A fake low-speed traction loss for burnouts: grip ≈ 1/(1+`fLowSpeedTractionLossMult`).
- RPM gains from suspension compression, which produce curb boost.
- Handbrake boost.
- Flag-based extra gravity: +10% or +20%.
- Righting forces.
- Mid-air auto-levelling on some flags.
- A speed-dependent steering reduction ("steering assist").
- Traction-control and stability-control flags exist but are undefined or don't work. TC only reduces throttle.

### Cited findings
- **[datamined]** `fLowSpeedTractionLossMult`: "approximate formula for how much traction the vehicle has at low speed is `1 / (1 + fLowSpeedTractionLossMult)`, so a value of 1 means a car will have around half as much traction at low speed." — [gtacars.net glossary](https://gtacars.net/gta5/glossary); GTAMods: "It affects mainly car burnout (spinning wheels when car doesn't move)… A completely artificial force." Default 1.0. — [GTAMods](https://gtamods.com/wiki/Handling.meta). Example values: Adder 1.5, Pariah 1.15, Blista 0.7 — [Adder](https://gtacars.net/gta5/adder), [Pariah](https://gtacars.net/gta5/pariah), [Blista](https://gtacars.net/gta5/blista)
- **[claim/datamined, secondhand]** Curb boost: "According to data miners, GTA Online is coded in such a way that when the suspension of a car or truck is compressed, the engine revs up more… Curb boosting supposedly takes advantage of this by repeatedly compressing the suspension." A correct curb boost "could shave 2 seconds or more off of their lap times". On legacy PC it was "even more effective due to higher frame rates". — [Kotaku 2018](https://kotaku.com/gta-onlines-car-exploit-is-still-polarizing-players-1824264759). The open-wheel advanced flag (`08000000`) "prevents any speed gain from mechanics such as curb boosting". — [gtacars.net Downforce](https://gtacars.net/gta5/downforce). Lower-sidewall wheels give "a bigger kerb boost" on `tyres_can_clip` cars. — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades). Broughy states FPS has no performance impact on Expanded & Enhanced. — [gtacars Top Speed](https://gtacars.net/gta5/topspeed)
- **[datamined]** Handbrake boost exists and is blocked by `hard_rev_limit`. — [gtacars.net glossary](https://gtacars.net/gta5/glossary). `fHandBrakeForce` "is on/off unlike regular brakes… Only locks the rear wheels." — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** Steering assist: `fSteeringLock` is the max inner-wheel angle when stopped, and "When travelling at higher speeds, steering angle is reduced from this maximum." — [gtacars.net glossary](https://gtacars.net/gta5/glossary). "when the game's steering assist reduces the steering amount at higher speeds, it simply uses a percentage of the original steering lock… Ideally the steering lock should be set up in a way that aligns the maximum steering cap with the optimal slip angle". Rule of thumb: `fSteeringLock ≈ fTractionCurveLateral × 1.25 + 10`. — [GTAMods](https://gtamods.com/wiki/Handling.meta)
- **[datamined]** Gravity: `offroad_abilities` raises the gravity constant by 10% to 10.78 m/s² (which implies a base of 9.8), giving more grip and faster falls, plus about half the power bonus of x2. `offroad_abilities_x2` raises gravity 20% to 11.76 m/s² and adds bush immunity, more power and "auto-levelling in mid-air". `offroad_increased_gravity_no_foliage_drag` is the same as x2 without the levelling. — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** Self-righting: `reduced_righting_force`, `improved_righting_force` and advanced `reduced_self_righting_speed` exist. This implies a default force that flips the car back onto its wheels. — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** Assists: advanced `assist_traction_control` (`00002000`) is "Currently undefined. Notes from source code: Just reduce throttle." `assist_stability_control` (`00004000`) is undefined. `force_no_tc_or_sc` "Allows motorcycles to lose traction". This implies bikes have built-in traction/stability control by default. — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** `fTractionSpringDeltaMax`: the distance in metres the vehicle "will pull back towards the direction it came from when it becomes completely stationary". GTAMods: "a small force pulling the vehicle inwards of a corner, more noticeable as the sliding angle increases." — [gtacars.net glossary](https://gtacars.net/gta5/glossary), [GTAMods](https://gtamods.com/wiki/Handling.meta)
- **[datamined]** Other notable flags:
  - `has_rally_tyres` inverts the grip curve, starting at Min and rising to Max with slip.
  - `block_increased_rot_velocity_with_drive_force` produces "fake wheelspin".
  - `can_wheelie` enables handbrake wheelies, and the "entire Muscle class is hardcoded to use this flag".
  - `low_speed_wheelies` (motorcycles).
  - `increase_suspension_force_with_speed`.
  - `diff_centre` / `fMaxDriveBiasTransfer` move drive from slipping wheels.
  - `fDriveBiasFront`: values >0.9 snap to 1 and <0.1 snap to 0.
  - `no_reverse`, `no_handbrake`, `steer_rearwheels`, `steer_all_wheels`.

  Source: [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** KERS on open-wheel cars "regenerates slowly when off the throttle and quickly when braking"; boosts are "most effective when activated at low speed". — [gtacars.net Upgrades](https://gtacars.net/gta5/upgrades)

### Inferences
- A faithful clone needs these non-physical layers:
  1. A low-speed grip multiplier, 1/(1+k), that fades out with speed. This produces the launch burnout.
  2. A speed-dependent steering limit tied to the optimal slip angle.
  3. RPM coupling to suspension compression and airborne wheel-spin, if curb boost and handbrake boost are wanted.
  4. A righting torque when the car is upside-down.
  5. An optional in-air pitch/roll control (GTA lets the player rotate cars in the air; only the x2 flag's *auto*-levelling is documented here).
  6. Engine braking when off throttle.

### Gaps
- I found no measured numbers for: the speed at which low-speed traction loss stops; the magnitude of the in-air rotation the player controls; the reverse speed cap; the gain in RPM per unit of suspension compression (the curb boost coefficient). These would need in-game measurement (e.g. Broughy's Fact-Finding videos, which I didn't transcribe).

---

## 5. Braking deceleration vs fBrakeForce; cornering g vs fTractionCurveMax; traction curve shape

### Takeaway
Grip values are treated as roughly "g". `fTractionCurveMax` ≈ peak cornering g; `fTractionCurveMin` is the sliding grip; peak grip comes at a slip angle of `fTractionCurveLateral/2`. `fBrakeForce` scales deceleration per wheel. Braking is traction-limited once `fBrakeForce > fTractionCurveMax/4`. No clean measured g-meter dataset was found.

### Cited findings
- **[datamined]** `fTractionCurveMax`: "The values roughly equate to g's of grip (such that a value of 1 means cornering at 1g)"; Min is the grip "when the wheels are sliding beyond their optimum slip angle… or when the vehicle's wheels are locked". `fTractionCurveLateral` is "the maximum angle the vehicle's tyre can handle during cornering before the wheels start to slide and revert from fTractionCurveMax to fTractionCurveMin". — [gtacars.net glossary](https://gtacars.net/gta5/glossary)
- **[datamined]** GTAMods: "peak traction position in degrees sideways = fTractionCurveLateral / 2". — [GTAMods](https://gtamods.com/wiki/Handling.meta). Eddlm: "The vehicle will tend to stay below half of this value". 22.5° is the recommended default, sports cars go down to 18°, and >24° only for the slidiest cars. — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[datamined]** Typical values: Adder Max/Min 2.5/2.38, Pariah 2.625/2.45, Blista 2.05/1.75. All use lateral 21.5–22.5. — [Adder](https://gtacars.net/gta5/adder), [Pariah](https://gtacars.net/gta5/pariah), [Blista](https://gtacars.net/gta5/blista). (Note: 2.5 "g" isn't physically realistic, which suggests an internal scaling. The glossary says "roughly".)
- **[derived]** Braking: "To use all of a vehicles traction for braking fBrakeForce must be higher than fTractionCurveMax / 4 (only tested with cars)". — [GTAMods](https://gtamods.com/wiki/Handling.meta). Eddlm: fBrakeForce is "How many Gs of deceleration are applied to each wheel… Assuming perfect balance, a fourth of brake is enough to make each wheel lockup". The editor example states "Target deceleration is 60-0 mph in ~1.71s" (that implies about 15.7 m/s² ≈ 1.6 g, but which slider value it used is unclear). — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[datamined]** Typical `fBrakeForce`: Adder 1.0, Pariah 1.0 (bias 0.52, handbrake 0.65), Blista 0.6. — gtacars pages above.
- **[datamined]** `fTractionLossMult` affects "traction and top speed" lost on surfaces whose grip multiplier isn't 1.0 (e.g. dirt). — [gtacars.net glossary](https://gtacars.net/gta5/glossary). Eddlm: high-end cars go "up to 1.5 or so before the traction loss of certain surfaces ends up making the car have negative grip." — [Eddlm](https://eddlm.github.io/Handling-Tools/handling)
- **[datamined] Suspension:** with `fSuspensionCompDamp` or `fSuspensionReboundDamp` set to `fSuspensionForce/2`, the suspension "perfectly cancels the compression in 1 bounce". Upper and lower limits are in metres relative to rest. If COM z sits well above `fRollCentreHeight`, the car tips easily; if it sits below, the car leans inward "like a Tyrus". — [gtacars.net glossary](https://gtacars.net/gta5/glossary). Example: Pariah has force 2.5, comp 1.5, rebound 3.0, limits +0.08/−0.09 m, ARB 0.8 — [Pariah](https://gtacars.net/gta5/pariah)
- **[datamined]** `vecInertiaMultiplier`: higher values make the vehicle take longer to rotate or stop rotating. It is "essentially the vehicle's feeling of weight". — [gtacars.net glossary](https://gtacars.net/gta5/glossary)

### Inferences
- Calibration approach: set the clone's lateral grip so a skidpad test gives a cornering g proportional to `fTractionCurveMax`. The scale factor is unknown; the community's "≈ g" is approximate. Set brake decel per wheel ∝ `fBrakeForce`, capped by the grip from the traction curve, and lock up when `fBrakeForce` > TCMax/4.
- Use a piecewise traction curve: grip rises to Max at slip angle Lateral/2, then falls to Min. Rally tyres invert this.

### Gaps
- I found no published in-game g-meter measurements (skidpad or 100–0 braking distance) tied to specific handling values. Broughy's lap times are the only large measured performance dataset, and they mix grip, power and driver skill.
