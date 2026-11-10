# Network

This page lists every outbound call of Device Inspector.

## What it does

The page names each connection, its target and the reason.

## When to use it

Use this page to set a firewall rule or to check what the tool sends.

## Requirements

None.

## Calls

| Call | Target | When | Content |
|---|---|---|---|
| ConfigurationManager module | The SMS Provider computer, through the site drive that the console module opens | **Inspect** with a site server | `Get-CMSite`, `Get-CMDevice`, `Get-CMDeviceCollection`, `Get-CMDeployment`, `Get-CMSoftwareUpdate` and `Invoke-CMWmiQuery` (WQL `SELECT`). The ports are those of the console. |
| WinRM remote script block | The device, TCP 5985 (HTTP) by default | **Inspect** with no **Site only** | `Invoke-Command` with one script block that reads the device. |
| `https://api.github.com/repos/<repository>/releases/latest` | GitHub | At the start of the window, once a day, only when the tool is installed by the suite installer | The check for a newer suite version. The result goes to the log. |

A plain extract of the zip (no `suite-manifest.json`) makes no call to GitHub. The tool sends no user data and no telemetry.

## Steps

None.

## Limits

The tool does not change a proxy setting. A failed update check is ignored.

## Troubleshooting

See [Troubleshooting](../troubleshooting.md).

## Links

- [Windows Remote Management](https://learn.microsoft.com/windows/win32/winrm/portal): Describes WinRM and its ports.
