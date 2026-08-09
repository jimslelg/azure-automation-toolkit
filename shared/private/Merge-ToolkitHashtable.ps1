function Merge-ToolkitHashtable {
    # Internal: recursive deep-merge used by Get-ToolkitConfig for environment
    # overlays. Overlay values win; nested hashtables merge key by key; the inputs
    # are not mutated.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory transformation; nothing external changes state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Base,

        [Parameter(Mandatory)]
        [hashtable]$Overlay
    )

    $result = $Base.Clone()
    foreach ($key in $Overlay.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Overlay[$key] -is [hashtable]) {
            $result[$key] = Merge-ToolkitHashtable -Base $result[$key] -Overlay $Overlay[$key]
        }
        else {
            $result[$key] = $Overlay[$key]
        }
    }
    return $result
}
