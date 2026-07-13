param(
   [Parameter(Mandatory = $true)]
   [string]$FontDirectory
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $FontDirectory)) {
   throw "Font directory not found: $FontDirectory"
}

$fontTarget = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"
$fontRegistry = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
New-Item -ItemType Directory -Path $fontTarget -Force | Out-Null
if (-not (Test-Path -LiteralPath $fontRegistry)) {
   New-Item -Path $fontRegistry | Out-Null
}
Add-Type -AssemblyName System.Drawing

$changed = $false
$changes = [System.Collections.Generic.List[string]]::new()
$fonts = @(
   Get-ChildItem -LiteralPath $FontDirectory -Recurse -File |
      Where-Object { $_.Extension -in ".ttf", ".otf" }
)

foreach ($font in $fonts) {
   $target = Join-Path $fontTarget $font.Name
   $copy = -not (Test-Path -LiteralPath $target)
   if (-not $copy) {
      $copy = (Get-FileHash -LiteralPath $font.FullName).Hash -ne (Get-FileHash -LiteralPath $target).Hash
   }
   if ($copy) {
      Copy-Item -LiteralPath $font.FullName -Destination $target -Force
      $changed = $true
      $changes.Add("file:$($font.Name)")
   }

   $collection = [System.Drawing.Text.PrivateFontCollection]::new()
   try {
      $collection.AddFontFile($target)
      $familyName = $collection.Families[0].Name
   } finally {
      $collection.Dispose()
   }
   if ([string]::IsNullOrWhiteSpace($familyName)) {
      $familyName = $font.BaseName
   }
   $valueName = "$familyName (TrueType)"
   $fontProperties = Get-ItemProperty -Path $fontRegistry
   $registered = $fontProperties.$valueName
   if ($registered -ne $target) {
      New-ItemProperty -Path $fontRegistry -Name $valueName -Value $target -PropertyType String -Force | Out-Null
      $changed = $true
      $changes.Add("registry:$valueName")
   }
}

if ($fonts.Count -eq 0) {
   throw "No TTF or OTF files found under $FontDirectory"
}

if ($changed) {
   Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FontBroadcast {
   [DllImport("user32.dll", SetLastError = true)]
   public static extern IntPtr SendMessageTimeout(
      IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam,
      uint flags, uint timeout, out UIntPtr result);
}
"@
   $result = [UIntPtr]::Zero
   [void][FontBroadcast]::SendMessageTimeout(
      [IntPtr]0xffff, 0x001D, [UIntPtr]::Zero, [IntPtr]::Zero,
      2, 5000, [ref]$result
   )
   Write-Host "Updated Windows user fonts from $FontDirectory ($($changes -join ', '))."
} else {
   Write-Host "Windows user fonts are current."
}
