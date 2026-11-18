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
| The SMS Provider is a computer name or an FQDN. | Dialog **Inspect** and log | The saved SMS Provider has another character. | Correct it in **Options**. |
| The site code is three letters or digits. | Dialog **Inspect** and log | The saved site code has another form. | Enter three letters or digits in **Options**. |
| A site code needs an SMS Provider. | Dialog **Inspect** and log | A site code is set and the SMS Provider is empty. | Set the SMS Provider in **Options**, or clear the site code. |
| An SMS Provider needs a site code. Enter it in Options. | Dialog **Inspect** and log | The SMS Provider is set and the site code is empty. | Enter the site code in **Options**. |
| The Configuration Manager console is not installed on this computer. Device Inspector reads the site with the ConfigurationManager PowerShell module, which comes only with the console. Install the console, then start Device Inspector again. | Message box **Device Inspector** at start | The module is not found. | Install the console. |
| Inspect: Site Only needs an SMS Provider. | Log. The status bar says "Set an SMS Provider in Options, or clear Site Only." | **Site Only** is on and the SMS Provider is empty. | Set the SMS Provider in **Options**, or clear **Site Only**. |
| The inspection failed. Check the SMS Provider, the site code and your account rights in Options. The log file has the reason. | Dialog **Inspect**. The log says "Inspect failed. The log file has the reason." The status bar says "Inspect failed. The log file has the reason." | The inspection stopped on an error that no part caught. | Select **Open Log File**, find the line "Inspect failed:" in the file, and read the reason. |

### Options dialog

**OK** in the Options dialog checks the SMS Provider and the site code. A wrong value opens a message box with the title **Device Inspector**, and the dialog stays open.

| Message | Cause | Fix |
|---|---|---|
| The SMS Provider is a computer name or an FQDN. | The SMS Provider holds another character. | Enter a computer name or an FQDN. |
| The site code is three letters or digits. | The site code has another form. | Enter three letters or digits. |
| A site code needs an SMS Provider. | A site code is set and the SMS Provider is empty. | Enter an SMS Provider, or clear the site code. |
| An SMS Provider needs a site code. Enter it in Options. | The SMS Provider is set and the site code is empty. | Enter the site code. |

### Problems

See [Problems panel](../core/problems.md) for the lines of the failed parts.

### Export

| Message | Where | Cause | Fix |
|---|---|---|---|
| The `<kind>` export failed. Check the folder and the file name. The log file has the reason. | Dialog **Export**. The log says "Export `<kind>` failed. The log file has the reason." | The file could not be written. | Choose a folder that your account can write to. |

### Command line

The script checks its input first and stops with the messages of the Inspect bar, joined into one line.

| Message | Cause | Fix |
|---|---|---|
| Enter the device name. Use letters, digits, dots, hyphens and underscores. | The device name has another form. | Use letters, digits, dots, hyphens and underscores. |
| The SMS Provider is a computer name or an FQDN. | `-SiteServer` holds another character. | Enter a computer name or an FQDN. |
| The site code is three letters or digits. | `-SiteCode` has another form. | Enter three letters or digits. |
| A site code needs an SMS Provider. | `-SiteCode` is set and `-SiteServer` is not. | Add `-SiteServer`, or remove `-SiteCode`. |
| An SMS Provider needs a site code. Enter it in Options. | `-SiteServer` is set and `-SiteCode` is not. | Add `-SiteCode`. The script has no Options dialog. |
| Nothing to inspect: SiteServer is omitted and SkipDevice is set. | `-SkipDevice` is set and `-SiteServer` is not. | Add `-SiteServer` and `-SiteCode`, or remove `-SkipDevice`. |

The report can also start with a warning of the ConfigurationManager module about a wildcard in the `Name` parameter. This is a known item. The warning does not stop the report.

## Steps

1. Find the message in the tables.
2. Do the fix.

## Limits

The window shows a fixed message for each failure. The tool writes the error text of the site and of WinRM to the log file only, and the Problem detail section of the exports holds the reason of a failed part. This page cannot list those texts.

## Troubleshooting

See [Troubleshooting](../troubleshooting.md).

## Links

None.
