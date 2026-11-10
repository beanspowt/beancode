# Builds hermes\profiles\ (one Hermes profile distribution per /org role) from the OpenCode
# payload in config\opencode and the Hermes sources in hermes\ (roster.json, souls\, extra-skills\).
#
# Usage:
#   Build-BeanCodeHermes.ps1           regenerate hermes\profiles (replaces the whole folder)
#   Build-BeanCodeHermes.ps1 -Check    build into a temp folder and compare; writes nothing
#
# Each role's skills are the non-deny skill permissions of its source agents in
# config\opencode\agents, copied byte for byte from config\opencode\skills, plus any
# hermes\extra-skills listed for the role. Skills listed under openCodeOnlySkills in the roster
# (OpenCode built-ins with no file in the repo) are skipped.
#
# Exit codes: 0 = built (or -Check: up to date), 1 = error or -Check found differences.

[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BeanCode.Hermes.ps1')
$repoRoot = Get-BeanCodeRepoRoot

try {
    $roster = Read-BeanCodeHermesRoster -RepoRoot $repoRoot
    $plan = Get-BeanCodeHermesPlan -RepoRoot $repoRoot -Roster $roster
    if (@($plan.Problems).Count -gt 0) {
        foreach ($p in $plan.Problems) { Write-Host "FAIL: $p" }
        exit 1
    }
    $target = Join-Path $repoRoot 'hermes\profiles'
    $tmp = New-BeanCodeTempDir -Prefix 'build'
    try {
        $out = Join-Path $tmp 'profiles'
        New-BeanCodeHermesProfiles -RepoRoot $repoRoot -Roster $roster -Plan $plan -OutDir $out
        if ($Check) {
            $diffs = @(Compare-BeanCodeTrees -Expected $out -Actual $target)
            foreach ($d in $diffs) { Write-Host "DIFF: $d" }
            if ($diffs.Count -gt 0) {
                Write-Host "hermes\profiles is out of date ($($diffs.Count) difference(s)). Run Build-BeanCodeHermes.ps1."
                exit 1
            }
            Write-Host 'hermes\profiles is up to date.'
            exit 0
        }
        if (Test-Path -LiteralPath $target) {
            if (Test-BeanCodeReparsePoint -Path $target) { throw "Reparse point not allowed: $target" }
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Copy-BeanCodeTree -From $out -To $target
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    foreach ($r in $plan.Roles) {
        $line = '{0,-17} {1,-18} {2,-7} skills: {3,3}' -f $r.Name, $r.Model, $r.Reasoning, (@($r.Skills).Count + @($r.ExtraSkills).Count)
        if (@($r.AskSkills).Count -gt 0) { $line += "  (approval: $(@($r.AskSkills).Count))" }
        Write-Host $line
    }
    Write-Host "Built $(@($plan.Roles).Count) profiles in hermes\profiles."
    exit 0
}
catch {
    Write-Host "FAIL: build error: $($_.Exception.Message)"
    exit 1
}
