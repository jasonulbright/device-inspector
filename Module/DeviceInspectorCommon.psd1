@{
    RootModule        = 'DeviceInspectorCommon.psm1'
    ModuleVersion     = '2026.11.10.0007'
    GUID              = '5b0d6f0e-6f6c-4c52-9a53-3a0d2f4c9b11'
    Author            = 'Jason Ulbright'
    Description       = 'Inspection of one device: Configuration Manager site facts plus facts from the device itself. Optional actions with a dry run and an action log.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        # Logging and settings come from the vendored SuiteCommon module
        # (Lib\SuiteCommon), imported globally by the root module.

        # Inspection
        'Get-DeviceInspection'
        'ConvertTo-DeviceInspectionReport'

        # Window support
        'Test-DeviceInspectorInput'
        'Test-DeviceInspectorConsole'
        'ConvertTo-DeviceInspectionFactRow'
        'ConvertTo-DeviceInspectionApplicationRow'
        'ConvertTo-DeviceInspectionUpdateRow'
        'ConvertTo-DeviceInspectionCollectionRow'
        'ConvertTo-DeviceInspectionDeploymentRow'
        'ConvertTo-DeviceInspectionJson'
        'ConvertTo-DeviceInspectionHtml'
        'Write-DeviceInspectionFile'
        'Write-DeviceInspectionFullLog'
        'Test-DeviceInspectionInventory'
        'Get-DeviceInspectorActionBlock'
        'Get-DeviceInspectorCollectionList'
        'Select-DeviceInspectorAddableCollection'
        'Get-DeviceInspectorDeviceList'
        'Invoke-DeviceInspectorPolicyUpdate'
        'Invoke-DeviceInspectorFullInventory'
        'Invoke-DeviceInspectorInventoryRepair'
        'Invoke-DeviceInspectorUpdateInstall'
        'Invoke-DeviceInspectorApplicationAction'
        'Invoke-DeviceInspectorCollectionChange'
        'ConvertTo-DeviceInspectorActionText'
        'Write-DeviceInspectorActionLog'
        'New-DeviceInspectorActionRecord'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('ConfigMgr', 'Inventory', 'Device', 'ReadOnly', 'Report', 'Pester')
            LicenseUri = 'https://github.com/jasonulbright/device-inspector/blob/main/LICENSE'
            ProjectUri = 'https://github.com/jasonulbright/device-inspector'
        }
    }
}