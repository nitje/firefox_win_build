param([string]$Version = '0.0.26')
$ErrorActionPreference = 'Stop'
$Root = 'C:\firefox_worker'
$DevPath = Join-Path $Root 'DEVDRIVE.json'
$ReadyPath = Join-Path $Root 'READY.json'
$DefenderPath = Join-Path $Root 'DEFENDER.json'
$VcRuntimePath = Join-Path $Root 'VCRUNTIME.json'
$BootstrapPath = Join-Path $Root 'BOOTSTRAP.json'
$PagefilePath = Join-Path $Root 'PAGEFILE.json'

$dev = $null
try { if (Test-Path $DevPath) { $dev = Get-Content -LiteralPath $DevPath -Raw | ConvertFrom-Json } } catch {}
if (-not $dev) { $dev = [pscustomobject]@{ready=$false;letter='D:';filesystem='';detail='Dev Drive Status fehlt'} }
$defender = $null
try { if (Test-Path $DefenderPath) { $defender = Get-Content -LiteralPath $DefenderPath -Raw | ConvertFrom-Json } } catch {}
if (-not $defender) { $defender = [pscustomobject]@{ready=$false;covered_paths=@();warnings=@('Defender-Status fehlt')} }
$vcruntime = $null
try { if (Test-Path $VcRuntimePath) { $vcruntime = Get-Content -LiteralPath $VcRuntimePath -Raw | ConvertFrom-Json } } catch {}
if (-not $vcruntime) { $vcruntime = [pscustomobject]@{ready=$false;x86=$null;x64=$null;warnings=@('VC++ Runtime Status fehlt')} }
$pagefile = $null
try { if (Test-Path $PagefilePath) { $pagefile = Get-Content -LiteralPath $PagefilePath -Raw | ConvertFrom-Json } } catch {}
if (-not $pagefile) { $pagefile = [pscustomobject]@{ready=$false;detail='Pagefile-Status fehlt';pending_reboot=$false} }
$mozilla = Test-Path 'C:\mozilla-build\start-shell.bat' 
$ready = [bool]($mozilla -and $dev.ready -and $vcruntime.ready -and $pagefile.ready)
$detail = if (-not $mozilla) {
    'MozillaBuild fehlt'
} elseif (-not $dev.ready) {
    "Dev Drive nicht bereit: $($dev.detail)"
} elseif (-not $vcruntime.ready) {
    'Microsoft Visual C++ Runtime x86/x64 nicht bereit'
} elseif (-not $pagefile.ready) {
    "Windows-Commit-Limit: $($pagefile.detail)"
} else {
    'MozillaBuild vorhanden; persistenter Dev Drive und VC++ Runtime bereit; FirefoxBuildWorker registriert'
}

$readyObj = [ordered]@{
    ready = $ready
    worker_version = $Version
    mozilla_build = $mozilla
    mozbuild_state_path = 'D:\mozbuild-state'
    dev_drive = $dev
    defender = $defender
    vcredist = $vcruntime
    pagefile = $pagefile
}
$bootObj = [ordered]@{
    state = if ($ready) {'ready'} else {'waiting'}
    phase = if (-not $dev.ready) {'DEV_DRIVE'} elseif (-not $vcruntime.ready) {'VC_RUNTIME'} elseif (-not $pagefile.ready) {'PAGEFILE'} else {'READY'}
    detail = $detail
    worker_version = $Version
    mozbuild_state_path = 'D:\mozbuild-state'
    dev_drive = $dev
    defender = $defender
    vcredist = $vcruntime
    pagefile = $pagefile
}
$readyObj | ConvertTo-Json -Compress -Depth 7 | Set-Content -LiteralPath "$ReadyPath.tmp" -Encoding UTF8
Move-Item -LiteralPath "$ReadyPath.tmp" -Destination $ReadyPath -Force
$bootObj | ConvertTo-Json -Compress -Depth 7 | Set-Content -LiteralPath "$BootstrapPath.tmp" -Encoding UTF8
Move-Item -LiteralPath "$BootstrapPath.tmp" -Destination $BootstrapPath -Force
