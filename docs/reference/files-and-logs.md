# Files and logs

This page lists every folder and file that Device Inspector writes.

## What it does

The tool writes next to its script. It writes nothing to the registry. It never writes to the site or to the device.

## When to use it

Use this page to find a log, to back up the settings, or to clean up.

## Requirements

Write access for your account to the folder of the script.

## Files

| Path (in the script folder) | Content | Written when |
|---|---|---|
| `DeviceInspector.prefs.json` | The site server, the site code, the last device and Site only. See [Settings](settings.md). | **Inspect**, **OK** in Options, the theme toggle. |
| `DeviceInspector.windowstate.json` | The window size, position and panel. | Window close. |
| `Logs\DeviceInspector-<yyyyMMdd-HHmmss>.log` | The tool log of one session. | During the session. |
| `Logs\DeviceInspector-startup-<yyyyMMdd-HHmmss>.txt` | The PowerShell transcript of the start. | At start. |
| `Logs\DeviceInspector-crash-<yyyyMMdd-HHmmss>.txt` | The details of an unhandled error. | Only after a crash. |
| `Reports\DeviceInspector-<device>-<yyyyMMdd-HHmmss>.json`, `.html` | The exports. | **Export JSON**, **Export HTML**, when you keep the default folder. |

The log has one line for each log line of the window, with the time and the level, and the lines `problem: <text>` for each problem.

## Steps

### Clean up

1. Close the tool.
2. Delete the files in `Logs` and `Reports` that you do not need.

## Limits

- The tool never deletes a log or an export.

## Troubleshooting

None.

## Links

None.
