param([Parameter(Mandatory=$true)][string]$JobFile,[string]$ShareRoot='\\host.lan\Data')
$ErrorActionPreference='Stop'
$job=Get-Content -LiteralPath $JobFile -Raw | ConvertFrom-Json
if([string]$job.kind -eq 'cleanup_workspace'){
  & 'C:\firefox_worker\cleanup_worker_data.ps1' -JobId ([string]$job.id) -Version ([string]$job.version) -ShareRoot $ShareRoot
  exit $LASTEXITCODE
}
& 'C:\firefox_worker\build_firefox_windows.ps1' -JobFile $JobFile -JobId ([string]$job.id) -Version ([string]$job.version) -ShareRoot $ShareRoot
exit $LASTEXITCODE
