$ErrorActionPreference = 'Stop'
$repoScripts = Split-Path $PSScriptRoot -Parent
$source = Get-Content (Join-Path $repoScripts 'apply-packages.ps1') -Raw
$start = $source.IndexOf('   # A deliberately activated, verified fork')
$end = $source.IndexOf('   # Synapse 4', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Could not locate production fork guard.' }
$guard = [scriptblock]::Create($source.Substring($start, $end - $start))
$scratch = Join-Path ([IO.Path]::GetTempPath()) "sunshine-guard-$([Guid]::NewGuid().ToString('N'))"
$oldLocal = $env:LOCALAPPDATA
$oldPrograms = $env:ProgramFiles
function Invoke-GuardCase {
	$temporaryPackages = '{"Sources":[{"Packages":[{"PackageIdentifier":"LizardByte.Sunshine"},{"PackageIdentifier":"Discord.Discord"}]}]}' | ConvertFrom-Json
	$manifestChanged = $false
	. $guard
	return @($temporaryPackages.Sources[0].Packages.PackageIdentifier)
}
try {
	$env:LOCALAPPDATA = $scratch
	$env:ProgramFiles = $scratch
	New-Item -ItemType Directory "$scratch\Sunshine","$scratch\dotfiles\sunshine-fork" -Force | Out-Null
	[IO.File]::WriteAllText("$scratch\Sunshine\sunshine.exe", 'fixture, not executable')
	if (@(Invoke-GuardCase).Count -ne 2) { throw 'Stock package was removed without activation.' }
	$state = "$scratch\dotfiles\sunshine-fork\active.json"
	@{schema=1;binaryHash=(Get-FileHash "$scratch\Sunshine\sunshine.exe").Hash} | ConvertTo-Json | Set-Content $state
	$remaining = @(Invoke-GuardCase)
	if ($remaining.Count -ne 1 -or $remaining[0] -ne 'Discord.Discord') { throw 'Verified fork was not selectively excluded.' }
	[IO.File]::AppendAllText("$scratch\Sunshine\sunshine.exe", 'changed')
	$rejected = $false
	try { Invoke-GuardCase | Out-Null } catch { $rejected = $_.Exception.Message -like '*does not match*' }
	if (-not $rejected) { throw 'Binary drift was not rejected.' }
	Write-Host 'PASS: stock retained, verified fork excluded, unrelated package retained, binary drift rejected.'
} finally {
	$env:LOCALAPPDATA = $oldLocal
	$env:ProgramFiles = $oldPrograms
}
