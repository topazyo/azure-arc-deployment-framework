# Test-NetworkSecurityCompliance.ps1
# This script tests network security configurations against a defined baseline.
# V1 focuses on registry settings, basic service states, and IPv6 adapter binding checks.
# TODO: Expand checks for DNS (e.g., specific DNS servers, DoH configuration).
# TODO: Add more Local Security Policy checks related to network security beyond registry keys.

Function Test-NetworkSecurityCompliance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have networkSettings, localSecurityPolicy.networkSecurity

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Primarily for reporting context in V1

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestNetworkSecurityCompliance_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"

        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }

    Write-Log "Starting Test-NetworkSecurityCompliance on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Most checks are performed locally. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required for many network security compliance checks. Results may be incomplete or inaccurate if registry/CIM access is denied." -Level "ERROR"
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    $script:overallCompliant = $true # Use script scope for helper function to modify

    # Helper function to add check results
    function Add-CheckResult {
        param([string]$Name, [bool]$IsCompliant, [object]$Expected, [object]$Actual, [string]$Details, [string]$RemediationSuggestion = "")
        $check = [PSCustomObject]@{ Name = $Name; Compliant = $IsCompliant; Expected = $Expected; Actual = $Actual; Details = $Details; Remediation = $RemediationSuggestion }
        $allChecks.Add($check) | Out-Null
        if (-not $IsCompliant) { $script:overallCompliant = $false }
        Write-Log "Check '$Name': Compliant=$IsCompliant. Expected='$Expected', Actual='$Actual'. Details: $Details" -Level (if($IsCompliant){"DEBUG"}else{"WARNING"})
    }

    # Helper function to safely get registry values
    function Get-RegistryValueSafe {
        param([string]$RegPath, [string]$RegName)
        try {
            return (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction Stop).$RegName
        } catch {
            Write-Log "Registry value not found or error accessing '$RegPath'\'$RegName': $($_.Exception.Message)" -Level "DEBUG"
            return $null
        }
    }

    # --- Proxy Settings ---
    if ($BaselineSettings.PSObject.Properties['networkSettings'] -and $BaselineSettings.networkSettings.PSObject.Properties['proxy']) {
        $proxyBaseline = $BaselineSettings.networkSettings.proxy
        Write-Log "Checking Proxy Settings..."

        $regPathIESettings = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"

        if ($proxyBaseline.PSObject.Properties.Contains('useProxy')) {
            $expectedProxyEnable = if ([bool]$proxyBaseline.useProxy) { 1 } else { 0 }
            $currentProxyEnable = Get-RegistryValueSafe -RegPath $regPathIESettings -RegName "ProxyEnable"
            Add-CheckResult -Name "ProxyEnabled" -IsCompliant ($currentProxyEnable -eq $expectedProxyEnable) `
                -Expected $expectedProxyEnable -Actual $currentProxyEnable `
                -Details "$regPathIESettings\ProxyEnable" `
                -RemediationSuggestion "Configure ProxyEnable registry value to $expectedProxyEnable."
        }

        if ($proxyBaseline.useProxy -and $proxyBaseline.PSObject.Properties.Contains('proxyServer')) {
            $currentProxyServer = Get-RegistryValueSafe -RegPath $regPathIESettings -RegName "ProxyServer"
            Add-CheckResult -Name "ProxyServerAddress" -IsCompliant ($currentProxyServer -eq $proxyBaseline.proxyServer) `
                -Expected $proxyBaseline.proxyServer -Actual $currentProxyServer `
                -Details "$regPathIESettings\ProxyServer" `
                -RemediationSuggestion "Configure ProxyServer registry value to '$($proxyBaseline.proxyServer)'."
        }

        if ($proxyBaseline.useProxy -and $proxyBaseline.PSObject.Properties.Contains('bypassList')) {
            $expectedBypassStr = if ($proxyBaseline.bypassList -is [array]) { ($proxyBaseline.bypassList -join ';').TrimEnd(';') } else { $proxyBaseline.bypassList }
            $currentProxyOverride = Get-RegistryValueSafe -RegPath $regPathIESettings -RegName "ProxyOverride"
            Add-CheckResult -Name "ProxyBypassList" -IsCompliant ($currentProxyOverride -eq $expectedBypassStr) `
                -Expected $expectedBypassStr -Actual $currentProxyOverride `
                -Details "$regPathIESettings\ProxyOverride" `
                -RemediationSuggestion "Configure ProxyOverride registry value to '$expectedBypassStr'."
        }
    }

    # --- DNS Settings ---
    if ($BaselineSettings.PSObject.Properties['networkSettings'] -and $BaselineSettings.networkSettings.PSObject.Properties['dns']) {
        $dnsBaseline = $BaselineSettings.networkSettings.dns
        Write-Log "Checking DNS Settings..."
        if ($dnsBaseline.PSObject.Properties.Contains('dnsCache')) {
            $svc = Get-Service -Name "Dnscache" -ErrorAction SilentlyContinue
            $actualState = if($svc){$svc.Status.ToString()}else{"NotFound"} # Ensure string comparison
            $expectedState = if([bool]$dnsBaseline.dnsCache){"Running"}else{"Stopped"}
            Add-CheckResult -Name "DnsClientService (DnsCache)" -IsCompliant ($actualState -eq $expectedState) `
                -Expected $expectedState -Actual $actualState `
                -Details "Checks DnsClient (DNS Cache) service state." `
                -RemediationSuggestion "Configure DnsClient service to '$expectedState'."
        }
        if ($dnsBaseline.PSObject.Properties.Contains('preferIPv4')) {
            $regPathTcpip6Params = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
            $disabledComponents = Get-RegistryValueSafe -RegPath $regPathTcpip6Params -Name "DisabledComponents"
            $actualDisabledComponentsStr = if($null -ne $disabledComponents){"0x$($disabledComponents.ToString('X'))"}else{"NotSet"}
            $isCompliant = $false

            if ([bool]$dnsBaseline.preferIPv4) { # Baseline wants IPv4 preferred
                # Compliant if IPv6 is de-prioritized (0x20 bit set) OR if IPv6 is fully disabled (0xFF)
                $isCompliant = ($null -ne $disabledComponents -and (($disabledComponents -band 0x20) -eq 0x20 -or $disabledComponents -eq 0xFF))
                $expectedBehavior = "IPv6 de-prioritized (e.g., DisabledComponents bit 0x20 set) or IPv6 disabled (0xFF)"
            } else { # Baseline does NOT want IPv4 preferred (i.e., IPv6 should be fully enabled or default behavior)
                $isCompliant = ($null -eq $disabledComponents -or (($disabledComponents -band 0x20) -ne 0x20 -and $disabledComponents -ne 0xFF) )
                $expectedBehavior = "IPv6 fully enabled/default (e.g., DisabledComponents bit 0x20 NOT set and not 0xFF)"
            }
            Add-CheckResult -Name "PreferIPv4 (via IPv6 DisabledComponents)" -IsCompliant $isCompliant `
                -Expected $expectedBehavior -Actual $actualDisabledComponentsStr `
                -Details "Checks $regPathTcpip6Params\DisabledComponents." `
                -RemediationSuggestion "Adjust Tcpip6\Parameters\DisabledComponents registry key accordingly."
        }
    }

    # --- IPv6 Enabled Check ---
    if ($BaselineSettings.PSObject.Properties['networkSettings'] -and $BaselineSettings.networkSettings.PSObject.Properties['ipv6']) {
        $ipv6Baseline = $BaselineSettings.networkSettings.ipv6
        Write-Log "Checking IPv6 Enabled Status on active NICs..."
        if ($ipv6Baseline.PSObject.Properties.Contains('enabled')) {
            $expectedIPv6EnabledOverall = [bool]$ipv6Baseline.enabled
            $activeNetAdapters = Get-NetAdapter | Where-Object {$_.Status -eq 'Up' -and $_.ifIndex -ne 1} -ErrorAction SilentlyContinue
            $allAdaptersMatchBaseline = $true
            $ipv6BindingStatesDetails = [System.Collections.ArrayList]::new()

            if ($activeNetAdapters.Count -gt 0) {
                foreach($adapter in $activeNetAdapters){
                    try {
                        $binding = Get-NetAdapterBinding -InterfaceDescription $adapter.InterfaceDescription -ComponentID ms_tcpip6 -ErrorAction Stop
                        $isCurrentlyEnabled = $binding.Enabled
                        $ipv6BindingStatesDetails.Add("$($adapter.Name):$isCurrentlyEnabled") | Out-Null
                        if($isCurrentlyEnabled -ne $expectedIPv6EnabledOverall){ $allAdaptersMatchBaseline = $false }
                    } catch {
                        Write-Log "Could not get IPv6 binding for adapter '$($adapter.Name)'. Error: $($_.Exception.Message)" -Level "WARNING"
                        $ipv6BindingStatesDetails.Add("$($adapter.Name):ErrorGettingBinding") | Out-Null
                        $allAdaptersMatchBaseline = $false # Consider error as non-compliant
                    }
                }
            } else { Write-Log "No active non-loopback network adapters found to check IPv6 status." -Level "INFO"; $allAdaptersMatchBaseline = $true } # Vacuously true if no adapters to check against a disabling baseline

            $actualOverallState = if($activeNetAdapters.Count -eq 0 -and -not $expectedIPv6EnabledOverall) {"NoActiveAdapters_CompliantAsDisabledExpected"} elseif($activeNetAdapters.Count -eq 0) {"NoActiveAdapters"} else {$ipv6BindingStatesDetails -join "; "}
            Add-CheckResult -Name "IPv6_Enabled_On_Active_Adapters" -IsCompliant $allAdaptersMatchBaseline `
                -Expected $expectedIPv6EnabledOverall -Actual $actualOverallState `
                -Details "Checks (Get-NetAdapterBinding -ComponentID ms_tcpip6).Enabled on active non-loopback NICs." `
                -RemediationSuggestion "Ensure IPv6 binding is set to '$expectedIPv6EnabledOverall' on all active network adapters."
        }
    }

    # --- Local Security Policy - Network Security (Registry Keys) ---
    if ($BaselineSettings.PSObject.Properties['localSecurityPolicy'] -and $BaselineSettings.localSecurityPolicy.PSObject.Properties['networkSecurity']) {
        $lspNetSecBaseline = $BaselineSettings.localSecurityPolicy.networkSecurity
        Write-Log "Checking Local Security Policy - Network Security settings (via registry)..."

        $lsaRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
        if ($lspNetSecBaseline.PSObject.Properties.Contains('DoNotStoreLanManagerHash')) {
            $expectedVal = if([bool]$lspNetSecBaseline.DoNotStoreLanManagerHash){1}else{0}
            $actualVal = Get-RegistryValueSafe -RegPath $lsaRegPath -RegName "NoLMHash"
            Add-CheckResult "LSP_NoLMHash" ($actualVal -eq $expectedVal) $expectedVal $actualVal "$lsaRegPath\NoLMHash" "Set NoLMHash to $expectedVal."
        }
        if ($lspNetSecBaseline.PSObject.Properties.Contains('LanManagerAuthenticationLevel')) {
            $expectedVal = $lspNetSecBaseline.LanManagerAuthenticationLevel
            $actualVal = Get-RegistryValueSafe -RegPath $lsaRegPath -RegName "LmCompatibilityLevel"
            Add-CheckResult "LSP_LmCompatibilityLevel" ($actualVal -eq $expectedVal) $expectedVal $actualVal "$lsaRegPath\LmCompatibilityLevel" "Set LmCompatibilityLevel to $expectedVal."
        }

        if ($lspNetSecBaseline.PSObject.Properties.Contains('MinimumSessionSecurity_Client')) { # Example, baseline might define specific keys
            $regPathLsaMSV1_0 = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
            $expectedClientSec = $lspNetSecBaseline.MinimumSessionSecurity_Client # Assume this is the DWORD value, e.g., 0x20080000
            $actualClientSec = Get-RegistryValueSafe -RegPath $regPathLsaMSV1_0 -RegName "NtlmMinClientSec"
            Add-CheckResult "LSP_NtlmMinClientSec" ($actualClientSec -eq $expectedClientSec) ("0x{0:X8}" -f $expectedClientSec) ("0x{0:X8}" -f $actualClientSec) "$regPathLsaMSV1_0\NtlmMinClientSec" "Set NtlmMinClientSec to 0x$($expectedClientSec.ToString('X8'))."
        }
         if ($lspNetSecBaseline.PSObject.Properties.Contains('MinimumSessionSecurity_Server')) {
            $regPathLsaMSV1_0 = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
            $expectedServerSec = $lspNetSecBaseline.MinimumSessionSecurity_Server # Assume this is the DWORD value
            $actualServerSec = Get-RegistryValueSafe -RegPath $regPathLsaMSV1_0 -RegName "NtlmMinServerSec"
            Add-CheckResult "LSP_NtlmMinServerSec" ($actualServerSec -eq $expectedServerSec) ("0x{0:X8}" -f $expectedServerSec) ("0x{0:X8}" -f $actualServerSec) "$regPathLsaMSV1_0\NtlmMinServerSec" "Set NtlmMinServerSec to 0x$($expectedServerSec.ToString('X8'))."
        }
    }

    Write-Log "Test-NetworkSecurityCompliance script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $allChecks
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}
