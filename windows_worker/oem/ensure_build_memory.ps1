# Firefox Windows build memory policy (adaptive for small and large Windows VMs).
# Use the *active* total commit limit, account for already allocated C: paging
# space, and never touch the persistent D: ReFS Dev Drive. Windows may need a
# reboot before changed pagefile settings become active.
param(
  [int]$MinimumCommitGB=0,
  [int]$InitialPagefileMB=0,
  [int]$MaximumPagefileMB=0
)
$ErrorActionPreference='Stop'
$Root='C:\firefox_worker'
$Output=Join-Path $Root 'PAGEFILE.json'
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$status=[ordered]@{
  ready=$false;pending_reboot=$false;needs_attention=$false
  physical_ram_gb=$null;minimum_commit_gb=$null;commit_limit_gb=$null;free_commit_gb=$null
  c_free_gb=$null;pagefile_current_mb=$null;pagefile_c_current_mb=$null
  target_initial_mb=$null;target_maximum_mb=$null;additional_disk_mb=$null
  c_reserve_gb=$null;recommended_cpp_jobs=$null;recommended_rust_jobs=$null
  memory_profile=$null;automatic_management_restored=$false
  detail='Speicher wird geprueft';checked_at=(Get-Date -Format o)
}
$step='Initialisierung'
$turnedOffAutomaticManagement=$false
function Save-Status {
  $status.checked_at=Get-Date -Format o
  $tmp="$Output.tmp"
  $status | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $Output -Force
}
try {
  $previous=$null
  try { if(Test-Path -LiteralPath $Output){$previous=Get-Content -LiteralPath $Output -Raw | ConvertFrom-Json} } catch {}
  $step='Windows-Speicher und Laufwerk C: abfragen'
  $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $ramGB=[math]::Round([double]$os.TotalVisibleMemorySize/1048576,2)
  $limitGB=[math]::Round([double]$os.TotalVirtualMemorySize/1048576,2)
  $freeGB=[math]::Round([double]$os.FreeVirtualMemory/1048576,2)

  # Minimums are conservative starting points, NOT a guarantee of a completed
  # build. An 8-GiB full optimized build can page heavily during gkrust/LTO.
  # 24 GiB / ~32 GiB commit failed on this project; 32 GiB / ~37 GiB succeeded.
  # Keep physical RAM and build concurrency distinct from the total commit.
  if($ramGB -lt 7.5) {
    $profile='low-ram';$cpp=1;$rust=1;$recommended=32
  } elseif($ramGB -lt 12) {
    $profile='8-gb';$cpp=1;$rust=1;$recommended=32
  } elseif($ramGB -lt 20) {
    $profile='12-16-gb';$cpp=2;$rust=1;$recommended=32
  } elseif($ramGB -lt 30.5) {
    $profile='24-gb';$cpp=3;$rust=2;$recommended=36
  } elseif($ramGB -lt 47.5) {
    $profile='32-gb';$cpp=4;$rust=2;$recommended=36
  } else {
    $profile='high-ram';$cpp=[int][math]::Min(8,[math]::Max(4,[math]::Floor($ramGB/8)))
    $rust=[int][math]::Min(4,[math]::Max(2,[math]::Floor($ramGB/16)))
    $recommended=[int][math]::Ceiling($ramGB)+4
  }
  if($MinimumCommitGB -le 0){$MinimumCommitGB=$recommended}
  $status.physical_ram_gb=$ramGB
  $status.minimum_commit_gb=$MinimumCommitGB
  $status.commit_limit_gb=$limitGB
  $status.free_commit_gb=$freeGB
  $status.recommended_cpp_jobs=$cpp
  $status.recommended_rust_jobs=$rust
  $status.memory_profile=$profile

  $disk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
  if($disk){$status.c_free_gb=[math]::Round([double]$disk.FreeSpace/1GB,2)}
  $used=@(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
  $allCurrent=($used|Measure-Object -Property AllocatedBaseSize -Sum).Sum
  $status.pagefile_current_mb=if($null -eq $allCurrent){0}else{[int64]$allCurrent}
  $cCurrent=($used | Where-Object {$_.Name -ieq 'C:\pagefile.sys'} | Measure-Object -Property AllocatedBaseSize -Sum).Sum
  $cCurrentMB=if($null -eq $cCurrent){[int64]0}else{[int64]$cCurrent}
  $status.pagefile_c_current_mb=$cCurrentMB
  $settings=@(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue)
  $cSettings=@($settings | Where-Object {$_.Name -ieq 'C:\pagefile.sys'} | Select-Object -First 1)
  $computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop

  # Repair specifically recognized 0.0.10 half-configurations, without
  # overwriting someone else's explicit manual pagefile settings.
  if($previous -and [string]$previous.detail -match 'Value out of range' -and
     -not $computer.AutomaticManagedPagefile -and
     @($settings | Where-Object {$_.InitialSize -gt 0 -or $_.MaximumSize -gt 0}).Count -eq 0){
    try {
      $step='Automatische Pagefile-Verwaltung aus 0.0.10 wiederherstellen'
      Set-CimInstance -InputObject $computer -Property @{AutomaticManagedPagefile=$true} -ErrorAction Stop | Out-Null
      $computer=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
      $status.automatic_management_restored=$true
    } catch {$status.needs_attention=$true}
  }

  $step='Aktives Commit-Limit vergleichen'
  if($limitGB -ge $MinimumCommitGB){
    $status.ready=$true
    $status.detail="Commit-Limit $limitGB GB bei $ramGB GB RAM ausreichend (Richtwert $MinimumCommitGB GB, $cpp C++ / $rust Rust Jobs); Pagefile unveraendert"
    if($ramGB -lt 12){$status.detail+='; wenig RAM: grosser Swap-/Zeitbedarf trotz ausreichendem Commit-Limit moeglich'}
    if($status.automatic_management_restored){$status.detail+='; automatische Verwaltung wiederhergestellt (VM-Neustart empfohlen)'}
    elseif($status.needs_attention){$status.detail+='; fruehere Pagefile-Einstellungen bitte in Windows pruefen'}
    Save-Status
    exit 0
  }

  # Grow the EXISTING C: pagefile by only the *missing* commit amount.
  # Old implementation incorrectly calculated an entire new pagefile from RAM
  # and ignored existing C: pagefile + all other already committed paging.
  $step='Zusaetzlichen Commit-Speicher berechnen'
  $gapMB=[int64][math]::Ceiling(($MinimumCommitGB-$limitGB)*1024)
  $headroomMB=256 # small safety margin; do not demand many unnecessary GiB
  $minimumInitial=[int64][math]::Max(1024,($cCurrentMB+$gapMB+$headroomMB))
  if($InitialPagefileMB -gt 0){$minimumInitial=[int64][math]::Max($minimumInitial,$InitialPagefileMB)}
  if($cSettings.Count -gt 0 -and -not $computer.AutomaticManagedPagefile){
    $minimumInitial=[int64][math]::Max($minimumInitial,[int64]$cSettings[0].InitialSize)
  }
  # A *configured*, but not yet activated, pagefile should not be expanded
  # repeatedly on each 30s worker loop while a reboot is pending.
  if($cSettings.Count -gt 0){
    $previousInitial=[int64]$cSettings[0].InitialSize
    $previousMax=[int64]$cSettings[0].MaximumSize
    if($previousInitial -ge $minimumInitial -and $previousMax -ge $previousInitial -and -not $computer.AutomaticManagedPagefile){
      $status.target_initial_mb=$previousInitial
      $status.target_maximum_mb=$previousMax
      $status.pending_reboot=$true
      $status.detail="Commit-Limit $limitGB GB unter $MinimumCommitGB GB; C:\pagefile.sys bereits auf $previousInitial-$previousMax MB vorbereitet. Windows-VM neu starten und aktives Limit erneut pruefen."
      Save-Status
      exit 3010
    }
  }

  $step='Platzreserve und Pagefile-Groessen berechnen'
  # Small C: disks need proportional reserve. Never reduce below 4 GiB.
  $reserveMB=if($ramGB -lt 12){4096}elseif($ramGB -lt 24){6144}else{8192}
  $status.c_reserve_gb=$reserveMB/1024
  $freeMB=if($disk){[int64][math]::Floor([double]$disk.FreeSpace/1MB)}else{[int64]0}
  $safeGrowthMB=[int64][math]::Max(0,$freeMB-$reserveMB)
  $growthMB=[int64][math]::Max(0,$minimumInitial-$cCurrentMB)
  $status.target_initial_mb=$minimumInitial
  $status.additional_disk_mb=$growthMB
  # A modest maximum avoids the 0.0.10 Value-out-of-range path and leaves C:
  # a safety buffer. When too little space is available, never change paging.
  $requestedMaximum=[int64]($minimumInitial + [math]::Min(2048,[math]::Max(0,$safeGrowthMB-$growthMB)))
  if($MaximumPagefileMB -gt 0){$requestedMaximum=[int64][math]::Min($requestedMaximum,$MaximumPagefileMB)}
  $requestedMaximum=[int64][math]::Max($minimumInitial,$requestedMaximum)
  $status.target_maximum_mb=$requestedMaximum

  if(-not $disk -or $growthMB -gt $safeGrowthMB){
    $missingMB=[int64][math]::Max(0,$growthMB-$safeGrowthMB)
    $status.needs_attention=$true
    $status.detail="Commit-Limit $limitGB GB unter Richtwert $MinimumCommitGB GB ($ramGB GB RAM). C: braucht zusaetzlich ca. $([math]::Round($growthMB/1024,1)) GB Pagefile-Platz + $($status.c_reserve_gb) GB Reserve; frei $($status.c_free_gb) GB. Es fehlen ca. $([math]::Round($missingMB/1024,1)) GB: C:-VM-Datentraeger vergroessern oder VM-RAM bei ausreichend Host-RAM erhoehen. C: und D: nicht veraendert."
    Save-Status
    exit 2
  }

  # Do not delete / reduce other pagefiles or change the ReFS Dev Drive.
  # We only touch C: and restore AutomaticManagedPagefile after a WMI failure.
  if($computer.AutomaticManagedPagefile){
    $step='Automatische Pagefile-Verwaltung abschalten'
    Set-CimInstance -InputObject $computer -Property @{AutomaticManagedPagefile=$false} -ErrorAction Stop | Out-Null
    $turnedOffAutomaticManagement=$true
  }
  $step="C:\pagefile.sys ${minimumInitial}-${requestedMaximum} MB konfigurieren"
  if($cSettings.Count -gt 0){
    Set-CimInstance -InputObject $cSettings[0] -Property @{InitialSize=[uint32]$minimumInitial;MaximumSize=[uint32]$requestedMaximum} -ErrorAction Stop | Out-Null
  } else {
    New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name='C:\pagefile.sys';InitialSize=[uint32]$minimumInitial;MaximumSize=[uint32]$requestedMaximum} -ErrorAction Stop | Out-Null
  }
  $status.pending_reboot=$true
  $status.detail="Adaptive Pagefile C: ${minimumInitial}-${requestedMaximum} MB vorbereitet (+$([math]::Round($growthMB/1024,1)) GB gegenueber aktivem C:-Pagefile); Windows-VM neu starten, damit Commit-Limit von $limitGB auf mindestens $MinimumCommitGB GB steigen kann. D: unveraendert."
  Save-Status
  exit 3010
} catch {
  $errorMessage=$_.Exception.Message
  if($turnedOffAutomaticManagement){
    try {
      $restore=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
      Set-CimInstance -InputObject $restore -Property @{AutomaticManagedPagefile=$true} -ErrorAction Stop | Out-Null
      $status.automatic_management_restored=$true
    }catch{$errorMessage+="; automatische Verwaltung konnte nicht wiederhergestellt werden: $($_.Exception.Message)"}
  }
  $status.needs_attention=$true
  $status.detail="Pagefile-Pruefung fehlgeschlagen bei '$step': $errorMessage; C: frei=$($status.c_free_gb) GB; Ziel=$($status.target_initial_mb)-$($status.target_maximum_mb) MB. Bestehenden Datentraeger nicht veraendert, soweit moeglich."
  try{Save-Status}catch{}
  exit 1
}
