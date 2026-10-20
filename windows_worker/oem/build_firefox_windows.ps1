param([Parameter(Mandatory=$true)][string]$JobFile,[Parameter(Mandatory=$true)][string]$JobId,[Parameter(Mandatory=$true)][string]$Version,[string]$ShareRoot='\\host.lan\Data')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$Log=Join-Path $ShareRoot "logs\$JobId.log";$Status=Join-Path $ShareRoot "status\$JobId.json"
$SourceRoot="D:\mozilla-source\firefox-$Version";$BuildRoot="D:\firefox-builds\$Version";$Archive="D:\firefox-builds\firefox-$Version.source.tar.xz"
$SourceUrl="https://archive.mozilla.org/pub/firefox/releases/$Version/source/firefox-$Version.source.tar.xz"
$Flavor='legacy'
$BuildPrefs=@()
try{
  $j=Get-Content -LiteralPath $JobFile -Raw | ConvertFrom-Json
  if([string]$j.flavor -in @('release','nightly','legacy')){$Flavor=[string]$j.flavor}
  if($null -ne $j.about_config){$BuildPrefs=@($j.about_config)}
}catch{}
$ObjName=if($Flavor -eq 'legacy'){'obj-firefox'}else{"obj-firefox-$Flavor"}
$MozState='D:\mozbuild-state';$BuildHome='C:\firefox_worker\home'
# Pick a safe default from the VM's measured RAM instead of assuming that
# every dockurr installation has 24 GiB. The worker memory policy writes the
# recommended values to PAGEFILE.json. Explicit system overrides still win.
$CppJobs=1;$RustJobs=1
try {
  $policy=Get-Content -LiteralPath 'C:\firefox_worker\PAGEFILE.json' -Raw | ConvertFrom-Json
  if([int]$policy.recommended_cpp_jobs -ge 1){$CppJobs=[int]$policy.recommended_cpp_jobs}
  if([int]$policy.recommended_rust_jobs -ge 1){$RustJobs=[int]$policy.recommended_rust_jobs}
} catch {
  # Safe default for an unknown / older worker status is one job each.
}
try{if([int]$env:FIREFOX_CPP_JOBS -ge 1 -and [int]$env:FIREFOX_CPP_JOBS -le 64){$CppJobs=[int]$env:FIREFOX_CPP_JOBS}}catch{}
try{if([int]$env:FIREFOX_RUST_JOBS -ge 1 -and [int]$env:FIREFOX_RUST_JOBS -le 64){$RustJobs=[int]$env:FIREFOX_RUST_JOBS}}catch{}
$script:LogWriter=$null
$script:MsysFirstRunDetected=$false
$script:MozillaSawNsisFailure=$false
$script:MozillaSawMemoryFailure=$false

function Open-LogWriter {
  try {
    $dir=Split-Path -Parent $Log
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $fs=[System.IO.FileStream]::new($Log,[System.IO.FileMode]::Append,[System.IO.FileAccess]::Write,[System.IO.FileShare]::ReadWrite)
    $utf8=[System.Text.UTF8Encoding]::new($false)
    $script:LogWriter=[System.IO.StreamWriter]::new($fs,$utf8)
    $script:LogWriter.AutoFlush=$true
  } catch {
    $script:LogWriter=$null
    Write-Warning "Build-Log konnte nicht geöffnet werden: $($_.Exception.Message)"
  }
}
function Close-LogWriter {
  if($null -ne $script:LogWriter){try{$script:LogWriter.Dispose()}catch{};$script:LogWriter=$null}
}
function LogOnly([string]$m) {
  $line="$(Get-Date -Format o) $m"
  if($null -ne $script:LogWriter){
    try{$script:LogWriter.WriteLine($line);return}catch{Write-Warning "Build-Log Schreibfehler: $($_.Exception.Message)"}
  }
  try{[System.IO.File]::AppendAllText($Log,$line+[Environment]::NewLine,[System.Text.UTF8Encoding]::new($false))}catch{Write-Warning "Build-Log Fallback fehlgeschlagen: $($_.Exception.Message)"}
}
function Log([string]$m){LogOnly $m;Write-Output $m}
function State([string]$s,[string]$err='',[string]$an='',[string]$ap=''){
  $obj=[ordered]@{id=$JobId;status=$s;updated_at=(Get-Date -Format o);error=if($err){$err}else{$null};artifact_name=if($an){$an}else{$null};artifact_path=if($ap){$ap}else{$null}}
  $tmp="$Status.tmp"
  for($i=0;$i -lt 5;$i++){
    try{$obj|ConvertTo-Json -Compress|Set-Content $tmp -Encoding UTF8;Move-Item -LiteralPath $tmp -Destination $Status -Force;return}catch{if($i -eq 4){throw};Start-Sleep -Milliseconds 200}
  }
}
function Set-MozillaEnvironment {
  New-Item -ItemType Directory -Force -Path $MozState,$BuildHome | Out-Null
  # Keep Mozilla's large build/toolchain state on the persistent Dev Drive, but
  # keep rustup/cargo internally consistent with the already working MozillaBuild
  # installation of the SYSTEM account. 0.0.7 mixed the old rustup.exe from
  # systemprofile\.cargo\bin with new CARGO_HOME/RUSTUP_HOME paths on D:, which
  # makes `rustup update` reject the installation.
  $env:MOZBUILD_STATE_PATH=$MozState
  $env:HOME=$BuildHome
  $systemProfile=Join-Path $env:SystemRoot 'System32\config\systemprofile'
  $systemCargo=Join-Path $systemProfile '.cargo'
  $systemRustup=Join-Path $systemProfile '.rustup'
  $systemRustupExe=Join-Path $systemCargo 'bin\rustup.exe'
  if(Test-Path $systemRustupExe){
    $env:CARGO_HOME=$systemCargo
    $env:RUSTUP_HOME=$systemRustup
    $cargoBin=Join-Path $systemCargo 'bin'
    if(-not (($env:Path -split ';') -contains $cargoBin)){$env:Path=$cargoBin+';'+$env:Path}
  } else {
    # Fresh VM: let Mozilla bootstrap/rustup choose its normal defaults.
    Remove-Item Env:RUSTUP_HOME -ErrorAction SilentlyContinue
    Remove-Item Env:CARGO_HOME -ErrorAction SilentlyContinue
  }
}
function Invoke-MozillaOnce([string]$cmd){
  $script:MsysFirstRunDetected=$false
  $script:MozillaSawNsisFailure=$false
  $script:MozillaSawMemoryFailure=$false
  Set-MozillaEnvironment
  # Native tools such as rustup intentionally write warnings/progress to stderr.
  # Windows PowerShell 5.1 may otherwise turn redirected stderr into a
  # terminating NativeCommandError. The native process exit code is authoritative.
  $oldErrorActionPreference=$ErrorActionPreference
  $script:ResourceSampleAt=[DateTime]::UtcNow.AddMinutes(1)
  try {
    $ErrorActionPreference='Continue'
    & 'C:\mozilla-build\start-shell.bat' -no-start -defterm -c $cmd 2>&1 | ForEach-Object {
      $line=[string]$_
      if($line -match 'MSYS2 is starting for the first time|Executing the initial setup'){ $script:MsysFirstRunDetected=$true }
      if($line -match 'Failed to get nsis version|3221225595|-1073741701|0xC000007B|STATUS_INVALID_IMAGE_FORMAT'){ $script:MozillaSawNsisFailure=$true }
      if($line -match 'rustc-LLVM ERROR: out of memory|Allocation failed'){ $script:MozillaSawMemoryFailure=$true }
      LogOnly $line
      # Write directly to the host console, not PowerShell output/information
      # streams: otherwise periodic RESOURCE lines contaminate the function
      # return value when stdout is captured by the caller.
      [Console]::Out.WriteLine($line)
      if($cmd -match '\./mach build' -and [DateTime]::UtcNow -ge $script:ResourceSampleAt){
        Log-MemorySnapshot 'DURING-BUILD' | Out-Null
        $script:ResourceSampleAt=[DateTime]::UtcNow.AddMinutes(1)
      }
    }
    $rc=$LASTEXITCODE
  } finally {
    $ErrorActionPreference=$oldErrorActionPreference
  }
  if($null -eq $rc){$rc=1}
  # Return exactly one integer. A successful mach build MUST NOT be turned
  # into FAILED because resource messages slipped into the returned value.
  return [int]$rc
}
function Ensure-VCRuntime {
  $script='C:\firefox_worker\ensure_vcredist.ps1'
  if(-not(Test-Path $script)){throw 'ensure_vcredist.ps1 fehlt'}
  # Run in a child powershell.exe because ensure_vcredist.ps1 intentionally
  # uses exit codes. Calling it in-process would let `exit` terminate this
  # build script before we can write FAILED/diagnostic state.
  $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$script,'-Quiet') -Wait -PassThru -WindowStyle Hidden
  $rc=[int]$p.ExitCode
  $status='C:\firefox_worker\VCRUNTIME.json'
  $vc=$null
  try{$vc=Get-Content -LiteralPath $status -Raw|ConvertFrom-Json}catch{}
  if($vc -and $vc.ready){
    Log "VC-RUNTIME: x86=$($vc.x86.version) · x64=$($vc.x64.version)"
    return
  }
  $details=if($vc){(@($vc.warnings)-join ' | ')}else{"Status fehlt (Exit $rc)"}
  throw "Microsoft Visual C++ Runtime x86/x64 nicht bereit: $details"
}
function Reset-NsisToolchain {
  Set-MozillaEnvironment
  Log "NSIS SELF-HEAL: beschädigte/inkompatible NSIS-Toolchain unter $MozState wird verworfen"
  foreach($path in @((Join-Path $MozState 'nsis'),(Join-Path $MozState 'nsis.tar.zst'),(Join-Path $MozState 'nsis.tar.xz'),(Join-Path $MozState 'nsis.tar.gz'))){
    if(Test-Path $path){try{Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop}catch{Log "NSIS SELF-HEAL WARNING: $path konnte nicht entfernt werden: $($_.Exception.Message)"}}
  }
  $toolchains=Join-Path $MozState 'toolchains'
  if(Test-Path $toolchains){
    Get-ChildItem -LiteralPath $toolchains -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)nsis' } | ForEach-Object {
      try{Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop}catch{Log "NSIS SELF-HEAL WARNING: Cache $($_.FullName) konnte nicht entfernt werden"}
    }
  }
}
function Log-MemorySnapshot([string]$phase){
  try {
    $os=Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $freeGB=[math]::Round([double]$os.FreePhysicalMemory / 1048576,2)
    $totalGB=[math]::Round([double]$os.TotalVisibleMemorySize / 1048576,2)
    $commitFreeGB=[math]::Round([double]$os.FreeVirtualMemory / 1048576,2)
    $commitTotalGB=[math]::Round([double]$os.TotalVirtualMemorySize / 1048576,2)
    $buildProcesses=@(Get-Process -Name clang-cl,rustc,lld-link -ErrorAction SilentlyContinue)
    $top=@($buildProcesses | Sort-Object WorkingSet64 -Descending | Select-Object -First 4 | ForEach-Object {"$($_.ProcessName) pid=$($_.Id) RAM=$([math]::Round($_.WorkingSet64/1GB,2))GB"})
    LogOnly "RESOURCE ${phase}: free RAM=$freeGB/$totalGB GB; free commit=$commitFreeGB/$commitTotalGB GB; compiler processes=$($buildProcesses.Count); top=$($top -join '; ')"
  }catch{LogOnly "RESOURCE ${phase}: Snapshot nicht verfuegbar: $($_.Exception.Message)"}
}
function Log-CompilerCrashEvents {
  try {
    $since=(Get-Date).AddHours(-2)
    $events=@(Get-WinEvent -FilterHashtable @{LogName='Application';Id=1000,1001;StartTime=$since} -MaxEvents 80 -ErrorAction Stop | Where-Object {$_.Message -match '(?i)(clang-cl\.exe|rustc\.exe|lld-link\.exe)'} | Select-Object -First 6)
    if($events.Count -eq 0){Log 'CRASH-DIAG: Keine Windows-Anwendungsereignisse fuer clang-cl/rustc/lld-link gefunden.'}
    foreach($event in $events){
      $short=($event.Message -replace '[\r\n]+',' ')
      if($short.Length -gt 900){$short=$short.Substring(0,900)}
      Log "CRASH-DIAG: event=$($event.Id) time=$($event.TimeCreated.ToString('o')) $short"
    }
  }catch{Log "CRASH-DIAG: Ereignisabfrage nicht verfuegbar: $($_.Exception.Message)"}
}
function Ensure-SourceTree {
  $marker=Join-Path $SourceRoot '.firefox_worker_source_complete'
  $mach=Join-Path $SourceRoot 'mach'
  $objdir=Join-Path $SourceRoot $ObjName
  if((Test-Path -LiteralPath $mach) -and ((Test-Path -LiteralPath $marker) -or (Test-Path -LiteralPath $objdir))){
    Log "SOURCE REUSE: $SourceRoot bleibt erhalten; $ObjName wird beim Retry inkrementell weitergebaut (kein clobber)."
    return
  }
  # A partially extracted tree is not considered reusable. Stage first, then
  # mark complete; never remove an existing objdir just to retry a build.
  $staging="$SourceRoot.extracting"
  if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force}
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  Log "SOURCE EXTRACT: $Archive -> $staging"
  tar.exe -xf $Archive -C $staging --strip-components=1
  if($LASTEXITCODE -ne 0 -or -not(Test-Path -LiteralPath (Join-Path $staging 'mach'))){
    throw 'Source-Archiv konnte nicht vollstaendig entpackt werden'
  }
  Set-Content -LiteralPath (Join-Path $staging '.firefox_worker_source_complete') -Value "Firefox $Version" -Encoding ASCII
  if(Test-Path -LiteralPath $SourceRoot){Remove-Item -LiteralPath $SourceRoot -Recurse -Force}
  Move-Item -LiteralPath $staging -Destination $SourceRoot
}
function Remove-LegacyAboutConfigDefaults {
  # v0.0.14 edited browser/app/profile/firefox.js, which is embedded in
  # omni.ja during compilation. New builds intentionally keep upstream prefs
  # untouched: the manager adds AutoConfig defaults to the finished ZIP,
  # allowing future about:config edits without recompilation.
  $file=Join-Path $SourceRoot 'browser\app\profile\firefox.js'
  if(-not(Test-Path -LiteralPath $file)){throw "Firefox-Profilquelle nicht gefunden: $file"}
  $content=[System.IO.File]::ReadAllText($file)
  $clean=[regex]::Replace($content,'(?s)\r?\n?// BEGIN FIREFOX_WEBBROWSER_BUILD ABOUT_CONFIG\r?\n.*?// END FIREFOX_WEBBROWSER_BUILD ABOUT_CONFIG\r?\n?',"`n")
  if($clean -cne $content){
    [System.IO.File]::WriteAllText($file,$clean,[System.Text.UTF8Encoding]::new($false))
    Log 'ABOUT:CONFIG: v0.0.14-Quellpatch aus firefox.js entfernt; Firefox-Defaultwerte wieder upstream. Beim ersten Umstieg kann ein Teil neu kompiliert werden.'
  }
  Log "ABOUT:CONFIG: $($BuildPrefs.Count) aktivierte Standard-Prefs werden nach mach package ohne neue Kompilierung ins ZIP eingefuegt."
}

function Run-Mozilla([string]$cmd,[switch]$RetryNsis){
  Log "MOZILLA-SHELL: $cmd"
  [int]$rc=Invoke-MozillaOnce $cmd
  if($rc -ne 0 -and $script:MsysFirstRunDetected){
    Log 'MOZILLA-SHELL: MozillaBuild/MSYS2-Ersteinrichtung wurde ausgeführt; derselbe Befehl wird einmal automatisch wiederholt.'
    Start-Sleep -Seconds 2
    [int]$rc=Invoke-MozillaOnce $cmd
  }
  if($rc -ne 0 -and $RetryNsis -and $script:MozillaSawNsisFailure){
    Log 'NSIS SELF-HEAL: makensis konnte nicht gestartet werden. VC++ x86/x64 wird geprüft und NSIS wird frisch von Mozillas Toolchain-Bootstrap geladen.'
    Ensure-VCRuntime
    Reset-NsisToolchain
    Start-Sleep -Seconds 2
    [int]$rc=Invoke-MozillaOnce $cmd
    Log "MOZILLA-SHELL NSIS-RETRY EXIT: $rc"
  }
  Log "MOZILLA-SHELL EXIT: $([int]$rc)"
  if($rc -ne 0 -and $cmd -match '\./mach (build|package)'){
    Log-MemorySnapshot 'AFTER-FAILURE'
    Log-CompilerCrashEvents
  }
  if($rc -ne 0 -and $script:MozillaSawMemoryFailure){throw "Firefox Rust/LLVM: out of memory (Exit $rc). Pagefile/Commit-Limit pruefen; kompilierte Objekte werden fuer Retry erhalten: $cmd"}
  if($rc -ne 0){throw "MozillaBuild command failed ($rc): $cmd"}
}
function Collect-Diagnostics([string]$phase){
  try{
    $script='C:\firefox_worker\collect_diagnostics.ps1'
    if(-not(Test-Path -LiteralPath $script)){return}
    $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File', $script, '-JobId',$JobId,'-Version',$Version,'-Flavor',$Flavor,'-BuildStatus',$phase,'-ShareRoot',$ShareRoot) -Wait -PassThru -WindowStyle Hidden
    if($p.ExitCode -ne 0){LogOnly "DIAG WARN: Diagnose-Snapshot fehlgeschlagen (Exit $($p.ExitCode))"}
  }catch{LogOnly "DIAG WARN: $($_.Exception.Message)"}
}
function Ensure-DefenderExclusions {
  try {
    & 'C:\firefox_worker\ensure_defender_exclusions.ps1' -Quiet *> $null
    $defenderPath='C:\firefox_worker\DEFENDER.json'
    if(Test-Path $defenderPath){
      $def=Get-Content -LiteralPath $defenderPath -Raw | ConvertFrom-Json
      if($def.ready){ Log ('DEFENDER: Build-Pfade ausgenommen: '+(@($def.covered_paths)-join ', ')) }
      else{ Log ('DEFENDER WARNING: '+(@($def.warnings)-join ' | ')) }
    }
  } catch {
    Log "DEFENDER WARNING: Ausnahmen konnten nicht geprüft werden; Build läuft weiter. $($_.Exception.Message)"
  }
}

Open-LogWriter
try{
  State 'BUILDING'
  New-Item -ItemType Directory -Force -Path 'D:\mozilla-source','D:\firefox-builds',$MozState,$BuildHome|Out-Null
  Set-MozillaEnvironment
  Ensure-DefenderExclusions
  Ensure-VCRuntime
  $memStatus='C:\firefox_worker\PAGEFILE.json'
  if(-not(Test-Path -LiteralPath $memStatus)){throw 'PAGEFILE.json fehlt: Worker-Speicherpruefung nicht ausgefuehrt'}
  $mem=Get-Content -LiteralPath $memStatus -Raw | ConvertFrom-Json
  if(-not $mem.ready){throw "Windows-Commit-Limit nicht bereit: $($mem.detail)"}
  Log "PAGEFILE: $($mem.detail); frei=$($mem.free_commit_gb) GB; C: frei=$($mem.c_free_gb) GB"
  Log "MOZBUILD STATE: $MozState (persistenter Dev Drive); RUSTUP_HOME=$env:RUSTUP_HOME; CARGO_HOME=$env:CARGO_HOME"
  Log "Firefox $Version Build gestartet; Profil=$Flavor; Objektverzeichnis=$ObjName";Log "Source: $SourceUrl"
  if(-not(Test-Path $Archive)){Invoke-WebRequest -Uri $SourceUrl -OutFile $Archive -UseBasicParsing}
  Ensure-SourceTree
  $unix=('/'+$SourceRoot.Substring(0,1).ToLower()+$SourceRoot.Substring(2).Replace('\','/'))
  Run-Mozilla "cd '$unix' && ./mach --no-interactive bootstrap --application-choice browser"
  $mozconfig=@'
ac_add_options --enable-application=browser
ac_add_options --enable-optimize
ac_add_options --disable-debug
mk_add_options MOZ_OBJDIR=@TOPSRCDIR@/__OBJNAME__
mk_add_options MOZ_PARALLEL_BUILD=__CPP_JOBS__
'@
  $mozconfig=$mozconfig.Replace('__CPP_JOBS__',[string]$CppJobs).Replace('__OBJNAME__',$ObjName)
  if($Flavor -eq 'release'){
    # Release branding using actual Mozilla release source, no auto-updater
    # enrollment to Mozilla's official release service for a custom build.
    $mozconfig+="`nac_add_options --with-branding=browser/branding/official`nac_add_options --enable-update-channel=default`n"
  }elseif($Flavor -eq 'nightly'){
    # Nightly look only; an archive from /releases/ is NOT a real nightly snapshot.
    $mozconfig+="`nac_add_options --with-branding=browser/branding/nightly`nac_add_options --enable-update-channel=default`n"
  }
  Log "BRANDING: $Flavor (Mozilla release source; custom build, update channel=default)"
  Set-Content -Path (Join-Path $SourceRoot 'mozconfig') -Value $mozconfig -Encoding ASCII
  Log "MOZCONFIG: $($mozconfig -replace '[\r\n]+',' | ')"
  Remove-LegacyAboutConfigDefaults
  $env:CARGO_BUILD_JOBS=[string]$RustJobs
  Log "BUILD CONCURRENCY: MOZ_PARALLEL_BUILD=$CppJobs; CARGO_BUILD_JOBS=$RustJobs; physical RAM=$($mem.physical_ram_gb) GB; memory profile=$($mem.memory_profile)"
  Log-MemorySnapshot 'BEFORE-BUILD'
  Run-Mozilla "cd '$unix' && ./mach build" -RetryNsis
  State 'PACKAGE';Run-Mozilla "cd '$unix' && ./mach package" -RetryNsis
  $dist=Join-Path (Join-Path $SourceRoot $ObjName) 'dist';$candidate=Get-ChildItem -Path $dist -File -Filter '*.zip' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1
  if(-not $candidate){$candidate=Get-ChildItem -Path $dist -File -Filter '*.exe' -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending|Select-Object -First 1}
  if(-not $candidate){throw "Kein Paket unter $dist gefunden"}
  $flavorSuffix=if($Flavor -eq 'legacy'){'legacy'}else{$Flavor}
  $artifactName="firefox-$Version-$flavorSuffix-windows-x64"+$candidate.Extension;$target=Join-Path $ShareRoot "artifacts\$artifactName";Copy-Item $candidate.FullName $target -Force
  Log "Build erfolgreich: $artifactName"
  Collect-Diagnostics 'FINISHED'
  State 'FINISHED' '' $artifactName "artifacts/$artifactName"
  Log "WORKER: FINISHED-Status geschrieben; Buildprozess wird beendet."
  Log-MemorySnapshot 'AFTER-SUCCESS' | Out-Null
  Close-LogWriter
  exit 0
}catch{
  $m=$_.Exception.Message
  try{State 'FAILED' $m}catch{Write-Warning "FAILED-Status konnte nicht geschrieben werden: $($_.Exception.Message)"}
  try{LogOnly "FAILED: $m"}catch{}
  try{Collect-Diagnostics 'FAILED'}catch{}
  Close-LogWriter
  exit 1
}finally{
  Close-LogWriter
}
