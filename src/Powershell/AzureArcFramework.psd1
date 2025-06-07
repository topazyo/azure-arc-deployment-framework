@{
    RootModule = 'AzureArcFramework.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'newly-generated-guid'
    Author = 'Your Name'
    CompanyName = 'Your Company'
    Copyright = '(c) 2024 Your Company. All rights reserved.'
    Description = 'Azure Arc Deployment and Management Framework'
    PowerShellVersion = '5.1'
    
    # Required Modules
    RequiredModules = @(
        @{ModuleName='Az.Accounts'; ModuleVersion='2.7.0'},
        @{ModuleName='Az.ConnectedMachine'; ModuleVersion='0.4.0'},
        @{ModuleName='Az.Monitor'; ModuleVersion='3.0.0'}
    )

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
        'Merge-Hashtables'
    )

    # Variables to export
    VariablesToExport = @()

    # Aliases to export
    AliasesToExport = @()

    # Private data
    PrivateData = @{
        PSData = @{
            Tags = @('Azure', 'Arc', 'Deployment', 'Management', 'AI', 'Monitoring')
            LicenseUri = 'https://github.com/yourusername/azure-arc-framework/blob/main/LICENSE'
            ProjectUri = 'https://github.com/yourusername/azure-arc-framework'
            ReleaseNotes = 'Initial release of Azure Arc Framework'
        }
    }
}