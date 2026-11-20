---
name: localization
description: 'Use when adding or changing BeamNG part names, slot descriptions, interaction messages, translation keys, or mod localization across the supported languages.'
---

# Mod Localization

When a change introduces or changes player-facing text, check whether it needs localization and update the affected keys across the supported locales as part of the task. This includes part names and slot descriptions, as well as messages and interaction labels when applicable. Do not assume every JBeam change produces a new key.

## Identify keys

1. Inspect the changed source text, its context, and existing entries to determine the exact keys and meanings. Preserve existing naming conventions; do not rename a key without updating its references.
2. Use the `jbeamtool` skill's read-only `keys` workflow for each affected locale (`en-US`, `de_DE`, `bg-BG`, and `pt_BR`) to help find JBeam-related missing keys. Compare the exact keys introduced or changed with each locale file; do not treat the tool's total missing count as the change's result. It can report unrelated, pre-existing, common-part, or stock-game keys, especially for less-complete locale coverage. The tool does not cover every Lua or interaction reference; check those separately.
3. If JBeamTool is unavailable, inspect the affected references and locale files manually where possible and report that the tool check was not run. Do not silently skip localization or claim comprehensive key coverage.

JBeamTool currently does not evaluate dynamic JBeam `$=` expressions used as slot descriptions. It may report the raw expression (for example, a description that chooses "Front Left" or "Front Right") as a missing literal key. Treat that expression entry as a false positive: determine the possible evaluated strings and check their actual translation keys instead. Do not add a translation whose key is the unevaluated expression.

## Update affected locales

The current source locale files are under `bug/locales/translations/`:

- `en-US/bug.translation.json`: English.
- `de_DE/bug.translation.json`: German.
- `bg-BG/bug.translation.json`: Bulgarian.
- `pt_BR/bug.translation.json`: Brazilian Portuguese.

For each new or changed key in scope, ensure each supported source locale has an appropriate value. Use English source/context and existing translations for consistent vehicle terminology. Write natural German, Bulgarian, and Brazilian Portuguese translations; retain proper names, identifiers, units, and technical specifications where appropriate. Do not use the English text as a substitute just because a language cannot be independently reviewed. If uncertain about a translation or technical term, report the uncertainty and seek review rather than presenting it as verified.

English and German can be reviewed by the maintainers. Bulgarian and Brazilian Portuguese should be reported as AI-assisted and pending qualified human review; do not claim native-speaker verification. Preserve `{{placeholder}}` names exactly, along with meaningful formatting and line breaks. Never insert review markers into user-facing strings.

Keep existing translations and unrelated missing keys unchanged unless the user requests a broader reconciliation. Preserve the existing JSON layout and ordering where practical. Edit the main source or AW overlay as appropriate; generated AW files can be replaced during a rebuild.

## Verify and report

1. Parse each changed locale file as JSON. For every affected key, check presence and non-empty values in all four locales and compare placeholder names against the source text.
2. Run the read-only JBeamTool key check for all four locales when available. Confirm that the affected keys no longer appear in each locale's missing-key results; separately classify dynamic-expression false positives and unrelated baseline gaps. Do not run `keys --apply` without authorization: it writes files and can use English placeholders instead of translations.
3. Report the changed keys and locales, any pre-existing gaps left untouched, validation performed, and any unverified Bulgarian/Portuguese wording. Flag unavailable tooling or in-game checks explicitly.