# Scope, read-only design and limits

## What the tool reads

| Source | Facts |
|---|---|
| Site (SMS Provider, `SELECT` queries only) | Device record (resource ID, client installed, client version, active, operating system, last logon user). Last hardware inventory date. Installed applications from hardware inventory (32-bit and 64-bit). Collection memberships with collection names. Deployments targeted at those collections. Updates that the site lists as required for the device. |
| The device (one WinRM script block) | Operating system (caption, version, build, architecture, last boot). Client health (`CcmExec` service state and start mode, client version, assigned site code, current management point, last hardware inventory cycle, last discovery data cycle). Installed applications from the uninstall registry keys. Client application policy (`CCM_Application`). Pending updates in the client policy (`CCM_SoftwareUpdate`). |

Two "last hardware inventory" values exist on purpose. The site value is the scan date that the site stored. The device value is the start time of the last hardware inventory cycle on the client. They can differ.

## Read-only design

- The only path to the site is the private function `Invoke-SiteQuery`. It refuses every query that does not start with `SELECT`.
- The device block calls `Get-CimInstance` and `Get-ItemProperty` and no write command.
- A Pester test parses the module with the PowerShell parser and fails if the module calls a command from a list of state-changing commands. A second test does the same for the window script.
- The computer name is validated by pattern. Collection IDs from the site are checked against `^[A-Za-z0-9]{8}$` before they enter a query.
- The only files the tool writes are its log files, its settings files and the exports that the person names.
- The tool uses the permissions of the Windows account that runs it. It stores no password.

## Layout for later actions

This release has no action that changes the site or the device. The window keeps room for them:

- The **Enable actions** switch in the sidebar is disabled.
- The right-click menus of the Applications, Updates and Collections grids hold disabled entries: Uninstall, Repair, Install pending updates, Remove from collection, Add to collection.

Each later action will follow the rules of the suite: off until Enable actions is on, a confirmation before each change, a dry run, and a record in an action log.

## Known limits

- The tool shows deployments that target a collection of the device. It does not show the per-device result of each deployment.
- The site inventory list depends on the hardware inventory classes `Add Remove Programs` and `Add Remove Programs (64)`. The classes must be enabled in the client settings.
- The device list reads the machine-wide uninstall keys only. Per-user installs are not listed.
- A device name that has several resource records in the site uses the first record and adds a problem line.
- The updates that the site lists as required come from the update compliance status of the site. They can lag the state on the device.
