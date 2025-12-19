@{
    RootModule = 'AzureArcFramework.psm1'
    ModuleVersion = '1.0.0'
    GUID = '9890992f-6a97-4ba0-8ae5-415caa81eaba'
    Author = 'Project Contributor'
    CompanyName = 'Community Project'
    Copyright = '(c) 2024 Your Company. All rights reserved.'
    Description = 'Azure Arc Deployment and Management Framework'
    PowerShellVersion = '5.1'
    
    # NOTE: Az.* dependencies are imported on-demand by cmdlets that need them.
    # Keeping this empty allows unit tests and lightweight environments to import the module.
    RequiredModules = @()

    # Functions to export
    FunctionsToExport = @(
        # Core Functions
        'Initialize-ArcDeployment',
        'New-ArcDeployment',
        'Start-ArcTroubleshooter',
        'Test-ArcPrerequisites',
        'Deploy-ArcAgent',
        'Start-ArcDiagnostics',
        'Invoke-ArcAnalysis',
        'Start-ArcRemediation',
        'Test-DeploymentHealth',

        # AI Functions
        'Start-AIEnhancedTroubleshooting',
        'Invoke-AIPatternAnalysis',
        'Get-PredictiveInsights',

        # Utility Functions
        'Write-Log',
        'New-RetryBlock',
        'Convert-ErrorToObject',
        'Test-Connectivity',
        'Merge-CommonHashtable'
    )

    # Variables to export
    VariablesToExport = @()

    # Aliases to export
    AliasesToExport = @()

    # Private data
    PrivateData = @{
        PSData = @{
            Tags = @('Azure', 'Arc', 'Deployment', 'Management', 'AI', 'Monitoring')
            LicenseUri = 'https://github.com/project-owner/azure-arc-framework/blob/main/LICENSE'
            ProjectUri = 'https://github.com/project-owner/azure-arc-framework'
            ReleaseNotes = 'Initial release of Azure Arc Framework'
        }
    }
}