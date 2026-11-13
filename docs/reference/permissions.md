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
| Site facts | The SMS Provider, through the ConfigurationManager module (the Configuration Manager console on this computer) | A domain admin account that is a local administrator of the SMS Provider computer needs no Configuration Manager role. This was tested on the lab only. For another account, check the Configuration Manager roles and scopes in your site. An account with other rights is not tested. The tool reads only (`Get-CM*` cmdlets and `Invoke-CMWmiQuery` with `SELECT`). See [Read-only design](read-only-design.md). |
| Device facts | The device (`Invoke-Command` over WinRM, one script block) | Local administrator rights on the device. The script block runs `Get-CimInstance` and `Get-ItemProperty`. |
| Device actions | The device (`Invoke-Command` over WinRM) | Local administrator rights on the device. The action scripts call the client methods in `root\ccm` and `root\ccm\ClientSDK`, and delete the hardware inventory status record in `root\ccm\invagt`. See [Actions](../core/actions.md). |
| Collection actions | The SMS Provider, through the ConfigurationManager module | The right to modify the collection and its members (for example the Modify Resource permission on collections) and to send client notifications. The collection browser and the limiting-collection check read collections: a role with a collection scope sees only the collections of its scope, and the add can be refused when the account cannot read the limiting collection. On the lab, a domain admin account that is a local administrator of the SMS Provider computer did the change with no Configuration Manager role. |
| Export, logs, settings | This computer | Write access to the folder of the script, and to the folder that you choose for an export. |

The tool needs the Configuration Manager console on this computer. It checks for the ConfigurationManager module at start. The tool uses the Windows account that runs it. It stores no password. The command-line script accepts `-Credential` for both connections.

The inspection needs no right to change anything. It never changes the site or the device. The actions need the rights in the table, and run only when **Enable Actions** is on.

## Steps

### Check an account

1. Start the tool as the account. Clear **Site Only**, and read the **Problems** panel first: a missing group can also come from **Site Only** or from a device that did not answer.
2. Inspect a device with a site server. On the **Device** panel, missing **Operating system (device)** and **Client health (device)** groups mean that the device read failed. A missing **Site record** group means that the site read failed. The **Problems** panel names the part and shows the error text, for example "Access is denied".

## Limits

None.

## Troubleshooting

See [Troubleshooting](../troubleshooting.md).

## Links

- [Fundamentals of role-based administration](https://learn.microsoft.com/intune/configmgr/core/understand/fundamentals-of-role-based-administration): Describes the security roles and scopes.
