# Glossary

This page defines the terms of Device Inspector.

## What it does

The page gives one meaning for each term. The tool and the other pages use the term in this meaning only.

## When to use it

Use this page when a term is not clear.

## Requirements

None.

## Terms

| Term | Meaning |
|---|---|
| Client health | The state of the ConfigMgr client on the device: the `CcmExec` service, the client version, the assigned site code, the management point and the last cycles. |
| Console | The Configuration Manager console. The tool needs it on this computer, because the ConfigurationManager module comes only with it. |
| Device | The computer that you inspect. |
| Discovery data and hardware inventory | The data that the site stores about the device: the discovery data (`Get-CMDevice`) and the hardware inventory (`SMS_G_System_WORKSTATION_STATUS`). The group of the same name on the **Device** panel shows it. |
| EXE | An uninstall entry that is not an MSI entry. The Applications panel shows it with the type **EXE**. |
| Hardware inventory | The data that the client collects about a device and sends to the site. The site stores the installed applications from it. |
| MSI | An uninstall entry whose key name is a product code in braces, and whose uninstall string starts with `msiexec` or whose key has `WindowsInstaller` 1. |
| Problem | A part of the inspection that failed. The other parts still run. |
| Quiet uninstall string | The `QuietUninstallString` value of an uninstall key. It holds a command line that uninstalls the application without a window. The tool runs it as written and adds no switches. |
| Resource ID | The ID that the site gives to the device. |
| Site drive | The `CMSite` PowerShell drive that the tool opens for the site code. The ConfigurationManager cmdlets work only from it. It exists only in the PowerShell session of the tool. |
| Site Only | The option that skips the connection to the device. |
| SMS Provider | The SMS Provider: the computer that gives access to the site data. The SMS Provider box names it. |

## Steps

None.

## Limits

None.

## Troubleshooting

See [Troubleshooting](../troubleshooting.md).

## Links

None.
