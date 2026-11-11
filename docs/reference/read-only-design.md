# Read-only design

This page lists what Device Inspector reads, how the inspection stays read only, how the actions are kept apart, and the limits.

## What it does

The page states the scope and the design rules of the tool.

## When to use it

Use this page to check what the tool touches before you run it on a device.

## Requirements

None.

## What the tool reads

| Source | Command | Facts |
|---|---|---|
| Site | `Get-CMSite` | No fact. The tool runs it once, when it opens the site drive, to check that the site answers. |
| Site | `Get-CMDevice -Name <name> -Fast -DisableWildcardHandling` | Device record (resource ID, client installed, client version, active, operating system, last logon user). Last hardware inventory date. |
| Site | `Get-CMDevice -Name <pattern> -Fast`, `Get-CMCollectionMember -CollectionId <ID>` | The Device list panel: the devices that match a name pattern or a collection. |
| Site | `Invoke-CMWmiQuery` on `SMS_G_System_WORKSTATION_STATUS` | The hardware scan time, as the local clock time of the client, for the inventory check. |
| Site | `Invoke-CMWmiQuery` on `SMS_G_System_ADD_REMOVE_PROGRAMS` and `SMS_G_System_ADD_REMOVE_PROGRAMS_64` | Installed applications from hardware inventory (32-bit and 64-bit). |
| Site | `Invoke-CMWmiQuery` on `SMS_FullCollectionMembership` | Collection memberships (collection IDs, and `IsDirect` for the membership rule). |
| Site | `Get-CMDeviceCollection` | Collection names. One call, then a filter. |
| Site | `Get-CMDeployment` | Deployments targeted at those collections. One call, then a filter. |
| Site | `Invoke-CMWmiQuery` on `SMS_UpdateComplianceStatus` (status 2), then `Get-CMSoftwareUpdate -Fast -IncludeUpgrade` | Updates that the site lists as required for the device. Expired updates are left out. |
| The device | `Invoke-Command` with one script block | Operating system (caption, version, build, architecture, last boot). Client health (`CcmExec` service state and start mode, client version, assigned site code, current management point, last hardware inventory cycle, last discovery data cycle). Installed applications from the uninstall registry keys. Client application policy (`CCM_Application`). Pending updates in the client policy (`CCM_SoftwareUpdate`). |

`Invoke-CMWmiQuery` is a ConfigurationManager cmdlet. The tool uses it only for the four reads that no cmdlet returns: the installed applications of hardware inventory, the collection memberships of the device, the required updates of the device and the hardware scan time of the device (for the inventory check). See [Data sources](data-sources.md).

Two "last hardware inventory" values exist on purpose. The site value is the scan date that the site stored. The device value is the start time of the last hardware inventory cycle on the client. They can differ.

## Read-only design

- The site is read with the `Get-CM*` cmdlets in the table and with `Invoke-CMWmiQuery`. Every `Invoke-CMWmiQuery` call goes through the private function `Invoke-SiteQuery`, which refuses every query that does not start with `SELECT`. No command of the site read creates, changes or removes an object on the site.
- To use the cmdlets, the tool creates a `CMSite` drive in its own PowerShell session and sets the location to it. After the read, it sets the location back and removes the drive that it created. The drive exists only in the session on this computer.
- The device is read with `Invoke-Command` and one fixed script block. The block calls `Get-CimInstance` and `Get-ItemProperty` and no write command.
- A Pester test parses the module with the PowerShell parser and fails if the module calls a command from a list of state-changing commands. A second test does the same for the window script, and also fails if the window script calls `Invoke-Command`. A third test checks that the site query function refuses a `DELETE` and an `UPDATE` query.
- The computer name is validated by pattern. The site read uses the name without a domain suffix. Collection IDs from the site are checked against `^[A-Za-z0-9]{8}$` before they are used.
- The only files the tool writes are its log files, its settings files and the exports that the person names. In an installation of the suite, the shared update check also writes `%LOCALAPPDATA%\AppPackagerSuite\update-check.json`.
- The tool uses the permissions of the Windows account that runs it. It stores no password.

## Actions

The actions are the only code that changes the device or the site. They live in `Module/DeviceInspectorActions.ps1`, apart from the inspection code in `Module/DeviceInspectorCommon.psm1`, so that the read-only test of the inspection code still parses one file. The rules:

- The **Enable actions** switch is off at each start and is not saved. The window checks it before it shows the confirmation.
- Each action asks for a confirmation that names the action and shows the number of devices and their names.
- Each action has a dry run. The dry run runs the same code on the device, reads the state, lists the steps and skips every call that changes state. A test runs each device script with the dry run and fails if it calls a method.
- Each run and each dry run goes to the action log. See [Actions](../core/actions.md).
- Calls that change state (`Invoke-CimMethod`) appear only in the device scripts of the actions file. A test checks this.

The right-click menus of the Applications, Updates and Collections grids hold the action entries: the Updates menu installs pending updates, the Applications menu uninstalls and repairs applications, and the Collections menu removes and adds a direct membership rule (see [Actions](../core/actions.md)). The collection browser reads the device collections with one `Get-CMDeviceCollection` call.

The site actions use the ConfigurationManager cmdlets with the site drive, as the site read does. The cmdlets that change the site (`Add-CMDeviceCollectionDirectMembershipRule`, `Remove-CMDeviceCollectionDirectMembershipRule`, `Invoke-CMCollectionUpdate`, `Invoke-CMClientAction`) appear only in the collection change function. A test checks this.

## Known limits

- The tool needs the Configuration Manager console on the computer that runs it.
- The site value of the last hardware inventory comes from `Get-CMDevice`. Older versions read a class that was 4 hours early on the lab.
- A deployment deadline is shown as the local time that the site stores, with no zone.
- The tool shows deployments that target a collection of the device. It does not show the per-device result of each deployment.
- The site inventory list depends on the hardware inventory classes `Add Remove Programs` and `Add Remove Programs (64)`. The classes must be enabled in the client settings.
- The device list reads the machine-wide uninstall keys only. Per-user installs are not listed. System components are listed, as in the site inventory.
- The inventory check compares dates and application names only. An application removed after the last hardware inventory cycle makes the state **Corrupt** until the next cycle.
- A device name that has several resource records in the site uses the first record and adds a problem line.
- The updates that the site lists as required come from the update compliance status of the site. They can lag the state on the device.

## Links

- [Get-CimInstance](https://learn.microsoft.com/powershell/module/cimcmdlets/get-ciminstance): Describes the read command that the tool uses on the device.
