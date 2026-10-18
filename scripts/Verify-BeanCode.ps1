# Verifies the BeanCode payload (config\opencode) against MANIFEST.sha256.json.
#
# Usage:
#   Verify-BeanCode.ps1                          verify repo payload against manifest + structural checks
#   Verify-BeanCode.ps1 -Target <dir>            additionally verify an installed copy in <dir>
#                                                (only files listed in the manifest are compared)
#   Verify-BeanCode.ps1 -DenyTermsFile <path>    also scan file names and contents for the terms in
#                                                <path> (UTF-8, one case-insensitive term per line,
#                                                '#' comments allowed). The file must live OUTSIDE the
#                                                repo. Matching lines are never printed, only counts.
#
# Without -DenyTermsFile the term scan is skipped and a NOTE says so.
# Always checked: manifest path/size/hash, missing/extra files, forbidden names
# (service.json, backups, .env, auth files, node_modules, .local, research\), reparse points,
# and generic secret patterns (tokens, private key blocks).
#
# Exit codes: 0 = PASS, 1 = FAIL (manifest mismatch, forbidden file, secret pattern,
#             or a term hit in agents/, agent/, commands/, plugins/, opencode.jsonc,
#             AGENTS.md, cli.json, btw.jsonc, package*.json). WARN lines never change the exit code.

[CmdletBinding()]
param(
    [string]$PayloadRoot,
    [string]$ManifestPath,
    [string]$Target,
    [string]$DenyTermsFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BeanCode.Common.ps1')
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
if (-not $PayloadRoot) { $PayloadRoot = Join-Path $repoRoot 'config\opencode' }
if (-not $ManifestPath) { $ManifestPath = Join-Path $repoRoot 'MANIFEST.sha256.json' }

try {
    $terms = @()
    if ($DenyTermsFile) {
        $terms = @(Read-BeanCodeTermFile -Path $DenyTermsFile -RepoRoot $repoRoot)
    }
    $args2 = @{ PayloadRoot = $PayloadRoot; ManifestPath = $ManifestPath; DenyTerms = $terms }
    if ($Target) { $args2['Target'] = $Target }
    $r = Test-BeanCodePayload @args2
}
catch {
    Write-Host "FAIL: verifier error: $($_.Exception.Message)"
    exit 1
}

if ($r.Ok) { exit 0 } else { exit 1 }
