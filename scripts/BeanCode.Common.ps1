# BeanCode shared helpers. Dot-sourced by Install-BeanCode.ps1, Verify-BeanCode.ps1
# and New-Manifest.ps1. Windows PowerShell 5.1 compatible. Reads file bytes only,
# never reads or writes secrets/state files, never starts processes or touches network.
#
# This file contains no identity, employer or product terms. Those are supplied at run
# time by the user through a term file (Read-BeanCodeTermFile), which must live outside the repo.

# Generic secret patterns. Any hit fails verification in any payload file.
$script:BeanCodeSecretPatterns = @(
    @{ Name = 'github-token';        Regex = '(?<![A-Za-z0-9_-])ghp_[A-Za-z0-9]{36}(?![A-Za-z0-9_-])' },
    @{ Name = 'github-fine-grained'; Regex = '(?<![A-Za-z0-9_-])github_pat_[A-Za-z0-9_]{60,}(?![A-Za-z0-9_-])' },
    @{ Name = 'aws-access-key';      Regex = '(?<![A-Za-z0-9_-])AKIA[0-9A-Z]{16}(?![A-Za-z0-9_-])' },
    @{ Name = 'private-key-block';   Regex = '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' },
    @{ Name = 'sk-style-key';        Regex = '(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])' }
)

# Term or secret hits in these payload paths fail verification; hits elsewhere only WARN.
# Secret hits always fail, wherever they are.
$script:BeanCodeBlockingContent = '^(agents|agent|commands|plugins)/|(^|/)(opencode\.jsonc|AGENTS\.md|cli\.json|btw\.jsonc|package[^/]*\.json)$'

$script:BeanCodeReparseAttr = 0x400

function Test-BeanCodeReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    return (([int]$item.Attributes) -band $script:BeanCodeReparseAttr) -ne 0
}

function Get-BeanCodeSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

# Returns one object per file: Path (relative, forward slashes), Full (absolute).
# Throws on any reparse point (symlink/junction) so payloads cannot hide links.
function Get-BeanCodeTree {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $out = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    if (Test-BeanCodeReparsePoint -Path $rootFull) { throw "Reparse point not allowed: $rootFull" }
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        foreach ($file in [System.IO.Directory]::GetFiles($dir)) {
            if (Test-BeanCodeReparsePoint -Path $file) { throw "Reparse point not allowed: $file" }
            $rel = $file.Substring($rootFull.Length + 1).Replace('\', '/')
            [void]$out.Add([pscustomobject]@{ Path = $rel; Full = $file })
        }
        foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
            if (Test-BeanCodeReparsePoint -Path $sub) { throw "Reparse point not allowed: $sub" }
            $stack.Push($sub)
        }
    }
    return $out.ToArray()
}

# Returns a reason string if a payload-relative path must never ship, else $null.
function Get-BeanCodeForbiddenReason {
    param([Parameter(Mandatory = $true)][string]$Rel)
    $segs = $Rel.Split('/')
    $leaf = $segs[$segs.Length - 1].ToLowerInvariant()
    if ($leaf -eq 'service.json') { return 'service.json' }
    if ($leaf -match '\.(bak|backup)(-.*)?$') { return 'backup file' }
    if ($leaf -eq '.env' -or $leaf.StartsWith('.env.')) { return '.env file' }
    if ($leaf -match '^auth([._-].*)?$') { return 'auth file' }
    foreach ($s in $segs) {
        if ($s -eq 'node_modules') { return 'node_modules directory' }
        if ($s -eq '.local') { return '.local directory' }
    }
    if ($segs.Length -gt 1 -and $segs[0] -eq 'research') { return 'research directory' }
    return $null
}

# Reads a user term file (UTF-8, one term per line, '#' comments, blank lines ignored).
# The file must live outside the repo. Returns lowercase terms; never prints them.
function Read-BeanCodeTermFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
    if ($full -ieq $repo -or $full.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DenyTermsFile must be outside the repo.'
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "DenyTermsFile not found: $full" }
    $terms = New-Object System.Collections.ArrayList
    foreach ($line in [System.IO.File]::ReadAllLines($full, [System.Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        [void]$terms.Add($t.ToLowerInvariant())
    }
    return $terms.ToArray()
}

# Scans one payload file. Returns Binary flag, term hit counts (no term text) and secret hits.
function Get-BeanCodeContentScan {
    param(
        [Parameter(Mandatory = $true)][string]$Full,
        [string[]]$Terms
    )
    $bytes = [System.IO.File]::ReadAllBytes($Full)
    $probe = [Math]::Min($bytes.Length, 8000)
    for ($i = 0; $i -lt $probe; $i++) {
        if ($bytes[$i] -eq 0) {
            return [pscustomobject]@{ Binary = $true; TermHits = 0; SecretHits = @() }
        }
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $termHits = 0
    foreach ($term in @($Terms)) {
        if (-not $term) { continue }
        $idx = 0
        while (($idx = $text.IndexOf($term, $idx, [StringComparison]::OrdinalIgnoreCase)) -ge 0) {
            $termHits++
            $idx += $term.Length
        }
    }
    $secrets = New-Object System.Collections.ArrayList
    foreach ($p in $script:BeanCodeSecretPatterns) {
        $n = [regex]::Matches($text, $p.Regex).Count
        if ($n -gt 0) { [void]$secrets.Add([pscustomobject]@{ Name = $p.Name; Count = $n }) }
    }
    return [pscustomobject]@{ Binary = $false; TermHits = $termHits; SecretHits = $secrets.ToArray() }
}

# Verifies payload against manifest (and optionally an installed Target copy).
# -DenyTerms: optional lowercase terms from Read-BeanCodeTermFile. Without them the term scan is skipped.
# Returns [pscustomobject]{ Ok, Failures, Warnings, FileCount }. Prints FAIL/WARN/NOTE lines.
function Test-BeanCodePayload {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$Target,
        [string[]]$DenyTerms
    )
    $fail = New-Object System.Collections.ArrayList
    $warn = New-Object System.Collections.ArrayList
    $count = 0
    $tree = @()
    $payloadFull = [System.IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
    $terms = @($DenyTerms | Where-Object { $_ })
    $result = {
        foreach ($f in $fail) { Write-Host "FAIL: $f" }
        foreach ($w in $warn) { Write-Host "WARN: $w" }
        $ok = ($fail.Count -eq 0)
        $diskCount = @($tree).Count
        Write-Host ("Manifest entries: {0}; payload files on disk: {1}; failures: {2}; warnings: {3}; result: {4}" -f $count, $diskCount, $fail.Count, $warn.Count, $(if ($ok) { 'PASS' } else { 'FAIL' }))
        return [pscustomobject]@{ Ok = $ok; Failures = $fail.ToArray(); Warnings = $warn.ToArray(); FileCount = $count }
    }

    if ($terms.Count -eq 0) {
        Write-Host 'NOTE: no -DenyTermsFile supplied; identity/term scan skipped.'
    }
    else {
        Write-Host "NOTE: term scan enabled with $($terms.Count) term(s) from the supplied file (terms not printed)."
    }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        [void]$fail.Add("manifest missing: $ManifestPath")
        return (& $result)
    }
    if (-not (Test-Path -LiteralPath $payloadFull -PathType Container)) {
        [void]$fail.Add("payload root missing: $payloadFull")
        return (& $result)
    }

    try {
        $manifest = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($ManifestPath, [System.Text.Encoding]::UTF8))
    }
    catch {
        [void]$fail.Add("manifest unreadable: $($_.Exception.Message)")
        return (& $result)
    }

    if ($manifest.schema -ne 1) { [void]$fail.Add("manifest schema is not 1") }
    if ($manifest.root -ne 'config/opencode') { [void]$fail.Add("manifest root is not config/opencode") }
    $entries = @($manifest.files)
    if ([int]$manifest.fileCount -ne $entries.Count) { [void]$fail.Add("manifest fileCount $($manifest.fileCount) != entries $($entries.Count)") }

    $expected = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($e in $entries) {
        $p = [string]$e.path
        if ($p -eq '' -or $p.StartsWith('/') -or $p.Contains('\') -or ($p -match '(^|/)\.\.(/|$)')) {
            [void]$fail.Add("bad manifest path: $p")
            continue
        }
        if ($expected.ContainsKey($p)) { [void]$fail.Add("duplicate manifest path: $p"); continue }
        if ([string]$e.sha256 -cnotmatch '^[0-9a-f]{64}$') { [void]$fail.Add("bad sha256 in manifest for: $p"); continue }
        $expected.Add($p, $e)
    }
    $count = $expected.Count

    $tree = @(Get-BeanCodeTree -Root $payloadFull)
    $disk = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($t in $tree) { $disk.Add($t.Path, $t) }

    foreach ($p in $expected.Keys) {
        if (-not $disk.ContainsKey($p)) { [void]$fail.Add("MISSING $p") }
    }
    foreach ($p in $disk.Keys) {
        if (-not $expected.ContainsKey($p)) { [void]$fail.Add("EXTRA (not in manifest) $p") }
    }
    foreach ($p in $expected.Keys) {
        if (-not $disk.ContainsKey($p)) { continue }
        $e = $expected[$p]
        $full = $disk[$p].Full
        $size = (New-Object System.IO.FileInfo $full).Length
        if ([long]$e.size -ne $size) { [void]$fail.Add("SIZE $p (manifest $($e.size), disk $size)"); continue }
        if ((Get-BeanCodeSha256 -Path $full) -ne [string]$e.sha256) { [void]$fail.Add("HASH $p") }
    }

    foreach ($t in $tree) {
        $reason = Get-BeanCodeForbiddenReason -Rel $t.Path
        if ($reason) { [void]$fail.Add("FORBIDDEN ($reason) $($t.Path)") }
        $blocking = ($t.Path -match $script:BeanCodeBlockingContent)

        if ($terms.Count -gt 0) {
            $lowerPath = $t.Path.ToLowerInvariant()
            $nameHit = $false
            foreach ($term in $terms) {
                if ($lowerPath.IndexOf($term, [StringComparison]::Ordinal) -ge 0) { $nameHit = $true; break }
            }
            if ($nameHit) {
                $msg = "term hit in file name: $($t.Path)"
                if ($blocking) { [void]$fail.Add($msg) } else { [void]$warn.Add($msg) }
            }
        }

        $scan = Get-BeanCodeContentScan -Full $t.Full -Terms $terms
        if ($scan.Binary) { continue }
        foreach ($s in @($scan.SecretHits)) {
            [void]$fail.Add("SECRET-PATTERN ($($s.Name)) x$($s.Count) in $($t.Path)")
        }
        if ($scan.TermHits -gt 0) {
            $msg = "term hits x$($scan.TermHits) in $($t.Path)"
            if ($blocking) { [void]$fail.Add($msg) } else { [void]$warn.Add($msg) }
        }
    }

    if ($Target) {
        $targetFull = [System.IO.Path]::GetFullPath($Target).TrimEnd('\')
        if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
            [void]$fail.Add("target missing: $targetFull")
        }
        else {
            foreach ($p in $expected.Keys) {
                $tf = Join-Path $targetFull ($p.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $tf -PathType Leaf)) { [void]$fail.Add("TARGET MISSING $p"); continue }
                $e = $expected[$p]
                $size = (New-Object System.IO.FileInfo $tf).Length
                if ([long]$e.size -ne $size) { [void]$fail.Add("TARGET SIZE $p"); continue }
                if ((Get-BeanCodeSha256 -Path $tf) -ne [string]$e.sha256) { [void]$fail.Add("TARGET HASH $p") }
            }
        }
    }

    return (& $result)
}

# Writes manifest for payload (UTF-8 no BOM, LF). Refuses forbidden paths.
function New-BeanCodeManifestText {
    param([Parameter(Mandatory = $true)][string]$PayloadRoot)
    $payloadFull = [System.IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
    $tree = @(Get-BeanCodeTree -Root $payloadFull)
    $bad = @()
    foreach ($t in $tree) {
        $reason = Get-BeanCodeForbiddenReason -Rel $t.Path
        if ($reason) { $bad += "$($t.Path) ($reason)" }
    }
    if ($bad.Count -gt 0) { throw "Refusing to manifest forbidden payload files: $($bad -join ', ')" }

    $byPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($t in $tree) { $byPath.Add($t.Path, $t) }
    $keys = New-Object 'string[]' $byPath.Count
    $byPath.Keys.CopyTo($keys, 0)
    [Array]::Sort($keys, [StringComparer]::Ordinal)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`n")
    [void]$sb.Append('  "schema": 1,' + "`n")
    [void]$sb.Append('  "root": "config/opencode",' + "`n")
    [void]$sb.Append('  "fileCount": ' + $keys.Length + ',' + "`n")
    [void]$sb.Append('  "files": [' + "`n")
    for ($i = 0; $i -lt $keys.Length; $i++) {
        $p = $keys[$i]
        $full = $byPath[$p].Full
        $size = (New-Object System.IO.FileInfo $full).Length
        $hash = Get-BeanCodeSha256 -Path $full
        $line = '    {"path": ' + (ConvertTo-BeanCodeJsonString -Value $p) + ', "size": ' + $size + ', "sha256": "' + $hash + '"}'
        [void]$sb.Append($line)
        if ($i -lt $keys.Length - 1) { [void]$sb.Append(',') }
        [void]$sb.Append("`n")
    }
    [void]$sb.Append("  ]`n}`n")
    return [pscustomobject]@{ Text = $sb.ToString(); Count = $keys.Length }
}

function ConvertTo-BeanCodeJsonString {
    param([Parameter(Mandatory = $true)][string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}
