# Settings

This page lists every setting of Device Inspector with its default and the place where it is stored.

## What it does

The tool saves its settings in `DeviceInspector.prefs.json` and the window state in `DeviceInspector.windowstate.json`. Both files are in the folder of the script. The tool creates them on first use.

When the AppPackager Suite launcher chose a site, the tool keeps the site settings (the SMS Provider, the site code and the last device) per site in `%LOCALAPPDATA%\AppPackagerData\sites\<SITE>\tools\device-inspector\prefs.json`, for example `sites\AB1\tools\device-inspector`. The other settings (the theme and Site Only) and the window state stay in the folder of the script. The launcher chooses the site code. The tool never changes it. See [Options](../core/options.md#sites).

## When to use it

Use this page to find where a setting lives, or to reset the tool.

## Requirements

Write access for your account to the folder of the script.

## Settings

| Setting | Where in the window | Key | Default | Saved | Stored |
|---|---|---|---|---|---|
| Theme | Toggle at the bottom of the sidebar | `DarkMode` | `true` (dark) | At once | `DeviceInspector.prefs.json` |
| SMS Provider | **Options** | `SMSProvider` | Empty, or `SUITE_CM_PROVIDER` | **OK** in Options | The site, or `DeviceInspector.prefs.json` with no site |
| Site code | **Options** (read-only when the launcher chose a site) | `SiteCode` | Empty, or `SUITE_CM_SITECODE`. Required when an SMS Provider is set. | **OK** in Options | The site, or `DeviceInspector.prefs.json` with no site |
| Last device | The device box | `LastDevice` | Empty | **Inspect** | The site, or `DeviceInspector.prefs.json` with no site |
| Site Only | **Site Only** | `SiteOnly` | `false` | **Inspect** | `DeviceInspector.prefs.json` |

### Window state

| Key in `DeviceInspector.windowstate.json` | Content |
|---|---|
| `Width`, `Height`, `Left`, `Top` | The size and the position of the window. |
| `Maximized` | `true` when the window was maximized. |
| `ActiveView` | `Device`, `Applications`, `Updates`, `Collections` or `Problems`. The window opens on this panel. |

### Environment variables

| Variable | Effect |
|---|---|
| `SUITE_CM_PROVIDER` | Fills an empty SMS Provider. The suite launcher sets it. |
| `SUITE_CM_SITECODE` | Fills an empty site code. The suite launcher sets it. |

With no site chosen, a value that is saved in `DeviceInspector.prefs.json` and is not empty wins over the variable, and an empty saved value is filled from the variable. With a site chosen, the site decides and the tool ignores the two variables.

## Steps

### Reset the tool

1. Close the tool.
2. Delete `DeviceInspector.prefs.json` and `DeviceInspector.windowstate.json`. To reset the site settings too, delete `prefs.json` in the folder of the site.
3. Start the tool. It opens with the defaults.

## Limits

The status of the filter boxes of the Applications panel is not saved.

## Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| The window opens on the wrong panel or in the wrong place. | `DeviceInspector.windowstate.json` holds an old state. | Delete the file. |

## Links

None.
