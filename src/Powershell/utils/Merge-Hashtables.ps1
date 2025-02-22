function Merge-Hashtables {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Original,
        [Parameter(Mandatory)]
        [hashtable]$Update,
        [Parameter()]
        [switch]$PreserveOriginal,
        [Parameter()]
        [switch]$Deep
    )

    $result = if ($PreserveOriginal) { 
        $Original.Clone() 
    } 
    else { 
        $Original 
    }

    foreach ($key in $Update.Keys) {
        $updateValue = $Update[$key]

        if ($Deep -and 
            $updateValue -is [hashtable] -and 
            $result.ContainsKey($key) -and 
            $result[$key] -is [hashtable]) {
            # Recursive merge for nested hashtables
            $result[$key] = Merge-Hashtables `
                -Original $result[$key] `
                -Update $updateValue `
                -PreserveOriginal:$PreserveOriginal `
                -Deep
        }
        else {
            $result[$key] = $updateValue
        }
    }

    return $result
}