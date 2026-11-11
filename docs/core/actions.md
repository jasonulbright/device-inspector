# Actions

The actions change the device or the site. They are off until you turn on **Enable actions**.

## What it does

Each action follows the same steps:

1. You turn on **Enable actions** at the bottom of the sidebar. The switch is off at each start of the tool. The status bar shows "actions on" while it is on.
2. You select the action button.
3. A dialog names the action. A banner at the top shows the number of devices that the action targets, and their names.
4. You select **Run**, **Dry run** or **Cancel**. **Cancel** is the default button, so Enter and Esc change nothing.
5. The action runs in the background. **Dry run** reads the current state and lists the steps, and changes nothing.
6. Before a run, the tool writes a `STARTED` line to the action log. If it cannot write the line, the run does not start. The result goes to the window log, to the tool log and to the action log. A message shows the result.

## When to use it

- Use **Dry run** first, to see the steps and to check that the device answers.
- Use **Run** to make the change.

## Requirements

- An inspection that reached the device. With **Site only**, the device actions stay off.
- The rights in [Permissions](../reference/permissions.md). The tool uses the Windows account that runs it. It stores no password.

## Steps

### Update the client policy

The **Client policy update...** button is on the Device panel.

1. Turn on **Enable actions**.
2. Inspect the device.
3. On the Device panel, select **Client policy update...**.
4. Select **Dry run**. The log shows the client version and the two steps.
5. Select **Client policy update...** again, then **Run**.

The client requests machine policy from its management point (schedule `{00000000-0000-0000-0000-000000000021}`, Machine Policy Assignments Request) and then evaluates it (schedule `{00000000-0000-0000-0000-000000000022}`, Machine Policy Evaluation). This is the Machine Policy Retrieval and Evaluation Cycle of the client. The request returns at once. The client downloads and applies the policy in the next minutes.

### Start a full hardware inventory

The **Full hardware inventory...** button is on the Device panel. Use it when the site shows old or wrong hardware inventory for the device.

1. Turn on **Enable actions**.
2. Inspect the device.
3. On the Device panel, select **Full hardware inventory...**.
4. Select **Dry run**. The log shows the status record of hardware inventory on the device (last cycle, last report, report version) and the steps.
5. Select **Full hardware inventory...** again, then **Run**.

The tool deletes the `InventoryActionStatus` record of hardware inventory (`{00000000-0000-0000-0000-000000000001}`) in `root\ccm\invagt` on the device. Then it triggers the Hardware Inventory schedule. Without the record, the client sends a full report instead of a delta report, and the site replaces all hardware inventory of the device. When no record exists, the tool only triggers the schedule. When the delete fails, the tool does not trigger the schedule. The client log `InventoryAgent.log` shows the full report. The site shows the new inventory date after it processes the report. When hardware inventory is off in the client settings, the client sends no report.

### Repair a corrupt inventory

Each inspection with the site and the device runs an inventory check. The Device panel shows it in the group **Inventory check**.

| State | Meaning |
|---|---|
| **Current** | The hardware scan time of the site is not older than the start of the last hardware inventory cycle on the device, and the installed applications of the site inventory and of the device match. Both times are local clock times of the device. |
| **Corrupt** | The site inventory is current, but applications differ. The rows **Difference** name them. The **Problems** panel gets a line. |
| **NotCurrent** | The site has not processed the last hardware inventory cycle of the device yet. The check does not compare the applications. |
| **Unknown** | The site record, the client facts or a date is missing. |

An application on the device with an install date on or after the day of the last cycle does not count, because the next cycle reports it.

The check reads the hardware scan time from `SMS_G_System_WORKSTATION_STATUS`. The site stores it as the local clock time of the client, with no zone. The **Last hardware inventory** fact of the site record comes from `Get-CMDevice`. On the lab on 2026-11-11 it showed the date of an older report for hours after the site processed a new full report. The check does not use it.

The **Repair inventory...** button is on the Device panel. It is on only when the state is **Corrupt**.

1. Turn on **Enable actions**.
2. Inspect the device. The state is **Corrupt**.
3. Select **Repair inventory...**. The dialog shows the result of the check.
4. Select **Dry run**, then select **Repair inventory...** again and select **Run**.

The repair runs the same device steps as **Full hardware inventory**, under the action name `Corrupt-inventory repair`. Inspect the device again after the site processes the full report. The state is then **Current**.

## Options and settings of this page

| Control | Effect |
|---|---|
| **Enable actions** | Off: the tool only reads, and the action buttons are off. On: they turn on when an inspection reached the device. |
| **Run** | Makes the change. |
| **Dry run** | Reads the state and lists the steps. Changes nothing. |
| **Cancel** | Closes the dialog. Changes nothing. |

## The action log

The action log is `Logs\DeviceInspector-actions.log` in the script folder. The tool appends to it and never deletes it. It keeps every run and every dry run of every session. Each entry has one line with the UTC time, the account, the device, the action, the mode (`RUN` or `DRY RUN`), the outcome (`STARTED`, `OK` or `FAILED`) and a summary, then one indented line for each step. A line break in a field from the device becomes a space.

```text
2026-11-10T20:00:00Z | CONTOSO\admin1 | CLIENT01 | Client policy update | DRY RUN | OK | Dry run: the client answers. Nothing changed.
    Client version 5.00.9146.1009 answers.
    Dry run: would trigger Machine policy retrieval (Machine Policy Assignments Request) {00000000-0000-0000-0000-000000000021}.
    Dry run: would trigger Machine policy evaluation (Machine Policy Evaluation) {00000000-0000-0000-0000-000000000022}.
```

## Limits

- An action works on the device of the last inspection. Inspect again after you change the device name.
- A request to the client starts work on the client. The result of that work shows in a later inspection.

## Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| Cannot run the action on <device>: ... | WinRM to the device failed. On a run, a step can have run before the failure. | Check that the device is on and that your account is a local administrator on it. Inspect the device to see its state. |
| <step> failed. The earlier steps, if any, ran. | A method call on the client failed. | Read the step lines in the log. Read `PolicyAgent.log` on the device. |
| The action log cannot be written, so the run does not start. | The `Logs` folder is not writable. | Make the folder of the script writable. |
| The Configuration Manager client does not answer: ... | The client is not installed or its WMI namespace is broken. | Install or repair the client. |
| ... failed with return value <n>. | The client refused the request. | Read `PolicyAgent.log` on the device. |
| The hardware inventory status cannot be read: ... | WMI refused the read of `root\ccm\invagt`. | Check the rights on `root\ccm\invagt`. Repair the client. |
| The hardware inventory status record cannot be deleted. The schedule was not triggered. | WMI refused the delete. | Check the rights on `root\ccm\invagt`. Read `InventoryAgent.log`. |
| The cycle did not start (return value <n>). | The client refused the trigger after the delete. | Read `InventoryAgent.log` on the device. The next scheduled cycle sends a full report. |
| The status record is deleted, but the cycle did not start. | The trigger failed after the delete. | Wait for the next scheduled cycle. It sends a full report. Or run the action again. |

## Links

- [TriggerSchedule Method in Class SMS_Client](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/client-classes/triggerschedule-method-in-class-sms_client): Lists the schedule IDs that the actions use.
- [How to manage clients in Configuration Manager](https://learn.microsoft.com/intune/configmgr/core/clients/manage/manage-clients#start-policy-retrieval): Describes policy retrieval.
- [How to Reset the Hardware Inventory Cache](https://learn.microsoft.com/intune/configmgr/develop/core/clients/inventory/how-to-reset-the-hardware-inventory-cache): Describes the delete of the status record.
- [InventoryActionStatus Client WMI Class](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/client-classes/inventoryactionstatus-client-wmi-class): Lists the properties of the status record.
- [Hardware inventory views in Configuration Manager](https://learn.microsoft.com/intune/configmgr/develop/core/understand/sqlviews/hardware-inventory-views-configuration-manager): Describes the Add Remove Programs inventory that the check compares.
