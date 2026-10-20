$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ProjectVersion = '0.0.26'
$Root = 'C:\firefox_worker'
$Log = 'C:\OEM\bootstrap.log'
$MozillaBuild = 'C:\mozilla-build'

function Log([string]$m) { "$(Get-Date -Format o) $m" | Tee-Object -FilePath $Log -Append }
function Write-State([string]$state,[string]$phase,[string]$detail,$dev=$null) {
  $o=[ordered]@{state=$state;phase=$phase;detail=$detail;worker_version=$ProjectVersion}
  if($null -ne $dev){$o.dev_drive=$dev}
  $o | ConvertTo-Json -Compress -Depth 5 | Set-Content "$Root\BOOTSTRAP.json" -Encoding UTF8
}
New-Item -ItemType Directory -Force -Path $Root | Out-Null
Write-State 'running' 'START' 'Firefox Windows Worker Bootstrap startet'
Log "Firefox Windows worker bootstrap $ProjectVersion"
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /hibernate off | Out-Null
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LanmanWorkstation' -Name AllowInsecureGuestAuth -Value 1 -PropertyType DWord -Force | Out-Null
fsutil.exe behavior set SymlinkEvaluation L2R:1 | Out-Null

Log 'OpenSSH Server wird installiert/aktiviert'
$ssh=Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if($ssh.State -ne 'Installed'){Add-WindowsCapability -Online -Name $ssh.Name | Out-Null}
Set-Service sshd -StartupType Automatic
$cfg='C:\ProgramData\ssh\sshd_config'
if(Test-Path $cfg){$t=Get-Content $cfg -Raw;if($t -match '(?im)^\s*#?\s*PasswordAuthentication\s+\w+'){$t=$t -replace '(?im)^\s*#?\s*PasswordAuthentication\s+\w+','PasswordAuthentication yes'}else{$t+="`r`nPasswordAuthentication yes`r`n"};Set-Content $cfg $t -Encoding ascii}
if(-not(Get-NetFirewallRule -Name 'FirefoxBuilder-OpenSSH' -ErrorAction SilentlyContinue)){New-NetFirewallRule -Name 'FirefoxBuilder-OpenSSH' -DisplayName 'Firefox Builder OpenSSH' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null}
Start-Service sshd


Log 'MozillaBuild wird geprüft/installiert'
if(-not(Test-Path "$MozillaBuild\start-shell.bat")){
  $setup='C:\OEM\MozillaBuildSetup-Latest.exe'
  Invoke-WebRequest -Uri 'https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe' -OutFile $setup -UseBasicParsing
  $p=Start-Process -FilePath $setup -ArgumentList '/S' -PassThru -Wait
  if($p.ExitCode -ne 0){throw "MozillaBuild Installer ExitCode $($p.ExitCode)"}
}
if(-not(Test-Path "$MozillaBuild\start-shell.bat")){throw 'MozillaBuild wurde nach Installation nicht erkannt'}

Copy-Item 'C:\OEM\worker.cmd','C:\OEM\dispatch_build.ps1','C:\OEM\build_firefox_windows.ps1','C:\OEM\mark_job_failed.ps1','C:\OEM\repair_worker.cmd','C:\OEM\cleanup_version.cmd','C:\OEM\ensure_devdrive.ps1','C:\OEM\ensure_defender_exclusions.ps1','C:\OEM\ensure_vcredist.ps1','C:\OEM\ensure_build_memory.ps1','C:\OEM\update_worker_ready.ps1' -Destination $Root -Force
New-Item -ItemType Directory -Force -Path "$Root\jobs","$Root\processing","$Root\failed" | Out-Null
Write-State 'running' 'DEV_DRIVE' 'Persistenter Dev Drive wird geprüft/eingerichtet'
$devProc=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$Root\ensure_devdrive.ps1") -Wait -PassThru -WindowStyle Hidden
$devRc=$devProc.ExitCode
$dev=$null
try { $dev=Get-Content "$Root\DEVDRIVE.json" -Raw | ConvertFrom-Json } catch {}
$devText=if($dev){$dev|ConvertTo-Json -Compress}else{'Status fehlt'}
Log ("Dev Drive: "+$devText)
if($devRc -ne 0){ Log 'Dev Drive noch nicht bereit; Worker-Task versucht die Einrichtung nach dem Neustart erneut' }
Log 'Windows-Defender-Ausnahmen für Firefox-Buildpfade werden geprüft'
$defProc=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$Root\ensure_defender_exclusions.ps1") -Wait -PassThru -WindowStyle Hidden
try { $def=Get-Content "$Root\DEFENDER.json" -Raw | ConvertFrom-Json; Log ("Defender: "+($def|ConvertTo-Json -Compress -Depth 5)) } catch { Log 'Defender-Status konnte nicht gelesen werden' }
Log 'Microsoft Visual C++ Runtime x86/x64 wird geprüft/aktualisiert'
$vcProc=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$Root\ensure_vcredist.ps1") -Wait -PassThru -WindowStyle Hidden
try { $vc=Get-Content "$Root\VCRUNTIME.json" -Raw | ConvertFrom-Json; Log ("VC Runtime: "+($vc|ConvertTo-Json -Compress -Depth 6)) } catch { Log 'VC-Runtime-Status konnte nicht gelesen werden' }
New-Item -ItemType Directory -Force -Path 'C:\firefox_worker\home' | Out-Null
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$Root\ensure_build_memory.ps1" | Out-Null
Log 'Windows Commit-Limit / Pagefile geprueft; erforderlicher Neustart wird im Worker-Status angezeigt.'
if($devRc -eq 0){New-Item -ItemType Directory -Force -Path 'D:\mozbuild-state' | Out-Null}
$readyProc=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$Root\update_worker_ready.ps1",'-Version',$ProjectVersion) -Wait -PassThru -WindowStyle Hidden
if($readyProc.ExitCode -ne 0){ Log "READY-Status konnte nicht aktualisiert werden (Exit $($readyProc.ExitCode))" }
Write-State 'running' 'REGISTER' 'Worker-Task wird registriert' $dev
cmd /c "$Root\repair_worker.cmd" | Out-Null
Log 'Bootstrap abgeschlossen'
