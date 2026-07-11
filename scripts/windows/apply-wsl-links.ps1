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
   if ($script:SymlinkCreationAvailable) {
      return
   }

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

   $script:SymlinkCreationAvailable = $true
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
   if ($existing -and $existing.LinkType -eq "SymbolicLink") {
      $normalizedTarget = $TargetPath.TrimEnd("\")
      $existingTargets = @($existing.Target | ForEach-Object {
         $target = [string]$_
         if ($target.StartsWith("UNC\")) {
            $target = "\\" + $target.Substring(4)
         } elseif ($target.StartsWith("\??\UNC\")) {
            $target = "\\" + $target.Substring(8)
         }
         $target.TrimEnd("\")
      })
      if ($existingTargets -contains $normalizedTarget) {
         return
      }
   }

   Assert-SymlinkCreationAvailable

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

function Set-RegistryString {
   param(
      [string]$Path,
      [string]$Name,
      [string]$Value
   )

   if (-not (Test-Path -LiteralPath $Path)) {
      New-Item -Path $Path -Force | Out-Null
   }
   if ($Name) {
      Set-ItemProperty -Path $Path -Name $Name -Value $Value
   } else {
      Set-Item -Path $Path -Value $Value
   }
}

function Convert-PngToIco {
   param(
      [string]$PngPath,
      [string]$IcoPath
   )

   $sizes = @(16, 24, 32, 48, 64, 128)
   $images = New-Object 'System.Collections.Generic.List[byte[]]'
   $source = New-Object System.Drawing.Bitmap($PngPath)
   try {
      foreach ($size in $sizes) {
         $bitmap = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
         $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
         $memoryStream = New-Object System.IO.MemoryStream
         $imageWriter = New-Object System.IO.BinaryWriter($memoryStream)
         try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $graphics.DrawImage($source, 0, 0, $size, $size)

            $maskRowBytes = [int]([Math]::Ceiling($size / 32.0) * 4)
            $pixelBytes = $size * $size * 4
            $imageWriter.Write([uint32]40)
            $imageWriter.Write([int32]$size)
            $imageWriter.Write([int32]($size * 2))
            $imageWriter.Write([uint16]1)
            $imageWriter.Write([uint16]32)
            $imageWriter.Write([uint32]0)
            $imageWriter.Write([uint32]$pixelBytes)
            $imageWriter.Write([int32]0)
            $imageWriter.Write([int32]0)
            $imageWriter.Write([uint32]0)
            $imageWriter.Write([uint32]0)

            for ($y = $size - 1; $y -ge 0; $y--) {
               for ($x = 0; $x -lt $size; $x++) {
                  $color = $bitmap.GetPixel($x, $y)
                  $imageWriter.Write([byte]$color.B)
                  $imageWriter.Write([byte]$color.G)
                  $imageWriter.Write([byte]$color.R)
                  $imageWriter.Write([byte]$color.A)
               }
            }

            for ($y = $size - 1; $y -ge 0; $y--) {
               $mask = New-Object byte[] $maskRowBytes
               for ($x = 0; $x -lt $size; $x++) {
                  if ($bitmap.GetPixel($x, $y).A -lt 128) {
                     $byteIndex = [int][Math]::Floor($x / 8.0)
                     $mask[$byteIndex] = [byte]($mask[$byteIndex] -bor (0x80 -shr ($x % 8)))
                  }
               }
               $imageWriter.Write($mask)
            }
            $imageWriter.Flush()
            $images.Add($memoryStream.ToArray())
         } finally {
            $imageWriter.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
         }
      }
   } finally {
      $source.Dispose()
   }

   $output = [System.IO.File]::Create($IcoPath)
   $writer = New-Object System.IO.BinaryWriter($output)
   try {
      $writer.Write([uint16]0)
      $writer.Write([uint16]1)
      $writer.Write([uint16]$images.Count)
      $offset = 6 + (16 * $images.Count)
      for ($index = 0; $index -lt $images.Count; $index++) {
         $size = $sizes[$index]
         $bytes = $images[$index]
         $writer.Write([byte]$size)
         $writer.Write([byte]$size)
         $writer.Write([byte]0)
         $writer.Write([byte]0)
         $writer.Write([uint16]1)
         $writer.Write([uint16]32)
         $writer.Write([uint32]$bytes.Length)
         $writer.Write([uint32]$offset)
         $offset += $bytes.Length
      }
      foreach ($bytes in $images) {
         $writer.Write($bytes)
      }
   } finally {
      $writer.Dispose()
   }
}

function Build-NvimLauncher {
   param(
      [string]$SourcePath,
      [string]$DestinationDirectory
   )

   $iconPath = Join-Path $DestinationDirectory "NvimWSL.ico"
   $iconPngPath = Join-Path $DestinationDirectory "Neovim.png"
   $launcherPath = Join-Path $DestinationDirectory "NvimWSL.exe"
   $temporaryLauncher = Join-Path $DestinationDirectory "NvimWSL.build.exe"

   Add-Type -AssemblyName System.Drawing
   # Official Neovim runtime icon:
   $iconUrl = "https://raw.githubusercontent.com/neovim/neovim/master/runtime/nvim.png"
   $iconSha256 = "E6E68A31327F67C24F5FCBEA175B13862275363C2E7B0A5999781104C8658C16"
   $currentIconHash = if (Test-Path -LiteralPath $iconPngPath) {
      (Get-FileHash -LiteralPath $iconPngPath -Algorithm SHA256).Hash
   } else {
      ""
   }
   if ($currentIconHash -ne $iconSha256) {
      Invoke-WebRequest -UseBasicParsing -Uri $iconUrl -OutFile $iconPngPath
   }
   $downloadedIconHash = (Get-FileHash -LiteralPath $iconPngPath -Algorithm SHA256).Hash
   if ($downloadedIconHash -ne $iconSha256) {
      throw "The downloaded Neovim icon failed SHA-256 verification."
   }

   Convert-PngToIco $iconPngPath $iconPath

   Remove-Item -LiteralPath $temporaryLauncher -Force -ErrorAction SilentlyContinue
   $compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
   $compilerParameters.GenerateExecutable = $true
   $compilerParameters.OutputAssembly = $temporaryLauncher
   $compilerParameters.CompilerOptions = "/target:winexe /win32icon:$iconPath"
   $compilerParameters.ReferencedAssemblies.Add("System.dll") | Out-Null
   Add-Type -Path $SourcePath -CompilerParameters $compilerParameters
   Move-Item -LiteralPath $temporaryLauncher -Destination $launcherPath -Force
   return $launcherPath
}

function Register-NvimOpenWith {
   param([string]$LauncherPath)

   $progId = "NvimWSL.Text"
   $classes = "HKCU:\Software\Classes"
   $progIdPath = Join-Path $classes $progId
   $iconPath = [System.IO.Path]::ChangeExtension($LauncherPath, ".ico")
   $command = '"{0}" "%1"' -f $LauncherPath

   Set-RegistryString $progIdPath "" "Neovim (WSL) text file"
   Set-RegistryString (Join-Path $progIdPath "DefaultIcon") "" "$iconPath,0"
   Set-RegistryString (Join-Path $progIdPath "Application") "ApplicationName" "Neovim (WSL)"
   Set-RegistryString (Join-Path $progIdPath "Application") "ApplicationIcon" "$iconPath,0"
   Set-RegistryString (Join-Path $progIdPath "shell\open\command") "" $command

   $applicationPath = Join-Path $classes "Applications\NvimWSL.exe"
   Set-RegistryString $applicationPath "FriendlyAppName" "Neovim (WSL)"
   Set-RegistryString $applicationPath "ApplicationName" "Neovim (WSL)"
   Set-RegistryString $applicationPath "ApplicationDescription" "Open text files in Neovim inside NixOS WSL"
   Set-RegistryString (Join-Path $applicationPath "DefaultIcon") "" "$iconPath,0"
   Set-RegistryString (Join-Path $applicationPath "shell\open\command") "" $command

   $appPathsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\NvimWSL.exe"
   Set-RegistryString $appPathsPath "" $LauncherPath
   Set-RegistryString $appPathsPath "Path" (Split-Path -Parent $LauncherPath)

   $contextMenu = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Classes\*\shell\NvimWSL")
   try {
      $contextMenu.SetValue("MUIVerb", "Edit with Neovim (WSL)")
      $contextMenu.SetValue("Icon", "$iconPath,0")
      $contextCommand = $contextMenu.CreateSubKey("command")
      try {
         $contextCommand.SetValue("", $command)
      } finally {
         $contextCommand.Dispose()
      }
   } finally {
      $contextMenu.Dispose()
   }

   $textExtensions = @(
      ".adoc", ".asm", ".astro", ".bash", ".bat", ".bib", ".c", ".cc", ".cfg", ".cjs",
      ".clj", ".cljc", ".cljs", ".cmake", ".cmd", ".conf", ".config", ".cpp", ".cs", ".css",
      ".cts", ".csv", ".cxx", ".dart", ".diff", ".dockerfile", ".edn", ".env", ".erl", ".ex",
      ".exs", ".fish", ".fs", ".fsx", ".gitattributes", ".gitignore", ".gitmodules", ".go", ".gradle",
      ".graphql", ".groovy", ".gql", ".h", ".hcl", ".hpp", ".hrl", ".hs", ".htm", ".html",
      ".http", ".ini", ".java", ".js", ".json", ".json5", ".jsonc", ".jsx", ".kt", ".kts",
      ".less", ".lhs", ".lock", ".log", ".lua", ".m", ".markdown", ".md", ".mjs", ".ml",
      ".mli", ".mts", ".nix", ".patch", ".php", ".pl", ".pm", ".properties", ".proto", ".ps1",
      ".psd1", ".psm1", ".py", ".pyi", ".r", ".rb", ".reg", ".rest", ".rst", ".rs",
      ".s", ".sass", ".scala", ".scss", ".sh", ".sql", ".svelte", ".svg", ".swift", ".tex",
      ".text", ".tf", ".tfvars", ".toml", ".ts", ".tsv", ".tsx", ".txt", ".vim", ".vue",
      ".xml", ".xsl", ".xslt", ".yaml", ".yml", ".zig", ".zsh"
   )

   foreach ($extension in $textExtensions) {
      $subKey = "Software\Classes\$extension\OpenWithProgids"
      $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey)
      try {
         $key.SetValue($progId, (New-Object byte[] 0), [Microsoft.Win32.RegistryValueKind]::None)
      } finally {
         $key.Dispose()
      }

      $openWithList = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Software\Classes\$extension\OpenWithList\NvimWSL.exe")
      $openWithList.Dispose()
      Set-RegistryString (Join-Path $applicationPath "SupportedTypes") $extension ""
   }

   if (-not ([System.Management.Automation.PSTypeName]"NvimWSL.AssociationNotifier").Type) {
      Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NvimWSL {
   public static class AssociationNotifier {
      [DllImport("shell32.dll")]
      public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
   }
}
'@
   }
   [NvimWSL.AssociationNotifier]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
   & "$env:SystemRoot\System32\ie4uinit.exe" -show

   Write-Host "Registered Neovim (WSL) for $($textExtensions.Count) text-oriented file extensions."
}

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

$launcherDirectory = Join-Path $env:LOCALAPPDATA "NvimWSL"
New-Item -ItemType Directory -Force -Path $launcherDirectory | Out-Null
$launcherScript = Join-Path $launcherDirectory "open-in-nvim.ps1"
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "open-in-nvim.ps1") -Destination $launcherScript -Force
$launcherPath = Build-NvimLauncher `
   (Join-Path $PSScriptRoot "NvimWSL.cs") `
   $launcherDirectory
Register-NvimOpenWith $launcherPath

Write-Host "Windows links and Neovim integration now point at $DistroName."
