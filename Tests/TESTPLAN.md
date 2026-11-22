# Device Inspector: test plan

Measured 2026-11-17 with `Invoke-Checks.ps1` (Pester 5.7.1, PSScriptAnalyzer 1.25.0) on a lab computer, with the window tests off. Counts are tests as run; each data row counts as one test.

| | Windows PowerShell 5.1 | PowerShell 7 |
|---|---|---|
| Passed | 906 | 895 |
| Skipped (window tests, opt-in off) | 222 | 222 |

Run: `.\Invoke-Checks.ps1` (lint, then tests). It runs in CI on both hosts (`.github/workflows/ci.yml`).

Window tests: `Window.Tests.ps1` and the other `*.Window.Tests.ps1` files open windows only when `SUITE_ALLOW_WINDOW_TESTS` is `1`. The CI workflow sets it. Otherwise Pester reports those tests as Skipped with that reason, not as Failed. `WindowGuard.Tests.ps1` tests the guard and checks that every test file that can open a window applies it. It opens no window. `ButtonStates.Window.Tests.ps1` needs the real mouse and runs only in a visible run (`SUITE_VISIBLE_WINDOWS=1`).

## What is covered

| Area | File | Contents |
|---|---|---|
| Module | `DeviceInspectorCommon.Tests.ps1` | The module functions with stubbed ConfigMgr commands |
| Actions | `DeviceInspectorActions.Tests.ps1` | The device actions in `Module\DeviceInspectorActions.ps1` |
| Module and window | `DeviceInspectorWindow.Tests.ps1` | The module calls that the window makes |
| Windows | `Window.Tests.ps1` | Main window and Options dialog, both themes, 1024x720 and the work area: names, titles, no clipped text, nothing off screen, contrast |
| Chrome | `Chrome.Window.Tests.ps1` | Chrome and buttons of the main window, every dialog and popup, both themes |
| Density | `Density.Tests.ps1`, `Density.Window.Tests.ps1` | The compact 1080p layout from the XAML, and measured on screen with space-use checks |
| Button states | `ButtonStates.Window.Tests.ps1` | Hover, focus and pressed fills of the main window buttons, both themes (visible run only) |
| Window guard | `WindowGuard.Tests.ps1` | The opt-in guard and its use in every window test file |
| Theme guards | `Theme.Guard.Tests.ps1`, `Theme.Source.Guard.Tests.ps1`, `ButtonStyle.Guard.Tests.ps1`, `FontWeight.Guard.Tests.ps1`, `Footer.Guard.Tests.ps1` | White text on blue, fonts independent of the theme, banned words, one themed button style (also in the vendored SuiteCommon dialogs), Title Case, the footer |
| Encoding | `Encoding.Guard.Tests.ps1` | Plain ASCII in every PowerShell file and every file that PowerShell reads |
| Documents and images | `Documentation.Tests.ps1`, `Readme.Images.Guard.Tests.ps1`, `GuideImages.Guard.Tests.ps1` | Index and links, every README image is current, every guide image was produced by a capture run |
| Start script | `Shell.Logic.Tests.ps1`, `Script.Contract.Tests.ps1`, `Startup.Tests.ps1` | The pure functions of `start-deviceinspector.ps1` cut from its syntax tree (action gate, view switch, status line, filters, preferences, Title Case), every named parameter of a call into the module or SuiteCommon, and the start without the Configuration Manager console |
| View data | `DeviceInspectorWindow.Tests.ps1` (Show-Inspection) | The rows that reach the controls, counted on real WPF controls that are not shown: an inspection in `Show-Inspection` (facts, applications, updates, collections and deployments grids, summary line, problems text) and the application filter |
| Capture tool | `GuideCapture.Tests.ps1` | The capture scripts parse, carry no secret and take the lab lock |

## Not covered, and why

- The tests stub the ConfigMgr commands. No test calls a real site.
- The scan, the actions and the refresh handlers run inside the window with a site. The tests cover the module calls that they make, not the clicks.
- The settings save in SuiteCommon is not atomic. The fix belongs in `app-packager-suite`.