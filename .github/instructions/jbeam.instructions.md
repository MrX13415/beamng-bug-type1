---
description: 'Use when editing BeamNG JBeam parts, configurations, suspension, seats, or vehicle physics in this repository.'
applyTo: '**/*.jbeam'
---

# JBeam Changes

- Use the [JBeamTool skill](../skills/jbeamtool/SKILL.md) for before-and-after validation; JBeam is not strict JSON. Parsing success does not prove the assembled vehicle or its physics works in-game.
- When a change introduces or changes player-facing part names or slot descriptions, follow the [localization skill](../skills/localization/SKILL.md) for the affected keys and supported locales.
- Identify the active configuration, selected parts, inherited settings, and relevant node/beam connections before drawing conclusions. A part present in a file may not be installed in the user's test vehicle.
- Respect the requested part and variant scope. Keep part IDs, slots, deliberate overrides, and existing user experiments intact unless the task explicitly changes them. Test one variant before mirroring changes when requested.
- Treat asymmetry and differences from stock vehicles as leads, not automatic defects. Compare geometry, mass, active variants, and intended behavior before copying or changing values.
- Separate observations from hypotheses. Avoid unsupported stiffness, damping, or strength tuning; use a focused reversible change and an in-game comparison to evaluate a physical hypothesis.