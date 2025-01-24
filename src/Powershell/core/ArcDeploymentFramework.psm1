# Module manifest
@{
    ModuleVersion = '1.0.0'
    GUID = 'newly-generated-guid'
    Author = 'Your Name'
    Description = 'Azure Arc Deployment and Troubleshooting Framework'
    PowerShellVersion = '5.1'
    RequiredModules = @(
        @{ModuleName='Az.ConnectedMachine'; ModuleVersion='0.4.0'},
        @{ModuleName='Az.Accounts'; ModuleVersion='2.7.0'}
    )
    FunctionsToExport = @(
        'Test-ArcPrerequisites',
        'Deploy-ArcAgent',
        'Start-ArcDiagnostics',
        'Invoke-ArcAnalysis',
        'Start-ArcRemediation',
        'Start-AIEnhancedTroubleshooting'
    )
}