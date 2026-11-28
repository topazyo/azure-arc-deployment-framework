# tests/Powershell/unit/New-ArcDeployment.SecretHandling.Tests.ps1
#
# AR-01: New-ArcDeployment must never turn the service principal secret into plain
# text. The command it returns and displays carries an inert placeholder instead.
#
# This file dot-sources only core/New-ArcDeployment.ps1. It imports no module, so
# nothing is written to ProgramData or the host.

Describe 'New-ArcDeployment service principal secret handling' {
    BeforeAll {
        . "$PSScriptRoot/../../../src/Powershell/core/New-ArcDeployment.ps1"

        # Low-entropy sentinel: unique enough to search for, useless as a credential.
        $script:SecretSentinel = 'arcws0-sentinel-value'
        $script:SecretPattern = [regex]::Escape($script:SecretSentinel)
        $script:SecretPlaceholder = '<SERVICE_PRINCIPAL_SECRET>'
        $script:AppId = 'sp-app-id-0000'

        $script:BaseParams = @{
            ServerName        = 'SERVER-SP-01'
            ResourceGroupName = 'arc-rg'
            SubscriptionId    = '<subscription-id>'
            Location          = 'eastus'
            TenantId          = '<tenant-id>'
            AzcmagentPath     = 'azcmagent'
        }

        # Keep the Az.Accounts soft check from reaching Write-Error, which terminates
        # under the ErrorActionPreference=Stop that GitHub Actions sets for pwsh steps.
        Mock Get-Module { [pscustomobject]@{ Name = 'Az.Accounts' } } -ParameterFilter { $Name -contains 'Az.Accounts' }
    }

    Context 'when called with <Mode>' -ForEach @(
        @{ Mode = 'WhatIf'; Switches = @{ WhatIf = $true } }
        @{ Mode = 'ConfirmFalse'; Switches = @{ Confirm = $false } }
    ) {
        BeforeAll {
            $params = $script:BaseParams.Clone()
            $params.ServicePrincipalAppId = $script:AppId
            $params.ServicePrincipalSecret = ConvertTo-SecureString -String $script:SecretSentinel -AsPlainText -Force
            foreach ($key in $Switches.Keys) {
                $params[$key] = $Switches[$key]
            }

            # Emit debug records too, so stream 5 is actually observed.
            $DebugPreference = 'Continue'
            $infoRecords = $null
            $warningRecords = $null
            $captured = New-ArcDeployment @params -Verbose `
                -InformationVariable infoRecords -InformationAction SilentlyContinue `
                -WarningVariable warningRecords -WarningAction SilentlyContinue 4>&1 5>&1
            $DebugPreference = 'SilentlyContinue'

            $result = @($captured | Where-Object { $_.PSObject.Properties.Name -contains 'OnboardingCommand' })
            $verboseText = @($captured | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message }) -join "`n"
            $debugText = @($captured | Where-Object { $_ -is [System.Management.Automation.DebugRecord] } | ForEach-Object { $_.Message }) -join "`n"
            $warningText = @($warningRecords | ForEach-Object { $_.Message }) -join "`n"
            $informationText = @($infoRecords | ForEach-Object { [string]$_.MessageData }) -join "`n"
        }

        It 'returns exactly one deployment record' {
            $result.Count | Should -Be 1
        }

        It 'does not put the secret in OnboardingCommand' {
            $result[0].OnboardingCommand | Should -Not -Match $script:SecretPattern
        }

        It 'does not put the secret in the serialized result' {
            ($result[0] | ConvertTo-Json -Depth 5) | Should -Not -Match $script:SecretPattern
        }

        It 'does not write the secret to the information stream' {
            # The stream must carry the command, or this check would be vacuous.
            $informationText | Should -Match 'connect --resource-group'
            $informationText | Should -Not -Match $script:SecretPattern
        }

        It 'does not write the secret to the verbose, warning or debug streams' {
            # Verbose and warning capture must work, or these checks would be vacuous.
            $verboseText | Should -Match 'SERVER-SP-01'
            $verboseText | Should -Not -Match $script:SecretPattern
            $warningText | Should -Not -BeNullOrEmpty
            $warningText | Should -Not -Match $script:SecretPattern
            # The function writes no debug records today; this guards future additions.
            $debugText | Should -Not -Match $script:SecretPattern
        }

        It 'keeps the service principal id in OnboardingCommand' {
            $result[0].OnboardingCommand | Should -BeLike ('*--service-principal-id "{0}"*' -f $script:AppId)
        }

        It 'puts the placeholder in OnboardingCommand' {
            $result[0].OnboardingCommand | Should -BeLike ('*--service-principal-secret "{0}"*' -f $script:SecretPlaceholder)
        }
    }

    It 'rejects a service principal app id without a secret' {
        $params = $script:BaseParams.Clone()
        { New-ArcDeployment @params -ServicePrincipalAppId $script:AppId -Confirm:$false } |
            Should -Throw '*Both ServicePrincipalAppId and ServicePrincipalSecret must be provided*'
    }

    It 'rejects a service principal secret without an app id' {
        $params = $script:BaseParams.Clone()
        $secret = ConvertTo-SecureString -String $script:SecretSentinel -AsPlainText -Force
        { New-ArcDeployment @params -ServicePrincipalSecret $secret -Confirm:$false } |
            Should -Throw '*Both ServicePrincipalAppId and ServicePrincipalSecret must be provided*'
    }

    It 'adds no service principal arguments when the app id is blank and no secret is given' {
        $params = $script:BaseParams.Clone()
        $result = New-ArcDeployment @params -ServicePrincipalAppId ' ' -Confirm:$false `
            -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $result.OnboardingCommand | Should -Not -BeLike '*--service-principal-*'
    }

    It 'contains no SecureString-to-plaintext conversion' {
        $sourcePath = Join-Path $PSScriptRoot '../../../src/Powershell/core/New-ArcDeployment.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Resolve-Path -LiteralPath $sourcePath).ProviderPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty

        $function = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-ArcDeployment'
            }, $true)
        $function | Should -Not -BeNullOrEmpty

        $commandNames = @($function.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { $_.GetCommandName() })
        $commandNames | Should -Not -Contain 'ConvertFrom-SecureString'

        $memberNames = @($function.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.MemberExpressionAst]
                }, $true) | ForEach-Object { $_.Member.Extent.Text })
        foreach ($forbidden in @(
                'SecureStringToBSTR', 'SecureStringToGlobalAllocUnicode', 'SecureStringToCoTaskMemUnicode',
                'PtrToStringBSTR', 'PtrToStringAuto', 'PtrToStringUni', 'PtrToStringAnsi', 'GetNetworkCredential')) {
            $memberNames | Should -Not -Contain $forbidden
        }

        # [NetworkCredential]::new('', $s).Password and New-Object NetworkCredential
        # also expose the plain text, so the type may not be named at all.
        $typeNames = @($function.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TypeExpressionAst] -or
                    $node -is [System.Management.Automation.Language.TypeConstraintAst]
                }, $true) | ForEach-Object { $_.TypeName.FullName })
        $typeNames | Where-Object { $_ -like '*NetworkCredential' } | Should -BeNullOrEmpty
        $stringValues = @($function.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | ForEach-Object { $_.Value })
        $stringValues | Where-Object { $_ -like '*NetworkCredential' } | Should -BeNullOrEmpty
    }
}
