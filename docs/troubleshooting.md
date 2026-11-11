# Troubleshooting

This page lists the most common problems of Device Inspector with their cause and their fix. Each entry has three parts: the message or the symptom, the cause and the fix.

## What it does

The page helps you find the fix for a message in a dialog, in the log or on the **Problems** panel. See [Error messages](reference/error-messages.md) for the dialog and command-line messages, and [Problems panel](core/problems.md) for the inspection problems.

## When to use it

Use this page when a panel is empty, a button is off, or the **Problems** panel shows a line.

## Requirements

None. Some fixes need rights on the site or on the device.

## Steps

1. Read the message. A message in `<angle brackets>` shows a value that the tool inserts.
2. Find the message in the tables below.
3. Do the fix.
4. Select **Inspect** again.

## Start

| Message or symptom | Cause | Fix |
|---|---|---|
| A message box says that the Configuration Manager console is not installed, and the tool ends. | The ConfigurationManager module is not on this computer. | Install the console, then start the tool again. |

## Inspect

| Message or symptom | Cause | Fix |
|---|---|---|
| A message opens when you select **Inspect**. | A box holds a wrong value. | Read the message. See [Inspect bar](core/inspect.md). |
| **Export JSON** and **Export HTML** are off. | No inspection exists yet. | Select **Inspect**. |
| A message says "A site server needs a site code. Enter it in Options." | The site server is set and the site code is empty. | Enter the site code in **Options**. |
| **OK** in **Options** opens a message box with the title **Device Inspector**, and the dialog stays open. | The site server or the site code has a wrong value. | Read the message. Correct the value. See [Options dialog](core/options.md). |
| The status bar shows "Enter a site server, or clear Site only." | **Site only** is on and the site server box is empty. | Enter the site server, or clear **Site only** to inspect the device. |

## Problems panel

| Message or symptom | Cause | Fix |
|---|---|---|
| Device: Connecting to remote server `<name>` failed ... the server name cannot be resolved. | The device name is wrong, or the name does not resolve. | Check the name and the DNS. |
| Device: ... Access is denied. | The account has no remote management right on the device. | Run the tool as an account with the right. |
| Device: ... WinRM cannot process the request. | The device is off, or WinRM is not on. | Start the device. Check the WinRM service and the firewall. |
| Site: no device named `<name>` exists in site `<code>`. | The site has no record with that name. | Check the name. The device must be in the site. |
| Device: Client health: the CcmExec service does not exist. | The device has no ConfigMgr client. | Install the client, or inspect another device. |
| Site: Cannot open site `<code>` on `<server>`. Check the site code and the site server name, and the account rights. ... | The site drive did not open: a wrong site code or server name, no network path, or no right on the site. | Check the values in **Options**. See [Permissions](reference/permissions.md). |
| Site: Cannot open site `<code>` on `<server>`. The site server is this computer, and Windows does not allow credentials for a local connection. ... | The script ran with `-Credential` on the site server, and the site server name is an alias that the tool does not know as this computer. | Enter the name of this computer as the site server, or run without `-Credential`. With the short name, the full name, `localhost` or an IP address of this computer, the tool uses the signed-in account for the site and keeps the credential for the device. |
| Site: `<n>` resource records share the name `<name>`. The first one is used. | The site has several records with one name. | Compare the records in the console. Confirm that a record is no longer needed before you delete it. Deleting a client record removes its history and its earlier associations. |

## Command line

| Message or symptom | Cause | Fix |
|---|---|---|
| The report starts with a warning of the ConfigurationManager module about a wildcard in the `Name` parameter. | A known item of the site read. | None. The warning does not stop the report. |

## Panels

| Message or symptom | Cause | Fix |
|---|---|---|
| The Applications list is empty. | The device part failed or **Site only** was on. | Read the **Problems** panel. Clear **Site only** and inspect again. |
| **Uninstall...** or **Repair...** is off for an application. | The entry is a system component, or an EXE entry without a quiet uninstall string. Repair is off for every EXE entry. | Hover over the entry. The tooltip gives the reason. See [Applications](core/applications.md#when-uninstall-and-repair-are-on). |
| A new install is not in the Applications list. | The list shows the state at the time of the inspection. | Inspect the device again. |

## Window

| Message or symptom | Cause | Fix |
|---|---|---|
| The window opens in the wrong place. | The saved window state holds an old position. | Delete `DeviceInspector.windowstate.json`. |
| The tool does not start. | The folder is blocked, or the PowerShell version is wrong. | Extract the zip again. Start with Windows PowerShell 5.1. |

## Links

None.
