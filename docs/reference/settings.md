# Settings

This page lists every setting of Device Inspector with its default and the place where it is stored.

## What it does

The tool saves its settings in `DeviceInspector.prefs.json` and the window state in `DeviceInspector.windowstate.json`. Both files are in the folder of the script. The tool creates them on first use.

## When to use it

Use this page to find where a setting lives, or to reset the tool.

## Requirements

Write access for your account to the folder of the script.

## Settings

| Setting | Where in the window | Key in `DeviceInspector.prefs.json` | Default | Saved |
|---|---|---|---|---|
| Theme | Toggle at the bottom of the sidebar | `DarkMode` | `true` (dark) | At once |
| Site server | **Options**, or the site server box | `SMSProvider` | Empty, or `SUITE_CM_PROVIDER` | **OK** in Options, and **Inspect** when the box is not empty |
| Site code | **Options** | `SiteCode` | Empty, or `SUITE_CM_SITECODE`. Required when a site server is set. | **OK** in Options |
| Last device | The device box | `LastDevice` | Empty | **Inspect** |
| Site only | **Site only** | `SiteOnly` | `false` | **Inspect** |

### Window state

| Key in `DeviceInspector.windowstate.json` | Content |
|---|---|
| `Width`, `Height`, `Left`, `Top` | The size and the position of the window. |
| `Maximized` | `true` when the window was maximized. |
| `ActiveView` | `Device`, `Applications`, `Updates`, `Collections` or `Problems`. The window opens on this panel. |

### Environment variables

| Variable | Effect |
|---|---|
| `SUITE_CM_PROVIDER` | Fills an empty site server. The suite launcher sets it. |
| `SUITE_CM_SITECODE` | Fills an empty site code. The suite launcher sets it. |

A value that is saved in `DeviceInspector.prefs.json` and is not empty wins over the variable. An empty saved value is filled from the variable.

## Steps

### Reset the tool

1. Close the tool.
2. Delete `DeviceInspector.prefs.json` and `DeviceInspector.windowstate.json`.
3. Start the tool. It opens with the defaults.

## Limits

The status of the filter boxes of the Applications panel is not saved.

## Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| The window opens on the wrong panel or in the wrong place. | `DeviceInspector.windowstate.json` holds an old state. | Delete the file. |

## Links

None.
