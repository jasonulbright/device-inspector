# Changelog

All notable changes to Device Inspector are documented in this file.

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
