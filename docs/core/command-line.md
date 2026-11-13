# Command line

`Invoke-DeviceInspector.ps1` prints the same facts as the window, as text, from a PowerShell prompt.

## What it does

The script inspects one device and prints a report. With `-JsonPath` it also writes all facts as JSON. It only reads.

## When to use it

- Use it in a script or a scheduled task.
- Use it to see the facts with no window.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- For site queries, the Configuration Manager console on this computer (the ConfigurationManager module).
- The same rights as the window. See [Permissions](../reference/permissions.md).

## Steps

### Print a report

1. Open a PowerShell prompt in the Device Inspector folder.
2. Run the script:

   ```powershell
   .\Invoke-DeviceInspector.ps1 -ComputerName WS01 -SiteServer sms01.example.com -SiteCode XYZ
   ```

3. Read the report. It starts with `Device Inspector report: WS01`, the time and the site server. It has one section for each part: operating system, client health, site record, collections, deployments, updates, applications and problems.

### Write the JSON

1. Add `-JsonPath`:

   ```powershell
   .\Invoke-DeviceInspector.ps1 -ComputerName WS01 -SiteServer sms01.example.com -SiteCode XYZ -JsonPath .\ws01.json
   ```

2. Open the file. It holds all entries of every list.

### Read one source

- `-SkipDevice` reads only the site. The device sections say "No data."
- Omit `-SiteServer` to read only the device. The report says "Site server: not queried" and the site sections say "No data." or "(none)".

### A failed part

A part that fails is listed in the **Problems** section. The other parts still print. A device that does not exist gives "The site has no record of this device." in **Problems**, and the WinRM error in the **Problem detail** section.

## Options and settings of this page

| Parameter | Default | Effect |
|---|---|---|
| `-ComputerName` | None. Required. Position 0. | The device. Letters, digits, dots, hyphens and underscores. |
| `-SiteServer` | None | The SMS Provider computer. Omit it to skip the site facts. |
| `-SiteCode` | None. Required with `-SiteServer`. | Three letters or digits. |
| `-Credential` | The current account | A credential for both connections. |
| `-SkipDevice` | Off | Does not contact the device. Requires `-SiteServer` and `-SiteCode`. |
| `-JsonPath` | None | Writes the facts as JSON (UTF-8 without BOM, dates in ISO 8601). A deployment deadline has no time zone: the site stores the local time that the administrator entered. |
| `-MaximumListedItems` | 25 | The most entries in each list of the report. The JSON has all entries. A list with more entries ends with "... <n> more (see the JSON output)". |

## Exit codes

The table applies to a PowerShell process that you start with `-File`. When you call the script with `&` from a PowerShell session, an invalid name throws an exception and does not set `$LASTEXITCODE` to 1. A caller must handle the exception.

| Code | Meaning |
|---|---|
| 0 | The script finished. |
| 1 | The script stopped on an error, for example a device name that is not valid. The message is on the error stream. |

## Limits

- The report shows at most `-MaximumListedItems` entries in each list.
- With a site server, the report can start with a warning of the ConfigurationManager module about a wildcard in the `Name` parameter. This is a known item. The warning does not stop the report.

## Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| Enter the device name. Use letters, digits, dots, hyphens and underscores. | The device name is empty or holds another character. | Use letters, digits, dots, hyphens and underscores. |
| Nothing to inspect: SiteServer is omitted and SkipDevice is set. | `-SkipDevice` is set and `-SiteServer` is not. | Add `-SiteServer` and `-SiteCode`, or remove `-SkipDevice`. |

See [Error messages](../reference/error-messages.md) for the other input messages.

## Links

- [about_Remote_Troubleshooting](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting): Describes how to fix remoting errors.
