$ValidationMatrix = @{
    Connectivity = @{
        Tests = @(
            @{
                Name = "Azure Management Endpoint"
                Test = { Test-NetConnection -ComputerName "management.azure.com" -Port 443 }
                ExpectedResult = { param($result) $result.TcpTestSucceeded }
            },
            @{
                Name = "Azure Identity Endpoint"
                Test = { Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443 }
                ExpectedResult = { param($result) $result.TcpTestSucceeded }
            }
        )
        Weight = 0.4
    }
    Security = @{
        Tests = @(
            @{
                Name = "TLS 1.2 Configuration"
                Test = { Test-TLSConfiguration }
                ExpectedResult = { param($result) $result.TLS12Enabled }
            },
            @{
                Name = "Certificate Validation"
                Test = { Test-CertificateTrust }
                ExpectedResult = { param($result) $result.IsValid }
            }
        )
        Weight = 0.3
    }
    Agent = @{
        Tests = @(
            @{
                Name = "Service Status"
                Test = { Get-Service -Name himds }
                ExpectedResult = { param($result) $result.Status -eq 'Running' }
            }
        )
        Weight = 0.3
    }
}