param(
   [string]$DistroName = "Ubuntu-26.04",
   [string]$SourceDistroName = "NixOS",
   [string]$LinuxUser = "alx",
   [int]$TemporarySshPort = 2222
)

$ErrorActionPreference = "Stop"
$Wsl = "$env:SystemRoot\System32\wsl.exe"
$StagingDirectory = Join-Path $env:LOCALAPPDATA "dotfiles\ubuntu-wsl-bootstrap"

function Invoke-WslChecked {
   param([string[]]$Arguments)

   & $Wsl @Arguments
   if ($LASTEXITCODE -ne 0) {
      throw "wsl.exe $($Arguments -join ' ') exited with status $LASTEXITCODE."
   }
}

function Convert-WindowsPathToWsl {
   param([Parameter(Mandatory = $true)][string]$Path)

   $fullPath = [IO.Path]::GetFullPath($Path)
   if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') {
      throw "Bootstrap staging path is not on a Windows drive: $fullPath"
   }
   $drive = $Matches[1].ToLowerInvariant()
   $tail = $Matches[2] -replace '\\', '/'
   return "/mnt/$drive/$tail"
}

if (-not (Test-Path -LiteralPath $Wsl)) {
   throw "wsl.exe was not found."
}

$installedDistros = @(& $Wsl --list --quiet | ForEach-Object { ($_ -replace "`0", "").Trim() })
$newInstall = $DistroName -notin $installedDistros
if ($newInstall) {
   Write-Host "Installing $DistroName alongside $SourceDistroName."
   Invoke-WslChecked @("--install", "--distribution", $DistroName, "--web-download", "--no-launch")
} else {
   Write-Host "WSL distro '$DistroName' already exists; reconciling it in place."
}

New-Item -ItemType Directory -Force -Path $StagingDirectory | Out-Null
$rootScript = Join-Path $StagingDirectory "ubuntu-wsl-root.sh"
$userScript = Join-Path $StagingDirectory "ubuntu-wsl-user.sh"
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "ubuntu-wsl-root.sh") -Destination $rootScript -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "ubuntu-wsl-user.sh") -Destination $userScript -Force

$authorizedKeys = Join-Path $StagingDirectory "authorized_keys"
$sourceExists = $SourceDistroName -in $installedDistros
if ($sourceExists) {
   $keyOutput = & $Wsl --distribution $SourceDistroName --user $LinuxUser --exec `
      /bin/sh -lc 'test -s "$HOME/.ssh/authorized_keys" && cat "$HOME/.ssh/authorized_keys"'
   if ($LASTEXITCODE -eq 0 -and $keyOutput) {
      [IO.File]::WriteAllLines($authorizedKeys, @($keyOutput), [Text.UTF8Encoding]::new($false))
   }
}

$rootWslPath = Convert-WindowsPathToWsl $rootScript
$userWslPath = Convert-WindowsPathToWsl $userScript
$rootArguments = @(
   "--distribution", $DistroName,
   "--user", "root",
   "--exec", "/bin/bash", $rootWslPath,
   "--user", $LinuxUser,
   "--ssh-port", [string]$TemporarySshPort
)
if (Test-Path -LiteralPath $authorizedKeys) {
   $rootArguments += @("--authorized-keys", (Convert-WindowsPathToWsl $authorizedKeys))
}

$rootOutput = & $Wsl @rootArguments
if ($LASTEXITCODE -ne 0) {
   throw "Ubuntu system bootstrap exited with status $LASTEXITCODE."
}
$rootOutput | Write-Host
if ($newInstall -or ($rootOutput -match '^WSL_RESTART_REQUIRED=1$')) {
   Write-Host "Restarting only $DistroName once so its systemd configuration takes effect."
   Invoke-WslChecked @("--terminate", $DistroName)
}

Invoke-WslChecked ($rootArguments + "--install-nix")
Invoke-WslChecked @(
   "--distribution", $DistroName,
   "--user", $LinuxUser,
   "--exec", "/bin/bash", $userWslPath
)

Write-Host "$DistroName is installed beside $SourceDistroName with the Ubuntu-WSL Home Manager profile active."
