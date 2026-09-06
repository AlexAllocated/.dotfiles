param(
   [Parameter(Mandatory = $true)]
   [string]$WallpaperPath,
   [Parameter(Mandatory = $true)]
   [string]$ProductionModeScriptPath,
   [Parameter(Mandatory = $true)]
   [string]$ProductionFrameLauncherPath,
   [Parameter(Mandatory = $true)]
   [string]$FrameLimiterPath
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

$branchOutputVersion = "1.0.9"
$branchOutputArchiveSha256 = "C5FD0AD2097494001995E78A55AE905841C6B7D58A05757AEE21C5DB5EBC6B64"
$branchOutputDllSha256 = "6950FF0E583BDB376CCA1DF06B607212A204C062AFCA376DD3907882312DD0C6"
$branchOutputUrl = "https://github.com/OPENSPHERE-Inc/branch-output/releases/download/$branchOutputVersion/osi-branch-output-$branchOutputVersion-windows-x64.zip"
$pluginRoot = Join-Path $env:ProgramData "obs-studio\plugins\osi-branch-output"
$pluginDll = Join-Path $pluginRoot "bin\64bit\osi-branch-output.dll"
$backgroundRemovalRoot = Join-Path $env:ProgramData "obs-studio\plugins\obs-backgroundremoval"
$obsRoot = Join-Path $env:APPDATA "obs-studio"
$globalConfig = Join-Path $obsRoot "global.ini"
$profileRoot = Join-Path $obsRoot "basic\profiles\HiveTech_1440p"
$profileConfig = Join-Path $profileRoot "basic.ini"
$sceneCollection = Join-Path $obsRoot "basic\scenes\HiveTech_1440p.json"
$assetRoot = Join-Path $env:LOCALAPPDATA "dotfiles\obs-assets"
$wallpaperTarget = Join-Path $assetRoot "pixel-meadow-hive-2560x1440.png"
$integrationRoot = Join-Path $env:LOCALAPPDATA "dotfiles"
$productionModeScriptTarget = Join-Path $integrationRoot "obs-production-mode.lua"
$productionFrameLauncherTarget = Join-Path $integrationRoot "obs-production-frame-limit.vbs"
$frameLimiterTarget = Join-Path $integrationRoot "set-nvidia-frame-limit.ps1"
$audioArrayExecutable = Join-Path $env:LOCALAPPDATA "AudioArray\bin\audioarray.exe"
$audioArrayConfig = Join-Path $env:APPDATA "AudioArray\config.toml"
$obsExecutable = Join-Path $env:ProgramFiles "obs-studio\bin\64bit\obs64.exe"

function Test-FileEqual {
   param(
      [Parameter(Mandatory = $true)][string]$Source,
      [Parameter(Mandatory = $true)][string]$Destination
   )
   return (
      (Test-Path -LiteralPath $Destination -PathType Leaf) -and
      (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
         (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
   )
}

function Set-TextFileIfChanged {
   param(
      [Parameter(Mandatory = $true)][string]$Path,
      [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
   )
   $current = if (Test-Path -LiteralPath $Path -PathType Leaf) {
      [IO.File]::ReadAllText($Path)
   } else {
      $null
   }
   if ($current -ceq $Content) {
      return $false
   }
   $parent = Split-Path -Parent $Path
   if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
   }
   [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
   return $true
}

function Set-IniValue {
   param(
      [Parameter(Mandatory = $true)]
      [string]$Path,

      [Parameter(Mandatory = $true)]
      [string]$Section,

      [Parameter(Mandatory = $true)]
      [string]$Name,

      [Parameter(Mandatory = $true)]
      [string]$Value
   )

   $lines = [Collections.Generic.List[string]]::new()
   $changed = $false
   if (Test-Path -LiteralPath $Path) {
      foreach ($line in Get-Content -LiteralPath $Path) {
         $lines.Add([string]$line)
      }
   }
   $sectionPattern = "^\[$([regex]::Escape($Section))\]$"
   $sectionIndex = -1
   for ($index = 0; $index -lt $lines.Count; $index++) {
      if ($lines[$index] -match $sectionPattern) {
         $sectionIndex = $index
         break
      }
   }

   if ($sectionIndex -lt 0) {
      if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne "") {
         $lines.Add("")
      }
      $lines.Add("[$Section]")
      $lines.Add("$Name=$Value")
      $changed = $true
   } else {
      $nextSectionIndex = $lines.Count
      for ($index = $sectionIndex + 1; $index -lt $lines.Count; $index++) {
         if ($lines[$index] -match '^\[.+\]$') {
            $nextSectionIndex = $index
            break
         }
      }
      $keyPattern = "^$([regex]::Escape($Name))="
      $keyIndex = -1
      for ($index = $sectionIndex + 1; $index -lt $nextSectionIndex; $index++) {
         if ($lines[$index] -match $keyPattern) {
            $keyIndex = $index
            break
         }
      }
      if ($keyIndex -ge 0) {
         $desired = "$Name=$Value"
         if ($lines[$keyIndex] -ne $desired) {
            $lines[$keyIndex] = $desired
            $changed = $true
         }
      } else {
         $lines.Insert($nextSectionIndex, "$Name=$Value")
         $changed = $true
      }
   }

   if ($changed) {
      Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
   }
}

foreach ($requiredFile in @(
   $WallpaperPath,
   $ProductionModeScriptPath,
   $ProductionFrameLauncherPath,
   $FrameLimiterPath
)) {
   if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
      throw "OBS integration file not found: $requiredFile"
   }
}

$pluginCurrent =
   (Test-Path -LiteralPath $pluginDll -PathType Leaf) -and
   ((Get-FileHash -LiteralPath $pluginDll -Algorithm SHA256).Hash -eq $branchOutputDllSha256)
if (-not $pluginCurrent) {
   if (Get-Process obs64 -ErrorAction SilentlyContinue) {
      throw "Close OBS before installing or updating Branch Output $branchOutputVersion."
   }

   $temporaryRoot = Join-Path $env:TEMP "dotfiles-obs-$([guid]::NewGuid().ToString('N'))"
   $archivePath = Join-Path $temporaryRoot "branch-output.zip"
   $expandedPath = Join-Path $temporaryRoot "expanded"
   New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
   try {
      Invoke-WebRequest -Uri $branchOutputUrl -OutFile $archivePath -UseBasicParsing
      $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
      if ($archiveHash -ne $branchOutputArchiveSha256) {
         throw "Branch Output archive checksum mismatch: expected $branchOutputArchiveSha256, received $archiveHash."
      }
      Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedPath -Force
      New-Item -ItemType Directory -Path (Join-Path $pluginRoot "bin\64bit") -Force | Out-Null
      New-Item -ItemType Directory -Path (Join-Path $pluginRoot "data") -Force | Out-Null
      Copy-Item `
         -LiteralPath (Join-Path $expandedPath "obs-plugins\64bit\osi-branch-output.dll") `
         -Destination $pluginDll `
         -Force
      Copy-Item `
         -Path (Join-Path $expandedPath "data\obs-plugins\osi-branch-output\*") `
         -Destination (Join-Path $pluginRoot "data") `
         -Recurse `
         -Force
   } finally {
      Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
   }
   Write-Host "Installed OBS Branch Output $branchOutputVersion."
} else {
   Write-Host "OBS Branch Output $branchOutputVersion is current."
}

if (Test-Path -LiteralPath $backgroundRemovalRoot) {
   if (Get-Process obs64 -ErrorAction SilentlyContinue) {
      throw "Close OBS before removing the superseded CPU Background Removal plugin."
   }
   Remove-Item -LiteralPath $backgroundRemovalRoot -Recurse -Force
   Write-Host "Removed the superseded CPU Background Removal plugin."
}

New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
if (-not (Test-FileEqual -Source $WallpaperPath -Destination $wallpaperTarget)) {
   Copy-Item -LiteralPath $WallpaperPath -Destination $wallpaperTarget -Force
}
New-Item -ItemType Directory -Path $integrationRoot -Force | Out-Null
foreach ($integrationFile in @(
   @($ProductionModeScriptPath, $productionModeScriptTarget),
   @($ProductionFrameLauncherPath, $productionFrameLauncherTarget),
   @($FrameLimiterPath, $frameLimiterTarget)
)) {
   if (-not (Test-FileEqual -Source $integrationFile[0] -Destination $integrationFile[1])) {
      Copy-Item -LiteralPath $integrationFile[0] -Destination $integrationFile[1] -Force
   }
}
New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE "Videos\OBS") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $env:USERPROFILE "Videos\OBS Clean") -Force | Out-Null

$dockSettings = [ordered]@{
   interlock = 1
   sortingColumn = "name"
   sortingOrder = 0
}
$globalPluginRoot = Join-Path $obsRoot "plugin_config\osi-branch-output"
New-Item -ItemType Directory -Path $globalPluginRoot -Force | Out-Null
$dockJson = $dockSettings | ConvertTo-Json
$null = Set-TextFileIfChanged `
   -Path (Join-Path $globalPluginRoot "outputStatusDock.json") `
   -Content $dockJson

New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $profileConfig)) {
   Set-Content -LiteralPath $profileConfig -Value @("[General]", "Name=HiveTech 1440p") -Encoding UTF8
}

$profileValues = @(
   @("Output", "Mode", "Advanced"),
   @("Output", "FilenameFormatting", "%CCYY-%MM-%DD %hh-%mm-%ss"),
   # Keep the edit-critical clean recording on NVENC, but move the disposable
   # Twitch branch to the otherwise underused CPU. This preserves an NVENC unit
   # and GPU scheduling headroom for the recording and for an occasional
   # concurrent Sunshine session.
   @("AdvOut", "Encoder", "obs_x264"),
   @("AdvOut", "TrackIndex", "1"),
   # Preserve the 2560x1440 canvas and clean recording, but scale only the
   # Twitch stream. At 8 Mbps, 1080p60 is both cheaper to encode and cleaner
   # than trying to describe 1440p60 with the same constrained bitrate.
   @("AdvOut", "Rescale", "true"),
   @("AdvOut", "RescaleRes", "1920x1080"),
   @("AdvOut", "RecType", "Standard"),
   @("AdvOut", "RecEncoder", "obs_nvenc_hevc_tex"),
   # Track 1 is the live stream mix. Record tracks 2-6: publish-ready mix
   # without media, Clean Mic, Comms, Game, and Media respectively.
   @("AdvOut", "RecTracks", "62"),
   @("AdvOut", "RecFormat2", "mkv"),
   @("AdvOut", "RecFilePath", "C:\\Users\\$env:USERNAME\\Videos\\OBS"),
   @("AdvOut", "RecRescale", "false"),
   @("AdvOut", "Track1Bitrate", "320"),
   @("AdvOut", "Track2Bitrate", "320"),
   @("AdvOut", "Track3Bitrate", "320"),
   @("AdvOut", "Track4Bitrate", "320"),
   @("AdvOut", "Track5Bitrate", "320"),
   @("AdvOut", "Track6Bitrate", "320"),
   @("AdvOut", "Track1Name", "Stream Mix"),
   @("AdvOut", "Track2Name", "Publish Mix - No Media"),
   @("AdvOut", "Track3Name", "Clean Mic"),
   @("AdvOut", "Track4Name", "Comms"),
   @("AdvOut", "Track5Name", "Game"),
   @("AdvOut", "Track6Name", "Media"),
   @("Audio", "SampleRate", "48000"),
   @("Audio", "ChannelSetup", "Stereo"),
   @("Video", "BaseCX", "2560"),
   @("Video", "BaseCY", "1440"),
   @("Video", "OutputCX", "2560"),
   @("Video", "OutputCY", "1440"),
   @("Video", "FPSType", "2"),
   @("Video", "FPSNum", "60"),
   @("Video", "FPSDen", "1"),
   @("Video", "ScaleType", "lanczos"),
   @("Video", "ColorFormat", "NV12"),
   @("Video", "ColorSpace", "709"),
   @("Video", "ColorRange", "Partial")
)
foreach ($profileValue in $profileValues) {
   Set-IniValue `
      -Path $profileConfig `
      -Section $profileValue[0] `
      -Name $profileValue[1] `
      -Value $profileValue[2]
}

$streamEncoder = [ordered]@{
   # A 12-thread ceiling leaves 20 logical processors for the game, OBS
   # composition support, AudioArray, and Windows on Tracer's 16C/32T CPU.
   bf = 2
   bitrate = 8000
   buffer_size = 8000
   keyint_sec = 2
   preset = "fast"
   profile = "high"
   rate_control = "CBR"
   repeat_headers = $false
   tune = ""
   use_bufsize = $false
   vfr = $false
   x264opts = "threads=12"
}
$recordEncoder = [ordered]@{
   adaptive_quantization = $true
   bf = 2
   cqp = 18
   device = -1
   keyint_sec = 2
   lookahead = $false
   multipass = "disabled"
   preset = "p5"
   profile = "main"
   rate_control = "CQP"
   tune = "hq"
}
$null = Set-TextFileIfChanged `
   -Path (Join-Path $profileRoot "streamEncoder.json") `
   -Content ($streamEncoder | ConvertTo-Json)
$null = Set-TextFileIfChanged `
   -Path (Join-Path $profileRoot "recordEncoder.json") `
   -Content ($recordEncoder | ConvertTo-Json)
$null = Set-TextFileIfChanged `
   -Path (Join-Path $profileRoot "outputStatusDock.json") `
   -Content $dockJson

# Scene composition and the tokenized Bumblebee URL remain OBS-owned mutable
# state. The public repository installs the exact plugin, asset, profile, and
# encoder contract without ever persisting the private overlay token.
if (Test-Path -LiteralPath $sceneCollection) {
   $userConfig = Join-Path $obsRoot "user.ini"
   if (Test-Path -LiteralPath $userConfig) {
      Set-IniValue -Path $userConfig -Section "Basic" -Name "Profile" -Value "HiveTech 1440p"
      Set-IniValue -Path $userConfig -Section "Basic" -Name "ProfileDir" -Value "HiveTech_1440p"
      Set-IniValue -Path $userConfig -Section "Basic" -Name "SceneCollection" -Value "HiveTech 1440p"
      Set-IniValue -Path $userConfig -Section "Basic" -Name "SceneCollectionFile" -Value "HiveTech_1440p.json"
   }
}

function New-ObsAudioDevice {
   param(
      [Parameter(Mandatory = $true)][string]$Name,
      [Parameter(Mandatory = $true)][string]$Uuid,
      [Parameter(Mandatory = $true)][string]$DeviceId,
      [Parameter(Mandatory = $true)][int]$Mixers
   )

   return [ordered]@{
      prev_ver = 537001985
      name = $Name
      uuid = $Uuid
      id = "wasapi_input_capture"
      versioned_id = "wasapi_input_capture"
      settings = [ordered]@{
         device_id = $DeviceId
         use_device_timing = $false
      }
      mixers = $Mixers
      sync = 0
      flags = 0
      volume = 1.0
      balance = 0.5
      enabled = $true
      muted = $false
      "push-to-mute" = $false
      "push-to-mute-delay" = 0
      "push-to-talk" = $false
      "push-to-talk-delay" = 0
      hotkeys = [ordered]@{
         "libobs.mute" = @()
         "libobs.unmute" = @()
         "libobs.push-to-mute" = @()
         "libobs.push-to-talk" = @()
      }
      deinterlace_mode = 0
      deinterlace_field_order = 0
      monitoring_type = 0
      private_settings = [ordered]@{}
   }
}

function Set-ObsJsonProperty {
   param(
      [Parameter(Mandatory = $true)][object]$Object,
      [Parameter(Mandatory = $true)][string]$Name,
      [Parameter(Mandatory = $true)]$Value
   )

   $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function Set-CleanRecordingAudioTracks {
   param([Parameter(Mandatory = $true)][object]$SceneCollection)

   $filters = @(
      foreach ($source in @($SceneCollection.sources)) {
         foreach ($filter in @($source.filters)) {
            if ($filter.id -eq "osi_branch_output" -and $filter.name -eq "Clean HEVC Recording") {
               $filter
            }
         }
      }
   )
   if ($filters.Count -ne 1) {
      throw "Expected exactly one Clean HEVC Recording Branch Output filter; found $($filters.Count)."
   }

   $settings = $filters[0].settings
   Set-ObsJsonProperty -Object $settings -Name "custom_audio_source" -Value $true
   Set-ObsJsonProperty -Object $settings -Name "multitrack_audio" -Value $true

   # Branch Output track 1 is an edit-friendly no-music mix. Tracks 2-5 are
   # isolated Clean Mic, Comms, Game, and Media stems sourced from OBS master
   # tracks 3-6. The live stream independently uses OBS master track 1.
   $masterTracks = @(2, 3, 4, 5, 6)
   for ($index = 1; $index -le 6; $index++) {
      $suffix = if ($index -eq 1) { "" } else { "_$index" }
      if ($index -le $masterTracks.Count) {
         Set-ObsJsonProperty -Object $settings -Name "audio_source$suffix" -Value "master_track"
         Set-ObsJsonProperty -Object $settings -Name "audio_track$suffix" -Value $masterTracks[$index - 1]
         Set-ObsJsonProperty -Object $settings -Name "audio_dest$suffix" -Value "recording"
      } else {
         Set-ObsJsonProperty -Object $settings -Name "audio_source$suffix" -Value "disabled"
         Set-ObsJsonProperty -Object $settings -Name "audio_track$suffix" -Value 1
         Set-ObsJsonProperty -Object $settings -Name "audio_dest$suffix" -Value "recording"
      }
   }
}

function Set-ObsPerformancePolicy {
   param([Parameter(Mandatory = $true)][object]$SceneCollection)

   foreach ($source in @($SceneCollection.sources)) {
      if ($source.id -eq "game_capture") {
         # OBS composites at 60 FPS. Do not make the capture hook copy frames
         # from a 120/160 FPS game that the output can never consume.
         Set-ObsJsonProperty -Object $source.settings -Name "limit_framerate" -Value $true
      }
   }
}

function Set-ObsProductionModeScript {
   param([Parameter(Mandatory = $true)][object]$SceneCollection)

   if ($null -eq $SceneCollection.modules) {
      Set-ObsJsonProperty -Object $SceneCollection -Name "modules" -Value ([pscustomobject]@{})
   }

   $scriptsProperty = $SceneCollection.modules.PSObject.Properties["scripts-tool"]
   $existingScripts = if ($null -ne $scriptsProperty) { @($scriptsProperty.Value) } else { @() }
   $preservedScripts = @(
      $existingScripts | Where-Object {
         -not $_.path -or
         -not [string]::Equals(
            [IO.Path]::GetFullPath([string]$_.path),
            [IO.Path]::GetFullPath($productionModeScriptTarget),
            [StringComparison]::OrdinalIgnoreCase
         )
      }
   )
   $managedScript = [ordered]@{
      path = $productionModeScriptTarget
      settings = [ordered]@{
         launcher_path = $productionFrameLauncherTarget
      }
   }
   Set-ObsJsonProperty `
      -Object $SceneCollection.modules `
      -Name "scripts-tool" `
      -Value @($preservedScripts + $managedScript)
}

if (Test-Path -LiteralPath $obsExecutable -PathType Leaf) {
   # OBS's D3D11 GPU-reservation workaround is available only to an elevated
   # process. The per-user compatibility flag applies regardless of which
   # normal OBS shortcut or launcher starts the executable.
   $compatibilityRoot = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
   New-Item -Path $compatibilityRoot -Force | Out-Null
   $runAsAdministrator = "~ RUNASADMIN"
   $compatibilityProperties = Get-ItemProperty -Path $compatibilityRoot
   $compatibilityProperty = $compatibilityProperties.PSObject.Properties[$obsExecutable]
   $currentCompatibility = if ($null -ne $compatibilityProperty) {
      $compatibilityProperty.Value
   } else {
      $null
   }
   if ($currentCompatibility -ne $runAsAdministrator) {
      New-ItemProperty `
         -Path $compatibilityRoot `
         -Name $obsExecutable `
         -Value $runAsAdministrator `
         -PropertyType String `
         -Force | Out-Null
   }
}

# OBS's elevated GPU-priority workaround cooperates with modern Windows Game
# Mode. These are per-user policy values and do not require a machine reboot.
$gameBarRoot = "HKCU:\Software\Microsoft\GameBar"
New-Item -Path $gameBarRoot -Force | Out-Null
New-ItemProperty -Path $gameBarRoot -Name "AllowAutoGameMode" -Value 1 -PropertyType DWord -Force |
   Out-Null
New-ItemProperty -Path $gameBarRoot -Name "AutoGameModeEnabled" -Value 1 -PropertyType DWord -Force |
   Out-Null

if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {
   if (-not (Test-Path -LiteralPath $globalConfig -PathType Leaf)) {
      New-Item -ItemType Directory -Path $obsRoot -Force | Out-Null
      Set-Content -LiteralPath $globalConfig -Value @("[General]") -Encoding UTF8
   }
   Set-IniValue -Path $globalConfig -Section "General" -Name "ProcessPriority" -Value "High"
} else {
   Write-Warning "OBS is running; deferring its High process-priority setting until the next apply after OBS closes."
}

if (
   (Test-Path -LiteralPath $audioArrayExecutable -PathType Leaf) -and
   (Test-Path -LiteralPath $audioArrayConfig -PathType Leaf) -and
   (Test-Path -LiteralPath $sceneCollection -PathType Leaf)
) {
   $endpointLines = & $audioArrayExecutable --config $audioArrayConfig endpoints 2>$null
   if ($LASTEXITCODE -eq 0) {
      $endpoints = @{}
      foreach ($line in $endpointLines) {
         $parts = $line -split "`t", 2
         if ($parts.Count -eq 2) {
            $endpoints[$parts[0]] = $parts[1]
         }
      }
      $requiredEndpoints = @("game", "comms", "music", "clean_mic")
      $missingEndpoints = @($requiredEndpoints | Where-Object { -not $endpoints.ContainsKey($_) })
      if ($missingEndpoints.Count -gt 0) {
         throw "AudioArray did not resolve OBS endpoints: $($missingEndpoints -join ', ')."
      }

      if (Get-Process obs64 -ErrorAction SilentlyContinue) {
         Write-Warning "OBS is running; deferring AudioArray source injection until the next apply after OBS closes."
      } else {
         $scene = Get-Content -LiteralPath $sceneCollection -Raw | ConvertFrom-Json
         $audioDevices = @{
            AuxAudioDevice1 = New-ObsAudioDevice `
               -Name "AudioArray Clean Mic" `
               -Uuid "394efb51-33e8-4de9-bfca-004b74c27323" `
               -DeviceId $endpoints.clean_mic `
               -Mixers 7
            AuxAudioDevice2 = New-ObsAudioDevice `
               -Name "AudioArray Comms Audio" `
               -Uuid "04855d18-2817-4fa7-9e91-dfb4eb02c6b0" `
               -DeviceId $endpoints.comms `
               -Mixers 11
            AuxAudioDevice3 = New-ObsAudioDevice `
               -Name "AudioArray Game" `
               -Uuid "803f7f80-a130-47a2-805b-59fb2e653270" `
               -DeviceId $endpoints.game `
               -Mixers 19
            AuxAudioDevice4 = New-ObsAudioDevice `
               -Name "AudioArray Media" `
               -Uuid "a51eb26b-e112-48d1-9d0f-995603b3ce96" `
               -DeviceId $endpoints.music `
               -Mixers 33
         }
         foreach ($entry in $audioDevices.GetEnumerator()) {
            $scene | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value -Force
         }
         foreach ($desktopDevice in @("DesktopAudioDevice1", "DesktopAudioDevice2")) {
            if ($scene.PSObject.Properties.Name -contains $desktopDevice) {
               $scene.PSObject.Properties.Remove($desktopDevice)
            }
         }
         Set-CleanRecordingAudioTracks -SceneCollection $scene
         Set-ObsPerformancePolicy -SceneCollection $scene
         Set-ObsProductionModeScript -SceneCollection $scene
         $sceneChanged = Set-TextFileIfChanged `
            -Path $sceneCollection `
            -Content ($scene | ConvertTo-Json -Depth 100)
         if ($sceneChanged) {
            Write-Host "Configured OBS stream mix and five-track clean recording."
         } else {
            Write-Host "OBS stream mix and five-track clean recording are current."
         }
      }
   } else {
      Write-Warning "AudioArray VAC endpoints are not ready; leaving the OBS scene collection unchanged."
   }
}

# The production limiter is independent of AudioArray endpoint discovery. Keep
# it loaded even during a future first boot or temporary audio-driver outage.
if (
   (Test-Path -LiteralPath $sceneCollection -PathType Leaf) -and
   -not (Get-Process obs64 -ErrorAction SilentlyContinue)
) {
   $scene = Get-Content -LiteralPath $sceneCollection -Raw | ConvertFrom-Json
   Set-ObsPerformancePolicy -SceneCollection $scene
   Set-ObsProductionModeScript -SceneCollection $scene
   $null = Set-TextFileIfChanged `
      -Path $sceneCollection `
      -Content ($scene | ConvertTo-Json -Depth 100)
}

Write-Host "OBS 1080p x264 stream, 1440p NVENC clean recording, lifetime GPU headroom, six-track AudioArray contract, and meadow asset are current."
