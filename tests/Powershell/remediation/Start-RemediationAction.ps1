param([pscustomobject]$ApprovedAction,[string]$LogPath) return [pscustomobject]@{ RemediationActionId = $ApprovedAction.RemediationActionId; Status = 'Success'; Output = 'ok'; Errors = '' }
