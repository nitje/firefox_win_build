param([Parameter(Mandatory=$true)][string]$JobId,[string]$ShareRoot='\\host.lan\Data',[int]$ExitCode=1)
$ErrorActionPreference='SilentlyContinue'
$statusPath=Join-Path $ShareRoot "status\$JobId.json"
$logPath=Join-Path $ShareRoot "logs\$JobId.log"
$current=$null
if(Test-Path $statusPath){try{$current=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json}catch{}}
if($null -ne $current -and @('FINISHED','FAILED') -contains [string]$current.status){exit 0}
$errorText="Worker-Prozess wurde mit ExitCode $ExitCode beendet, ohne einen finalen Build-Status zu hinterlassen."
$obj=[ordered]@{id=$JobId;status='FAILED';updated_at=(Get-Date -Format o);error=$errorText;artifact_name=$null;artifact_path=$null}
$tmp="$statusPath.tmp"
try{$obj|ConvertTo-Json -Compress|Set-Content $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $statusPath -Force}catch{}
try{
  $line="$(Get-Date -Format o) FAILED-FALLBACK: $errorText"+[Environment]::NewLine
  $fs=[System.IO.FileStream]::new($logPath,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
  try{$bytes=[System.Text.UTF8Encoding]::new($false).GetBytes($line);$fs.Write($bytes,0,$bytes.Length)}finally{$fs.Dispose()}
}catch{}
exit 0
