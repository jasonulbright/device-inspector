# Device Inspector documentation

Device Inspector reads the facts of one device from a Configuration Manager site and from the device itself. The inspection only reads. The actions change the device or the site only when **Enable Actions** is on. This page links every page of the documentation.

## Start

- [Getting started](getting-started.md): install, set the site server, inspect the first device.

## Core

- [Inspect bar](core/inspect.md): the device name, the site server, Site Only, Inspect and the checks before a run.
- [Device List](core/device-list.md): find devices of the site by name or collection, and inspect one.
- [Device panel](core/device.md): the operating system, the client health and the site record.
- [Applications panel](core/applications.md): the uninstall keys of the device, live, with a filter and Uninstall and Repair.
- [Updates panel](core/updates.md): the updates that the site requires and the updates pending on the device.
- [Collections panel](core/collections.md): the collections of the device and the deployments that target them.
- [Problems panel](core/problems.md): the parts that failed, and what a failed part leaves.
- [Export](core/export.md): Export JSON and Export HTML.
- [Actions](core/actions.md): Enable Actions, the confirmation, the dry run, the action log, and each action.
- [Options dialog](core/options.md): the site server, the site code and About.
- [Command line](core/command-line.md): `Invoke-DeviceInspector.ps1`, its parameters and its output.

## Reference

- [Read-only design](reference/read-only-design.md): what the tool reads, how the inspection stays read only, how the actions are kept apart, and the limits.
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

The images in `docs/images` come from one command. Run it on a computer with PowerShell remoting to a lab workstation. The lab workstation needs the Configuration Manager console and an interactive session of the lab account. The command copies the tool there, runs the steps in that session through a scheduled task, and copies the images back. It replaces only the images that are already in `docs/images`. To also add a new image, add `-AddNew`. It stops and replaces no image when a step fails, when an image of the guide is missing, or when the run does not finish in `-Minutes` minutes (default 20). One capture runs at a time on a lab workstation: the command takes the lock file `C:\guide\capture.lock` and waits while another capture holds it (`-LockWaitMinutes`, default 90). It works in its own folder `C:\guide\device-inspector` and its own scheduled task. At the end, it removes the scheduled task, its folder and the lock. It never removes `C:\guide`.

```powershell
.\tools\guide-capture\Invoke-GuideCapture.ps1 -CredentialScript <credential script> -Target <lab workstation> -LogonUser <domain\account> -SmsProvider <site server> -SiteCode <site code> -Device <client device> -SecondDevice <server device>
```

The credential script sets `$LabCredential`. Keep it outside the repository. The images of the `-SecondDevice` server end with `-server`. `-UnreachableDevice` names a device that does not exist, for the images of an unreachable device. The default is `no-such-device`. The steps are in `tools/guide-capture/steps-guide.ps1` and `tools/guide-capture/steps-console-missing.ps1`.

The images of the uninstall menu need an MSI row with the Uninstall entry on. Add `-UninstallApp` with the name of such an application when the workstation lists the default (Microsoft Visual C++ 2022 X86 Minimum Runtime) as a system component. The capture never runs the uninstall: it chooses **Cancel**.

To retake a few images, add `-Section` with the names of the sections that make them, and `-Image` with the image names (without `.png`). Only the named sections run, and only the named images are copied. A section uses the state that the sections before it leave, so name every section that the images need, in the order of the steps file. The section `action menus` makes the uninstall images and needs an application row that the capture can uninstall: leave it out when the workstation has none. The script stops before it connects when a section name is wrong.
