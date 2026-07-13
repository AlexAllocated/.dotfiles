param(
   [Parameter(Mandatory = $true, Position = 0)]
   [string]$InputValue,
   [string]$DistroName = "NixOS",
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
      throw "The Neovide launcher received invalid JSON: $($_.Exception.Message)"
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

$neovide = (Get-Command neovide.exe -ErrorAction SilentlyContinue).Source
if (-not $neovide) {
   $neovide = Join-Path $env:ProgramFiles "Neovide\neovide.exe"
}
if (-not (Test-Path -LiteralPath $neovide)) {
   throw "Neovide was not found. Run dotctl apply nixos-wsl to install Windows applications."
}

$neovideArgs = @("--wsl", $linuxPath)
if ($line -gt 0) {
   $neovideArgs += @("--", "+call cursor($line, $column)")
}

if ($DryRun) {
   [pscustomobject]@{
      FilePath = $neovide
      Arguments = $neovideArgs
      LinuxPath = $linuxPath
      Line = $line
      Column = $column
   } | ConvertTo-Json -Depth 4
   exit 0
}

Start-Process -FilePath $neovide -ArgumentList $neovideArgs | Out-Null
