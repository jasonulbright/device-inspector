# External references

This page lists the Microsoft Learn pages for each feature of Device Inspector. Each link was opened and checked on 2026-11-06. The same links are in the Links section at the end of each page.

## Core features

### [Getting started](getting-started.md)

- [Introduction to Configuration Manager](https://learn.microsoft.com/intune/configmgr/core/understand/introduction): Explains the site and its clients.
- [Fundamentals of role-based administration](https://learn.microsoft.com/intune/configmgr/core/understand/fundamentals-of-role-based-administration): Describes the security roles, including Read-only Analyst.

### [Inspect bar](core/inspect.md)

- [Windows Remote Management](https://learn.microsoft.com/windows/win32/winrm/portal): Describes WinRM, which the tool uses for the device.

### [Device list](core/device-list.md)

- [Get-CMDevice](https://learn.microsoft.com/powershell/module/configurationmanager/get-cmdevice): Describes the device read and its name wildcards.
- [Get-CMCollectionMember](https://learn.microsoft.com/powershell/module/configurationmanager/get-cmcollectionmember): Describes the member read of a collection.

### [Device panel](core/device.md)

- [How to monitor clients in Configuration Manager](https://learn.microsoft.com/intune/configmgr/core/clients/manage/monitor-clients): Explains how the site judges client health.
- [SMS_G_System_WORKSTATION_STATUS Server WMI Class](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/manage/sms_g_system_workstation_status-server-wmi-class): Describes `LastHardwareScan`, the source of the Last hardware inventory fact. The page does not state the zone of the value.
- [Get-CMDevice](https://learn.microsoft.com/powershell/module/configurationmanager/get-cmdevice): Describes the device record. The page does not explain why its `LastHardwareScan` can lag.

### [Applications panel](core/applications.md)

- [How to configure hardware inventory](https://learn.microsoft.com/intune/configmgr/core/clients/manage/inventory/configure-hardware-inventory): Describes how to enable inventory classes.

### [Updates panel](core/updates.md)

- [Monitor software updates](https://learn.microsoft.com/intune/configmgr/sum/deploy-use/monitor-software-updates): Describes how the site reports update compliance.

### [Actions](core/actions.md)

- [TriggerSchedule Method in Class SMS_Client](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/client-classes/triggerschedule-method-in-class-sms_client): Lists the schedule IDs that the actions use.
- [How to manage clients in Configuration Manager](https://learn.microsoft.com/intune/configmgr/core/clients/manage/manage-clients#start-policy-retrieval): Describes policy retrieval.
- [How to Reset the Hardware Inventory Cache](https://learn.microsoft.com/intune/configmgr/develop/core/clients/inventory/how-to-reset-the-hardware-inventory-cache): Describes the delete of the status record.
- [InventoryActionStatus Client WMI Class](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/client-classes/inventoryactionstatus-client-wmi-class): Lists the properties of the status record.
- [InstallUpdates Method in Class CCM_SoftwareUpdatesManager](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/sdk/installupdates-method-in-class-ccm_softwareupdatesmanager): Describes the install request.
- [CCM_SoftwareUpdate Client WMI Class](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/sdk/ccm_softwareupdate-client-wmi-class): Lists ComplianceState and EvaluationState.
- [Command-Line Options](https://learn.microsoft.com/windows/win32/msi/command-line-options): Describes `/x` and `/i` with a product code. It says that `/f` ignores properties on the command line.
- [Standard Installer Command-Line Options](https://learn.microsoft.com/windows/win32/msi/standard-installer-command-line-options): Describes `/quiet` and `/norestart`.
- [Reboot property](https://learn.microsoft.com/windows/win32/msi/reboot): Describes `ReallySuppress`.
- [REINSTALL property](https://learn.microsoft.com/windows/win32/msi/reinstall) and [REINSTALLMODE property](https://learn.microsoft.com/windows/win32/msi/reinstallmode): Describe a repair with `REINSTALL=ALL` and `omus`.
- [Windows Installer error codes](https://learn.microsoft.com/windows/win32/msi/error-codes): Lists the exit codes 0, 1605, 1618, 1641 and 3010.
- [Uninstall registry key](https://learn.microsoft.com/windows/win32/msi/uninstall-registry-key): Describes the key that is named by the product code.
- [Create application scripts for VM Applications](https://learn.microsoft.com/azure/virtual-machines/vm-applications-create-app-scripts): Shows the use of `QuietUninstallString` and of `msiexec /x {GUID} /qn /norestart`.
- [Add-CMDeviceCollectionDirectMembershipRule](https://learn.microsoft.com/powershell/module/configurationmanager/add-cmdevicecollectiondirectmembershiprule): Describes the new direct rule.
- [Get-CMDeviceCollection](https://learn.microsoft.com/powershell/module/configurationmanager/get-cmdevicecollection): Describes the collection list of the browser.
- [Remove-CMDeviceCollectionDirectMembershipRule](https://learn.microsoft.com/powershell/module/configurationmanager/remove-cmdevicecollectiondirectmembershiprule): Describes the removal of a direct rule.
- [Invoke-CMClientAction](https://learn.microsoft.com/powershell/module/configurationmanager/invoke-cmclientaction): Describes the client notification.
- [SMS_FullCollectionMembership Server WMI Class](https://learn.microsoft.com/intune/configmgr/develop/reference/core/clients/collections/sms_fullcollectionmembership-server-wmi-class): Describes `IsDirect`.
- [Hardware inventory views in Configuration Manager](https://learn.microsoft.com/intune/configmgr/develop/core/understand/sqlviews/hardware-inventory-views-configuration-manager): Describes the Add Remove Programs inventory that the check compares.

### [Collections panel](core/collections.md)

- [Introduction to collections](https://learn.microsoft.com/intune/configmgr/core/clients/manage/collections/introduction-to-collections): Explains device collections and their members.

### [Problems panel](core/problems.md) and [Command line](core/command-line.md)

- [about_Remote_Troubleshooting](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_remote_troubleshooting): Describes how to fix remoting errors.

### [Options dialog](core/options.md) and [Getting started](getting-started.md)

- [Install consoles](https://learn.microsoft.com/intune/configmgr/core/servers/deploy/install/install-consoles): Describes how to install the Configuration Manager console.


- [Plan for the SMS Provider](https://learn.microsoft.com/intune/configmgr/core/plan-design/hierarchy/plan-for-the-sms-provider): Explains what the SMS Provider is.

## Reference

### [Permissions](reference/permissions.md)

- [Fundamentals of role-based administration](https://learn.microsoft.com/intune/configmgr/core/understand/fundamentals-of-role-based-administration): Describes the security roles and scopes.

### [Network](reference/network.md)

- [Windows Remote Management](https://learn.microsoft.com/windows/win32/winrm/portal): Describes WinRM and its ports.

### [Read-only design](reference/read-only-design.md)

- [Get-CimInstance](https://learn.microsoft.com/powershell/module/cimcmdlets/get-ciminstance): Describes the read command that the tool uses on the device.
