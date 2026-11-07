# Inspect bar

The Inspect bar is the row above every panel. It holds the device name, the site server, Site only, Inspect and the two export buttons.

## What it does

**Inspect** reads the device and the site and fills the five panels. Nothing changes on the site or on the device.

## When to use it

Use it each time you want the facts of a device, or when you want them again after a change.

## Requirements

- A device name.
- A site server and its site code (set in **Options**), unless you want only the device facts.
- The rights in [Permissions](../reference/permissions.md).

## Steps

### Inspect a device

1. In the first box, enter the device name. Use letters, digits, dots, hyphens and underscores.
2. In the second box, enter the site server (the SMS Provider computer).
3. Select **Inspect**. You can also press Enter in the device box.
4. Wait for the overlay to end. The log writes "Inspection of <device> finished: <n> problems." and the status bar shows the device, the time and the problem count.

![The overlay while the tool inspects a device](../images/inspect-running.png)

![A device selected by Enter in the device box](../images/inspect-by-enter.png)

The summary line on the **Device** panel counts the applications, the update rows, the collections and the problems.

### Read only the site

1. Select **Site only**.
2. Select **Inspect**. The tool does not contact the device. The device groups are missing from the **Device** panel.

![The Device panel after an inspection with Site only](../images/device-site-only.png)

### Read only the device

1. Clear the site server box.
2. Select **Inspect**. The tool does not contact the site. The site record is missing from the **Device** panel, and the Site server row says "not queried".

![The Device panel after an inspection with no site server](../images/device-device-only.png)

### Checks before the run

The tool checks the boxes before it reads anything. A wrong value opens a message and stops the run.

![The message for an empty device name](../images/inspect-empty-device.png)

![The message for a device name that is not valid](../images/inspect-bad-device.png)

**Site only** with no site server does not open a message. The log writes "Inspect: Site only needs a site server." and the status bar shows "Enter a site server, or clear Site only."

![The status bar after Site only with no site server](../images/inspect-site-only-no-server.png)

## Options and settings of this page

| Control | Effect |
|---|---|
| Device box | The device name. The watermark shows `Device name, e.g. CLIENT01`. |
| Site server box | The SMS Provider computer. The watermark shows `Site server, e.g. cm01.contoso.com`. |
| **Site only** | Skips the connection to the device. |
| **Inspect** | Reads the device and the site. |
| **Export JSON**, **Export HTML** | Save the inspection. See [Export](export.md). They turn on when an inspection exists. |

The site code comes from **Options**. It is required whenever a site server is set. The tool saves the device name, the site server and **Site only** when you select **Inspect**.

The **Enable actions** switch at the bottom of the sidebar is off and cannot be turned on in this release. The tool is read only. See [Read-only design](../reference/read-only-design.md).

## Limits

- The tool inspects one device at a time.
- A device name that has several resource records in the site uses the first record and adds a problem line.

## Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| Enter the device name. Use letters, digits, dots, hyphens and underscores. | The device box is empty or holds another character. | Enter a valid device name. |
| The site server is a computer name or an FQDN. | The site server box holds another character. | Enter a computer name or an FQDN. |
| A site code needs a site server. | A site code is set in Options and the site server box is empty. | Enter a site server, or clear the site code in **Options**. |
| A site server needs a site code. Enter it in Options. | The site server box holds a value and Options holds no site code. | Enter the site code in **Options**. |

## Links

- [Windows Remote Management](https://learn.microsoft.com/windows/win32/winrm/portal): Describes WinRM, which the tool uses for the device.
