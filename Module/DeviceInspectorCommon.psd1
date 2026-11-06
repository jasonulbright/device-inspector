@{
    RootModule        = 'DeviceInspectorCommon.psm1'
    ModuleVersion     = '2026.11.06.0003'
    GUID              = '5b0d6f0e-6f6c-4c52-9a53-3a0d2f4c9b11'
    Author            = 'Jason Ulbright'
    Description       = 'Read-only inspection of one device: Configuration Manager site facts plus facts from the device itself.'
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