# Files and logs

This page lists every folder and file that Device Inspector writes.

## What it does

The tool writes its global files next to its script and its site data below `%LOCALAPPDATA%\AppPackagerData`. It writes nothing to the registry. It never writes to the site or to the device during an inspection. An action writes only what the action names. See [Actions](../core/actions.md). An export writes to the folder that you select in the Save As dialog. That folder can be a share on another computer.

## When to use it

Use this page to find a log, to back up the settings, or to clean up.

## Requirements

Write access for your account to the folder of the script, and to `%LOCALAPPDATA%\AppPackagerData`.

## Files

| Path (in the script folder) | Content | Written when |
|---|---|---|
| `DeviceInspector.prefs.json` | The theme and Site Only. With no site chosen, also the SMS Provider, the site code and the last device. See [Settings](settings.md). | **Inspect**, **OK** in Options, the theme toggle. |
| `DeviceInspector.windowstate.json` | The window size, position and panel. | Window close. |
| `Logs\DeviceInspector-<yyyyMMdd-HHmmss>.log` | The full log of one session: every line of the window log, the full report of each inspection with every list entry, and each action with its steps. | During the session. |
| `Logs\DeviceInspector-startup-<yyyyMMdd-HHmmss>.txt` | The PowerShell transcript of the start. | At start. |
| `Logs\DeviceInspector-crash-<yyyyMMdd-HHmmss>.txt` | The details of an unhandled error. | Only after a crash. |

The log has one line for each log line of the window, with the time and the level, and the lines `problem: <text>` for each problem. The window shows a fixed sentence for each failure. The error text of the failure is in the log file only, in a line of the level ERROR, and in the **Problem detail** section of the full report. After each inspection it also holds the full report between the lines `----- Full report: <device> -----` and `----- end of Full report: <device> -----`. The report has the same sections as the command-line report, with every entry of every list. The first log lines of the window show the path of the log file.

### Site data

When the AppPackager Suite launcher chose a site, the tool keeps these files per site in `%LOCALAPPDATA%\AppPackagerData\sites\<SITE>\tools\device-inspector`, for example `sites\AB1\tools\device-inspector`. With no site chosen, the tool uses the old places in the script folder, shown in the second column.

| Path (in the site folder) | Old place (script folder) | Content | Written when |
|---|---|---|---|
| `prefs.json` | `DeviceInspector.prefs.json` | The SMS Provider, the site code and the last device. | **Inspect**, **OK** in Options. |
| `DeviceInspector-actions.log` | `Logs\DeviceInspector-actions.log` | The action log: every run and every dry run of an action, from every session of the site. Each line has an action ID. | Before a run (`STARTED`), after each action, and at window close for each open run (`CLOSED`). |
| `reports\DeviceInspector-<device>-<yyyyMMdd-HHmmss>.json`, `.html` | `Reports\...` | The exports. | **Export JSON**, **Export HTML**, when you keep the default folder. |
| `migrated.json` | None | The record of the copy of the old data into the site folder. | At the first start for the site. |

The first start for a site after an update copies the old data into the site folder (the action log, the exports and the site settings) and keeps the old files. A later start does not copy again.

### Open the log file

Select **Open Log File** at the right of **Log Output**. The log file of this session opens in the program that Windows uses for `.log` files.

## Steps

### Clean up

1. Close the tool.
2. Delete the files in `Logs` that you do not need. Delete the files in the `reports` folder of the site (or in `Reports` with no site) that you do not need.

## Limits

- The tool never deletes a log, the action log or an export.

## Troubleshooting

None.

## Links

None.
