# BeanCode Hermes helpers. Dot-sourced by Build-BeanCodeHermes.ps1, Verify-BeanCodeHermes.ps1
# and Install-BeanCodeHermes.ps1. Windows PowerShell 5.1 compatible.
#
# Turns the OpenCode /org agents in config\opencode into Hermes profile distributions under
# hermes\profiles\<role>\ (distribution.yaml, SOUL.md, config.yaml, skills\). Role definitions
# live in hermes\roster.json; Hermes instructions in hermes\souls\. Skill lists are never written
# by hand: they come from the skill permissions in each source agent's frontmatter.

. (Join-Path $PSScriptRoot 'BeanCode.Common.ps1')

$script:BeanCodeUtf8NoBom = New-Object System.Text.UTF8Encoding $false

function Read-BeanCodeText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n")
}

function Write-BeanCodeText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $script:BeanCodeUtf8NoBom)
}

function Get-BeanCodeRepoRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
}

function Read-BeanCodeHermesRoster {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $path = Join-Path $RepoRoot 'hermes\roster.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "roster missing: $path" }
    $roster = ConvertFrom-Json -InputObject (Read-BeanCodeText -Path $path)
    if ($roster.schema -ne 1) { throw 'roster schema is not 1' }
    $seen = @{}
    foreach ($r in @($roster.roles)) {
        if ([string]$r.name -cnotmatch '^[a-z0-9][a-z0-9_-]{0,63}$') { throw "bad role name in roster: $($r.name)" }
        if ($seen.ContainsKey($r.name)) { throw "duplicate role in roster: $($r.name)" }
        $seen[$r.name] = $true
        if (@($r.sources).Count -eq 0) { throw "role $($r.name) has no sources" }
    }
    return $roster
}

# Parses an OpenCode agent file's frontmatter permissions list.
# Returns objects { Action; Resource; Effect } in file order.
function Get-BeanCodeAgentPermissions {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Read-BeanCodeText -Path $Path
    if (-not $text.StartsWith('---')) { throw "no frontmatter: $Path" }
    $end = $text.IndexOf("`n---", 3)
    if ($end -lt 0) { throw "unterminated frontmatter: $Path" }
    $out = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in $text.Substring(0, $end).Split("`n")) {
        if ($line -match '^\s*-\s*action:\s*"?([A-Za-z_-]+)"?\s*$') {
            if ($cur) { [void]$out.Add([pscustomobject]$cur) }
            $cur = @{ Action = $Matches[1]; Resource = $null; Effect = $null }
        }
        elseif ($cur -and $line -match '^\s+resource:\s*"?([^"]*?)"?\s*$') { $cur.Resource = $Matches[1] }
        elseif ($cur -and $line -match '^\s+effect:\s*"?([A-Za-z]+)"?\s*$') { $cur.Effect = $Matches[1] }
        elseif ($cur -and $line -match '^\S') {
            [void]$out.Add([pscustomobject]$cur)
            $cur = $null
        }
    }
    if ($cur) { [void]$out.Add([pscustomobject]$cur) }
    return $out.ToArray()
}

function Get-BeanCodeAgentPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Agent
    )
    return (Join-Path $RepoRoot ("config\opencode\agents\{0}.md" -f $Agent))
}

# The /org team: the agents reachable from the director through allowed subagent permissions.
# Built-in agents with no file in config\opencode\agents (explore, general) are skipped.
function Get-BeanCodeOrgAgents {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $orgCmd = Join-Path $RepoRoot 'config\opencode\commands\org.md'
    $start = 'director'
    if (Test-Path -LiteralPath $orgCmd) {
        $m = [regex]::Match((Read-BeanCodeText -Path $orgCmd), '(?m)^agent:\s*"?([A-Za-z0-9_-]+)"?\s*$')
        if ($m.Success) { $start = $m.Groups[1].Value }
    }
    $seen = New-Object 'System.Collections.Generic.List[string]'
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($start)
    while ($queue.Count -gt 0) {
        $a = [string]$queue.Dequeue()
        if ($seen.Contains($a)) { continue }
        $p = Get-BeanCodeAgentPath -RepoRoot $RepoRoot -Agent $a
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $seen.Add($a)
        foreach ($perm in (Get-BeanCodeAgentPermissions -Path $p)) {
            if ($perm.Action -eq 'subagent' -and $perm.Effect -ne 'deny' -and $perm.Resource -and $perm.Resource -ne '*') {
                $queue.Enqueue($perm.Resource)
            }
        }
    }
    return $seen.ToArray()
}

# Skills an agent may load: { Skill; Ask } for every non-deny skill permission except '*'.
function Get-BeanCodeAgentSkills {
    param([Parameter(Mandatory = $true)][string]$Path)
    $out = New-Object System.Collections.ArrayList
    foreach ($perm in (Get-BeanCodeAgentPermissions -Path $Path)) {
        if ($perm.Action -ne 'skill' -or -not $perm.Resource -or $perm.Resource -eq '*') { continue }
        if ($perm.Effect -eq 'deny') { continue }
        [void]$out.Add([pscustomobject]@{ Skill = $perm.Resource; Ask = ($perm.Effect -eq 'ask') })
    }
    return $out.ToArray()
}

function Get-BeanCodeSortedUnique {
    param([string[]]$Items)
    $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach ($i in @($Items)) { if ($i) { [void]$set.Add($i) } }
    $arr = New-Object 'string[]' $set.Count
    $set.CopyTo($arr)
    return $arr
}

# Per-role plan: which skills (from config\opencode\skills), which approval skills, which
# extra skills (from hermes\extra-skills), which toolsets are disabled. Problems are collected,
# never thrown, so Verify can report them all.
function Get-BeanCodeHermesPlan {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Roster
    )
    $skillsRoot = Join-Path $RepoRoot 'config\opencode\skills'
    $openCodeOnly = @()
    if ($Roster.openCodeOnlySkills) { $openCodeOnly = @($Roster.openCodeOnlySkills.PSObject.Properties.Name) }
    $problems = New-Object System.Collections.ArrayList
    $roles = New-Object System.Collections.ArrayList
    foreach ($r in @($Roster.roles)) {
        $skills = New-Object System.Collections.ArrayList
        $ask = New-Object System.Collections.ArrayList
        $dropped = New-Object System.Collections.ArrayList
        foreach ($src in @($r.sources)) {
            $p = Get-BeanCodeAgentPath -RepoRoot $RepoRoot -Agent $src
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
                [void]$problems.Add("role $($r.name): source agent missing: $src")
                continue
            }
            foreach ($s in (Get-BeanCodeAgentSkills -Path $p)) {
                if ($openCodeOnly -contains $s.Skill) { [void]$dropped.Add($s.Skill); continue }
                if (-not (Test-Path -LiteralPath (Join-Path $skillsRoot "$($s.Skill)\SKILL.md") -PathType Leaf)) {
                    [void]$problems.Add("role $($r.name): skill '$($s.Skill)' (from $src) is not in config\opencode\skills")
                    continue
                }
                [void]$skills.Add($s.Skill)
                if ($s.Ask) { [void]$ask.Add($s.Skill) }
            }
        }
        $extra = @()
        foreach ($e in @($r.extraSkills)) {
            if (-not $e) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "hermes\extra-skills\$e\SKILL.md") -PathType Leaf)) {
                [void]$problems.Add("role $($r.name): extra skill '$e' is not in hermes\extra-skills")
                continue
            }
            if ($skills -contains $e) { [void]$problems.Add("role $($r.name): extra skill '$e' collides with an OpenCode skill") }
            $extra += $e
        }
        $enable = @($r.enableToolsets | Where-Object { $_ })
        $disabled = @(Get-BeanCodeSortedUnique -Items (@($Roster.commonDisabledToolsets) + @($r.disabledToolsets))) | Where-Object { $enable -notcontains $_ }
        $soul = Join-Path $RepoRoot "hermes\souls\$($r.name).md"
        if (-not (Test-Path -LiteralPath $soul -PathType Leaf)) { [void]$problems.Add("role $($r.name): SOUL missing: hermes\souls\$($r.name).md") }
        $cardProtocol = $true
        if ($null -ne $r.cardProtocol) { $cardProtocol = [bool]$r.cardProtocol }
        [void]$roles.Add([pscustomobject]@{
            Name          = [string]$r.name
            Sources       = @($r.sources)
            Description   = [string]$r.description
            Model         = [string]$r.model
            Reasoning     = [string]$r.reasoning
            Skills        = @(Get-BeanCodeSortedUnique -Items $skills.ToArray())
            AskSkills     = @(Get-BeanCodeSortedUnique -Items $ask.ToArray())
            ExtraSkills   = @(Get-BeanCodeSortedUnique -Items $extra)
            Dropped       = @(Get-BeanCodeSortedUnique -Items $dropped.ToArray())
            Disabled      = @($disabled)
            Enable        = @($enable)
            CardProtocol  = $cardProtocol
        })
    }
    return [pscustomobject]@{ Roles = $roles.ToArray(); Problems = $problems.ToArray() }
}

function ConvertTo-BeanCodeYamlString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Format-BeanCodeSkillList {
    param([string[]]$Skills)
    return ((@($Skills) | ForEach-Object { '`' + $_ + '`' }) -join ', ')
}

function New-BeanCodeHermesSoul {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Role,
        [Parameter(Mandatory = $true)]$Roster
    )
    $body = (Read-BeanCodeText -Path (Join-Path $RepoRoot "hermes\souls\$($Role.Name).md")).TrimEnd()
    $all = @(Get-BeanCodeSortedUnique -Items (@($Role.Skills) + @($Role.ExtraSkills)))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($body + "`n`n## Your skills`n`n")
    [void]$sb.Append("Load a skill with ``skill_view`` before doing work it covers. These are the $($all.Count) skills of your role: ")
    [void]$sb.Append((Format-BeanCodeSkillList -Skills $all) + ".`n`n")
    $bundled = @($Roster.bundledSkills)
    if ($bundled.Count -gt 0) {
        [void]$sb.Append("Hermes also installs " + (Format-BeanCodeSkillList -Skills $bundled) + ": ``hermes-agent`` explains Hermes itself, ``sdlc-review`` is used when a Kanban card goes to review.`n")
    }
    if (@($Role.AskSkills).Count -gt 0) {
        [void]$sb.Append("`nApproval required before use (team protocol rule 8): " + (Format-BeanCodeSkillList -Skills $Role.AskSkills) + ".`n")
    }
    if ($Role.CardProtocol) {
        [void]$sb.Append("`n" + (Read-BeanCodeText -Path (Join-Path $RepoRoot 'hermes\souls\_protocol.md')).TrimEnd() + "`n")
    }
    return $sb.ToString()
}

function New-BeanCodeHermesConfig {
    param(
        [Parameter(Mandatory = $true)]$Role,
        [Parameter(Mandatory = $true)]$Roster
    )
    $lines = @(
        'model:',
        "  default: $($Role.Model)",
        "  provider: $($Roster.provider)",
        "  base_url: $($Roster.baseUrl)",
        'agent:',
        "  reasoning_effort: $($Role.Reasoning)",
        '  disabled_toolsets:'
    )
    foreach ($t in @($Role.Disabled)) { $lines += "    - $t" }
    return (($lines -join "`n") + "`n")
}

function New-BeanCodeHermesManifest {
    param(
        [Parameter(Mandatory = $true)]$Role,
        [Parameter(Mandatory = $true)]$Roster
    )
    $lines = @(
        "name: $($Role.Name)",
        "version: $($Roster.version)",
        ('description: ' + (ConvertTo-BeanCodeYamlString -Value $Role.Description)),
        ('hermes_requires: ' + (ConvertTo-BeanCodeYamlString -Value ([string]$Roster.hermesRequires))),
        'author: beancode'
    )
    return (($lines -join "`n") + "`n")
}

function Copy-BeanCodeTree {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    foreach ($f in (Get-BeanCodeTree -Root $From)) {
        $dest = Join-Path $To ($f.Path.Replace('/', '\'))
        $dir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
        [System.IO.File]::Copy($f.Full, $dest, $true)
    }
}

# Writes every role's distribution into OutDir\<role>\. OutDir must not exist yet.
function New-BeanCodeHermesProfiles {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Roster,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$OutDir
    )
    if (Test-Path -LiteralPath $OutDir) { throw "output directory already exists: $OutDir" }
    [void](New-Item -ItemType Directory -Force -Path $OutDir)
    foreach ($role in @($Plan.Roles)) {
        $dir = Join-Path $OutDir $role.Name
        Write-BeanCodeText -Path (Join-Path $dir 'distribution.yaml') -Text (New-BeanCodeHermesManifest -Role $role -Roster $Roster)
        Write-BeanCodeText -Path (Join-Path $dir 'config.yaml') -Text (New-BeanCodeHermesConfig -Role $role -Roster $Roster)
        Write-BeanCodeText -Path (Join-Path $dir 'SOUL.md') -Text (New-BeanCodeHermesSoul -RepoRoot $RepoRoot -Role $role -Roster $Roster)
        foreach ($s in @($role.Skills)) {
            Copy-BeanCodeTree -From (Join-Path $RepoRoot "config\opencode\skills\$s") -To (Join-Path $dir "skills\$s")
        }
        foreach ($s in @($role.ExtraSkills)) {
            Copy-BeanCodeTree -From (Join-Path $RepoRoot "hermes\extra-skills\$s") -To (Join-Path $dir "skills\$s")
        }
    }
}

# Compares two trees by relative path and SHA-256. Returns difference strings.
function Compare-BeanCodeTrees {
    param(
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Actual
    )
    $diff = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Actual -PathType Container)) {
        [void]$diff.Add("MISSING directory $Actual")
        return $diff.ToArray()
    }
    $exp = @{}
    foreach ($f in (Get-BeanCodeTree -Root $Expected)) { $exp[$f.Path] = $f.Full }
    $act = @{}
    foreach ($f in (Get-BeanCodeTree -Root $Actual)) { $act[$f.Path] = $f.Full }
    foreach ($p in ($exp.Keys | Sort-Object)) {
        if (-not $act.ContainsKey($p)) { [void]$diff.Add("MISSING $p"); continue }
        if ((Get-BeanCodeSha256 -Path $exp[$p]) -ne (Get-BeanCodeSha256 -Path $act[$p])) { [void]$diff.Add("CHANGED $p") }
    }
    foreach ($p in ($act.Keys | Sort-Object)) {
        if (-not $exp.ContainsKey($p)) { [void]$diff.Add("EXTRA $p") }
    }
    return $diff.ToArray()
}

function New-BeanCodeTempDir {
    param([string]$Prefix = 'beancode-hermes')
    $base = Join-Path ([System.IO.Path]::GetTempPath()) 'hermes-org'
    $dir = Join-Path $base ('{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N').Substring(0, 12))
    [void](New-Item -ItemType Directory -Force -Path $dir)
    return $dir
}

# Static checks of the repo's Hermes payload. Prints FAIL/WARN/NOTE lines and a summary.
# Returns { Ok; Failures; Warnings; Plan; OrgAgents }.
function Test-BeanCodeHermesPayload {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string[]]$DenyTerms
    )
    $fail = New-Object System.Collections.ArrayList
    $warn = New-Object System.Collections.ArrayList
    $roster = Read-BeanCodeHermesRoster -RepoRoot $RepoRoot
    $plan = Get-BeanCodeHermesPlan -RepoRoot $RepoRoot -Roster $roster
    foreach ($p in @($plan.Problems)) { [void]$fail.Add($p) }

    # Every /org agent maps to a role, and every skill it may load is in that role.
    $org = @(Get-BeanCodeOrgAgents -RepoRoot $RepoRoot)
    $openCodeOnly = @()
    if ($roster.openCodeOnlySkills) { $openCodeOnly = @($roster.openCodeOnlySkills.PSObject.Properties.Name) }
    $orgSkills = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $covered = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($a in $org) {
        $agentSkills = @(Get-BeanCodeAgentSkills -Path (Get-BeanCodeAgentPath -RepoRoot $RepoRoot -Agent $a) | Where-Object { $openCodeOnly -notcontains $_.Skill })
        foreach ($s in $agentSkills) { [void]$orgSkills.Add($s.Skill) }
        $roles = @($plan.Roles | Where-Object { $_.Sources -contains $a })
        if ($roles.Count -eq 0) { [void]$fail.Add("/org agent '$a' is not a source of any Hermes role"); continue }
        foreach ($s in $agentSkills) {
            foreach ($r in $roles) {
                if ($r.Skills -contains $s.Skill) { [void]$covered.Add($s.Skill) }
                else { [void]$fail.Add("/org agent '$a' skill '$($s.Skill)' is missing from role '$($r.Name)'") }
            }
        }
    }
    foreach ($r in @($plan.Roles)) {
        foreach ($src in $r.Sources) {
            if ($org -notcontains $src) { [void]$warn.Add("role '$($r.Name)' source '$src' is not part of /org") }
        }
    }

    # The committed profiles must equal a fresh build.
    $tmp = New-BeanCodeTempDir -Prefix 'check'
    try {
        $out = Join-Path $tmp 'profiles'
        New-BeanCodeHermesProfiles -RepoRoot $RepoRoot -Roster $roster -Plan $plan -OutDir $out
        $diffs = @(Compare-BeanCodeTrees -Expected $out -Actual (Join-Path $RepoRoot 'hermes\profiles'))
        $shown = 0
        foreach ($d in $diffs) {
            if ($shown -lt 25) { [void]$fail.Add("hermes\profiles out of date: $d") }
            $shown++
        }
        if ($diffs.Count -gt 25) { [void]$fail.Add("hermes\profiles out of date: ... and $($diffs.Count - 25) more") }
        if ($diffs.Count -gt 0) { [void]$fail.Add('run scripts\Build-BeanCodeHermes.ps1 to regenerate hermes\profiles') }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Content checks over everything under hermes\ (same rules as the OpenCode payload).
    $terms = @($DenyTerms | Where-Object { $_ })
    if ($terms.Count -eq 0) { Write-Host 'NOTE: no -DenyTermsFile supplied; identity/term scan skipped.' }
    else { Write-Host "NOTE: term scan enabled with $($terms.Count) term(s) from the supplied file (terms not printed)." }
    $fileCount = 0
    foreach ($t in (Get-BeanCodeTree -Root (Join-Path $RepoRoot 'hermes'))) {
        $fileCount++
        $reason = Get-BeanCodeForbiddenReason -Rel $t.Path
        if ($reason) { [void]$fail.Add("FORBIDDEN ($reason) hermes/$($t.Path)") }
        $blocking = ($t.Path -notmatch '(^|/)skills/')
        $scan = Get-BeanCodeContentScan -Full $t.Full -Terms $terms
        if ($scan.Binary) { continue }
        foreach ($s in @($scan.SecretHits)) { [void]$fail.Add("SECRET-PATTERN ($($s.Name)) x$($s.Count) in hermes/$($t.Path)") }
        if ($scan.TermHits -gt 0) {
            $msg = "term hits x$($scan.TermHits) in hermes/$($t.Path)"
            if ($blocking) { [void]$fail.Add($msg) } else { [void]$warn.Add($msg) }
        }
    }

    foreach ($f in $fail) { Write-Host "FAIL: $f" }
    foreach ($w in $warn) { Write-Host "WARN: $w" }
    $ok = ($fail.Count -eq 0)
    Write-Host ("Roles: {0}; /org agents: {1}; /org skills covered: {2}/{3}; files under hermes\: {4}; failures: {5}; warnings: {6}; result: {7}" -f `
        @($plan.Roles).Count, $org.Count, $covered.Count, $orgSkills.Count, $fileCount, $fail.Count, $warn.Count, $(if ($ok) { 'PASS' } else { 'FAIL' }))
    return [pscustomobject]@{ Ok = $ok; Failures = $fail.ToArray(); Warnings = $warn.ToArray(); Plan = $plan; OrgAgents = $org; Roster = $roster }
}
