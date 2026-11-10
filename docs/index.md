# Device Inspector documentation

Device Inspector reads the facts of one device from a Configuration Manager site and from the device itself. It only reads. This page links every page of the documentation.

## Start

- [Getting started](getting-started.md): install, set the site server, inspect the first device.

## Core

- [Inspect bar](core/inspect.md): the device name, the site server, Site only, Inspect and the checks before a run.
- [Device panel](core/device.md): the operating system, the client health and the site record.
- [Applications panel](core/applications.md): the device list and the site inventory list, merged, with a filter.
- [Updates panel](core/updates.md): the updates that the site requires and the updates pending on the device.
- [Collections panel](core/collections.md): the collections of the device and the deployments that target them.
- [Problems panel](core/problems.md): the parts that failed, and what a failed part leaves.
- [Export](core/export.md): Export JSON and Export HTML.
- [Options dialog](core/options.md): the site server, the site code and About.
- [Command line](core/command-line.md): `Invoke-DeviceInspector.ps1`, its parameters and its output.

## Reference

- [Read-only design](reference/read-only-design.md): what the tool reads, why it cannot change anything, and its limits.
- [Data sources](reference/data-sources.md): the cmdlet or device read behind each fact, with the lab comparison.
- [Settings](reference/settings.md): every setting with its default and where it is stored.
- [Permissions](reference/permissions.md): the rights that each part needs.
- [Network](reference/network.md): every outbound call.
- [Files and logs](reference/files-and-logs.md): every folder and file that the tool writes.
- [Keyboard](reference/keyboard.md): the Tab order and the keys.
- [Error messages](reference/error-messages.md): message, cause and fix.
- [Glossary](reference/glossary.md): the terms of the tool.

## External references

- [External references](external-references.md): Microsoft Learn pages for each feature.

## Troubleshooting

- [Troubleshooting](troubleshooting.md): the most common messages with cause and fix.

## Retake the captures

The images in `docs/images` come from one command. Run it on a computer with PowerShell remoting to a lab workstation. The lab workstation needs the Configuration Manager console and an interactive session of the lab account. The command copies the tool there, runs the steps in that session through a scheduled task, and copies the images back. It stops and replaces no image when a step fails or an image is missing.

```powershell
.\tools\guide-capture\Invoke-GuideCapture.ps1 -CredentialScript <credential script> -Target <lab workstation> -LogonUser <domain\account> -SmsProvider <site server> -SiteCode <site code> -Device <client device> -SecondDevice <server device>
```

The credential script sets `$LabCredential`. Keep it outside the repository. The images of the server end with the lower-case name of `-SecondDevice`. The steps are in `tools/guide-capture/steps-guide.ps1` and `tools/guide-capture/steps-console-missing.ps1`.
