param([switch]$Quiet)
$ErrorActionPreference = 'Continue'
$Root = 'C:\firefox_worker'
$StatusPath = Join-Path $Root 'DEFENDER.json'
New-Item -ItemType Directory -Force -Path $Root | Out-Null

function Say([string]$Message) {
    if (-not $Quiet) { Write-Output "DEFENDER: $Message" }
}
function Normalize-Path([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path).Trim()
    try { $expanded = [IO.Path]::GetFullPath($expanded) } catch {}
    return $expanded.TrimEnd([IO.Path]::DirectorySeparatorChar)
}
function Is-Covered([string]$Target, [string[]]$Existing) {
    foreach ($entry in @($Existing)) {
        $candidate = Normalize-Path $entry
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($Target.Equals($candidate, [StringComparison]::OrdinalIgnoreCase) -or
            $Target.StartsWith(($candidate + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            return $candidate
        }
    }
    return $null
}

$requested = @(
    'C:\mozilla-build',
    'D:\mozilla-source',
    'D:\firefox-builds',
    'D:\mozbuild-state',
    'C:\Windows\System32\config\systemprofile\.cargo',
    'C:\Windows\System32\config\systemprofile\.rustup',
    'C:\firefox_worker'
)
$covered = @()
$added = @()
$warnings = @()
$getMp = Get-Command Get-MpPreference -ErrorAction SilentlyContinue
$addMp = Get-Command Add-MpPreference -ErrorAction SilentlyContinue

if (-not $getMp -or -not $addMp) {
    $warnings += 'Microsoft-Defender-PowerShell-Cmdlets sind nicht verfügbar.'
    Say $warnings[-1]
} else {
    try {
        $existing = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | ForEach-Object { Normalize-Path ([string]$_) } | Where-Object { $_ })
    } catch {
        $existing = @()
        $warnings += "Vorhandene Defender-Ausnahmen konnten nicht gelesen werden: $($_.Exception.Message)"
        Say $warnings[-1]
    }

    foreach ($path in $requested) {
        $target = Normalize-Path $path
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        $cover = Is-Covered $target $existing
        if ($cover) {
            $covered += $target
            Say "bereits abgedeckt: $target (durch $cover)"
            continue
        }
        try {
            Add-MpPreference -ExclusionPath $target -ErrorAction Stop
            $existing += $target
            $covered += $target
            $added += $target
            Say "Ausnahme hinzugefügt: $target"
        } catch {
            # Wie im Chromium-Paket noch einmal lesen: parallel/älter eingerichtete
            # Ausnahmen sollen nicht als Fehler gelten.
            $effective = $false
            try {
                $after = @((Get-MpPreference -ErrorAction Stop).ExclusionPath | ForEach-Object { Normalize-Path ([string]$_) } | Where-Object { $_ })
                $cover = Is-Covered $target $after
                if ($cover) { $effective = $true; $existing = $after }
            } catch {}
            if ($effective) {
                $covered += $target
                Say "nach erneuter Prüfung bereits wirksam: $target"
            } else {
                $warnings += "Ausnahme konnte nicht gesetzt werden: $target - $($_.Exception.Message)"
                Say $warnings[-1]
            }
        }
    }
}

$obj = [ordered]@{
    ready = ($warnings.Count -eq 0)
    requested_paths = $requested
    covered_paths = @($covered | Select-Object -Unique)
    added_paths = @($added | Select-Object -Unique)
    warnings = $warnings
    checked_at = (Get-Date -Format o)
    note = 'Defender bleibt aktiv; nur dedizierte Firefox-Build-/Toolchain-Pfade werden ausgenommen.'
}
$tmp = "$StatusPath.tmp"
$obj | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $StatusPath -Force
if (-not $Quiet) { $obj | ConvertTo-Json -Compress -Depth 5 }
# Defender-Probleme sind absichtlich nicht build-fatal, analog zum Chromium-Paket.
exit 0
