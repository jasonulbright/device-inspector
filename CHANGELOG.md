# Changelog

All notable changes to Device Inspector are documented in this file.

## [2026.11.10.0005] - 2026-11-10

## 36 user guide images retaken from the fixed window

### Fixed

- Show the app name, not Options, in the message boxes of the Options dialog.
- Meet 4.5:1 text and 3:1 border contrast in both themes, disabled buttons included.
- Use the signed-in account, not a credential, when the site server is this computer.
- Remove the cmdlet warning about the Name wildcard from the command-line report.

### Added

- Add window tests for titles, centering, contrast and clipping. CI runs them.
- Add capture scripts in tools/guide-capture. One command takes all images again.

### Changed

- Correct the user guide against the code.
- Retake all 36 images of the user guide.

## [2026.11.07.0004] - 2026-11-07

## 1 user guide ships with the release

### Added

- Add the user guide (docs/index.md) with images of the running window.

## [2026.11.06.0003] - 2026-11-06

## 1 data access that uses the supported ConfigurationManager cmdlets

### Changed

- Read the site facts with the ConfigurationManager cmdlets (Get-CMDevice, Get-CMDeviceCollection, Get-CMDeployment, Get-CMSoftwareUpdate). The tool needs the Configuration Manager console on the computer.
- Read the installed applications, the collection memberships and the required updates of the device with Invoke-CMWmiQuery, because no cmdlet returns them.
- Require the site code when a site server is set. The tool no longer asks the SMS Provider for it.
- Keep the facts from the device itself live (WinRM and CIM on the device).

### Added

- Stop with a plain message at start when the console is not installed.
- Add Test-DeviceInspectorConsole.

## [2026.11.06.0002] - 2026-11-06

## 1 defect fixed that the user guide found

### Fixed

- Check the input of `Invoke-DeviceInspector.ps1` first. A device name that is not valid stops the script with one message, the same text as the window, and exit code 1. Before, a second error came from the report step.

## [2026.11.06.0001] - 2026-11-06

## 5 read-only panels for one device

### Added

- Open a window that shows one device in five panels.
- Show the device facts: operating system, client health and site record.
- Compare the installed applications of the device with the site inventory.
- List the updates that the site requires and the updates pending on the device.
- List the collections of the device and the deployments that target them.
- List the parts of the inspection that failed, and keep the other parts.
- Export the inspection as JSON or as an HTML report.
- Keep the command line script `Invoke-DeviceInspector.ps1`.
