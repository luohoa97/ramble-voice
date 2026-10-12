# Contributing to Ramble Voice

Thanks for helping. Please read the [Code of Conduct](CODE_OF_CONDUCT.md) first.

## Ground rules

- Ramble Voice is GPL-3.0-or-later. By contributing you agree your work is
  licensed under the same terms.
- No telemetry, analytics, or backend. Network is used only for Gemini (opt-in
  cloud mode) and model downloads.
- The app is text-only. Dictated content must never be executed or obeyed.
- No secrets in the repo, and no model weights (`*.task`, `*.litertlm`, `*.bin`,
  `*.gguf`, `*.safetensors`) or files larger than 20 MB. CI rejects both.

## Development setup

Flutter 3.47.7 is required. In the maintainer's environment all Flutter and Dart
commands go through `tool/fl`, which runs them inside the `ramble` toolbox:

```sh
tool/fl flutter pub get
tool/fl dart run build_runner build --delete-conflicting-outputs
tool/fl flutter analyze
tool/fl flutter test
```

Without the toolbox, use `flutter` and `dart` directly. See the README for the
native build dependencies and `docs/ARCHITECTURE.md` for the module map. The
shared interfaces are in `docs/CONTRACTS.md`; change them only after discussing
in an issue.

## Before you open a pull request

1. `flutter analyze` is clean (no warnings, no infos).
2. `flutter test` passes. Add tests for new behavior.
3. Generated files (drift, riverpod) are up to date: rerun `build_runner` and
   commit the result.
4. Every source file has the SPDX header and `tool/check_spdx.sh` passes.
5. The shell scripts pass `shellcheck`.

## SPDX header rule

Every `.dart`, `.kt`, `.kts`, `.c`, `.h`, `.cc`, `.cmake`, `CMakeLists.txt`,
`.sh`, `.yml` and `.yaml` file under `lib/`, `linux/`, `native/`,
`android/app/src`, `tool/`, `packaging/` and `.github/` starts with the header
for its comment syntax:

```dart
// SPDX-License-Identifier: GPL-3.0-or-later
```

Use `#` for shell, YAML and CMake, and `<!-- -->` for XML. Markdown and JSON are
exempt. Generated files (`*.g.dart`, `GeneratedPluginRegistrant*`,
`generated_plugin*`, `linux/flutter/ephemeral`) are exempt.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/):
`feat(linux): ...`, `fix(android): ...`, `docs: ...`, `ci: ...`,
`chore: ...`, `test: ...`, `refactor: ...`. Keep the subject under 72
characters, in the imperative mood.

## Platform reports

Linux behavior varies a lot between compositors. Please use the "Platform
report" issue template to tell us what works on your setup. Only GNOME 50 on
Wayland (x86_64) has been verified on hardware so far.
