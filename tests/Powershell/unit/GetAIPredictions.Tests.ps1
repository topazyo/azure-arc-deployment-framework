# tests/Powershell/unit/GetAIPredictions.Tests.ps1
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

class FakeOnnxResult {
    [string]$ValueType = 'Tensor'
    [string]$ElementType = 'System.Single'
    [float[]]$Data
    FakeOnnxResult([float[]]$data) { $this.Data = $data }
    [object] AsTensor() { return $this.Data }
}

class FakeOnnxSession {
    [hashtable]$InputMetadata
    FakeOnnxSession() { $this.InputMetadata = @{ input0 = @{ shape = @(1,2) } } }
    [object[]] Run([object]$inputs) { return @([FakeOnnxResult]::new(@(0.2, 0.8))) }
}

Describe 'Get-AIPredictions.ps1' {
    BeforeAll {
        $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        $script:ScriptPath_Predictions = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\AI\Get-AIPredictions.ps1'))
        if (-not (Test-Path $script:ScriptPath_Predictions -PathType Leaf)) { throw "Script not found at $script:ScriptPath_Predictions" }
        . $script:ScriptPath_Predictions
    }

    AfterAll {
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'pred.log') -ErrorAction SilentlyContinue
    }

    It 'maps ordered features, defaults missing, and applies class labels for ONNX' {
        . $script:ScriptPath_Predictions
        $logPath = Join-Path $script:TestScriptRootSafe 'pred.log'
        $model = [FakeOnnxSession]::new()
        $features = @([pscustomobject]@{ f1 = 1 })
        $schema = @{ f1 = @{ default = 0 }; f2 = @{ default = 5 } }
        $result = Get-AIPredictions -InputFeatures $features -ModelObject $model -ModelType 'ONNX' -OnnxFeatureOrder @('f1','f2') -FeatureSchema $schema -ClassLabels @('Healthy','Unhealthy') -LogPath $logPath

        $result.Count | Should -Be 1
        $result[0].Status | Should -Be 'Success'
        $result[0].Prediction | Should -Be 'Unhealthy'
        $result[0].Probability | Should -BeGreaterThan 0.79
        $result[0].Probability | Should -BeLessThan 0.81
    }

    It 'uses Predict() on CustomPSObject model when available' {
        . $script:ScriptPath_Predictions
        $model = New-Object PSObject
        $model | Add-Member -MemberType ScriptMethod -Name Predict -Value { param($item) @{ Prediction = 'OK'; Probability = 0.61 } }
        $features = @([pscustomobject]@{ a = 1 })
        $result = Get-AIPredictions -InputFeatures $features -ModelObject $model -ModelType 'CustomPSObject'

        $result.Count | Should -Be 1
        $result[0].Status | Should -Be 'Success'
        $result[0].Prediction | Should -Be 'OK'
        $result[0].Probability | Should -Be 0.61
    }
}
