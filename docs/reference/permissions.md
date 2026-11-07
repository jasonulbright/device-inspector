# Permissions

This page lists the rights that each part of Device Inspector needs.

## What it does

The page names the site rights, the device rights and the file rights.

## When to use it

Use this page to set up an account, or to find the cause of an access error.

## Requirements

None.

## Rights by part

| Part | Where | Right |
|---|---|---|
| Site facts | The SMS Provider, through the ConfigurationManager module (the Configuration Manager console on this computer) | A domain admin account that is a local administrator of the SMS Provider computer needs no Configuration Manager role. An account with fewer rights on the site is not tested. The tool reads only (`Get-CM*` cmdlets and `Invoke-CMWmiQuery` with `SELECT`). |
| Device facts | The device (WinRM, one script block) | Local administrator rights on the device. The script block runs `Get-CimInstance` and `Get-ItemProperty`. |
| Export, logs, settings | This computer | Write access to the folder of the script, and to the folder that you choose for an export. |

The tool needs the Configuration Manager console on this computer. It checks for the ConfigurationManager module at start. The tool uses the Windows account that runs it. It stores no password. The command-line script accepts `-Credential` for both connections.

The tool needs no right to change anything. It never changes the site or the device.

## Steps

### Check an account

1. Start the tool as the account.
2. Inspect a device with a site server. An empty **Device** group means the device right is missing. An empty **Site record** means the site right is missing. The **Problems** panel names the part.

## Limits

None.

## Troubleshooting

See [Troubleshooting](../troubleshooting.md).

## Links

- [Fundamentals of role-based administration](https://learn.microsoft.com/intune/configmgr/core/understand/fundamentals-of-role-based-administration): Describes the security roles and scopes.
