# Changelog

All notable changes to Device Inspector are documented in this file.

## [2026.11.11.0009] - 2026-11-11

## 2 Close with open actions, and two text fixes

### Fixed

- End the process by an explicit exit after Close anyway with a run open, when the script owns the process (started with `-File`, as the suite launcher does). The end of Windows PowerShell waits for an open remoting call. In an isolated test, a process with a held call stayed until the call returned (38 s of a 40 s hold); the explicit exit ended it in 2.3 s. In the app on CLIENT01 and on DC01 the process ended after 2.7 s with and without this change, so the long wait was not reproduced in the app. The earlier desktop check against CM01 saw 70 s in 3 of 6 samples.
- Do not end the process when an admin runs the script inside a console. The script returns as normal and the console stays open.
- Write the `CLOSED` line before the exit, as before. The `CLOSED` line still says that the result of the run is not known. The tool does not claim that the run stopped.
- Write "1 action is still running" in the close warning for one run. Write "2 actions are still running" for more runs.
- Show the version once in the Uninstall and Repair confirmation and in the log detail. The tool adds the version only when the display name does not hold it as a whole token. A version with trailing `.0` parts counts as equal to the shorter version.

## 1 Guide images for the actions and the live Applications panel

### Changed

- Retake 33 images of the user guide from release 2026.11.11.0008. The Applications panel images show the live columns (type and view) and the All, MSI and EXE filter, the sidebar shows Device list, and the version in the sidebar is current.
- Add images of the action buttons, the confirmation dialog, the running-actions list, the result window, the close warning, the right-click menus of the Applications, Updates and Collections panels, the uninstall confirmation, the collection browser and the Device list panel.
- Add the steps of these images to `tools/guide-capture/steps-guide.ps1`. The steps choose Dry run or Cancel and never Run, and a test checks that. The capture scrolls the window log to its first lines before an image that would show the account of an action result.
- Fix the capture harness: clear the site code for the device-only step, stop when an inspection read no applications (`Assert-Applications`), find the Not now button of a Windows restart prompt by its name (`Dismiss-RestartPrompt`), and select a named Microsoft Visual C++ runtime row for the uninstall images, with a guard that stops the capture on a Configuration Manager row.

## [2026.11.11.0008] - 2026-11-11

## 1 Device actions that run in the background

### Added

- Run an action on a device in its own background task. The window stays free: inspect other devices, search the device list and start actions on other devices while an action runs.
- Allow one running action for each device. The device key is the lower-case name without the text after the first dot, an IP address as it is, and the site resource ID when the inspection knows it. The tool refuses a second action on a device that has a running action, with the reason as tooltip or message.
- Give each run and each dry run an action ID, and write it on the `STARTED` line and on the result line of the action log.
- Show the running actions in a list under the Inspect bar, with the device, the action, the mode, the start time and the ID.
- Show the result of a run in a window that does not take the focus. Refresh the view only when it shows the device of the run.
- Warn when the window closes while actions run: the tool stops waiting, and a run on a device can stop before it is complete. The default button is Wait. Write a `CLOSED` line with the ID for each open run.

### Changed

- Write exactly one result line for each run, before the window updates. A run that returns no result or more than one result gets a `FAILED` line that says so. A run whose work ended without the Done flag counts as ended.
- Write the action ID as the second field of each action log line, after the time.
- Keep the changes of the site (add to and remove from a collection) on the exclusive path with the progress panel.

## [2026.11.10.0007] - 2026-11-10

## 1 Applications panel that shows the uninstall keys of the device live

### Changed

- Show one row for each uninstall registry key of the device, with its type and view.
- Uninstall and repair an application from its uninstall key, not from the client policy.
- Run MSI products with msiexec, and EXE entries with their quiet uninstall string.
- Turn Uninstall and Repair off, with the reason as tooltip, when the key does not allow them.
- Filter the Applications panel by type: All, MSI or EXE.
- Show the version, publisher, install date, type and key name in the HTML report.

### Removed

- Remove the Status column, its filter values and the Inventory version column.
- Remove the rows of Configuration Manager applications from the Applications panel.

## [2026.11.10.0006] - 2026-11-10

## 9 actions that change a device or the site, each with a dry run and an action log

### Added

- Add an Enable actions switch that is off at each start.
- Confirm each action in a dialog that shows the device count.
- Run a dry run of each action before the real run.
- Write each run and dry run to a separate action log.
- Request and evaluate machine policy on the device.
- Start a full hardware inventory on the device.
- Flag a corrupt site inventory.
- Repair a corrupt site inventory with a full hardware inventory.
- Install selected or all pending software updates from the Updates panel.
- Uninstall a Configuration Manager application from the Applications panel.
- Repair a Configuration Manager application from the Applications panel.
- Remove the device from a collection, for a direct membership rule only.
- Add the device to a collection that you pick in a collection browser.
- Find devices of the site by name or collection in the Device list panel.
- Write the full report of each inspection to the log file.
- Open the log file with Open log file.

### Changed

- Show the membership rule of each collection, in the window and in the HTML report.
- List installed Configuration Manager applications as their own rows in the Applications panel.

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
