# Source build and release design

Approved scope: make this repository buildable from source, move generated binaries to Releases, organize source/tests/docs, improve the README, and automate Windows verification and tag releases. Keep v1.0.0 and published Git history intact.

## Existing behavior

The imported host is a .NET 10 x64 WinForms app with a docked WebView2 control. It serves local HTML/CSS/JS at `https://appassets.local`, exchanges JSON lines with a hidden Windows PowerShell process, and stores configuration under `%LOCALAPPDATA%/SkillsJunction`. The original C# project was not included. The host behavior was inspected with ILSpy; the maintained source will be reconstructed code, not a claim to recover the original source formatting.

## Layout

- `src/SkillsJunction.Desktop/`: WinForms entry point, WebView2 window, and backend process ownership; NuGet supplies WebView2 1.0.4258.31.
- `src/web/`: existing frontend, copied to `web/` in build/publish output.
- `src/backend/`: existing Junction backend, copied to `backend/` in output.
- `scripts/`: build and ZIP packaging commands shared by developers and Actions.
- `tests/`: isolated real-junction tests plus native desktop integration tests.
- `artifacts/`, `bin/`, `obj/`, EXE/DLL/PDB/ZIP: generated, ignored, and not tracked.

## Host contract

Preserve the executable name `SkillsJunction.WebView2.exe`, existing window sizing, local HTTPS origin, UI, backend actions, and configuration schema. Only local app content may navigate or submit backend commands. Map the web directory rather than the entire application directory. Use UTF-8 input/output and start PowerShell with an encoded bootstrap that explicitly reads the backend as UTF-8. Forward response JSON onto the UI thread. Correlate send errors with the request ID. Log unexpected backend exit and shut down only the process owned by this app when its window closes.

Use `LOCALAPPDATA` for both host profile/logs and backend configuration, falling back to the Windows special folder. This agrees with normal Windows behavior and permits isolated integration tests without reading the user's configuration.

## Verification and packaging

Pin NuGet/npm dependencies with lockfiles. Build/publish from .NET 10 SDK; the application remains framework-dependent on .NET 10 Desktop Runtime and WebView2 Runtime. Preserve the ten existing real-junction tests. Desktop tests start the published executable with a temporary profile and attach via Playwright's documented WebView2 CDP support. Verify Vietnamese text, the actual bridge, per-skill toggles, and child-process shutdown.

Package only published application content, README/license, and SHA-256 checksums. CI restores locked dependencies, checks JavaScript syntax, runs backend tests, builds, runs desktop tests, and checks the ZIP. Tag pushes repeat those gates before publishing a GitHub Release; pull requests never receive release write permissions. Existing v1.0.0 is unchanged.

## Official references

- [WinForms WebView2 initialization and messaging](https://learn.microsoft.com/en-us/microsoft-edge/webview2/get-started/winforms)
- [Local virtual-host mapping](https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2.setvirtualhostnametofoldermapping)
- [Playwright WebView2 automation](https://playwright.dev/docs/webview2)
- [.NET publishing](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-publish)
- [GitHub Actions .NET builds](https://docs.github.com/en/actions/tutorials/build-and-test-code/net)
