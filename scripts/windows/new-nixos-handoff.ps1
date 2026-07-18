[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$ThreadId,

    [int]$BootPartitionNumber = -1,

    [int]$RootPartitionNumber = -1,

    [string]$OutputRoot = 'C:\NixOS-Handoff',
    [string]$WslDistro = 'NixOS',
    [string]$WslCodexHome = '/mnt/c/Users/chev/.codex',
    [string]$WslSqliteHome = '/home/alex/.codex/sqlite',
    [string]$WslDotfiles = '/home/alex/.dotfiles',
    [string]$Workspace = '/home/alex',
    [string]$AllowLiveThread = '',
    [switch]$CaptureDiskOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$EspType = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b'
$XbootldrType = 'bc13c2ff-59e6-4262-a352-b275fd6f7172'
$LinuxDataType = '0fc63daf-8483-4772-8e79-3d69d8477de4'

function Normalize-Guid([object]$Value) {
    return ([string]$Value).Trim().Trim('{', '}').ToLowerInvariant()
}

function Normalize-Serial([string]$Value) {
    return ([regex]::Replace($Value.ToUpperInvariant(), '[\._:\-\s]', ''))
}

function Get-GptDiskGuid([int]$DiskNumber) {
    $diskpartOutput = @(
        "select disk $DiskNumber"
        'uniqueid disk'
        'exit'
    ) | & "$env:SystemRoot\System32\diskpart.exe"
    $match = [regex]::Match(
        ($diskpartOutput -join "`n"),
        '(?im)^\s*Disk ID:\s*\{?([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\}?\s*$'
    )
    if (-not $match.Success) {
        throw "diskpart did not return a GPT disk GUID for disk $DiskNumber."
    }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Get-VolumeRecord([object]$Partition) {
    $volume = $null
    try {
        $volume = $Partition | Get-Volume -ErrorAction Stop
    }
    catch {
        $volume = $null
    }

    $fileSystem = $null
    $label = $null
    if ($null -ne $volume) {
        $windowsFileSystem = ([string]$volume.FileSystem).Trim().ToUpperInvariant()
        switch ($windowsFileSystem) {
            'FAT32' { $fileSystem = 'vfat' }
            'NTFS' { $fileSystem = 'ntfs' }
            'REFS' { $fileSystem = 'refs' }
            'RAW' { $fileSystem = $null }
            '' { $fileSystem = $null }
            default { $fileSystem = $windowsFileSystem.ToLowerInvariant() }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$volume.FileSystemLabel)) {
            $label = [string]$volume.FileSystemLabel
        }
    }

    return @{
        FileSystem = $fileSystem
        Label = $label
        Volume = $volume
    }
}

function Copy-StableFile([string]$Source, [string]$Destination) {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $before = Get-Item -LiteralPath $Source
        $data = [IO.File]::ReadAllBytes($Source)
        $after = Get-Item -LiteralPath $Source
        if ($before.Length -eq $after.Length -and
            $before.LastWriteTimeUtc -eq $after.LastWriteTimeUtc -and
            $data.LongLength -eq $after.Length) {
            [IO.File]::WriteAllBytes($Destination, $data)
            return
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Could not take a stable snapshot of $Source"
}

function New-PartitionRecord(
    [object]$Partition,
    [string]$Role,
    [string]$IntendedMount,
    [Int64]$LogicalSectorSize
) {
    if (($Partition.Offset % $LogicalSectorSize) -ne 0 -or ($Partition.Size % $LogicalSectorSize) -ne 0) {
        throw "Partition $($Partition.PartitionNumber) is not aligned to the logical sector size."
    }
    $startSector = [Int64]($Partition.Offset / $LogicalSectorSize)
    $sectorCount = [Int64]($Partition.Size / $LogicalSectorSize)
    $volumeRecord = Get-VolumeRecord $Partition
    return [ordered]@{
        role = $Role
        partuuid = Normalize-Guid $Partition.Guid
        gptType = Normalize-Guid $Partition.GptType
        startSector = $startSector
        endSector = [Int64]($startSector + $sectorCount - 1)
        sectorCount = $sectorCount
        byteSize = [Int64]$Partition.Size
        fsType = $volumeRecord.FileSystem
        fsLabel = $volumeRecord.Label
        intendedMount = $IntendedMount
    }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this read-only capture/export script from an elevated PowerShell window.'
}

$liveWindowsProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(Codex|ChatGPT)$'
})
if ($liveWindowsProcesses.Count -gt 0 -and $AllowLiveThread.ToLowerInvariant() -ne $ThreadId.ToLowerInvariant()) {
    $names = ($liveWindowsProcesses | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', '
    throw "Close every Windows Codex/ChatGPT writer before exporting. Still running: $names"
}

$systemLetter = $env:SystemDrive.Substring(0, 1)
$windowsPartition = Get-Partition -DriveLetter $systemLetter
$disk = Get-Disk -Number $windowsPartition.DiskNumber
if ([string]$disk.PartitionStyle -ne 'GPT') {
    throw "The Windows system disk is not GPT: disk $($disk.Number)"
}

$wmiDisk = Get-CimInstance Win32_DiskDrive | Where-Object { [int]$_.Index -eq [int]$disk.Number }
if (@($wmiDisk).Count -ne 1) {
    throw "Could not uniquely map Get-Disk $($disk.Number) to Win32_DiskDrive."
}
$logicalSectorSize = [Int64]$wmiDisk.BytesPerSector
if ($logicalSectorSize -lt 512 -or ($disk.Size % $logicalSectorSize) -ne 0) {
    throw 'System disk size is incompatible with its Win32_DiskDrive logical sector size.'
}
$model = [string]$disk.FriendlyName
if ([string]::IsNullOrWhiteSpace($model)) {
    throw 'Windows did not report a model for the system disk.'
}
$model = $model.Trim()
if ($model.StartsWith('WDC ', [StringComparison]::OrdinalIgnoreCase)) {
    $model = $model.Substring(4)
}
$serial = Normalize-Serial ([string]$disk.SerialNumber)
if ([string]::IsNullOrWhiteSpace($serial)) {
    throw 'Windows did not report a serial number for the system disk.'
}
$uniqueId = $null
if (-not [string]::IsNullOrWhiteSpace([string]$disk.UniqueId)) {
    $uniqueId = ([string]$disk.UniqueId).Trim().ToLowerInvariant()
}
$systemDiskRecord = [ordered]@{
    model = $model
    normalizedSerial = $serial
    platformUniqueId = $uniqueId
    gptDiskGuid = Get-GptDiskGuid $disk.Number
    logicalSectorSize = $logicalSectorSize
    byteSize = [Int64]$disk.Size
    sectorCount = [Int64]($disk.Size / $logicalSectorSize)
}

if ($CaptureDiskOnly) {
    $systemDiskRecord | ConvertTo-Json -Depth 5
    exit 0
}
if ($BootPartitionNumber -lt 1 -or $RootPartitionNumber -lt 1) {
    throw 'BootPartitionNumber and RootPartitionNumber are required unless -CaptureDiskOnly is used.'
}

$partitions = @(Get-Partition -DiskNumber $disk.Number)
$espPartitions = @($partitions | Where-Object { (Normalize-Guid $_.GptType) -eq $EspType })
if ($espPartitions.Count -ne 1) {
    throw "Expected exactly one EFI System Partition on the Windows system disk; found $($espPartitions.Count)."
}
$esp = $espPartitions[0]
$xbootldr = Get-Partition -DiskNumber $disk.Number -PartitionNumber $BootPartitionNumber
$nixRoot = Get-Partition -DiskNumber $disk.Number -PartitionNumber $RootPartitionNumber

if ((Normalize-Guid $xbootldr.GptType) -ne $XbootldrType) {
    throw "Partition $BootPartitionNumber is not an XBOOTLDR GPT partition."
}
if ((Normalize-Guid $nixRoot.GptType) -ne $LinuxDataType) {
    throw "Partition $RootPartitionNumber is not a Linux data GPT partition."
}
if ([Int64]$esp.Size -ne 104857600) {
    throw "The existing Windows ESP is not exactly 100 MiB; found $($esp.Size) bytes."
}
if ([Int64]$xbootldr.Size -lt 1GB) {
    throw 'XBOOTLDR is below the 1 GiB safety minimum.'
}
if ([Int64]$nixRoot.Size -lt 80GB) {
    throw 'The NixOS root partition is below the 80 GiB safety minimum.'
}

$partitionGuids = @(
    (Normalize-Guid $esp.Guid),
    (Normalize-Guid $xbootldr.Guid),
    (Normalize-Guid $nixRoot.Guid)
)
if (@($partitionGuids | Select-Object -Unique).Count -ne 3) {
    throw 'ESP, XBOOTLDR, and NixOS root do not have distinct partition GUIDs.'
}

$espVolumeRecord = Get-VolumeRecord $esp
if ($espVolumeRecord.FileSystem -ne 'vfat') {
    throw 'The selected Windows ESP is not FAT32.'
}
$espPaths = @($esp.AccessPaths)
if ($null -ne $espVolumeRecord.Volume -and $espVolumeRecord.Volume.PSObject.Properties.Name -contains 'Path') {
    $espPaths += [string]$espVolumeRecord.Volume.Path
}
$espVolumePath = $espPaths | Where-Object { $_ -like '\\?\Volume{*}\' } | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace([string]$espVolumePath)) {
    throw 'Windows did not expose a read-only volume path for the ESP.'
}
$microsoftLoader = Join-Path $espVolumePath 'EFI\Microsoft\Boot\bootmgfw.efi'
if (-not (Test-Path -LiteralPath $microsoftLoader -PathType Leaf)) {
    throw "Microsoft Boot Manager was not found on the selected ESP: $microsoftLoader"
}
$microsoftLoaderHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $microsoftLoader).Hash.ToLowerInvariant()
$fallbackLoader = Join-Path $espVolumePath 'EFI\BOOT\BOOTX64.EFI'
$fallbackPresent = Test-Path -LiteralPath $fallbackLoader -PathType Leaf
$fallbackHash = $null
if ($fallbackPresent) {
    $fallbackHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fallbackLoader).Hash.ToLowerInvariant()
}

$machineManifest = [ordered]@{
    schemaVersion = 1
    kind = 'chev-desktop-machine'
    modelNormalization = 'trim; remove leading WDC vendor token only'
    serialNormalization = 'uppercase; remove period underscore colon hyphen and ASCII whitespace only'
    systemDisk = $systemDiskRecord
    windowsBoot = [ordered]@{
        microsoftLoaderSha256 = $microsoftLoaderHash
        fallbackPresent = $fallbackPresent
        fallbackSha256 = $fallbackHash
    }
    partitions = [ordered]@{
        windowsEsp = New-PartitionRecord $esp 'windows-esp' '/efi' $logicalSectorSize
        xbootldr = New-PartitionRecord $xbootldr 'xbootldr' '/boot' $logicalSectorSize
        nixRoot = New-PartitionRecord $nixRoot 'nix-root' '/' $logicalSectorSize
    }
}

$finalPath = Join-Path $OutputRoot 'v1'
if (Test-Path -LiteralPath $finalPath) {
    throw "Refusing to overwrite an existing capsule: $finalPath"
}
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$stagingPath = Join-Path $OutputRoot ('.v1.staging.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingPath | Out-Null

try {
    $wslStagingPath = (& wsl.exe --distribution $WslDistro --exec wslpath -a -u $stagingPath).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($wslStagingPath)) {
        throw 'Could not translate the capsule staging path into WSL.'
    }

    $codexExporter = "$WslDotfiles/scripts/nixos/export-codex-handoff.py"
    $codexArguments = @(
        $codexExporter,
        '--thread-id', $ThreadId,
        '--codex-home', $WslCodexHome,
        '--sqlite-home', $WslSqliteHome,
        '--destination', $wslStagingPath
    )
    if (-not [string]::IsNullOrWhiteSpace($AllowLiveThread)) {
        $codexArguments += @('--allow-live-thread', $AllowLiveThread)
    }
    & wsl.exe --distribution $WslDistro --exec python3 @codexArguments
    if ($LASTEXITCODE -ne 0) {
        throw 'The WSL Codex online backup/export failed.'
    }

    $dotfilesStatus = (& wsl.exe --distribution $WslDistro --exec git -C $WslDotfiles status --porcelain=v1).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect the dotfiles Git worktree.'
    }
    if (-not [string]::IsNullOrWhiteSpace($dotfilesStatus)) {
        throw "Commit the dotfiles worktree before capsule export. Remaining changes:`n$dotfilesStatus"
    }
    $wslBundleDirectory = "$wslStagingPath/dotfiles"
    & wsl.exe --distribution $WslDistro --exec mkdir -p $wslBundleDirectory
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the capsule dotfiles directory.'
    }
    $wslBundle = "$wslBundleDirectory/repository.bundle"
    & wsl.exe --distribution $WslDistro --exec git -C $WslDotfiles bundle create $wslBundle --all
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create the dotfiles Git bundle.'
    }
    & wsl.exe --distribution $WslDistro --exec git bundle verify $wslBundle
    if ($LASTEXITCODE -ne 0) {
        throw 'The dotfiles Git bundle failed verification.'
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $machinePath = Join-Path $stagingPath 'machine-manifest.json'
    [IO.File]::WriteAllText($machinePath, ($machineManifest | ConvertTo-Json -Depth 10), $utf8)

    $sunshineSource = Join-Path $env:ProgramFiles 'Sunshine\config'
    $sunshineTarget = Join-Path $stagingPath 'sunshine'
    $sunshineCredentialsTarget = Join-Path $sunshineTarget 'credentials'
    New-Item -ItemType Directory -Path $sunshineCredentialsTarget -Force | Out-Null
    $sunshineStateTarget = Join-Path $sunshineTarget 'sunshine_state.json'
    $sunshineCertTarget = Join-Path $sunshineCredentialsTarget 'cacert.pem'
    $sunshineKeyTarget = Join-Path $sunshineCredentialsTarget 'cakey.pem'
    Copy-StableFile (Join-Path $sunshineSource 'sunshine_state.json') $sunshineStateTarget
    Copy-StableFile (Join-Path $sunshineSource 'credentials\cacert.pem') $sunshineCertTarget
    Copy-StableFile (Join-Path $sunshineSource 'credentials\cakey.pem') $sunshineKeyTarget

    $sunshineState = Get-Content -LiteralPath $sunshineStateTarget -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$sunshineState.root.uniqueid) -or
        $null -eq $sunshineState.root.named_devices) {
        throw 'Sunshine state is missing root.uniqueid or root.named_devices.'
    }
    $null = New-Object -TypeName Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $sunshineCertTarget
    $privateKeyText = [IO.File]::ReadAllText($sunshineKeyTarget)
    if ($privateKeyText -notmatch '(?s)^-----BEGIN (?:RSA )?PRIVATE KEY-----\s+.+\s+-----END (?:RSA )?PRIVATE KEY-----\s*$') {
        throw 'Sunshine cakey.pem is not a complete PEM private key.'
    }

    $handoff = @"
# NixOS migration handoff

Thread: $ThreadId
Workspace: $Workspace

This capsule was exported using an online SQLite backup and a stable JSONL snapshot.
Use resume-migration from the internal installer; do not copy these secrets
into a Git repository or an ISO.
"@
    [IO.File]::WriteAllText((Join-Path $stagingPath 'handoff.md'), $handoff, $utf8)

    $fileRecords = @()
    $totalBytes = [Int64]0
    foreach ($file in (Get-ChildItem -LiteralPath $stagingPath -File -Recurse | Sort-Object FullName)) {
        $relativePath = $file.FullName.Substring($stagingPath.Length).TrimStart('\').Replace('\', '/')
        if ($relativePath -eq 'manifest.json') {
            continue
        }
        if ($file.Length -gt 2GB) {
            throw "Capsule file exceeds 2 GiB: $relativePath"
        }
        $totalBytes += $file.Length
        if ($totalBytes -gt 4GB) {
            throw 'Capsule payload exceeds 4 GiB.'
        }
        $fileRecords += [ordered]@{
            path = $relativePath
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        }
    }

    $capsuleManifest = [ordered]@{
        schemaVersion = 1
        threadId = $ThreadId.ToLowerInvariant()
        workspace = $Workspace
        files = $fileRecords
    }
    [IO.File]::WriteAllText(
        (Join-Path $stagingPath 'manifest.json'),
        ($capsuleManifest | ConvertTo-Json -Depth 10),
        $utf8
    )

    Move-Item -LiteralPath $stagingPath -Destination $finalPath
    Write-Host "Created migration capsule: $finalPath"
    Write-Warning 'The capsule contains Codex authentication and Sunshine private keys. Keep it local.'
}
catch {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
    throw
}
