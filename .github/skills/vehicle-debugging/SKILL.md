---
name: vehicle-debugging
description: 'Use when diagnosing BeamNG vehicle behavior, including suspension, steering, drivetrain, seat or camera shake, or interpreting video and telemetry from the Bug mod.'
---

# Vehicle Debugging

## Establish the problem

1. Identify the exact symptom, active vehicle configuration and installed parts, inputs, speed, surface, and conditions where the issue appears or disappears. Preserve the user's reported observations; distinguish the vehicle motion, camera motion, vibration, and handling symptoms.
2. Record the baseline and known experiments, including whether the test part was actually installed. Preserve user changes and stated constraints. If the task is exploratory or the user requests a plan, do not tune the vehicle yet.
3. Trace the relevant JBeam topology and, where behavior depends on game logic, the current installed BeamNG Lua control path and runtime values. Use the `jbeamtool` skill for structured inspection and JBeam validation.

## Form and test a hypothesis

1. State a specific mechanism and a cheap observation that could disprove it. Check geometry, inherited properties, part selection, mass and load paths; a difference from a stock car or left/right asymmetry alone does not establish a defect.
2. For a reference vehicle such as Autobello, compare equivalent installed components and conditions. Differences in geometry, weight, loads, wheel/tire selection, and controls can make direct value copying misleading.
3. Prefer a single, reversible, clearly labeled diagnostic change or measurement. Avoid tuning several unrelated variables at once. Check in-game behavior against the baseline; do not claim a fix from parsing or static inspection alone.
4. If the test contradicts the hypothesis, say so and inspect the next controlling mechanism. Do not convert an unverified suggestion into a confirmed diagnosis or an unsupported realistic value.

## Evaluate measurements

- Inspect capture filenames, timestamps, config identity, samples, events, and phase boundaries before comparing runs. Match route, speed, inputs, surface, and load as closely as practical; document mismatches and units.
- Node positions and relative distances, orientation, velocity, beam extension, and the rendered camera pose measure different things. World-aligned relative coordinates can change with whole-vehicle rotation; stable distances do not exclude bending, rotation, or camera shake.
- Whole-phase ranges and standard deviations mix load transfer, trends, and oscillation. Do not infer damping ratios, sustained vibration, or a root cause without a suitable controlled test and relevant measurements.
- Report what the evidence supports, competing explanations, what was not measured, and the next discriminating in-game test. A lack of observed motion in a capture does not invalidate the user's visible symptom when the capture or measurement is not representative.