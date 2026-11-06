# Releasing Device Inspector

## 1. Test

Run the full suite under Windows PowerShell 5.1 and under PowerShell 7 with Pester 5. The release stops if a test fails on either host. Run the linter too.

```powershell
powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; $r = Invoke-Pester -Path Tests -PassThru -Output None; 'passed {0} failed {1}' -f $r.PassedCount, $r.FailedCount"
pwsh -NoProfile -File .\Invoke-Checks.ps1
```

The same checks run in `.github/workflows/ci.yml` on every pull request.

## 2. Version

The version is `YYYY.MM.DD.BBBB`: the release date, then a four-digit, zero-padded build number. The build number increases by 1 for each release and never resets. Keep the zero-padded text everywhere; `[version]` drops the leading zeros.

Set the same version in these places:

- `Module/DeviceInspectorCommon.psd1`, `ModuleVersion`
- `start-deviceinspector.ps1`, header line `Version    : <ver>`
- `Invoke-DeviceInspector.ps1`, the `Version:` note
- `CHANGELOG.md`, the top heading `## [<ver>] - <date>`

Add the new `CHANGELOG.md` entry at the top. Do not edit the entries of earlier releases. A test checks that the manifest, the start script and the changelog carry the same version.

## 3. Shared module

Check the vendored SuiteCommon copy for drift. Sync it if the check reports drift.

```powershell
C:\projects\app-packager-suite\sync-suitecommon.ps1 -Consumer C:\projects\device-inspector -Check
```

## 4. Pull request, tag, and package

Push a branch and open a pull request. Squash-merge it when CI is green and the review findings are fixed or answered. Never push to `main`. Then tag the merged commit `v<ver>` with an annotated tag. Build the zip from the tag. The zip excludes the tests, the screenshots and the maintenance files.

```bash
git checkout main && git pull
git tag -a v<ver> -m v<ver>
git push origin v<ver>
git archive --format=zip -o DeviceInspector-<ver>.zip v<ver> -- . ':(exclude)Tests' ':(exclude)*.Tests.ps1' ':(exclude)RELEASING.md' ':(exclude).github' ':(exclude).coderabbit.yaml' ':(exclude)screenshots' ':(exclude)screenshot.png' ':(exclude)Invoke-Checks.ps1' ':(exclude)PSScriptAnalyzerSettings.psd1'
sha256sum DeviceInspector-<ver>.zip | sed 's/ \*/  /' > checksums.txt
```

Extract the zip to a temporary folder. Import `Module/DeviceInspectorCommon.psd1` under Windows PowerShell 5.1. The import must succeed.

## 5. Publish

Create the GitHub release with the title `v<ver>` and two assets: the zip and `checksums.txt`. The release must not be a draft. The release notes have a `##` headline with one concrete outcome metric, the `###` sections of the changelog entry, and the footer `Full changelog: CHANGELOG.md`.

The app zip is not signed. The signed installer is built by the suite repository (`app-packager-suite/RELEASING.md`), which carries the latest release of this app.