# Error messages

This page lists the messages that Device Inspector shows, grouped by area. Each row gives the message, where it appears, the cause and the fix.

- `<x>` marks a value that the tool inserts.
- For the most common messages, see also [Troubleshooting](../troubleshooting.md).

## What it does

The page lists the texts of the window dialogs, the log and the command-line script.

## When to use it

Use this page when the tool shows a message that you do not know.

## Requirements

None.

## Messages

### Inspect bar

| Message | Where | Cause | Fix |
|---|---|---|---|
| Enter the device name. Use letters, digits, dots, hyphens and underscores. | Dialog **Inspect** and log | The device box is empty or holds another character. | Enter a valid device name. |
| The site server is a computer name or an FQDN. | Dialog **Inspect** | The site server holds another character. | Enter a computer name or an FQDN. |
| The site code is three letters or digits. | Dialog **Inspect** or **Options** | The site code has another form. | Enter three letters or digits. |
| A site code needs a site server. | Dialog **Inspect** | A site code is set and the site server is empty. | Enter a site server, or clear the site code in **Options**. |
| A site server needs a site code. Enter it in Options. | Dialog **Inspect** or **Options** | The site server is set and the site code is empty. | Enter the site code in **Options**. |
| The Configuration Manager console is not installed on this computer. Device Inspector reads the site with the ConfigurationManager PowerShell module, which comes only with the console. Install the console, then start Device Inspector again. | Message box at start | The module is not found. | Install the console. |
| Inspect: Site only needs a site server. | Log | **Site only** is on and the site server box is empty. | Enter a site server, or clear **Site only**. |
| Inspect failed: <text> | Dialog and log | The inspection stopped on an error that no part caught. | Read the text. |

### Problems

See [Problems panel](../core/problems.md) for the lines of the failed parts.

### Export

| Message | Where | Cause | Fix |
|---|---|---|---|
| Export <kind> failed: <text> | Dialog **Export** and log | The file could not be written. | Choose a folder that your account can write to. |

### Command line

| Message | Cause | Fix |
|---|---|---|
| Enter the device name. Use letters, digits, dots, hyphens and underscores. | The device name has another form. | Use letters, digits, dots, hyphens and underscores. |

## Steps

1. Find the message in the tables.
2. Do the fix.

## Limits

The tool shows the error text of the site and of WinRM as it is. This page cannot list those texts.

## Troubleshooting

See [Troubleshooting](../troubleshooting.md).

## Links

None.
