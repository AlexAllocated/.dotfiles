param(
	[Parameter(Mandatory = $true)]
	[ValidateSet("Start", "Stop")]
	[string]$Mode,
	[string]$StateDirectory = "$env:PUBLIC\AudioArray"
)

$ErrorActionPreference = "Stop"
$markerPath = Join-Path $StateDirectory "sunshine-session-active"

if ($Mode -eq "Start") {
	New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
	[IO.File]::WriteAllText(
		$markerPath,
		"$([DateTimeOffset]::Now.ToString('O'))`r`n",
		[Text.UTF8Encoding]::new($false)
	)
	Write-Host "AudioArray is yielding render defaults to Sunshine."
	exit 0
}

Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
Write-Host "AudioArray is restoring its physical monitor and VAC defaults."
