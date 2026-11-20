# Suspension / steering rumble: Bug vs. Autobello

> **Archived / superseded:** This was a read-only investigation of steering-wheel rumble. Its numerical comparisons and proposed tests are historical context, not current recommendations.

**Status:** read-only investigation, 2026-11-02. No vehicle tuning was changed.

## Purpose and limits

The goal is not to declare a culprit from static JBeam values. The reported symptom is a high-speed steering-wheel rumble which is amplified by FFB, appears on some road sections, disappears on a smooth bridge/flat map, and returns with the rougher road. The seat makes it easier to perceive but is not considered the origin. The owner has also previously tried making the steering more like the Autobello without resolving the issue; that history lowers the priority of a broad “copy Autobello steering” recommendation.

JBeamTool parsed the compared JBeam files with `ast --json`; the inspected Bug and Autobello suspension/body files also passed `verify --json --strict` with no warnings. This validates syntax/structure, **not** suspension behavior. AST array counts include comments/trivia, so raw AST counts are not used as counts of active physical beams or torsion bars.

The comparison is between:

- Bug baseline: the 1200 EU hardtop preset, which loads the standard Bug front and rear suspension, shocks, springs, steering, and steering box. See [bug_1200_eu_hardtop.pc](../../bug/vehicles/bug/bug_1200_eu_hardtop.pc#L1-L18).
- Autobello baseline: the user-provided standard 110 preset, using the Autobello body defaults and standard front/rear suspension. Its source is the local Autobello reference directory supplied by the user. This is a more appropriate reference than the modified street/race preset previously inspected.

The cars are useful qualitative controls, not identical experiments: they have different dimensions, frame/body structures, wheel/tire sizes, masses, suspension geometry, and powertrains. A parameter copied numerically between them does not necessarily produce the same wheel rate or response.

## Most actionable low-confidence-to-medium-confidence leads

### 1. Front toe/precompression default — first isolated A/B candidate

The Bug front steering part defaults `$toe_F` to **0.991**; the Autobello reference defaults it to **0.9995**. The baseline Bug preset does not provide a `$toe_F` override, so it inherits the Bug default. These values feed the precompression of the steering links, as shown in [Bug front steering](../../bug/vehicles/bug/components/frame/bug.suspension-F.jbeam#L420-L422); the corresponding Bug link definitions are in [the same steering part](../../bug/vehicles/bug/components/frame/bug.suspension-F.jbeam#L500-L501). The Autobello values and links were checked in the user-provided local front-suspension reference.

These are **beam precompression multipliers, not degrees of toe**. Do not convert the difference directly to an angle without evaluating the actual tie-rod geometry. But the defaults are conspicuously far apart for two vehicles the user considers comparable. A static toe/preload mismatch can bias tire forces and make road inputs more perceptible through the steering, even if it is not the root vibration mode.

**Suggested test, not applied:** on a duplicate Bug config only, override `$toe_F` to 0.9995 while keeping all other settings unchanged. Compare the same road section, direction, speed, and FFB setting. Record both steering-wheel feel and whether the physical steering/wheel motion changes. Restore the original config after the pass. This is a high-value, reversible test because it isolates one small default without touching suspension stiffness.

The user has already tried matching the steering setup generally, with no resolution. This test is only useful if the earlier comparison did **not** explicitly match the loaded `$toe_F` value; if it did, mark this hypothesis as already tested rather than repeating it.

### 2. Front suspension travel-limit envelope

The standard Bug front damper uses bump/rebound damping **1000 / 2000**; the standard Autobello front damper uses **850 / 1700**. More notably, the Bug front bounded-beam range is `longBoundRange: 0.06`, `shortBoundRange: 0.06`, `boundZone: 0.03`, while the Autobello uses `0.06 / 0.08 / 0.04`. Compare [Bug front shock](../../bug/vehicles/bug/components/frame/bug.suspension-F.parts.jbeam#L204-L220) with the standard front shock in the user-provided Autobello reference.

This difference could matter on a particular road profile if the Bug is reaching its bounded travel region earlier or entering the limit zone more sharply. It is not proof of bottoming: actual ride height, motion ratio, preload, and dynamic travel are needed. The road-dependent symptom makes this worth checking before making broad stiffness changes.

**Evidence to gather before tuning:** look for repeatable sharp events at the same bumps, visible/suspension-debug travel near the limit, or suspension impact sounds. If there is no evidence of limiter contact, do not change the bounds just because the numbers differ.

### 3. Front torsion-bar rate, preload, and standard damping

The standard Bug front torsion-bar parameter is **388.5** with precompression angle **0.40** ([Bug](../../bug/vehicles/bug/components/frame/bug.suspension-F.parts.jbeam#L51-L59)); the Autobello standard value is **327.7** with precompression angle **0.69** in the corresponding part. Bug standard front damping is 1000/2000 versus Autobello 850/1700 as noted above.

These are not a direct natural-frequency calculation. The torsion-bar tuple geometry and leverage differ, so the 18.6% scalar spring difference is not a claim that the Bug’s effective wheel rate is 18.6% higher. The different precompression angles also affect static position/load. If matching front toe has no effect and no limiter contact is observed, a controlled front-only spring/preload/damper comparison is more informative than changing front and rear together.

### 4. Rear suspension differences exist, but rear damper damping matches

The standard rear torsion-bar scalar is **4525** for the Bug ([Bug](../../bug/vehicles/bug/components/frame/bug.suspension-R.parts.jbeam#L73-L84)) versus **3155** for the Autobello. Again, do not compare these as wheel rates without geometry/motion-ratio analysis. The standard rear damper values themselves match at **2000 bump / 4000 rebound**, but the travel-limit envelope differs: Bug `301000 / 8000`, range `0.06 / 0.06`, zone `0.03`; Autobello `251000 / 5000`, range `0.08 / 0.06`, zone `0.04`. See [Bug rear shock](../../bug/vehicles/bug/components/frame/bug.suspension-R.parts.jbeam#L220-L242).

Because the symptom is most noticeable at the steering wheel, rear suspension is a lower-priority source than the front steering/suspension path, but rear impacts can still excite whole-body pitch/yaw and transmit loads forward.

### 5. Front steering helper damping is asymmetric in the Bug

The Bug has damping-only links from both `fh5l` and `fh5r` to `f2l`; the mirrored `fh5r`–`f2r` alternative is commented out in [Bug front steering](../../bug/vehicles/bug/components/frame/bug.suspension-F.jbeam#L587-L590). Git history shows this was a deliberate Release 22 experiment, not a parser mistake: it replaced a mirrored link. The user also reports having previously tried an Autobello-like steering setup without fixing the long-standing symptom.

Treat this as a **lower-priority follow-up**, not the leading fix. It is worth revisiting only if the previous steering comparison did not include these damping-only helper links, and only as a reversible one-change test. Damping-only links can transmit velocity-dependent force without imposing the same static length constraint as a normal spring beam, but the actual effect depends on their geometry and solver response.

The Bug steering box uses `FFBcoef = $ffbstrength * 10` (standard) and `* 8` (race) in [Bug front steering](../../bug/vehicles/bug/components/frame/bug.suspension-F.jbeam#L607-L644); the Autobello standard box uses `* 30`. Since the user reports that FFB only amplifies the rumble, these multipliers calibrate sensation downstream and should not be mistaken for the mechanical source. A higher number is not automatically wrong across vehicles or game versions.

## Structural context

The two cars have integrated body structures of broadly similar AST scale, but that does not make their load paths equivalent. The Bug’s front suspension has a separate sliding front subframe, multiple frame tie beams, and its own steering/damping network; see [Bug front suspension](../../bug/vehicles/bug/components/frame/bug.suspension-F.jbeam#L37-L160). The Autobello front setup also uses a subframe/steering assembly, but the hard points and their body connections are not identical. A suspension that started as a copy can accumulate small geometry, preload, bound, alignment, and body-attachment changes over years; copied beam constants do not guarantee copied behavior.

## Recommended investigation order

1. **Keep the current files untouched.** Save a duplicate of the baseline preset for experiments; do not make a tuning change to the shared source while diagnosing.
2. **Confirm whether the previous steering comparison included `$toe_F`.** If not, do the single-value 0.991 → 0.9995 test on the duplicate preset. Keep FFB fixed.
3. **Check travel/limit evidence on the rough section.** If the front shock approaches its bounded region, test only its range/zone against the Autobello envelope on the duplicate. If it does not, leave the bounds alone.
4. **Only then test front spring/preload or damping**, one category at a time. Avoid changing bump damping, rebound damping, torsion-bar rate, and steering helper damping simultaneously.
5. **Use the same road locations and speed windows**—rough segment, smooth bridge, rough segment again—with the same tires/config/FFB. Record whether the response is a single impact, repeated spatial texture, sustained oscillation, or steering-only feedback.
6. **Promote only reproducible results.** A change that merely reduces FFB gain is a perceptual mitigation; a change that reduces physical oscillation at unchanged FFB is evidence of a mechanical-path improvement.

## What the numbers cannot tell us

The files do not provide the effective modal mass, tire/road input spectrum, wheel-rate leverage, loaded static travel, or solver response needed to calculate the whole-car natural frequency reliably. The observed location dependence points to road input exciting a response, but cannot distinguish a body/frame mode from a suspension/steering mode by itself. The test sequence above is intended to identify the sensitive parameter without assuming the answer.

## Tool checks performed

JBeamTool `ast --json` was used to inspect parsed Bug and Autobello suspension/body structures. Strict checks returned `ok: true`, `sanity: true`, and no warnings for the inspected Bug front suspension, front spring/shock parts, rear suspension, rear spring/shock parts, frame, and body, as well as the supplied Autobello front/rear suspension and body files. Passing strict verification means structural validation passed; it does not certify dynamic tuning.
