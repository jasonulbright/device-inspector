# Files and logs

This page lists every folder and file that Device Inspector writes.

## What it does

The tool writes next to its script. It writes nothing to the registry. It never writes to the site or to the device during an inspection. An action writes only what the action names. See [Actions](../core/actions.md). An export writes to the folder that you select in the Save As dialog. That folder can be a share on another computer.

## When to use it

Use this page to find a log, to back up the settings, or to clean up.

## Requirements

Write access for your account to the folder of the script.

## Files

| Path (in the script folder) | Content | Written when |
|---|---|---|
| `DeviceInspector.prefs.json` | The site server, the site code, the last device and Site only. See [Settings](settings.md). | **Inspect**, **OK** in Options, the theme toggle. |
| `DeviceInspector.windowstate.json` | The window size, position and panel. | Window close. |
| `Logs\DeviceInspector-<yyyyMMdd-HHmmss>.log` | The full log of one session: every line of the window log, the full report of each inspection with every list entry, and each action with its steps. | During the session. |
| `Logs\DeviceInspector-actions.log` | The action log: every run and every dry run of an action, from every session. | After each action. |
| `Logs\DeviceInspector-startup-<yyyyMMdd-HHmmss>.txt` | The PowerShell transcript of the start. | At start. |
| `Logs\DeviceInspector-crash-<yyyyMMdd-HHmmss>.txt` | The details of an unhandled error. | Only after a crash. |
| `Reports\DeviceInspector-<device>-<yyyyMMdd-HHmmss>.json`, `.html` | The exports. | **Export JSON**, **Export HTML**, when you keep the default folder. |

The log has one line for each log line of the window, with the time and the level, and the lines `problem: <text>` for each problem. After each inspection it also holds the full report between the lines `----- Full report: <device> -----` and `----- end of Full report: <device> -----`. The report has the same sections as the command-line report, with every entry of every list. The first log lines of the window show the path of the log file.

### Open the log file

Select **Open log file** at the right of **LOG OUTPUT**. The log file of this session opens in the program that Windows uses for `.log` files.

## Steps

### Clean up

1. Close the tool.
2. Delete the files in `Logs` and `Reports` that you do not need.

## Limits

- The tool never deletes a log, the action log or an export.

## Troubleshooting

None.

## Links

None.
