param(
  [Parameter(Mandatory=$true)][string]$JobId,
  [Parameter(Mandatory=$true)][string]$Version,
  [string]$ShareRoot='\\host.lan\Data'
)
$ErrorActionPreference='Stop'
$status=Join-Path $ShareRoot "status\$JobId.json"
function State([string]$s,[string]$msg){
  $o=[ordered]@{id=$JobId;status=$s;updated_at=(Get-Date -Format o);detail=$msg;error=if($s -eq 'FAILED'){$msg}else{$null}}
  $tmp="$status.tmp"
  $o | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $status -Force
}
try{
  if($Version -notmatch '^\d+(\.\d+){1,3}$'){throw "Ungueltige Firefox-Version"}
  if($JobId -notmatch '^[0-9a-fA-F-]{36}$'){throw "Ungueltige Bereinigungs-ID"}
  State 'BUILDING' "Workerdaten fuer Firefox $Version werden entfernt"
  # Never delete MozillaBuild, D:\mozbuild-state, DEVDRIVE, Windows, logs,
  # published downloads or arbitrary paths from the job JSON.
  $paths=@("D:\mozilla-source\firefox-$Version", "D:\firefox-builds\$Version", "D:\firefox-builds\firefox-$Version.source.tar.xz")
  $removed=@()
  foreach($path in $paths){
    if(Test-Path -LiteralPath $path){
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      $removed+=$path
    }
  }
  State 'FINISHED' ("Bereinigt: "+($removed -join '; '))
  exit 0
}catch{
  try{State 'FAILED' $_.Exception.Message}catch{}
  exit 1
}
