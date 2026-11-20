---
description: 'Use when editing BeamNG mod localization, translation keys, or locale JSON files.'
applyTo: '**/locales/translations/**/*.json'
---

# Translations

- Check the source text and its JBeam, interaction, or Lua usage before changing a key or value. Preserve interpolation placeholders such as `{{volume}}`, their spelling, and intentional formatting and line breaks.
- Use the [localization skill](../skills/localization/SKILL.md) to add or update affected player-facing keys in all supported source locales. Keep unrelated translations and intentional locale differences intact; report Bulgarian and Brazilian Portuguese translations as needing qualified human review.
- Validate changed locale files with a JSON parser. Use the [JBeamTool skill](../skills/jbeamtool/SKILL.md) for missing keys referenced by JBeam, but also check relevant interaction and Lua references separately. Its `--apply` mode writes files, so do not use it without authorization.
- Edit the main source or AW overlay as appropriate; generated AW translations can be replaced during a rebuild.