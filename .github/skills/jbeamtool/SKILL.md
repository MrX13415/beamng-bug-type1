---
name: jbeamtool
description: 'Use JBeamTool to validate, inspect, and analyze BeamNG JBeam files, parts, slots, ASTs, and localization keys, especially before and after JBeam edits.'
---

# JBeamTool

Use the CLI for structured JBeam validation and inspection. Its output supplements, but does not replace, reading relevant JBeam and testing in BeamNG: successful parsing does not establish correct physics, complete assembled-vehicle references, or runtime behavior.

## Find the tool

First check `JBEAMTOOL_PATH` for the executable's full path. If it is unset, look for `JBeamTool` on `PATH`. If `JBEAMTOOL_PATH` is set but invalid, report it and ask for the correct path rather than silently using another version. For example, in PowerShell:

```powershell
if ($env:JBEAMTOOL_PATH) {
	if (-not (Test-Path -LiteralPath $env:JBEAMTOOL_PATH -PathType Leaf)) {
		throw 'JBEAMTOOL_PATH does not point to a file'
	}
	$tool = $env:JBEAMTOOL_PATH
} else {
	$command = Get-Command JBeamTool -CommandType Application -ErrorAction SilentlyContinue
	if (-not $command) { throw 'JBeamTool not found; configure JBEAMTOOL_PATH or PATH' }
	$tool = $command.Source
}
```

If the tool is missing, direct the user to [GitHub Releases](https://github.com/MrX13415/JBeamTool/releases/latest) to select a release suitable for their operating system, download and extract it to a location of their choice, and set `JBEAMTOOL_PATH` to the executable or add its directory to `PATH`. For the current PowerShell session, for example, use `$env:JBEAMTOOL_PATH = 'C:\path\to\JBeamTool.exe'`; persist it through the user's environment settings if desired. A binary may be placed beside the skill for local use, but avoid committing platform-specific binaries to the shared repository.

Do not silently download or execute a release: obtain permission for downloads, verify the release checksum when provided, and record the release or tool version used. If a suitable release is unavailable, the user may clone [JBeamTool](https://github.com/MrX13415/JBeamTool) and build it with the .NET 10 SDK, or run the source project directly with `dotnet run --project <path-to-JBeamTool.csproj> --no-launch-profile -- verify <path> --json --strict`. Source execution may restore dependencies and build in that checkout. If no usable tool is available, report the limitation rather than claiming validation. Check the installed version's help or source when behavior differs from this skill.

## Validate an edit

1. Before editing, run `verify <file-or-directory> --json --strict` on the smallest relevant scope and record existing failures and warnings. For an executable use `& $tool verify $path --json --strict` in PowerShell.
2. Make the scoped JBeam change, then rerun the same command. Expand to additional affected files or directories when the change crosses part boundaries.
3. Check the process exit code and JSON `ok`, each result's `sanity`, and `warnings`. Strict mode makes warnings fail validation. A missing path or no JBeam files also fails; do not mistake an empty scan for success. Report pre-existing failures separately from new ones.
4. Describe what was and was not verified. JBeamTool's parsed checks cannot prove the active configuration, node/beam interactions, stability, collisions, or in-game behavior.

## Inspect structure

- `info <file.jbeam> --json` provides part IDs, slots, section counts, and warnings for one file. A directory can select only its first JBeam file; specify the file explicitly.
- `ast <file.jbeam> --json` provides parsed root and per-part objects. A directory can produce a large AST; prefer a single file and inspect the relevant part/section using structured JSON parsing, not regex against raw JBeam. Use it to compare node, beam, or slot structure, while accounting for inherited JBeam options and runtime variables.
- `verify` remains the validation command; `info` and `ast` are inspection aids. Check warnings and `sanity` even when the command reports successful loading.

## Localization and writing commands

- Start read-only: `keys en-US <sourceDir> --json`. The language is optional and defaults to `en-US`. Inspect missing keys and their context before editing translations. Dynamic templates are not necessarily literal keys. In this source version, JSON mode returns a nonzero exit code when missing keys are found, including after applying them; inspect the result and rerun the report after changes.
- `keys en-US <sourceDir> --json --apply` writes locale files, potentially creating a fallback file. Use it only when localization updates are requested and authorized; review the resulting changes. In the source version inspected, place `--apply` after the language and directory because unrecognized options can otherwise be treated as positional arguments. JSON mode may still print introductory text, so do not assume stdout is a standalone JSON document.
- `dump <sourceDir> <targetDir>` and `slots2 <sourceDir> <targetDir>` write files and may overwrite matching destination paths. Use only on explicit request, supply both paths, and choose a separate safe target. `pricelist [-tree] <sourceDir> [targetFile]` can write a file when a target is specified. Confirm current help before using these commands and review generated output.

## JBeam-specific cautions

- Node and beam property blocks can persist across subsequent rows; inspect inherited settings instead of reading each row in isolation.
- A geometric or mass asymmetry is not automatically a defect. Compare against intended design and active configurations before proposing a fix.
- For physical changes, distinguish parser validation from controlled in-game tests and avoid inventing tuning values without evidence.