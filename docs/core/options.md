# Options dialog

The Options dialog sets the connection and shows the version of the tool.

## What it does

The dialog has two sections, **Connection** and **About**. **Connection** holds the site server and the site code. **About** shows the version, a description, the author and the license.

## When to use it

Use it to set the site server once, or to set a site code.

## Requirements

None. The dialog does not connect to the site.

## Steps

### Set the connection

1. Select **Options** in the sidebar.
2. Select **Connection**.
3. In **Site server (SMS Provider FQDN)**, enter a computer name or an FQDN.
4. In **Site Code**, enter the three letters or digits of the site code, for example `MCM`. The site code is required when a site server is set.
5. Select **OK**. Select **Cancel** or press Esc to discard the change.

![The Connection section of the Options dialog](../images/options-connection.png)

A site code of another form opens a message and the dialog stays open. A site server with no site code does the same.

![The message for a site server with no site code](../images/options-needs-site-code.png)

![The message for a wrong site code](../images/options-bad-site-code.png)

### Read the version

1. Select **About**.
2. Read the version, for example `Device Inspector v2026.11.06.0003`.

![The About section](../images/options-about.png)

### Options in the light theme

![The Options dialog in the light theme](../images/options-light.png)

## Options and settings of this page

| Control | Default | Effect |
|---|---|---|
| **Site server (SMS Provider FQDN)** | Empty, or the value that the suite launcher hands over | The SMS Provider computer. The site server box on the Inspect bar starts with this value. |
| **Site Code** | Empty, or the value that the suite launcher hands over | A three-character site code. Required with a site server. The tool no longer asks the provider for it. |

The dialog also says that the tool needs the Configuration Manager console on this computer, that the account needs local administrator rights on the device (WinRM), and that a domain admin account that is a local administrator of the SMS Provider computer needs no Configuration Manager role. This is the text of the dialog, and it was tested on the lab only. For another account, check the Configuration Manager roles and scopes in your site. An account with other rights is not tested.

## Limits

- The message boxes of the dialog carry the title **Options**, the same title as the dialog.
- The dialog has no credential field. To use another account, start the tool as that account.
- A site code needs a site server. See [Inspect bar](inspect.md).

## Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| The site code is three letters or digits. | The site code has another form. | Enter three letters or digits. |
| A site server needs a site code. Enter it in Options. | The site server is set and the site code is empty. | Enter the site code. |

## Links

- [Plan for the SMS Provider](https://learn.microsoft.com/intune/configmgr/core/plan-design/hierarchy/plan-for-the-sms-provider): Explains what the SMS Provider is.
