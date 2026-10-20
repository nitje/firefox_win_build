$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = 'C:\firefox_worker'
$StatusPath = Join-Path $Root 'DEVDRIVE.json'
$Label = 'FirefoxDevDrive'
$MinimumBytes = 50GB

New-Item -ItemType Directory -Force -Path $Root | Out-Null

function Write-DevStatus {
    param(
        [bool]$Ready,
        [string]$Detail,
        [Nullable[int]]$DiskNumber = $null,
        [string]$FileSystem = '',
        [Nullable[double]]$SizeGB = $null
    )
    $obj = [ordered]@{
        ready = $Ready
        letter = 'D:'
        filesystem = $FileSystem
        label = $Label
        detail = $Detail
        disk_number = $DiskNumber
        size_gb = $SizeGB
        source_root = 'D:\mozilla-source'
        build_root = 'D:\firefox-builds'
        checked_at = (Get-Date -Format o)
    }
    $tmp = "$StatusPath.tmp"
    $obj | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StatusPath -Force
    $obj | ConvertTo-Json -Compress -Depth 4
}

function Test-DevDriveLetter([string]$Letter) {
    if (-not (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue)) { return $false }
    & fsutil.exe devdrv query "${Letter}:" *> $null
    return ($LASTEXITCODE -eq 0)
}

function Get-DiskForLetter([string]$Letter) {
    try {
        $partition = Get-Partition -DriveLetter $Letter -ErrorAction Stop
        return ($partition | Get-Disk -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Release-DIfTemporary {
    $volume = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
    if (-not $volume) { return }

    $dDisk = Get-DiskForLetter 'D'
    if ($dDisk -and $script:TargetDisk -and $dDisk.Number -eq $script:TargetDisk.Number) { return }

    # During dockur/windows first setup D: can temporarily be an OEM/install FAT volume.
    # Only release obviously temporary media. Never steal D: from a normal data disk.
    $partition = Get-Partition -DriveLetter D -ErrorAction SilentlyContinue
    $partitionSize = if ($partition) { [double]$partition.Size } else { 0 }
    $isTemporary = ($volume.DriveType -in @('CD-ROM','Removable')) -or
                   (($volume.FileSystem -in @('FAT','FAT32')) -and ($partitionSize -eq 0 -or $partitionSize -lt 8GB))
    if (-not $isTemporary) {
        throw "D: ist bereits durch ein anderes dauerhaftes Volume belegt ($($volume.FileSystem), $($volume.DriveType))."
    }

    if ($partition) {
        Remove-PartitionAccessPath -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -AccessPath 'D:\' -ErrorAction SilentlyContinue
    } else {
        & mountvol.exe D: /D *> $null
    }
    Start-Sleep -Milliseconds 500
}

try {
    # Fast path: a real D: Dev Drive already exists.
    if (Test-DevDriveLetter 'D') {
        $vol = Get-Volume -DriveLetter D -ErrorAction Stop
        $disk = Get-DiskForLetter 'D'
        try { & fsutil.exe devdrv trust D: *> $null } catch {}
        New-Item -ItemType Directory -Force -Path 'D:\mozilla-source','D:\firefox-builds' | Out-Null
        Write-DevStatus -Ready $true -Detail 'Persistenter Dev Drive bereits vorhanden' -DiskNumber $disk.Number -FileSystem $vol.FileSystem -SizeGB ([math]::Round($disk.Size / 1GB, 1))
        exit 0
    }

    $systemDisk = (Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop)
    $candidates = @(Get-Disk | Where-Object {
        $_.Number -ne $systemDisk.Number -and
        -not $_.IsBoot -and
        -not $_.IsSystem -and
        $_.Size -ge $MinimumBytes
    })
    if (-not $candidates) {
        Write-DevStatus -Ready $false -Detail 'Kein persistenter zweiter Datenträger >= 50 GB erkannt'
        exit 20
    }

    # Prefer an already-labelled Firefox Dev Drive, then RAW disks, then the largest
    # secondary disk. /storage2 is dedicated to this worker in compose.yaml.
    $labelledDisk = $null
    foreach ($disk in $candidates) {
        $volumes = @(Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue)
        if ($volumes | Where-Object { $_.FileSystemLabel -eq $Label }) { $labelledDisk = $disk; break }
    }
    if ($labelledDisk) {
        $script:TargetDisk = $labelledDisk
    } else {
        $script:TargetDisk = $candidates | Sort-Object @{Expression={ if ($_.PartitionStyle -eq 'RAW') {0} else {1} }}, @{Expression='Size';Descending=$true} | Select-Object -First 1
    }

    Set-Disk -Number $script:TargetDisk.Number -IsOffline $false -ErrorAction SilentlyContinue
    Set-Disk -Number $script:TargetDisk.Number -IsReadOnly $false -ErrorAction SilentlyContinue

    # Recover a previously-created Dev Drive that merely lost its drive letter.
    $targetPartitions = @(Get-Partition -DiskNumber $script:TargetDisk.Number -ErrorAction SilentlyContinue)
    foreach ($part in $targetPartitions) {
        $vol = $part | Get-Volume -ErrorAction SilentlyContinue
        if (-not $vol -or $vol.FileSystemLabel -ne $Label -or $vol.FileSystem -ne 'ReFS') { continue }
        Release-DIfTemporary
        if ($part.DriveLetter -and $part.DriveLetter -ne 'D') {
            Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter D -ErrorAction Stop
        } elseif (-not $part.DriveLetter) {
            Add-PartitionAccessPath -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -AccessPath 'D:\' -ErrorAction Stop
        }
        if (Test-DevDriveLetter 'D') {
            try { & fsutil.exe devdrv trust D: *> $null } catch {}
            New-Item -ItemType Directory -Force -Path 'D:\mozilla-source','D:\firefox-builds' | Out-Null
            $vol = Get-Volume -DriveLetter D -ErrorAction Stop
            Write-DevStatus -Ready $true -Detail 'Persistenter Dev Drive wieder als D: eingebunden' -DiskNumber $script:TargetDisk.Number -FileSystem $vol.FileSystem -SizeGB ([math]::Round($script:TargetDisk.Size / 1GB, 1))
            exit 0
        }
    }

    Release-DIfTemporary

    # The secondary /storage2 disk is dedicated to build data. If it is not already
    # a valid Dev Drive, recreate it once as a genuine ReFS Dev Drive.
    if ($script:TargetDisk.PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $script:TargetDisk.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 500
    }
    $disk = Get-Disk -Number $script:TargetDisk.Number
    if ($disk.PartitionStyle -eq 'RAW') {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
    }
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter D -ErrorAction Stop

    # Do not fall back to FAT/NTFS/plain ReFS: the Dev Drive designation must be
    # created at format time.
    Format-Volume -DriveLetter D -DevDrive -NewFileSystemLabel $Label -Confirm:$false -Force -ErrorAction Stop | Out-Null
    if (-not (Test-DevDriveLetter 'D')) {
        throw 'D: wurde formatiert, aber Windows erkennt es nicht als Dev Drive'
    }
    try { & fsutil.exe devdrv trust D: *> $null } catch {}
    New-Item -ItemType Directory -Force -Path 'D:\mozilla-source','D:\firefox-builds' | Out-Null
    $vol = Get-Volume -DriveLetter D -ErrorAction Stop
    Write-DevStatus -Ready $true -Detail 'Persistenter /storage2-Datenträger als ReFS Dev Drive D: eingerichtet' -DiskNumber $disk.Number -FileSystem $vol.FileSystem -SizeGB ([math]::Round($disk.Size / 1GB, 1))
    exit 0
} catch {
    $msg = $_.Exception.Message
    try {
        $vol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
        $fs = if ($vol) { [string]$vol.FileSystem } else { '' }
        Write-DevStatus -Ready $false -Detail $msg -FileSystem $fs | Out-Null
    } catch {}
    Write-Error $msg
    exit 21
}
