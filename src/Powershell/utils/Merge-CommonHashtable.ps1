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
