# Regenerates MANIFEST.sha256.json from config\opencode (UTF-8 without BOM, LF endings).
# Refuses to manifest forbidden paths (service.json, backups, .env, auth files, node_modules,
# .local, research\). Run only once the payload is complete.
#
# Usage:
#   New-Manifest.ps1                  write repo MANIFEST.sha256.json
#   New-Manifest.ps1 -WhatIf          print the entry count and target path, write nothing
#
# Exit codes: 0 = written (or WhatIf), 1 = refused / error.

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$PayloadRoot,
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BeanCode.Common.ps1')
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
if (-not $PayloadRoot) { $PayloadRoot = Join-Path $repoRoot 'config\opencode' }
if (-not $ManifestPath) { $ManifestPath = Join-Path $repoRoot 'MANIFEST.sha256.json' }

try {
    $r = New-BeanCodeManifestText -PayloadRoot $PayloadRoot
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}

if (-not $PSCmdlet.ShouldProcess($ManifestPath, "Write manifest with $($r.Count) files")) {
    Write-Host "WhatIf: would write $($r.Count) entries to $ManifestPath"
    exit 0
}

[System.IO.File]::WriteAllText($ManifestPath, $r.Text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $($r.Count) entries to $ManifestPath"
exit 0
