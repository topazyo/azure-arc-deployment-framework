<#
.SYNOPSIS
Merges an update hashtable into an existing hashtable clone.

.DESCRIPTION
Creates a clone of the original hashtable, applies the update values by key, and
returns the merged result without mutating the original input.

.PARAMETER Original
Source hashtable to clone.

.PARAMETER Update
Hashtable containing the new or replacement values.

.OUTPUTS
Hashtable

.EXAMPLE
Merge-CommonHashtable -Original @{ Name = 'Arc'; Enabled = $true } -Update @{ Enabled = $false }
#>
function Merge-CommonHashtable {
    param (
        [hashtable]$Original,
        [hashtable]$Update
    )

    $result = $Original.Clone()
    foreach ($key in $Update.Keys) {
        $result[$key] = $Update[$key]
    }
    return $result
}
