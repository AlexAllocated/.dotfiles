param(
   [string]$DistroName = "NixOS",
   [string]$LinuxHome = ""
)

$ErrorActionPreference = "Stop"

trap {
   Write-Error $_
   exit 1
}

function Normalize-WslTarget {
   param([string]$RelativePath)
   $relative = $RelativePath -replace "/", "\"
   return "\\wsl.localhost\$DistroName$($LinuxHome -replace '/', '\')\.dotfiles\$relative"
}

function Assert-SymlinkCreationAvailable {
   $probeTarget = Join-Path $env:TEMP "dotfiles-link-probe-target"
   $probeLink = Join-Path $env:TEMP "dotfiles-link-probe-link"

   Remove-Item -LiteralPath $probeLink -Force -ErrorAction SilentlyContinue
   New-Item -ItemType Directory -Force -Path $probeTarget | Out-Null

   try {
      New-Item -ItemType SymbolicLink -Path $probeLink -Target $probeTarget -ErrorAction Stop | Out-Null
   } catch {
      throw "Creating Windows symlinks requires elevation or Developer Mode. No links were changed. Original error: $($_.Exception.Message)"
   } finally {
      Remove-Item -LiteralPath $probeLink -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath $probeTarget -Recurse -Force -ErrorAction SilentlyContinue
   }
}

function Set-Symlink {
   param(
      [string]$Name,
      [string]$LinkPath,
      [string]$TargetPath
   )

   $parent = Split-Path -Parent $LinkPath
   if ($parent -and -not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
   }

   $existing = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
   if ($existing -and $existing.LinkType -eq "SymbolicLink" -and $existing.Target -contains $TargetPath) {
      return
   }

   if ($existing) {
      $stamp = Get-Date -Format "yyyyMMddHHmmss"
      $backupRoot = Join-Path $env:USERPROFILE ".backup_dotfiles\windows-$stamp"
      New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
      $backupName = ($Name -replace '[^A-Za-z0-9._-]', '-')
      $backupPath = Join-Path $backupRoot $backupName
      Move-Item -LiteralPath $LinkPath -Destination $backupPath -Force
      Write-Host "Backed up $Name to $backupPath"
   }

   Write-Host "Linking $Name"
   New-Item -ItemType SymbolicLink -Path $LinkPath -Target $TargetPath | Out-Null
}

Assert-SymlinkCreationAvailable

if (-not $LinuxHome) {
   $LinuxHome = (& wsl.exe -d $DistroName -e sh -lc 'printf %s "$HOME"') -replace "`0", ""
   $LinuxHome = $LinuxHome.Trim()
   if (-not $LinuxHome.StartsWith("/")) {
      throw "Could not detect the default Linux home for '$DistroName'. Pass -LinuxHome explicitly."
   }
}

Set-Symlink "WezTerm config" (Join-Path $env:USERPROFILE ".wezterm.lua") (Normalize-WslTarget ".wezterm.lua")
Set-Symlink "WezTerm directory" (Join-Path $env:USERPROFILE ".wezterm") (Normalize-WslTarget "wezterm")
Set-Symlink "Neovim config" (Join-Path $env:LOCALAPPDATA "nvim") (Normalize-WslTarget "nvim")
Set-Symlink "Komorebi config" (Join-Path $env:USERPROFILE "komorebi.json") (Normalize-WslTarget "komorebi/komorebi.json")
Set-Symlink "whkd config" (Join-Path $env:USERPROFILE ".config\whkdrc") (Normalize-WslTarget "komorebi/whkdrc")

Write-Host "Windows links now point at $DistroName."
