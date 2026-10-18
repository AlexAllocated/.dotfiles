param(
	[Parameter(Mandatory = $true)][ValidateSet('Stage','Deploy','Rollback','Confirm')][string]$Mode,
	[Parameter(Mandatory = $true)][string]$StateDirectory,
	[string]$ArchivePath,
	[string]$ExpectedArchiveHash,
	[string]$BuildRevision
)
$ErrorActionPreference = 'Stop'
$env:PATHEXT = '.COM;.EXE;.BAT;.CMD'
$hostRoot = Join-Path $env:ProgramFiles 'Sunshine'
$serviceName = 'SunshineService'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Json($Path, $Value) {
	[IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), $utf8)
}
function Send-ArrayEdit($Plan, $Edit) {
	$root = Join-Path $Plan.arrayRoot 'control-v1'
	$status = Get-Content (Join-Path $root 'status.json') -Raw | ConvertFrom-Json
	if (-not $status.online -or $status.error) { throw 'AMPS is not healthy enough for a routing transaction.' }
	$id = [Guid]::NewGuid().ToString('N')
	$request = @{ id=$id; session=$status.session; expectedRevision=$status.revision; edit=$Edit }
	$temp = Join-Path $root "$id.pending"
	Write-Json $temp $request
	[IO.File]::Move($temp, (Join-Path $root "requests\$id.json"))
	$replyPath = Join-Path $root "replies\$id.json"
	$until = [DateTime]::UtcNow.AddSeconds(20)
	while (-not (Test-Path $replyPath)) {
		if ([DateTime]::UtcNow -gt $until) { throw "AMPS request $id timed out; inspect its reply before retrying." }
		Start-Sleep -Milliseconds 100
	}
	$reply = Get-Content $replyPath -Raw | ConvertFrom-Json
	if (-not $reply.applied) { throw "AMPS rejected routing change: $($reply.error)" }
}
function Stop-StreamingHost {
	Stop-Service $serviceName -ErrorAction Stop
	(Get-Service $serviceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(25))
	Get-CimInstance Win32_Process -Filter "Name='sunshine.exe'" | Where-Object ExecutablePath -eq (Join-Path $hostRoot 'sunshine.exe') | ForEach-Object {
		Stop-Process -Id $_.ProcessId -Force
	}
}
function Log-Step($Plan, $Message) {
	[IO.File]::AppendAllText($Plan.progressPath, "$([DateTimeOffset]::Now.ToString('O')) $Message`r`n", $utf8)
}
if ($Mode -eq 'Stage') {
	if (Test-Path $StateDirectory) { throw 'Use a new staging directory; existing state is never overwritten.' }
	if ($BuildRevision -notmatch '^[a-f0-9]{40}$' -or $ExpectedArchiveHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'Pinned revision and archive hash are required.' }
	if ((Get-FileHash $ArchivePath).Hash -ne $ExpectedArchiveHash) { throw 'Archive checksum mismatch.' }
	$service = Get-CimInstance Win32_Service -Filter "Name='SunshineService'"
	if ($service.PathName.Trim('"') -ne (Join-Path $hostRoot 'tools\sunshinesvc.exe')) { throw 'Unexpected Sunshine service path; refusing migration.' }
	$arrayRoot = Join-Path $env:APPDATA 'AMPS'
	$binary = Join-Path $env:LOCALAPPDATA 'AMPS\bin\amps.exe'
	$snapshot = (& $binary snapshot | ConvertFrom-Json)
	if (-not $snapshot.runtime.online -or $snapshot.runtime.error) { throw 'AMPS must be healthy before staging.' }
	$endpoint = @($snapshot.graph.outputDevices | Where-Object name -eq 'Speakers (Steam Streaming Speakers)')
	if ($endpoint.Count -ne 1) { throw 'Expected one Steam streaming endpoint.' }
	$nodeId = 'device-sunshine'
	if (@($snapshot.runtime.devices | Where-Object id -eq $nodeId).Count) { throw 'The proposed streaming node already exists; review its ownership first.' }
	$game = @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render' | Where-Object {
		$p = Get-ItemProperty (Join-Path $_.PSPath 'Properties')
		$p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2' -eq 'AMPS Game'
	})
	if ($game.Count -ne 1) { throw 'Expected one AMPS Game render endpoint.' }
	New-Item -ItemType Directory $StateDirectory | Out-Null
	Copy-Item $ArchivePath (Join-Path $StateDirectory 'package.zip')
	Expand-Archive (Join-Path $StateDirectory 'package.zip') (Join-Path $StateDirectory 'expanded')
	$candidate = Join-Path $StateDirectory 'expanded\Sunshine'
	foreach ($file in @('sunshine.exe','tools\sunshinesvc.exe','assets\web\config.html')) {
		if (-not (Test-Path (Join-Path $candidate $file))) { throw "Incomplete package: $file" }
	}
	Push-Location $candidate
	try { $version = (& (Join-Path $candidate 'sunshine.exe') --version | Out-String) }
	finally { Pop-Location }
	if ($LASTEXITCODE -ne 0 -or $version -notmatch '2026\.907\.1') { throw "Unexpected staged version: $version" }
	$tag = [Guid]::NewGuid().ToString('N')
	$plan = [ordered]@{
		schema=1; buildRevision=$BuildRevision; archiveHash=$ExpectedArchiveHash
		binaryHash=(Get-FileHash (Join-Path $candidate 'sunshine.exe')).Hash
		candidate=$candidate; arrayRoot=$arrayRoot; nodeId=$nodeId; audioSink=$endpoint[0].id
		gameEndpoint="{0.0.0.00000000}.$($game[0].PSChildName)"
		sources=@($snapshot.runtime.patches | Where-Object destination -in @('monitor','main_output') | Select-Object -ExpandProperty source -Unique)
		recoveryRoot=(Join-Path $env:ProgramData "DotfilesSunshineRecovery\$tag")
		activePath=(Join-Path $env:LOCALAPPDATA 'dotfiles\sunshine-fork\active.json')
		confirmPath=(Join-Path $StateDirectory 'confirmed'); progressPath=(Join-Path $StateDirectory 'progress.log')
		userSid=([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
	}
	Write-Json (Join-Path $StateDirectory 'plan.json') $plan
	Copy-Item $PSCommandPath (Join-Path $StateDirectory 'upgrade.ps1')
	Log-Step $plan 'STAGED: package hash, version, service path, and AMPS endpoints verified; live services unchanged.'
	$version.Trim()
	Write-Host "Staged at $StateDirectory"
	exit 0
}
$plan = Get-Content (Join-Path $StateDirectory 'plan.json') -Raw | ConvertFrom-Json
if ($Mode -eq 'Confirm') {
	if ((Get-FileHash (Join-Path $hostRoot 'sunshine.exe')).Hash -ne $plan.binaryHash -or (Get-Service $serviceName).Status -ne 'Running') { throw 'Cannot confirm an absent or stopped replacement.' }
	[IO.File]::WriteAllText($plan.confirmPath, [DateTimeOffset]::Now.ToString('O'), $utf8)
	Log-Step $plan 'CONFIRMED: user verified Moonlight. Recovery backups retained.'
	exit 0
}
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Deploy/rollback requires elevation; obtain it before disconnecting Moonlight.' }
$recovery = $plan.recoveryRoot
if ($Mode -eq 'Rollback') {
	Log-Step $plan 'ROLLBACK: restoring original Sunshine.'
	$retired = Join-Path $recovery 'retired-original'
	if (Test-Path $retired) {
		Stop-StreamingHost
		if (Test-Path $hostRoot) { Move-Item $hostRoot (Join-Path $recovery "failed-$([Guid]::NewGuid().ToString('N'))") }
		Move-Item $retired $hostRoot
	}
	$oldActive = Join-Path $recovery 'previous-active.json'
	if (Test-Path $oldActive) { Copy-Item $oldActive $plan.activePath -Force }
	elseif (Test-Path $plan.activePath) { Remove-Item -LiteralPath $plan.activePath }
	Start-Service $serviceName
	try {
		$status = Get-Content (Join-Path $plan.arrayRoot 'control-v1\status.json') -Raw | ConvertFrom-Json
		$owned = @($status.devices | Where-Object { $_.id -eq $plan.nodeId -and $_.endpoint_id -eq $plan.audioSink })
		# Binding uses camelCase in JSON.
		if (-not $owned.Count) { $owned = @($status.devices | Where-Object { $_.id -eq $plan.nodeId -and $_.endpointId -eq $plan.audioSink }) }
		if ($owned.Count) { Send-ArrayEdit $plan @{kind='remove_device';id=$plan.nodeId} }
	} catch { Log-Step $plan "AMPS rollback warning: $_" }
	Log-Step $plan 'ROLLED BACK: original service restored. Reconnect Moonlight normally.'
	exit 0
}
if (Test-Path $recovery) { throw 'This deployment already started; use its recovery plan instead of deploying twice.' }
if ((Get-FileHash (Join-Path $plan.candidate 'sunshine.exe')).Hash -ne $plan.binaryHash) { throw 'Staged binary changed.' }
New-Item -ItemType Directory $recovery -Force | Out-Null
& icacls.exe $recovery /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*$($plan.userSid):(OI)(CI)RX" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect recovery files.' }
Copy-Item (Join-Path $StateDirectory 'plan.json') (Join-Path $recovery 'plan.json')
Copy-Item $PSCommandPath (Join-Path $recovery 'upgrade.ps1')
Copy-Item $hostRoot (Join-Path $recovery 'original-backup') -Recurse
$arrayBackup = New-Item -ItemType Directory (Join-Path $recovery 'amps-state-backup')
Get-ChildItem $plan.arrayRoot -File | Copy-Item -Destination $arrayBackup.FullName
Copy-Item (Join-Path $plan.arrayRoot 'control-v1\status.json') (Join-Path $arrayBackup.FullName 'status.json')
if (Test-Path $plan.activePath) { Copy-Item $plan.activePath (Join-Path $recovery 'previous-active.json') }
Get-CimInstance Win32_Service -Filter "Name='SunshineService'" | Export-Clixml (Join-Path $recovery 'service.xml')
$candidate = Join-Path $recovery 'candidate'
Copy-Item $plan.candidate $candidate -Recurse
try {
	Log-Step $plan 'BACKUP READY: rollback on deployment failure is enabled. Disconnect begins now.'
	Stop-StreamingHost
	# The version probe can create a disposable config inside the staged package.
	if (Test-Path (Join-Path $candidate 'config')) { Remove-Item -LiteralPath (Join-Path $candidate 'config') -Recurse -Force }
	Copy-Item (Join-Path $hostRoot 'config') (Join-Path $candidate 'config') -Recurse
	& icacls.exe (Join-Path $candidate 'config') /grant:r "*$($plan.userSid):(OI)(CI)M" /T | Out-Null
	if ($LASTEXITCODE -ne 0) { throw 'Could not preserve interactive-user access to Sunshine configuration.' }
	$configPath = Join-Path $candidate 'config\sunshine.conf'
	$lines = @(Get-Content $configPath | Where-Object {$_ -notmatch '^\s*(external_audio|audio_sink|virtual_sink)\s*='})
	$lines += @('external_audio = enabled', "audio_sink = $($plan.audioSink)")
	[IO.File]::WriteAllLines($configPath, $lines, $utf8)
	Move-Item $hostRoot (Join-Path $recovery 'retired-original')
	Move-Item $candidate $hostRoot
	# Explicitly return ownership to AMPS in this interactive user's session.
	Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")] class AudioPolicyClient {}
[ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioPolicy {
 [PreserveSig] int GetMixFormat(string id, IntPtr p);
 [PreserveSig] int GetDeviceFormat(string id, bool d, IntPtr p);
 [PreserveSig] int ResetDeviceFormat(string id);
 [PreserveSig] int SetDeviceFormat(string id, IntPtr a, IntPtr b);
 [PreserveSig] int GetProcessingPeriod(string id, bool d, IntPtr a, IntPtr b);
 [PreserveSig] int SetProcessingPeriod(string id, IntPtr p);
 [PreserveSig] int GetShareMode(string id, IntPtr p);
 [PreserveSig] int SetShareMode(string id, IntPtr p);
 [PreserveSig] int GetPropertyValue(string id, bool f, IntPtr k, IntPtr v);
 [PreserveSig] int SetPropertyValue(string id, bool f, IntPtr k, IntPtr v);
 [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
}
public static class SunshineAudioHandoff {
 public static void SetConsole(string id) {
  var p=(IAudioPolicy)(object)new AudioPolicyClient();
  try { Marshal.ThrowExceptionForHR(p.SetDefaultEndpoint(id,0)); }
  finally { Marshal.ReleaseComObject(p); }
 }
}
'@
	[SunshineAudioHandoff]::SetConsole($plan.gameEndpoint)
	$until = [DateTime]::UtcNow.AddSeconds(25)
	do {
		Start-Sleep -Milliseconds 250
		$status = Get-Content (Join-Path $plan.arrayRoot 'control-v1\status.json') -Raw | ConvertFrom-Json
	} while ($status.outputName -eq 'Speakers (Steam Streaming Speakers)' -and [DateTime]::UtcNow -lt $until)
	if (-not $status.online -or $status.error -or $status.outputName -eq 'Speakers (Steam Streaming Speakers)') { throw 'AMPS did not leave the old implicit streaming route.' }
	Send-ArrayEdit $plan @{kind='add_device';device=@{id=$plan.nodeId;name='Moonlight';direction='output';endpointId=$plan.audioSink}}
	foreach ($source in $plan.sources) { Send-ArrayEdit $plan @{kind='connect';source=$source;destination=$plan.nodeId} }
	Start-Service $serviceName
	$until = [DateTime]::UtcNow.AddSeconds(45)
	do {
		Start-Sleep -Seconds 1
		$listener = Get-NetTCPConnection -State Listen -LocalPort 47989 -ErrorAction SilentlyContinue
	} while (-not $listener -and [DateTime]::UtcNow -lt $until)
	if (-not $listener -or (Get-Service $serviceName).Status -ne 'Running') { throw 'Replacement service did not become reachable.' }
	New-Item -ItemType Directory (Split-Path $plan.activePath) -Force | Out-Null
	Write-Json $plan.activePath @{schema=1;buildRevision=$plan.buildRevision;binaryHash=$plan.binaryHash;audioSink=$plan.audioSink;recoveryRoot=$recovery;confirmPath=$plan.confirmPath}
	Log-Step $plan 'READY: replacement service listening; AMPS Moonlight mix configured. Await user reconnection before confirmation.'
} catch {
	Log-Step $plan "DEPLOY FAILED: $_"
	& "$recovery\upgrade.ps1" -Mode Rollback -StateDirectory $recovery
	throw
}
