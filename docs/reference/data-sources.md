# Data sources and the lab comparison

This page lists the source of each fact and the result of the lab comparison of the old and the new read.

## What it does

The page says which cmdlet or which device read gives each fact.

## When to use it

Use this page when a value differs from the console, or to find the source of a fact.

## Requirements

None.

## Rule

- A fact that comes from the device itself stays live. The tool reads it on the device over WinRM (CIM and the registry on the device).
- A fact that the site holds (cached data) comes from a ConfigurationManager cmdlet first. A read that no cmdlet returns uses `Invoke-CMWmiQuery` (a ConfigurationManager cmdlet that runs a WQL `SELECT` on the open site drive).
- The tool needs the Configuration Manager console on the computer that runs it. The ConfigurationManager module comes only with the console. The site code is required when a site server is set.
- The cmdlets work only from a site drive. The tool opens a `CMSite` drive for the site code, checks the site with `Get-CMSite`, reads, and then removes the drive that it created.

## Site facts

Compared on 2026-11-06 on the lab site for the workstation and the site server. "Old" is the CIM read of version 2026.11.06.0001 (`root\sms\site_<site code>`, `Get-CimInstance`). "New" is the cmdlet read.

| Field | New source | Old CIM class | Result | Notes |
|---|---|---|---|---|
| Device found, resource ID | `Get-CMDevice -Name <name> -Fast -DisableWildcardHandling` | `SMS_R_System` | Match | The name has no domain suffix. One call gives all the record fields below. |
| Client installed | `Get-CMDevice` `IsClient` | `SMS_R_System.Client` | Match | |
| Client version | `Get-CMDevice` `ClientVersion` | `SMS_R_System.ClientVersion` | Match | The device reports the same version live. |
| Active | `Get-CMDevice` `IsActive` | `SMS_R_System.Active` | Match | |
| Operating system | `Get-CMDevice` `DeviceOS` | `SMS_R_System.OperatingSystemNameandVersion` | Match | The site text is generic ("Microsoft Windows NT Workstation 10.0"). The device block reads the real caption live. |
| Last logon user | `Get-CMDevice` `LastLogonUser` | `SMS_R_System.LastLogonUserName` | Match | |
| Last hardware inventory | `Get-CMDevice` `LastHardwareScan` | `SMS_G_System_WORKSTATION_STATUS.LastHardwareScan` | **Differs** | See below. The cmdlet value is right. |
| Installed applications | `Invoke-CMWmiQuery` on `SMS_G_System_ADD_REMOVE_PROGRAMS` and `_64` | same classes | Match (18 rows on the workstation, 74 on the site server) | No cmdlet returns the hardware inventory classes of one device. |
| Collection memberships (IDs) | `Invoke-CMWmiQuery` on `SMS_FullCollectionMembership` | same class | Match (11 on the workstation, 5 on the site server) | A cmdlet route exists: `Get-CMCollectionMember -ResourceId` for each device collection. It returned the same sets. It made one call for each of the 26 device collections and took about 4 s, against about 0.3 s for the one query. The tool keeps the query. |
| Collection names | `Get-CMDeviceCollection` (one call, then a filter) | `SMS_Collection` | Match | |
| Deployments of those collections | `Get-CMDeployment` (one call, then a filter) | `SMS_DeploymentSummary` | Rows match (13 on the workstation, 1 on the site server). **Deadline text differs.** | See below. |
| Required updates | `Invoke-CMWmiQuery` on `SMS_UpdateComplianceStatus` (status 2), details from `Get-CMSoftwareUpdate -Fast -IncludeUpgrade` (one call, then a filter) | `SMS_UpdateComplianceStatus`, `SMS_SoftwareUpdate` | Match (7 on the workstation, 4 on the site server) | No cmdlet returns the update status of one device. Expired updates are left out. |

### Last hardware inventory differs

| Device | Device, live (inventory cycle start) | New: `Get-CMDevice` | Old: `SMS_G_System_WORKSTATION_STATUS` |
|---|---|---|---|
| Workstation | 2026-11-05T17:40:51Z | 2026-11-05T17:41:51Z | 2026-11-05T13:41:51Z |
| Site server | 2026-11-02T12:11:51Z | 2026-11-02T12:12:40Z | 2026-11-02T08:12:40Z |

The site finishes about one minute after the client starts, so the cmdlet value fits the device. The old class value is 4 hours early. Both values come with no zone. The cmdlet value is UTC. The tool reads a site date with no zone as UTC. The old CIM read gave the wrong time. This is a fix, not a new difference.

### Deployment deadline differs in text

The site stores the deadline of a deployment as the local time that the administrator entered, with no zone. A test deployment on the lab confirmed it: a deadline entered as 2026-12-04 17:00 came back as 17:00 from `Get-CMDeployment`, from `Get-CMSoftwareUpdateDeployment` and from the CIM class. Version 2026.11.06.0001 added a "Z" to this value, which is wrong. The tool now writes the deadline without a zone: `2026-12-04T17:00:00`.

## Device facts (live)

These stay on the device. `Invoke-Command` runs one script block on the device over WinRM. The block reads the facts below, and they are not cached.

| Fact | Source on the device |
|---|---|
| Operating system caption, version, build, architecture, last boot | `Win32_OperatingSystem` |
| Client service state and start mode | `Win32_Service` (`CcmExec`) |
| Client version, assigned site code, management point | `root\ccm` `SMS_Client`, `CCM_Authority` |
| Last hardware and discovery inventory cycle | `root\ccm\invagt` `InventoryActionStatus` |
| Installed applications | The machine-wide uninstall registry keys (`HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` and the `WOW6432Node` key). An entry with no display name is left out. Entries with `SystemComponent` set to 1 are kept, because the Add Remove Programs inventory of the site keeps them. The install date (`InstallDate`) is read for the inventory check. |
| Client application policy | `root\ccm\ClientSDK` `CCM_Application` |
| Pending updates in the client policy (with `UpdateID` and `ComplianceState` for the install action) | `root\ccm\ClientSDK` `CCM_SoftwareUpdate` |

## Site against device

| Fact | Workstation | Site server | Which source is right |
|---|---|---|---|
| Client version | site and device equal | site and device equal | Equal. |
| Operating system | site: generic text. Device: Windows 11 Enterprise Evaluation 10.0.26200 | site: generic text. Device: Windows Server 2025 Datacenter Evaluation 10.0.26100 | The device. The site stores the generic product line. |
| Installed applications | site inventory 18 rows, device 9 rows | site 74, device 25 | They measure different things. The site lists the 32-bit and 64-bit Add Remove Programs inventory. The device lists the machine-wide uninstall keys. The Applications panel compares them row by row. |
| Required updates | site 7 | site 4 | The site value comes from the last update scan that the client reported. The device list holds only the updates in the client policy (1 on the workstation, 0 on the site server). The device is right for now. The site is right for what the client last reported. The panel shows both. |

## Time

Both devices, site facts only, from the workstation to the site server: 1.6 s with CIM (version 0001) and 6.5 s with the cmdlets (measured on 2026-11-06, including the first load of the module). One call for each collection or update took about ten times longer than one call for all, so the tool reads collections, deployments and updates in one call each and filters.

## Links

- [Get-CMDevice](https://learn.microsoft.com/powershell/module/configurationmanager/get-cmdevice): Describes the cmdlet that reads the site record of a device.
