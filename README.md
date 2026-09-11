# Ereader Patch Manager

A KOReader plugin that installs and updates the numbered user patches published
at [komadorirobin/Ereader](https://github.com/komadorirobin/Ereader).

## Behaviour

- Discovers root-level files matching KOReader's numbered patch convention,
  such as `2-custom-reader-header.lua`.
- Synchronizes automatically eight seconds after startup when Wi-Fi is already
  connected. It never turns Wi-Fi on by itself.
- Installs newly published patches by default and updates existing patches when
  their Git blob changes.
- Preserves enabled/disabled state when updating a patch.
- Validates file size and Lua syntax before installation.
- Stores the previous version in
  `settings/ereader-patch-manager/backups/` before replacing a patch.
- Never deletes or changes patches that are not supplied by the Ereader repo.

Patch changes are loaded on the next KOReader restart.

## Installation

Extract `ereader-patch-manager.koplugin.zip` into KOReader's `plugins`
directory and restart KOReader. The plugin is available under the Tools menu as
**Ereader Patch Manager**.

## Development

```sh
make test
make build
```
