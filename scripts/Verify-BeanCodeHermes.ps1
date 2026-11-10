# Verifies the Hermes /org payload (hermes\) without touching Hermes.
#
# Usage:
#   Verify-BeanCodeHermes.ps1                          static checks (below)
#   Verify-BeanCodeHermes.ps1 -DenyTermsFile <path>    also scan file names and contents for the
#                                                      terms in <path> (outside the repo; see
#                                                      docs\INSTALLER.md, Verify-BeanCode.ps1)
#
# Always checked:
#   - roster.json is valid and every role has a SOUL in hermes\souls\
#   - every /org agent (reached from commands\org.md's agent through allowed subagents) is the
#     source of a Hermes role, and every skill it may load is in that role's profile
#   - hermes\profiles equals a fresh build (Build-BeanCodeHermes.ps1 -Check)
#   - forbidden names, reparse points and generic secret patterns under hermes\
#
# Exit codes: 0 = PASS, 1 = FAIL. WARN lines never change the exit code.

[CmdletBinding()]
param(
    [string]$DenyTermsFile
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BeanCode.Hermes.ps1')
$repoRoot = Get-BeanCodeRepoRoot

try {
    $terms = @()
    if ($DenyTermsFile) { $terms = @(Read-BeanCodeTermFile -Path $DenyTermsFile -RepoRoot $repoRoot) }
    $r = Test-BeanCodeHermesPayload -RepoRoot $repoRoot -DenyTerms $terms
}
catch {
    Write-Host "FAIL: verifier error: $($_.Exception.Message)"
    exit 1
}

if ($r.Ok) { exit 0 } else { exit 1 }
