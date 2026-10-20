param(
  [Parameter(Mandatory=$true)][string]$JobId,
  [Parameter(Mandatory=$true)][string]$Version,
  [ValidateSet('release','nightly','legacy')][string]$Flavor='legacy',
  [string]$ShareRoot='\\host.lan\Data',
  [string]$BuildStatus='FAILED'
)
$ErrorActionPreference='Stop'
if($JobId -notmatch '^[0-9a-fA-F-]{36}$' -or $Version -notmatch '^\d+(\.\d+){1,3}$'){exit 2}
$source="D:\mozilla-source\firefox-$Version"
$obj=if($Flavor -eq 'legacy'){'obj-firefox'}else{"obj-firefox-$Flavor"}
$objDir=Join-Path $source $obj
$base=Join-Path $ShareRoot "diagnostics\$JobId"
# Retry diagnostics are additive. A second attempt never overwrites evidence
# from an earlier failure of the same build ID.
$attempt="attempt-$(Get-Date -Format yyyyMMdd_HHmmss_fff)"
$dest=Join-Path $base $attempt
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$manifest=[ordered]@{job_id=$JobId;version=$Version;flavor=$Flavor;build_status=$BuildStatus;
  collected_at=(Get-Date -Format o);objdir=$objDir;files=@();skipped=@();warnings=@()}
function Snapshot([string]$src,[string]$rel){
  try{
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){return}
    $f=Get-Item -LiteralPath $src -ErrorAction Stop
    if($f.Length -gt 83886080){$manifest.skipped+= "${rel}: too large ($($f.Length) bytes)";return}
    $out=Join-Path $dest $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out)|Out-Null
    Copy-Item -LiteralPath $src -Destination $out -Force -ErrorAction Stop
    $manifest.files+=$rel
  }catch{$manifest.warnings+="${rel}: $($_.Exception.Message)"}
}
Snapshot (Join-Path $source 'mozconfig') 'mozconfig.txt'
Snapshot (Join-Path $source 'browser\app\profile\firefox.js') 'firefox_preferences_source.js'
Snapshot (Join-Path $source '.firefox_worker_source_complete') 'source_marker.txt'
Snapshot (Join-Path $objDir 'config.log') 'configure/config.log'
Snapshot (Join-Path $objDir 'configure.log') 'configure/configure.log'
Snapshot (Join-Path $objDir 'config.status') 'configure/config.status'
Snapshot (Join-Path $objDir 'mozinfo.json') 'configure/mozinfo.json'
Snapshot (Join-Path $objDir 'dist\bin\application.ini') 'application.ini'
$buildLogs=Join-Path $objDir '.mozbuild\logs\build'
if(Test-Path $buildLogs){
  Get-ChildItem -LiteralPath $buildLogs -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
    $rel=$_.FullName.Substring($buildLogs.Length).TrimStart('\','/')
    Snapshot $_.FullName ("mach/build/"+($rel -replace '\\','/'))
  }
}
# Include targeted Firefox configure logs if they exist in additional locations.
foreach($rel in @('.mozbuild\logs\configure.log','.mozbuild\logs\mach.log')){
  Snapshot (Join-Path $objDir $rel) ("mach/"+($rel -replace '\\','/'))
}
foreach($f in @('READY.json','BOOTSTRAP.json','DEVDRIVE.json','PAGEFILE.json','VCRUNTIME.json','DEFENDER.json')){
  Snapshot (Join-Path 'C:\firefox_worker' $f) ("worker_state/"+$f)
}
foreach($group in @('jobs','processing','failed')){
  Snapshot ("C:\firefox_worker\$group\$JobId.json") ("job_${group}.json")
}
try {
  $events=@(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001; StartTime=(Get-Date).AddHours(-4)} -MaxEvents 120 -ErrorAction SilentlyContinue | Where-Object {$_.Message -match '(?i)(clang-cl|rustc|lld-link|makensis)' } | Select-Object -First 12 | ForEach-Object { [ordered]@{at=$_.TimeCreated.ToString('o');id=$_.Id;message=$_.Message} })
  if($events.Count){$events | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dest 'compiler_crash_events.json') -Encoding UTF8;$manifest.files+='compiler_crash_events.json'}
}catch{$manifest.warnings+="Windows event log: $($_.Exception.Message)"}
$manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $dest 'manifest.json') -Encoding UTF8
exit 0
