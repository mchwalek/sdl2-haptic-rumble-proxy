# Minimal PE reader: architecture, export table (with forwarders) and import table.
# Dot-source this file: . "$PSScriptRoot\pe.ps1"

function Read-PeFile([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 0x40 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw "Not a PE file: $Path" }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -lt 0 -or $pe + 24 -gt $b.Length -or [BitConverter]::ToUInt32($b, $pe) -ne 0x4550) { throw "Not a PE file: $Path" }
    $machine = [BitConverter]::ToUInt16($b, $pe + 4)
    $nSections = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt = $pe + 24
    $is64 = [BitConverter]::ToUInt16($b, $opt) -eq 0x20B
    $dirs = $opt + $(if ($is64) { 112 } else { 96 })
    $sections = for ($i = 0; $i -lt $nSections; $i++) {
        $s = $opt + $optSize + 40 * $i
        [pscustomobject]@{
            VA = [BitConverter]::ToUInt32($b, $s + 12)
            Size = [Math]::Max([BitConverter]::ToUInt32($b, $s + 8), [BitConverter]::ToUInt32($b, $s + 16))
            Raw = [BitConverter]::ToUInt32($b, $s + 20)
        }
    }
    [pscustomobject]@{
        Path = $Path; Bytes = $b; Is64 = $is64; Sections = $sections; Dirs = $dirs
        Arch = switch ($machine) { 0x14C { 'x86' } 0x8664 { 'x64' } 0xAA64 { 'arm64' } default { '0x{0:X}' -f $machine } }
    }
}

function ConvertTo-PeOffset($Pe, [uint32]$Rva) {
    foreach ($s in $Pe.Sections) {
        if ($Rva -ge $s.VA -and $Rva -lt $s.VA + $s.Size) { return [int]($Rva - $s.VA + $s.Raw) }
    }
    throw "RVA 0x{0:X} is outside all sections of $($Pe.Path)" -f $Rva
}

function Read-PeString($Pe, [uint32]$Rva) {
    $o = ConvertTo-PeOffset $Pe $Rva
    $e = [Array]::IndexOf($Pe.Bytes, [byte]0, $o)
    [Text.Encoding]::ASCII.GetString($Pe.Bytes, $o, $e - $o)
}

function Get-PeDirectory($Pe, [int]$Index) {
    $d = $Pe.Dirs + 8 * $Index
    [pscustomobject]@{ Rva = [BitConverter]::ToUInt32($Pe.Bytes, $d); Size = [BitConverter]::ToUInt32($Pe.Bytes, $d + 4) }
}

# Named exports. Forwarder is the "dll.func" string for forwarded exports, else $null.
function Get-PeExports($Pe) {
    $dir = Get-PeDirectory $Pe 0
    if ($dir.Rva -eq 0) { return @() }
    $b = $Pe.Bytes
    $o = ConvertTo-PeOffset $Pe $dir.Rva
    $nNames = [BitConverter]::ToUInt32($b, $o + 24)
    $funcs = ConvertTo-PeOffset $Pe ([BitConverter]::ToUInt32($b, $o + 28))
    $names = ConvertTo-PeOffset $Pe ([BitConverter]::ToUInt32($b, $o + 32))
    $ords = ConvertTo-PeOffset $Pe ([BitConverter]::ToUInt32($b, $o + 36))
    for ($i = 0; $i -lt $nNames; $i++) {
        $name = Read-PeString $Pe ([BitConverter]::ToUInt32($b, $names + 4 * $i))
        $ord = [BitConverter]::ToUInt16($b, $ords + 2 * $i)
        $rva = [BitConverter]::ToUInt32($b, $funcs + 4 * $ord)
        $fwd = if ($rva -ge $dir.Rva -and $rva -lt $dir.Rva + $dir.Size) { Read-PeString $Pe $rva } else { $null }
        [pscustomobject]@{ Name = $name; Forwarder = $fwd }
    }
}

# Static imports: one object per imported DLL with the imported function names.
function Get-PeImports($Pe) {
    $dir = Get-PeDirectory $Pe 1
    if ($dir.Rva -eq 0) { return @() }
    $b = $Pe.Bytes
    $o = ConvertTo-PeOffset $Pe $dir.Rva
    for (; ; $o += 20) {
        $thunkRva = [BitConverter]::ToUInt32($b, $o)
        $nameRva = [BitConverter]::ToUInt32($b, $o + 12)
        if ($nameRva -eq 0) { break }
        if ($thunkRva -eq 0) { $thunkRva = [BitConverter]::ToUInt32($b, $o + 16) }
        $t = ConvertTo-PeOffset $Pe $thunkRva
        $size = if ($Pe.Is64) { 8 } else { 4 }
        $funcs = for (; ; $t += $size) {
            if ($Pe.Is64) { if ([BitConverter]::ToUInt64($b, $t) -eq 0) { break } }
            elseif ([BitConverter]::ToUInt32($b, $t) -eq 0) { break }
            $low = [BitConverter]::ToUInt32($b, $t)
            # The top bit of the thunk (in its last byte) marks an import by ordinal.
            if ($b[$t + $size - 1] -band 0x80) { "#$($low -band 0xFFFF)" } else { Read-PeString $Pe ($low + 2) }
        }
        [pscustomobject]@{ Dll = Read-PeString $Pe $nameRva; Functions = @($funcs) }
    }
}
