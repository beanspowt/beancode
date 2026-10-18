# Installs the BeanCode OpenCode payload (config\opencode) into an OpenCode config directory.
#
# Default target is %USERPROFILE%\.config\opencode (the OpenCode user config dir).
# Nothing outside -Target (plus a sibling backup dir with -BackupExisting) is touched.
# OpenCode itself is never installed. Secrets/state files are never read or written.
#
# Usage:
#   Install-BeanCode.ps1                          install into default target
#   Install-BeanCode.ps1 -Target <dir>            install into <dir> (alias -Destination)
#   Install-BeanCode.ps1 -DryRun                  print plan only (also -WhatIf)
#   Install-BeanCode.ps1 -BackupExisting          back up conflicting files, then overwrite
#   Install-BeanCode.ps1 -InstallNpm              run npm ci (public registry) in -Target
#
# Behaviour:
#   1. Verifies payload against MANIFEST.sha256.json (aborts on mismatch).
#   2. Refuses unsafe targets: '..' segments, drive root, inside the repo, a file, or a reparse point.
#   3. Plans every file before writing: missing -> copy, identical SHA256 -> skip,
#      different -> conflict. Conflicts are refused unless -BackupExisting.
#   4. -BackupExisting copies each conflicting original to <Target>.bak-YYYYMMDD-HHMMSS
#      (a sibling of Target) before overwriting. Nothing is ever deleted.
#   5. Files are copied byte-exact and re-hashed after copy.
#
# Exit codes:
#   0 = success (or dry run / WhatIf with a clean plan)
#   1 = unexpected error
#   2 = payload does not match MANIFEST.sha256.json; nothing written
#   3 = unsafe target path refused; nothing written
#   4 = conflicting files refused (rerun with -BackupExisting); nothing written
#   5 = -InstallNpm precondition or npm ci failed

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Alias('Destination')]
    [string]$Target = (Join-Path $env:USERPROFILE '.config\opencode'),
    [switch]$DryRun,
    [switch]$BackupExisting,
    [switch]$InstallNpm
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'BeanCode.Common.ps1')

function Stop-Install {
    param([int]$Code, [string]$Message)
    Write-Host "ERROR: $Message"
    exit $Code
}

try {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
    $payload = Join-Path $repoRoot 'config\opencode'
    $manifest = Join-Path $repoRoot 'MANIFEST.sha256.json'

    Write-Host "BeanCode installer (PowerShell $($PSVersionTable.PSVersion))"
    Write-Host "Payload: $payload"

    $v = Test-BeanCodePayload -PayloadRoot $payload -ManifestPath $manifest
    if (-not $v.Ok) { Stop-Install 2 'payload does not match MANIFEST.sha256.json; nothing written.' }

    # --- target safety ---
    if ([string]::IsNullOrWhiteSpace($Target)) { Stop-Install 3 'empty -Target refused.' }
    if ($Target -match '(^|[\\/])\.\.([\\/]|$)') { Stop-Install 3 "path traversal ('..') in -Target refused: $Target" }
    $full = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') { Stop-Install 3 "drive root refused: $full" }
    if ($full -ieq $repoRoot -or $full.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Install 3 "target is inside the BeanCode repo (payload must not be a target): $full"
    }
    if (Test-Path -LiteralPath $full) {
        $ti = Get-Item -LiteralPath $full -Force
        if (-not $ti.PSIsContainer) { Stop-Install 3 "target exists and is not a directory: $full" }
        if (Test-BeanCodeReparsePoint -Path $full) { Stop-Install 3 "target is a reparse point (symlink/junction) refused: $full" }
    }

    # --- plan (no writes yet) ---
    $tree = @(Get-BeanCodeTree -Root $payload)
    $items = New-Object System.Collections.ArrayList
    $refusals = New-Object System.Collections.ArrayList
    foreach ($t in $tree) {
        $rel = $t.Path.Replace('/', '\')
        $dst = Join-Path $full $rel
        $segs = $rel.Split('\')
        $cur = $full
        for ($i = 0; $i -lt $segs.Length - 1; $i++) {
            $cur = Join-Path $cur $segs[$i]
            if (Test-Path -LiteralPath $cur) {
                $ci = Get-Item -LiteralPath $cur -Force
                if (-not $ci.PSIsContainer) { [void]$refusals.Add("not a directory: $cur"); break }
                if (Test-BeanCodeReparsePoint -Path $cur) { [void]$refusals.Add("reparse point: $cur"); break }
            }
        }
        $action = 'copy'
        if (Test-Path -LiteralPath $dst) {
            $di = Get-Item -LiteralPath $dst -Force
            if ($di.PSIsContainer) { $action = 'refuse' }
            elseif (Test-BeanCodeReparsePoint -Path $dst) { $action = 'refuse' }
            elseif ((Get-BeanCodeSha256 -Path $t.Full) -eq (Get-BeanCodeSha256 -Path $dst)) { $action = 'skip' }
            else { $action = 'conflict' }
        }
        if ($action -eq 'refuse') { [void]$refusals.Add("directory/reparse point where file expected: $dst") }
        [void]$items.Add([pscustomobject]@{ Rel = $rel; Src = $t.Full; Dst = $dst; Action = $action })
    }
    if ($refusals.Count -gt 0) {
        foreach ($r in $refusals) { Write-Host "REFUSED: $r" }
        Stop-Install 3 'unsafe layout in target; nothing written.'
    }

    $list = @($items.ToArray())
    $nCopy = @($list | Where-Object { $_.Action -eq 'copy' }).Count
    $nSkip = @($list | Where-Object { $_.Action -eq 'skip' }).Count
    $conf = @($list | Where-Object { $_.Action -eq 'conflict' })
    $nConf = $conf.Count
    foreach ($it in $list) { Write-Host ("[{0}] {1}" -f $it.Action, $it.Rel) }
    Write-Host "Plan: copy=$nCopy skip=$nSkip conflict=$nConf (target: $full)"

    if ($nConf -gt 0 -and -not $BackupExisting) {
        foreach ($c in $conf) { Write-Host "CONFLICT: $($c.Rel) differs from payload" }
        Stop-Install 4 "$nConf conflicting file(s) differ from payload; nothing written. Rerun with -BackupExisting to back them up and overwrite."
    }

    if ($InstallNpm) {
        if (-not (Test-Path -LiteralPath (Join-Path $payload 'package-lock.json') -PathType Leaf)) {
            Stop-Install 5 'package-lock.json missing from payload; -InstallNpm refused.'
        }
        if (Test-Path -LiteralPath (Join-Path $full 'node_modules')) {
            Stop-Install 5 'node_modules exists in target; npm ci would delete it. Remove it yourself, then rerun.'
        }
        if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { Stop-Install 5 'npm.cmd not found on PATH.' }
    }

    # --- dry run / WhatIf: stop before any write, network or process ---
    if ($DryRun -or -not $PSCmdlet.ShouldProcess($full, 'Install BeanCode payload')) {
        Write-Host 'DRY RUN / WhatIf: no files written, no network access, no processes started.'
        if ($nConf -gt 0 -and $BackupExisting) {
            Write-Host "Would back up $nConf file(s) to $($full).bak-<timestamp> before overwriting."
        }
        if ($InstallNpm) {
            Write-Host "Would run: npm ci --no-audit --no-fund --registry=https://registry.npmjs.org/ (in $full)"
        }
        exit 0
    }

    # --- backup (copy only; never delete) ---
    if ($nConf -gt 0) {
        $parent = Split-Path -Parent $full
        $leaf = Split-Path -Leaf $full
        $bak = Join-Path $parent ($leaf + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        if (Test-Path -LiteralPath $bak) { Stop-Install 1 "backup dir already exists: $bak" }
        [void][System.IO.Directory]::CreateDirectory($bak)
        foreach ($c in $conf) {
            $bdst = Join-Path $bak $c.Rel
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $bdst))
            [System.IO.File]::Copy($c.Dst, $bdst, $false)
            if ((Get-BeanCodeSha256 -Path $bdst) -ne (Get-BeanCodeSha256 -Path $c.Dst)) { Stop-Install 1 "backup verify failed: $($c.Rel)" }
        }
        Write-Host "Backed up $nConf file(s) to $bak"
    }

    # --- write ---
    [void][System.IO.Directory]::CreateDirectory($full)
    $written = 0
    foreach ($it in $list) {
        if ($it.Action -ne 'copy' -and $it.Action -ne 'conflict') { continue }
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $it.Dst))
        [System.IO.File]::Copy($it.Src, $it.Dst, $true)
        if ((Get-BeanCodeSha256 -Path $it.Dst) -ne (Get-BeanCodeSha256 -Path $it.Src)) { Stop-Install 1 "post-copy hash mismatch: $($it.Rel)" }
        $written++
    }
    Write-Host "Wrote $written file(s); $nSkip already identical."

    # --- optional npm ci ---
    if ($InstallNpm) {
        $npm = (Get-Command npm.cmd).Source
        Push-Location -LiteralPath $full
        try {
            & $npm ci --no-audit --no-fund --registry=https://registry.npmjs.org/
            $code = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        if ($code -ne 0) { Stop-Install 5 "npm ci failed (exit $code)." }
        Write-Host 'npm ci completed in target.'
    }

    Write-Host 'Install complete.'
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
    exit 1
}
