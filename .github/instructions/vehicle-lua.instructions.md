---
description: 'Use when editing BeamNG vehicle Lua, controllers, debug telemetry, or vehicle-to-game-engine communication.'
applyTo: '**/vehicles/bug/lua/**/*.lua'
---

# Vehicle Lua

- Identify whether code runs in the vehicle sandbox or game-engine Lua before using globals or APIs. Check the installed game's current Lua source and nearby mod code; do not assume an API is shared between contexts. The install location is machine-specific.
- Vehicle-root Lua files and controller modules have different loading and lifecycle paths. Verify how the selected file is loaded before adding registration or hooks; keep debug code separate from production behavior when practical.
- For an interaction change, trace the complete applicable path: JBeam triggers and enabled actions, `actions_*.interaction.json`, vehicle-facing exports in `vehicle.lua`, and the owning feature module. Check input bindings and localization when relevant; a syntactically valid file alone does not establish that the interaction works in-game.
- When a change introduces or changes player-facing messages or interaction labels, follow the [localization skill](../skills/localization/SKILL.md) for the affected keys and supported locales.
- Check initialization order before using controllers or enabling physics-step callbacks. In the previous telemetry implementation, enabling the hook during extension loading ran before `controller` was initialized; it was deferred to a graphics update. Confirm this against the current game version and code before copying the approach.
- Use bounded telemetry buffers and identify sampling time, units, coordinate frame, and missing nodes. Reset and export behavior should not silently mix runs; report when runtime testing is unavailable.
- For automated controls, verify the input API, use explicit opt-in and a stop path, and identify any motion or safety prerequisites. Do not treat vehicle-node telemetry as a direct measurement of the rendered camera.