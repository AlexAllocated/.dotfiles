param(
   [string]$DistroName = "NixOS"
)

$ErrorActionPreference = "Stop"

function Resolve-DockerCli {
   $candidates = @(
      (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"),
      (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin\docker.exe")
   )
   foreach ($candidate in $candidates) {
      if (Test-Path -LiteralPath $candidate) {
         return $candidate
      }
   }
   throw "Docker Desktop is not installed. Reconcile the Windows WinGet manifest first."
}

$docker = Resolve-DockerCli
$settingsPath = Join-Path $env:APPDATA "Docker\settings-store.json"

if (-not (Test-Path -LiteralPath $settingsPath)) {
   & $docker desktop start --timeout 120
   if ($LASTEXITCODE -ne 0) {
      throw "Docker Desktop did not initialize successfully."
   }
}
if (-not (Test-Path -LiteralPath $settingsPath)) {
   throw "Docker Desktop settings were not created at $settingsPath."
}

$desktopStatus = $null
$statusOutput = & $docker desktop status --format json 2>$null
if ($LASTEXITCODE -eq 0) {
   $desktopStatus = ($statusOutput -join "`n" | ConvertFrom-Json).Status
}
if ($desktopStatus -ne "stopped") {
   & $docker desktop stop --timeout 120
   if ($LASTEXITCODE -ne 0) {
      throw "Docker Desktop did not stop cleanly before settings reconciliation."
   }
}

$settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
$settings | Add-Member -NotePropertyName "AutoStart" -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName "EnableIntegrationWithDefaultWslDistro" -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName "IntegratedWslDistros" -NotePropertyValue ([string[]]@($DistroName)) -Force

$temporarySettings = "$settingsPath.dotfiles.tmp"
$json = $settings | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($temporarySettings, $json, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporarySettings -Destination $settingsPath -Force

& $docker desktop start --timeout 120
if ($LASTEXITCODE -ne 0) {
   throw "Docker Desktop did not start after settings reconciliation."
}

Write-Host "Docker Desktop is configured to start automatically and integrate with WSL distro '$DistroName'."
