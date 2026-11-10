# Installs the /org team into Hermes: one Hermes profile (a Bot in Hermes Desktop's Bot Mode)
# per role, from the profile distributions in hermes\profiles.
#
# Usage:
#   Install-BeanCodeHermes.ps1 -DryRun            print the plan only (also -WhatIf); changes nothing
#   Install-BeanCodeHermes.ps1                    install or update all roles
#   Install-BeanCodeHermes.ps1 -Role director     install or update only the named role(s)
#   Install-BeanCodeHermes.ps1 -HermesExe <path>  use this hermes executable
#   Install-BeanCodeHermes.ps1 -Force             also replace same-named profiles that beancode did not install
#   Install-BeanCodeHermes.ps1 -SkipBoardConfig   leave the Kanban board settings alone
#   Install-BeanCodeHermes.ps1 -Parallel 1        run one role at a time (default 5)
#
# Behaviour:
#   1. Finds hermes (-HermesExe, then PATH, then %LOCALAPPDATA%\hermes\bin\hermes.exe) and checks its
#      version against hermes\roster.json.
#   2. Verifies the payload (Verify-BeanCodeHermes.ps1 checks). Aborts on failure.
#   3. Plans each role: install (new), update (installed by beancode before), or conflict (a profile
#      with that name exists and beancode did not install it; refused unless -Force).
#   4. Per role: `hermes profile install <hermes\profiles\role> --force` (SOUL.md, config.yaml and the
#      role's skills are replaced; memories, sessions, .env and auth are kept), opts the profile out of
#      Hermes' bundled skills, installs the bundled skills listed in the roster, enables the role's
#      extra toolsets, sets the profile description, and removes skills an earlier install added that
#      the role no longer has (tracked in <profile>\local\beancode-org.json). Roles run in parallel.
#   5. Sets kanban.auto_decompose = false on the default profile, so the director (not Hermes'
#      automatic decomposer) splits work. -SkipBoardConfig leaves it alone.
#   6. Checks every role: all its skills are on disk, the role's own skills are listed by
#      `hermes skills list`, and reports the Copilot login status.
#
# Exit codes:
#   0 = success (or dry run / WhatIf)
#   1 = unexpected error
#   2 = payload verification failed; nothing changed
#   3 = hermes not found or too old; nothing changed
#   4 = a profile with a role's name exists and beancode did not install it (rerun with -Force); nothing changed
#   5 = an install step or a post-install check failed

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$DryRun,
    [string]$HermesExe,
    [string[]]$Role,
    [switch]$Force,
    [switch]$SkipBoardConfig,
    [ValidateRange(1, 10)][int]$Parallel = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BeanCode.Hermes.ps1')

function Stop-Install {
    param([int]$Code, [string]$Message)
    Write-Host "ERROR: $Message"
    exit $Code
}

function ConvertTo-BeanCodeArg {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Arg)
    if ($Arg -eq '') { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append(('\' * ($bs * 2 + 1)) + '"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Runs hermes with stdin closed (a prompt can never hang the install) and returns { Code; Output }.
# The child inherits this process's environment. ProcessStartInfo.EnvironmentVariables is not used:
# on .NET Framework it lowercases every variable name, which breaks the hermes launcher.
function Invoke-BeanCodeHermes {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-BeanCodeArg -Arg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $text = [regex]::Replace(($outTask.Result + $errTask.Result), '\x1b\[[0-9;?]*[A-Za-z]', '')
    return [pscustomobject]@{ Code = $p.ExitCode; Output = $text.Trim() }
}

# Runs several chains of hermes commands in parallel. Each chain is
# @{ Key = <name>; Steps = @( @{ Label = <text>; Args = @(...) }, ... ) }; its steps run in order and
# the chain stops at the first non-zero exit. Returns @{ <Key> = @( { Label; Args; Code; Output } ) }.
function Invoke-BeanCodeHermesChains {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][object[]]$Chains,
        [int]$Throttle = 5
    )
    $defs = foreach ($n in @('ConvertTo-BeanCodeArg', 'Invoke-BeanCodeHermes')) {
        "function $n {`n" + (Get-Item -LiteralPath "function:$n").ScriptBlock.ToString() + "`n}"
    }
    $script = "param(`$Exe, `$Steps)`n" + ($defs -join "`n") + "`n" + @'
$out = New-Object System.Collections.ArrayList
foreach ($s in $Steps) {
    $r = Invoke-BeanCodeHermes -Exe $Exe -Arguments ([string[]]$s.Args)
    [void]$out.Add([pscustomobject]@{ Label = $s.Label; Args = $s.Args; Code = $r.Code; Output = $r.Output })
    if ($r.Code -ne 0) { break }
}
$out.ToArray()
'@
    $pool = [runspacefactory]::CreateRunspacePool(1, $Throttle)
    $pool.Open()
    try {
        $jobs = foreach ($c in $Chains) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($script).AddArgument($Exe).AddArgument(@($c.Steps))
            [pscustomobject]@{ Key = $c.Key; PS = $ps; Handle = $ps.BeginInvoke() }
        }
        $results = @{}
        foreach ($j in @($jobs)) {
            $res = $j.PS.EndInvoke($j.Handle)
            if ($j.PS.Streams.Error.Count -gt 0) { throw "runner error for $($j.Key): $($j.PS.Streams.Error[0])" }
            $results[$j.Key] = @($res)
            $j.PS.Dispose()
        }
        return $results
    }
    finally {
        $pool.Close()
        $pool.Dispose()
    }
}

function Resolve-BeanCodeHermes {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit -PathType Leaf)) { return $null }
        return [System.IO.Path]::GetFullPath($Explicit)
    }
    $cmd = Get-Command hermes -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'hermes\bin\hermes.exe'
    if (Test-Path -LiteralPath $fallback -PathType Leaf) { return $fallback }
    return $null
}

function Test-BeanCodeVersion {
    param([string]$Have, [string]$Requires)
    $m = [regex]::Match($Requires, '^\s*>=\s*(\d+(\.\d+){0,2})\s*$')
    if (-not $m.Success) { return $true }
    $parts = @($m.Groups[1].Value.Split('.'))
    while ($parts.Count -lt 3) { $parts += '0' }
    return ([version]$Have -ge [version]($parts -join '.'))
}

function Get-BeanCodePathFromOutput {
    param([string]$Output)
    $m = [regex]::Match($Output, '(?m)^\s*(?:Profile path|Path):\s+(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Test-BeanCodeOwnedProfile {
    param([string]$Path)
    $manifest = Join-Path $Path 'distribution.yaml'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
    return [regex]::IsMatch((Read-BeanCodeText -Path $manifest), '(?m)^author:\s*["'']?beancode["'']?\s*$')
}

function Get-BeanCodeListedSkills {
    param([string]$Output)
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($line in $Output.Split("`n")) {
        $m = [regex]::Match($line, '^\s*[|\u2502]\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*[|\u2502]')
        if ($m.Success -and $m.Groups[1].Value -ne 'Name') { [void]$names.Add($m.Groups[1].Value) }
    }
    return , $names
}

function Find-BeanCodeInstalledSkill {
    param([string]$ProfilePath, [string]$Skill)
    $skills = Join-Path $ProfilePath 'skills'
    if (Test-Path -LiteralPath (Join-Path $skills "$Skill\SKILL.md") -PathType Leaf) { return $true }
    foreach ($cat in @(Get-ChildItem -LiteralPath $skills -Directory -ErrorAction SilentlyContinue)) {
        if ($cat.Name.StartsWith('.')) { continue }
        if (Test-Path -LiteralPath (Join-Path $cat.FullName "$Skill\SKILL.md") -PathType Leaf) { return $true }
    }
    return $false
}

try {
    $dry = [bool]($DryRun -or $WhatIfPreference)
    # Plain, wide, UTF-8 output from hermes so its tables can be read back.
    $env:PYTHONIOENCODING = 'utf-8'
    $env:NO_COLOR = '1'
    $env:COLUMNS = '300'
    $repoRoot = Get-BeanCodeRepoRoot
    Write-Host "BeanCode Hermes /org installer (PowerShell $($PSVersionTable.PSVersion))"
    Write-Host "Repo: $repoRoot"

    # --- hermes ---
    $hermes = Resolve-BeanCodeHermes -Explicit $HermesExe
    if (-not $hermes) { Stop-Install 3 'hermes not found. Install Hermes, or pass -HermesExe <path to hermes.exe>.' }
    $ver = Invoke-BeanCodeHermes -Exe $hermes -Arguments @('--version')
    $vm = [regex]::Match($ver.Output, 'v(\d+\.\d+\.\d+)')
    if ($ver.Code -ne 0 -or -not $vm.Success) { Stop-Install 3 "could not read the Hermes version from '$hermes --version': $($ver.Output)" }
    Write-Host "Hermes: $hermes (v$($vm.Groups[1].Value))"

    # --- payload ---
    $v = Test-BeanCodeHermesPayload -RepoRoot $repoRoot
    if (-not $v.Ok) { Stop-Install 2 'payload verification failed; nothing changed.' }
    $roster = $v.Roster
    if (-not (Test-BeanCodeVersion -Have $vm.Groups[1].Value -Requires ([string]$roster.hermesRequires))) {
        Stop-Install 3 "Hermes v$($vm.Groups[1].Value) is older than required ($($roster.hermesRequires)). Run 'hermes update' first."
    }

    $roles = @($v.Plan.Roles)
    if ($Role) {
        $unknown = @($Role | Where-Object { @($roles | ForEach-Object { $_.Name }) -notcontains $_ })
        if ($unknown.Count -gt 0) { Stop-Install 1 "unknown role(s): $($unknown -join ', '). Roles: $(@($roles | ForEach-Object { $_.Name }) -join ', ')" }
        $roles = @($roles | Where-Object { $Role -contains $_.Name })
    }
    $bundled = @($roster.bundledSkills)

    # --- plan ---
    $shown = Invoke-BeanCodeHermesChains -Exe $hermes -Throttle $Parallel -Chains @($roles | ForEach-Object {
        @{ Key = $_.Name; Steps = @(@{ Label = 'show'; Args = @('profile', 'show', $_.Name) }) }
    })
    $plan = New-Object System.Collections.ArrayList
    foreach ($r in $roles) {
        $res = @($shown[$r.Name])[0]
        $path = $null
        if ($res.Code -eq 0) {
            $path = Get-BeanCodePathFromOutput -Output $res.Output
            if (-not $path) { throw "could not read the path of profile '$($r.Name)' from 'hermes profile show'" }
        }
        $action = 'install'
        if ($path) {
            if (Test-BeanCodeOwnedProfile -Path $path) { $action = 'update' }
            elseif ($Force) { $action = 'replace' }
            else { $action = 'conflict' }
        }
        $dist = Join-Path $repoRoot "hermes\profiles\$($r.Name)"
        $skills = @(Get-ChildItem -LiteralPath (Join-Path $dist 'skills') -Directory | ForEach-Object { $_.Name } | Sort-Object)
        [void]$plan.Add([pscustomobject]@{ Role = $r; Path = $path; Action = $action; Dist = $dist; Skills = $skills })
    }

    $board = $null
    if (-not $SkipBoardConfig) {
        $g = Invoke-BeanCodeHermes -Exe $hermes -Arguments @('-p', 'default', 'config', 'get', 'kanban.auto_decompose')
        $board = (@($g.Output.Split("`n")) | Select-Object -Last 1).Trim()
    }

    Write-Host ''
    Write-Host "Plan ($($plan.Count) role(s)):"
    foreach ($p in $plan) {
        $r = $p.Role
        $tools = @()
        if (@($r.Enable).Count -gt 0) { $tools += ('+' + ($r.Enable -join ',+')) }
        $tools += "-$(@($r.Disabled).Count) toolsets"
        Write-Host ('  {0,-9} {1,-17} {2,-18} {3,-7} skills {4,3} + bundled {5}  {6}' -f $p.Action, $r.Name, $r.Model, $r.Reasoning, $p.Skills.Count, $bundled.Count, ($tools -join ' '))
    }
    if ($SkipBoardConfig) { Write-Host 'Board: left alone (-SkipBoardConfig).' }
    elseif ($board -eq 'false') { Write-Host 'Board: kanban.auto_decompose is already false.' }
    else { Write-Host "Board: kanban.auto_decompose $board -> false (default profile)." }

    $conflicts = @($plan | Where-Object { $_.Action -eq 'conflict' })
    foreach ($c in $conflicts) {
        Write-Host "CONFLICT: profile '$($c.Role.Name)' exists at $($c.Path) and beancode did not install it. Rerun with -Force to replace its SOUL.md, config.yaml and skills (memories and sessions are kept)."
    }
    if ($dry) {
        Write-Host ''
        Write-Host 'Dry run: nothing changed.'
        exit 0
    }
    if ($conflicts.Count -gt 0) { Stop-Install 4 'conflicting profiles refused; nothing changed.' }

    # --- install (roles in parallel, each role's steps in order) ---
    Write-Host ''
    Write-Host "Installing $($plan.Count) role(s), up to $Parallel at a time..."
    $chains = foreach ($p in $plan) {
        $r = $p.Role
        $steps = New-Object System.Collections.ArrayList
        $installArgs = @('profile', 'install', $p.Dist, '--name', $r.Name, '--yes')
        if ($p.Path) { $installArgs += '--force' }
        [void]$steps.Add(@{ Label = 'install distribution'; Args = $installArgs })
        # opt-out --remove deletes unmodified bundled skills, including the ones listed in the roster,
        # so they are installed again after it on every run.
        [void]$steps.Add(@{ Label = 'opt out of bundled skills'; Args = @('-p', $r.Name, 'skills', 'opt-out', '--remove', '--yes') })
        foreach ($b in $bundled) {
            [void]$steps.Add(@{ Label = "bundled skill $b"; Args = @('-p', $r.Name, 'skills', 'install', $b, '--yes') })
        }
        if (@($r.Enable).Count -gt 0) { [void]$steps.Add(@{ Label = "enable $($r.Enable -join ', ')"; Args = (@('-p', $r.Name, 'tools', 'enable') + @($r.Enable)) }) }
        [void]$steps.Add(@{ Label = 'description'; Args = @('profile', 'describe', $r.Name, '--text', $r.Description) })
        [void]$steps.Add(@{ Label = 'locate'; Args = @('profile', 'show', $r.Name) })
        @{ Key = $r.Name; Steps = $steps.ToArray() }
    }
    $installed = Invoke-BeanCodeHermesChains -Exe $hermes -Throttle $Parallel -Chains @($chains)

    $failures = New-Object System.Collections.ArrayList
    foreach ($p in $plan) {
        $r = $p.Role
        Write-Host ''
        Write-Host "== $($r.Name) ($($p.Action))"
        $ok = $true
        foreach ($s in @($installed[$r.Name])) {
            if ($s.Code -ne 0) {
                Write-Host "  FAIL $($s.Label) (exit $($s.Code)): hermes $($s.Args -join ' ')"
                foreach ($l in (@($s.Output.Split("`n")) | Select-Object -Last 8)) { Write-Host "    $l" }
                [void]$failures.Add("$($r.Name): $($s.Label)")
                $ok = $false
                continue
            }
            if ($s.Label -eq 'locate') { $p.Path = Get-BeanCodePathFromOutput -Output $s.Output; continue }
            Write-Host "  ok   $($s.Label)"
        }
        if (-not $ok -or -not $p.Path) { continue }

        $track = Join-Path $p.Path 'local\beancode-org.json'
        if (Test-Path -LiteralPath $track -PathType Leaf) {
            $prev = @((ConvertFrom-Json -InputObject (Read-BeanCodeText -Path $track)).skills)
            foreach ($old in $prev) {
                if ([string]$old -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $p.Skills -contains $old) { continue }
                $dir = Join-Path $p.Path "skills\$old"
                if (Test-Path -LiteralPath $dir -PathType Container) {
                    Remove-Item -LiteralPath $dir -Recurse -Force
                    Write-Host "  ok   removed skill no longer in this role: $old"
                }
            }
        }
        $json = '{"source": "beancode", "role": ' + (ConvertTo-BeanCodeJsonString -Value $r.Name) + ', "skills": [' + (($p.Skills | ForEach-Object { ConvertTo-BeanCodeJsonString -Value $_ }) -join ', ') + "]}`n"
        Write-BeanCodeText -Path $track -Text $json
    }

    if (-not $SkipBoardConfig -and $board -ne 'false') {
        $res = Invoke-BeanCodeHermes -Exe $hermes -Arguments @('-p', 'default', 'config', 'set', 'kanban.auto_decompose', 'false')
        Write-Host ''
        if ($res.Code -ne 0) { [void]$failures.Add('board: kanban.auto_decompose'); Write-Host "FAIL board config: $($res.Output)" }
        else { Write-Host 'Board: kanban.auto_decompose = false' }
    }

    # --- post-install checks ---
    $checkPlan = @($plan | Where-Object { $_.Path })
    $checked = Invoke-BeanCodeHermesChains -Exe $hermes -Throttle $Parallel -Chains @($checkPlan | ForEach-Object {
        @{ Key = $_.Role.Name; Steps = @(
            @{ Label = 'skills'; Args = @('-p', $_.Role.Name, 'skills', 'list', '--enabled-only') },
            @{ Label = 'auth'; Args = @('-p', $_.Role.Name, 'auth', 'status', [string]$roster.provider) }
        ) }
    })
    Write-Host ''
    Write-Host 'Checks:'
    foreach ($p in $checkPlan) {
        $r = $p.Role
        $res = @($checked[$r.Name])
        $listed = Get-BeanCodeListedSkills -Output ([string]$res[0].Output)
        $missing = New-Object System.Collections.ArrayList
        foreach ($s in @($p.Skills)) {
            if (-not (Find-BeanCodeInstalledSkill -ProfilePath $p.Path -Skill $s)) { [void]$missing.Add("$s (not on disk)"); continue }
            if (-not $listed.Contains($s)) { [void]$missing.Add("$s (not listed by hermes)") }
        }
        # Bundled skills can be gated on a toolset (sdlc-review loads only inside Kanban runs), so
        # `skills list` outside a run may hide them; on disk is the check.
        foreach ($s in $bundled) {
            if (-not (Find-BeanCodeInstalledSkill -ProfilePath $p.Path -Skill $s)) { [void]$missing.Add("$s (not on disk)") }
        }
        $authLine = ''
        if ($res.Count -gt 1) { $authLine = (@($res[1].Output.Split("`n") | Where-Object { $_.Trim() }) | Select-Object -Last 1) }
        $total = @($p.Skills).Count + $bundled.Count
        if ($missing.Count -eq 0) {
            Write-Host ('  PASS {0,-17} {1}/{1} skills; {2}' -f $r.Name, $total, $authLine)
        }
        else {
            Write-Host ('  FAIL {0,-17} {1} of {2} skills missing: {3}' -f $r.Name, $missing.Count, $total, ($missing -join ', '))
            [void]$failures.Add("$($r.Name): skills missing")
        }
        if ($authLine -notmatch 'logged in') { Write-Host "       $($r.Name) is not signed in to $($roster.provider): run 'hermes -p $($r.Name) auth add $($roster.provider)'" }
    }

    Write-Host ''
    if ($failures.Count -gt 0) {
        Write-Host "Finished with $($failures.Count) failure(s): $($failures -join '; ')"
        exit 5
    }
    Write-Host "Installed $($plan.Count) /org role(s)."
    Write-Host "Note: 'logged in' may come from the GitHub CLI's account and does not prove Copilot quota (docs\HERMES.md)."
    Write-Host 'Next: open Hermes Desktop, go to the Bots tab, open Director and send: /org <task>'
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
