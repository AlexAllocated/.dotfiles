param(
   [Parameter(Mandatory = $true, Position = 0)]
   [string]$InputValue,
   [string]$DistroName = "NixOS",
   [string]$LinuxUser = "alex",
   [switch]$NewTab,
   [switch]$DryRun
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

$path = $InputValue
$line = 0
$column = 1

if ($InputValue.TrimStart().StartsWith("{")) {
   try {
      $request = $InputValue | ConvertFrom-Json -ErrorAction Stop
      if ($request.path) {
         $path = [string]$request.path
      }
      if ($request.location.line) {
         $line = [Math]::Max(0, [int]$request.location.line)
      }
      if ($request.location.column) {
         $column = [Math]::Max(1, [int]$request.location.column)
      }
   } catch {
      throw "The Neovim launcher received invalid JSON: $($_.Exception.Message)"
   }
}

if (-not $path) {
   throw "No file path was provided."
}

if ($path.StartsWith("/")) {
   $linuxPath = $path
} else {
   $translatedPath = & wsl.exe -d $DistroName --exec wslpath -u -- $path
   $translateStatus = $LASTEXITCODE
   $linuxPath = ([string]($translatedPath | Select-Object -Last 1) -replace "`0", "").Trim()
   if ($translateStatus -ne 0 -or -not $linuxPath.StartsWith("/")) {
      throw "Could not translate '$path' into a path in the '$DistroName' WSL distribution."
   }
}

$wezTerm = (Get-Command wezterm.exe -ErrorAction SilentlyContinue).Source
if (-not $wezTerm) {
   $wezTerm = Join-Path $env:ProgramFiles "WezTerm\wezterm.exe"
}
if (-not (Test-Path -LiteralPath $wezTerm)) {
   throw "WezTerm was not found."
}

$launcherPath = "/home/$LinuxUser/.dotfiles/scripts/windows/open-in-nvim.sh"

$wezTermArgs = @("start", "--domain", "local")
if ($NewTab) {
   $wezTermArgs += "--new-tab"
}
$wezTermArgs += @(
   "--",
   "wsl.exe",
   "-d",
   $DistroName,
   "--exec",
   "/usr/bin/bash",
   $launcherPath,
   $linuxPath,
   [string]$line,
   [string]$column
)

if ($DryRun) {
   [pscustomobject]@{
      FilePath = $wezTerm
      Arguments = $wezTermArgs
      LinuxPath = $linuxPath
      Line = $line
      Column = $column
   } | ConvertTo-Json -Depth 4
   exit 0
}

& $wezTerm @wezTermArgs
if ($LASTEXITCODE -ne 0) {
   throw "WezTerm exited with status $LASTEXITCODE."
}
