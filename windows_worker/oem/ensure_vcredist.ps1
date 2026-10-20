param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = 'C:\firefox_worker'
$StatusPath = Join-Path $Root 'VCRUNTIME.json'
$CacheDir = Join-Path $Root 'cache'
$Minimum = [version]'14.50.0.0'
New-Item -ItemType Directory -Force -Path $Root,$CacheDir | Out-Null

function Say([string]$Message) {
    if (-not $Quiet) { Write-Output "VC-RUNTIME: $Message" }
}

function Get-RuntimeInfo([string]$Arch) {
    $paths = @("HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\$Arch")
    if ($Arch -eq 'x86') {
        $paths += "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86"
    }
    foreach ($path in $paths) {
        try {
            $p = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
            $installed = ([int]$p.Installed -eq 1)
            $rawVersion = [string]$p.Version
            $parsed = $null
            if (-not [string]::IsNullOrWhiteSpace($rawVersion)) {
                try { $parsed = [version]($rawVersion.TrimStart([char[]]@('v','V'))) } catch {}
            }
            if ($installed) {
                return [pscustomobject]@{
                    installed = $true
                    version = $rawVersion
                    version_ok = [bool]($parsed -and $parsed -ge $Minimum)
                    registry_path = $path
                }
            }
        } catch {}
    }
    return [pscustomobject]@{installed=$false;version='';version_ok=$false;registry_path=''}
}

function Install-Runtime([string]$Arch) {
    $url = "https://aka.ms/vc14/vc_redist.$Arch.exe"
    $installer = Join-Path $CacheDir "vc_redist.$Arch.exe"
    Say "lade aktuelle Microsoft Visual C++ Runtime $Arch"
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    $p = Start-Process -FilePath $installer -ArgumentList @('/install','/quiet','/norestart') -Wait -PassThru
    if (@(0,1638,3010) -notcontains [int]$p.ExitCode) {
        throw "VC++ Redistributable $Arch Installer ExitCode $($p.ExitCode)"
    }
    return ([int]$p.ExitCode -eq 3010)
}

$warnings = @()
$reboot = $false
foreach ($arch in @('x86','x64')) {
    $state = Get-RuntimeInfo $arch
    if (-not $state.installed -or -not $state.version_ok) {
        try {
            $reboot = (Install-Runtime $arch) -or $reboot
        } catch {
            $warnings += "$arch konnte nicht installiert/aktualisiert werden: $($_.Exception.Message)"
            Say $warnings[-1]
        }
    }
}

$x86 = Get-RuntimeInfo 'x86'
$x64 = Get-RuntimeInfo 'x64'
$ready = [bool]($x86.installed -and $x64.installed -and $x86.version_ok -and $x64.version_ok)
if ($ready) {
    Say "x86=$($x86.version), x64=$($x64.version)"
} else {
    if (-not $x86.installed) { $warnings += 'VC++ Runtime x86 fehlt.' }
    elseif (-not $x86.version_ok) { $warnings += "VC++ Runtime x86 ist älter als $Minimum ($($x86.version))." }
    if (-not $x64.installed) { $warnings += 'VC++ Runtime x64 fehlt.' }
    elseif (-not $x64.version_ok) { $warnings += "VC++ Runtime x64 ist älter als $Minimum ($($x64.version))." }
}

$obj = [ordered]@{
    ready = $ready
    minimum_version = $Minimum.ToString()
    x86 = $x86
    x64 = $x64
    reboot_recommended = $reboot
    warnings = @($warnings | Select-Object -Unique)
    checked_at = (Get-Date -Format o)
    note = 'Firefox/NSIS benötigt auch 32-bit Windows-Runtime-Unterstützung; x86 und x64 VC++ v14 werden geprüft.'
}
$tmp = "$StatusPath.tmp"
$obj | ConvertTo-Json -Compress -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $StatusPath -Force
if (-not $Quiet) { $obj | ConvertTo-Json -Compress -Depth 6 }
if ($ready) { exit 0 }
exit 1
