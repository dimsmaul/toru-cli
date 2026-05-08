# Contributing to Toru CLI

Thanks for your interest in improving Toru CLI. This document covers the workflow.

## Getting started

```bash
git clone https://github.com/dimsmauls/toru-cli.git
cd "toru-cli/Toru CLI"
open "Toru CLI.xcodeproj"
```

The project uses Xcode 16's `PBXFileSystemSynchronizedRootGroup`, so any `.swift` file you drop into `Toru CLI/Toru CLI/` is auto-included in the build — no manual `project.pbxproj` edits required for source files.

Dependencies are managed via Swift Package Manager (SPM). They resolve automatically when Xcode opens the project.

## Code style

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Prefer composition over inheritance. SwiftTerm's `LocalProcessTerminalView` exposes most behavior via delegates rather than overrides.
- Avoid force unwraps (`!`) except in tests or for compile-time-known invariants.
- Group code by feature (`Terminal/`, `Input/`, `History/`, `UI/`, `Settings/`, `Themes/`, `App/`), not by Swift type.
- Keep view bodies small. Extract subviews when a `View` exceeds ~60 lines.
- One `import` per dependency, ordered alphabetically.

## Tests

- Unit tests live in `Toru CLITests/` (XCTest). Prefer table-driven tests for filters and parsers — see `CommentFilterTests` for the pattern.
- Use `HistoryDatabase.inMemory()` for database tests; never touch the real Application Support directory.
- UI smoke tests live in `Toru CLIUITests/`. Keep them focused: launch + assert key elements + clean exit.
- `make test` runs the unit-test target.

## Pull request checklist

- [ ] `make build` succeeds with no new warnings.
- [ ] `make test` is green (14+ tests passing).
- [ ] You added or updated tests covering the new behavior.
- [ ] Public types and methods have brief doc comments where intent is non-obvious.
- [ ] No emoji in code. README and docs may use emoji sparingly.
- [ ] No new third-party dependencies without prior discussion in an issue.
- [ ] Commit messages follow `<type>: <imperative subject>` (e.g. `feat: …`, `fix: …`, `docs: …`).

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include macOS version, Toru CLI version, repro steps, expected vs. actual behavior, and console logs if relevant.

## Suggesting features

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md). Note that the project is intentionally opinionated and rejects features that conflict with the [non-goals listed in the PRD](PRD-MacTerminal.md#3-non-goals) — no AI, no SSH (in v1), no plugin system, no cloud sync.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
