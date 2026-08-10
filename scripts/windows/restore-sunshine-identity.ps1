param(
   [Parameter(Mandatory = $true)]
   [string]$SourceDirectory,
   [string]$SunshineDirectory = "$env:ProgramFiles\Sunshine\config",
   [string]$ServiceName = "SunshineService"
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
   $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
   $principal = [Security.Principal.WindowsPrincipal]::new($identity)
   return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
   throw "Restoring Sunshine identity requires an elevated Windows PowerShell."
}

$sourceState = Join-Path $SourceDirectory "sunshine_state.json"
$sourceCertificate = Join-Path $SourceDirectory "credentials\cacert.pem"
$sourcePrivateKey = Join-Path $SourceDirectory "credentials\cakey.pem"
foreach ($required in @($sourceState, $sourceCertificate, $sourcePrivateKey)) {
   if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
      throw "Sunshine identity file is missing: $required"
   }
}

$state = Get-Content -LiteralPath $sourceState -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$state.root.uniqueid) -or
   $null -eq $state.root.named_devices) {
   throw "Sunshine state is missing root.uniqueid or root.named_devices."
}
$null = New-Object -TypeName Security.Cryptography.X509Certificates.X509Certificate2 `
   -ArgumentList $sourceCertificate
$privateKey = [IO.File]::ReadAllText($sourcePrivateKey)
if ($privateKey -notmatch '(?s)^-----BEGIN (?:RSA )?PRIVATE KEY-----\s+.+\s+-----END (?:RSA )?PRIVATE KEY-----\s*$') {
   throw "Sunshine cakey.pem is not a complete PEM private key."
}

$service = Get-Service -Name $ServiceName -ErrorAction Stop
$destinationCredentials = Join-Path $SunshineDirectory "credentials"
$destinationState = Join-Path $SunshineDirectory "sunshine_state.json"
$destinationCertificate = Join-Path $destinationCredentials "cacert.pem"
$destinationPrivateKey = Join-Path $destinationCredentials "cakey.pem"

$stamp = Get-Date -Format "yyyyMMddHHmmss"
$backupDirectory = Join-Path $env:USERPROFILE ".backup_dotfiles\sunshine-$stamp"
New-Item -ItemType Directory -Path (Join-Path $backupDirectory "credentials") -Force | Out-Null
foreach ($pair in @(
   @($destinationState, (Join-Path $backupDirectory "sunshine_state.json")),
   @($destinationCertificate, (Join-Path $backupDirectory "credentials\cacert.pem")),
   @($destinationPrivateKey, (Join-Path $backupDirectory "credentials\cakey.pem"))
)) {
   if (Test-Path -LiteralPath $pair[0] -PathType Leaf) {
      Copy-Item -LiteralPath $pair[0] -Destination $pair[1]
   }
}

if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
   Stop-Service -Name $ServiceName
   $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
}

try {
   New-Item -ItemType Directory -Path $destinationCredentials -Force | Out-Null
   Copy-Item -LiteralPath $sourceState -Destination $destinationState -Force
   Copy-Item -LiteralPath $sourceCertificate -Destination $destinationCertificate -Force
   Copy-Item -LiteralPath $sourcePrivateKey -Destination $destinationPrivateKey -Force
} finally {
   Start-Service -Name $ServiceName
}

$service = Get-Service -Name $ServiceName
$service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
Write-Host "Restored Sunshine identity for $($state.root.named_devices.Count) paired device(s)."
Write-Host "The replaced installer identity is backed up at $backupDirectory."
