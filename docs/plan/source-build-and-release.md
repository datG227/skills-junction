# Source Build and Release Implementation Plan

> **For agentic workers:** REQUIRED EXECUTION METHOD: Use subagents (recommended) or the executing-plans skill to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A source-only repository that builds the current Windows app, verifies it, and produces downloadable tag releases.

**Architecture:** Reconstruct the small WinForms host around the existing frontend/backend contract. Keep process transport in `BackendProcess`, window ownership in `MainWindow`, and reusable build/package commands in PowerShell scripts.

**Tech Stack:** .NET 10, WinForms, WebView2 1.0.4258.31, Windows PowerShell, Python unittest, Playwright Test 1.64.1, GitHub Actions on Windows.

**Spec:** [source-build-design.md](../spec/source-build-design.md)

## Global Constraints

- Preserve the existing UI, Junction behavior, executable name, and configuration location/schema.
- Do not rewrite history or replace the v1.0.0 tag/assets.
- Never use real user configuration for automated tests.
- Track source/lockfiles/docs; generated binaries belong in ignored build output and Releases.

### Task 1: Source layout and buildable desktop host

**Files:** `src/SkillsJunction.Desktop/{Program,MainWindow,BackendProcess,AppPaths}.cs`, `SkillsJunction.Desktop.csproj`, `src/web/*`, `src/backend/SkillsJunction.WebView2.ps1`, `tests/test_skill_toggle.py`, `tests/desktop.spec.js`, `global.json`, `NuGet.config`, `package.json`, lockfiles, `.gitignore`, `.gitattributes`, `.editorconfig`.

**Interfaces:** `BackendProcess.Start()`, `Task SendAsync(string json)`, response/exit events, `Dispose()`; output `SkillsJunction.WebView2.exe` with `web/` and `backend/` content.

- [ ] Move existing web/backend source without behavior changes and update the Python script path.
- [ ] Add native desktop integration tests before implementing the new host. Confirm they fail because the source-built executable does not yet exist.
- [ ] Reconstruct the host using the inspected binary behavior and documented WebView2 initialization/messaging. Pin the same WebView2 package in the project.
- [ ] Restore and publish with:

  ```powershell
  dotnet restore src/SkillsJunction.Desktop/SkillsJunction.Desktop.csproj --locked-mode
  dotnet publish src/SkillsJunction.Desktop/SkillsJunction.Desktop.csproj -c Release --no-restore -o artifacts/publish
  python -m unittest discover -s tests -v
  npm run test:desktop
  ```

- [ ] Remove tracked imported binaries only after the source build and desktop tests pass.

### Task 2: Repeatable build and ZIP package

**Files:** `scripts/build.ps1`, `scripts/package.ps1`, `tests/test_package.py`.

**Interfaces:** build outputs `artifacts/publish`; package accepts a semantic version and writes `artifacts/releases/SkillsJunction-v<version>-win-x64.zip` plus `SHA256SUMS.txt`.

- [ ] Test package contents against a temporary publish folder: required host/web/backend files included; no profile/config/log/test content; hash matches ZIP.
- [ ] Implement guarded output paths, fail on command errors, and share the published-folder contract with desktop tests.
- [ ] Run:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1
  npm run test:desktop
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package.ps1 -Version 1.0.1
  python -m unittest discover -s tests -v
  ```

### Task 3: Documentation and Windows automation

**Files:** `README.md`, `docs/development.md`, `.github/workflows/ci.yml` (verification and gated tag release jobs), `.github/dependabot.yml`, `.github/PULL_REQUEST_TEMPLATE.md`.

- [ ] Document download/run requirements, screenshot, source build, tests, ZIP creation, and tag release behavior. Record host reconstruction provenance honestly.
- [ ] Configure PR/main CI for locked restores, syntax checks, backend tests, build/publish, desktop tests, packaging, and artifact upload.
- [ ] Configure tag releases with the same gates and `contents: write` only in the release job. Use official actions pinned to their verified version SHAs.
- [ ] Add lockfile/dependency update configuration and a focused PR template.

### Task 4: Clean checkout verification and review

- [ ] Build and run tests from a fresh source checkout with no imported binaries available.
- [ ] Confirm no EXE/DLL/PDB/generated runtime metadata is tracked in the branch.
- [ ] Request read-only code review, address material findings, and run affected checks again.
- [ ] Push branch, open a PR against main, wait for its actual GitHub CI result, and fix failures.
- [ ] Report the PR, checks actually completed, and the local source-built executable. Leave merge and creation of a new public tag for the user's next instruction.
