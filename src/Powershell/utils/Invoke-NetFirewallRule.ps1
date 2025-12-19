function Invoke-GetNetFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
}

function Invoke-NewNetFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Params
    )

    New-NetFirewallRule @Params -ErrorAction Stop
}

function Invoke-SetNetFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Params
    )

    Set-NetFirewallRule @Params -ErrorAction Stop
}
