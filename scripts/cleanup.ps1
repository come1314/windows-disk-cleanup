<#
.SYNOPSIS
    Windows disk cleanup toolkit: scan / clean / verify / admin-check.

.DESCRIPTION
    Safety model (five independent layers):
      1. WHITELIST - clean mode only deletes paths that exist in the live catalog.
         A plan file never supplies a path; it only supplies item keys. The
         catalog is recomputed at clean time, so a tampered or stale plan can
         only ever select an item the catalog still recognizes.
      2. DENYLIST - critical system and personal paths are refused in code,
         regardless of what the catalog or the user says.
      3. SUBTREE - the denylist is applied to every descendant of a target, not
         just to the target itself. A whitelisted folder holding a .vhdx (the
         Docker WSL store being the real-world case) is refused outright instead
         of being recursively deleted. See Get-DeniedDescendant.
      4. DRY RUN - clean mode deletes nothing without -Confirm.
      5. AUDIT - every action is appended to cleanup-audit.jsonl.

.PARAMETER Mode
    scan        read-only inventory, writes disk-scan.json   (safe, no changes)
    clean       delete catalog items whose IDs or keys are passed in -Keys
    verify      compare expected vs actual freed space, hunt common leaks
    admin-check shadow copy / hibernation / pagefile report (requires admin)

.PARAMETER Keys
    IDs from the report ("25,4") or keys from the scan output. Keys are looked
    up first, so an all-digit key is never mistaken for an ID.

.PARAMETER Lang
    zh (default) or en for the report language. auto guesses from the system UI
    language and is best-effort only - prefer an explicit value.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File cleanup.ps1 -Mode scan -Deep
    powershell -ExecutionPolicy Bypass -File cleanup.ps1 -Mode clean -Keys 3f2a91c1,8b1c22de -Confirm
    powershell -ExecutionPolicy Bypass -File cleanup.ps1 -Mode verify
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('scan', 'clean', 'verify', 'admin-check', 'selftest', 'report')]
    [string]$Mode,

    [string]$Plan,
    [string]$OutFile,
    [string[]]$Keys,
    [string[]]$Exclude,
    [switch]$Confirm,
    [switch]$Deep,
    [int]$MinAgeMinutes = 0,
    [int]$MinMB = 10,
    [int]$TopFiles = 15,

    # auto = Chinese dictionary on a Chinese Windows, built-in English labels
    # everywhere else. Detection is best-effort only (see Get-I18n), so the
    # default is explicit: zh. Pass -Lang en for an English report.
    [ValidateSet('auto', 'zh', 'en')]
    [string]$Lang = 'zh'
)

# ------------------------------------------------------- environment guards --
# Everything below assumes an ordinary signed-in Windows user session. On a host
# that does not match, say so and stop - a half-working cleanup tool is worse
# than one that refuses to start.
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Output ('This script needs PowerShell 5.1 or newer. Found ' + $PSVersionTable.PSVersion.ToString() + '.')
    exit 2
}
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Output ('LanguageMode is ' + $ExecutionContext.SessionState.LanguageMode + '.')
    Write-Output 'Constrained mode blocks the .NET file APIs this script is built on.'
    Write-Output 'Re-run from a normal PowerShell window, or ask an administrator to allow FullLanguage.'
    exit 2
}
# env vars can be missing under a service account, a broken profile, or a remote
# shell; fall back to the Known Folder API before giving up
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData') }
if (-not $env:APPDATA) { $env:APPDATA = [Environment]::GetFolderPath('ApplicationData') }
if (-not $env:USERPROFILE) { $env:USERPROFILE = [Environment]::GetFolderPath('UserProfile') }
if (-not $env:SystemDrive -and $env:WINDIR) { $env:SystemDrive = [System.IO.Path]::GetPathRoot($env:WINDIR).TrimEnd('\') }
if (-not $env:LOCALAPPDATA -or -not $env:USERPROFILE -or -not $env:SystemDrive) {
    Write-Output 'Could not resolve LOCALAPPDATA / USERPROFILE / SystemDrive.'
    Write-Output 'Run this as a normally signed-in user, not as a service or system account.'
    exit 2
}

$ErrorActionPreference = 'SilentlyContinue'

# Console encoding: leave it as the terminal expects.
# Setting Console.OutputEncoding = UTF8 rewrites the code page of the shared
# console. Two measured consequences: a parent that reads our stdout with the old
# code page decodes mojibake, and culture detection in every process started
# afterwards reports the system locale instead of the user's UI language
# (zh-CN user, en-US afterwards). Opt in only when a caller knows it wants that.
if ($env:WDC_FORCE_UTF8) {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
}

# Read the UI language before anything else can disturb it. Used by -Lang auto,
# which is best-effort; the default stays explicit so the output is predictable.
$script:UiLanguage = ''
try { $script:UiLanguage = [string]$PSUICulture } catch { }
if (-not $script:UiLanguage) {
    try { $script:UiLanguage = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName } catch { }
}

$script:Root = Split-Path -Parent $PSScriptRoot
if (-not $Plan) { $Plan = Join-Path $script:Root 'disk-scan.json' }
$script:AuditLog = Join-Path $script:Root 'cleanup-audit.jsonl'
$script:ProtectedRoots = $null
$script:DenyExact = $null
$script:DenyTree = $null
$script:DenyRegex = $null

# ---------------------------------------------------------------- helpers ----

function Get-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PathSize {
    param([string]$Path)
    if (-not $Path) { return [PSCustomObject]@{ Bytes = [int64]0; Files = 0 } }

    # .NET rather than Get-Item: package caches live past MAX_PATH and the
    # FileSystem provider gives up on those, silently reporting zero bytes
    $root = Get-LongPath $Path
    if ([System.IO.File]::Exists($root)) {
        $len = [int64]0
        try { $len = (New-Object System.IO.FileInfo $root).Length } catch { }
        return [PSCustomObject]@{ Bytes = $len; Files = 1 }
    }
    if (-not [System.IO.Directory]::Exists($root)) { return [PSCustomObject]@{ Bytes = [int64]0; Files = 0 } }

    # Explicit stack walk instead of Get-ChildItem -Recurse:
    #   - does not follow junctions / symlinks (C:\Users\x\AppData\Local\Application Data
    #     is a legacy junction to its own parent and will loop forever)
    #   - roughly 5-10x faster on directories with 100k+ small files
    $bytes = [int64]0; $files = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    $reparse = [System.IO.FileAttributes]::ReparsePoint

    while ($stack.Count -gt 0) {
        $cur = Get-LongPath ([string]$stack.Pop())
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                try { $bytes += (New-Object System.IO.FileInfo $f).Length; $files++ } catch { }
            }
        } catch { }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                try {
                    $di = New-Object System.IO.DirectoryInfo $d
                    if (($di.Attributes -band $reparse) -eq 0) { $stack.Push($d) }
                } catch { }
            }
        } catch { }
    }
    return [PSCustomObject]@{ Bytes = $bytes; Files = $files }
}

function Get-FreeBytes {
    # CIM can be broken or blocked by policy on locked-down machines; DriveInfo
    # does not depend on WMI, so keep it as the fallback rather than reporting 0
    try {
        $d = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'") -ErrorAction Stop
        if ($null -ne $d) { return [int64]$d.FreeSpace }
    } catch { }
    try { return [int64](New-Object System.IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace } catch { }
    return [int64]0
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-KeyForPath {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
    $hash = $sha.ComputeHash($bytes)
    return (-join ($hash[0..3] | ForEach-Object { $_.ToString('x2') }))
}

# .NET throws PathTooLongException past ~260 chars unless the path is prefixed.
# Package caches (npm, pip) easily exceed that, so qualify long paths on demand.
function Get-LongPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path.Length -ge 240 -and -not $Path.StartsWith('\\?\')) { return '\\?\' + $Path }
    return $Path
}

# the \\?\ prefix is plumbing - never show it to a user, never pattern-match on it
function Get-PlainPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

# Test-Path also surrenders on long paths, so existence checks go through .NET
function Test-PathExists {
    param([string]$Path)
    if (-not $Path) { return $false }
    $lp = Get-LongPath $Path
    return ([System.IO.File]::Exists($lp) -or [System.IO.Directory]::Exists($lp))
}

<#
    Known folders, resolved at runtime instead of guessed from the folder name.

    Two reasons this has to be dynamic:
      - Documents / Desktop / Downloads are routinely redirected to D: or E: on
        prebuilt and low-storage machines, and Chinese Windows names the target
        "\u6211\u7684\u6587\u6863" - a name-based rule never sees it
      - plenty of machines have Documents and Desktop pointed at OneDrive

    A name-based regex is still kept in Test-DeniedPath as the second opinion.
#>
function Get-ProtectedRoots {
    if ($null -ne $script:ProtectedRoots) { return $script:ProtectedRoots }

    # whole subtree is personal data or system files
    $treeNames = @(
        'MyDocuments', 'DesktopDirectory', 'MyPictures', 'MyVideos', 'MyMusic',
        'Favorites', 'Templates', 'SendTo', 'Recent',
        'ProgramFiles', 'ProgramFilesX86', 'CommonApplicationData',
        'CommonDesktopDirectory', 'CommonDocuments'
    )
    # only the folder itself: their children include legitimate cache locations
    $exactNames = @('UserProfile', 'ApplicationData', 'LocalApplicationData')

    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param([string]$p, [bool]$tree)
        if (-not $p) { return }
        $k = $p.ToLowerInvariant().TrimEnd('\')
        if (-not $k -or $seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        [void]$out.Add([PSCustomObject]@{ Path = $k; Tree = $tree })
    }.GetNewClosure()

    foreach ($n in $treeNames) {
        $p = $null
        try { $p = [Environment]::GetFolderPath($n) } catch { }
        & $add $p $true
    }
    foreach ($n in $exactNames) {
        $p = $null
        try { $p = [Environment]::GetFolderPath($n) } catch { }
        & $add $p $false
    }

    # Downloads is not in the .NET Framework SpecialFolder enum; ask the shell,
    # then fall back to the default location under the profile
    $dl = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $dl = $shell.Namespace('shell:Downloads').Self.Path
    } catch { }
    if (-not $dl) { $dl = Join-Path $env:USERPROFILE 'Downloads' }
    & $add $dl $true

    # flattened for Test-DeniedPath: a hash lookup for exact roots, a short list
    # for the few that protect their whole subtree
    $exact = New-Object 'System.Collections.Generic.HashSet[string]'
    $treeList = New-Object System.Collections.ArrayList
    foreach ($o in $out) {
        if ($o.Tree) { [void]$treeList.Add($o.Path) } else { [void]$exact.Add($o.Path) }
    }
    $script:DenyExact = $exact
    $script:DenyTree = $treeList
    $script:ProtectedRoots = $out
    return $script:ProtectedRoots
}

<#
    One reparse-safe, long-path-safe directory walk, shared by every recursive
    operation (sizing, subtree checks, deletion).

    Get-ChildItem -Recurse is not usable for this:
      - behaviour around junctions differs between Windows PowerShell and pwsh,
        and a self-referential junction (AppData\Local\Application Data) is a
        guaranteed loop or an escape outside the directory we were asked about
      - it stops silently at MAX_PATH, which package caches blow past
    The walk visits files and directories of one level at a time; callers pass
    scriptblocks that mutate their own state, so nothing is materialised.
#>
function Invoke-TreeWalk {
    param(
        [string]$Path,
        [switch]$Recurse,
        [scriptblock]$OnFile,
        [scriptblock]$OnDir
    )
    if (-not $Path) { return }
    $root = Get-LongPath $Path

    if ([System.IO.File]::Exists($root)) {
        if ($OnFile) { $null = & $OnFile (New-Object System.IO.FileInfo $root) }
        return
    }
    if (-not [System.IO.Directory]::Exists($root)) { return }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)

    while ($stack.Count -gt 0) {
        $cur = [string]$stack.Pop()
        try {
            foreach ($f in [System.IO.Directory]::EnumerateFiles($cur)) {
                if ($OnFile) { $null = & $OnFile (New-Object System.IO.FileInfo $f) }
            }
        } catch { }
        try {
            foreach ($d in [System.IO.Directory]::EnumerateDirectories($cur)) {
                $di = New-Object System.IO.DirectoryInfo $d
                if ($OnDir) { $null = & $OnDir $di }
                if ($Recurse -and (($di.Attributes -band $reparse) -eq 0)) { $stack.Push($d) }
            }
        } catch { }
    }
}

function Get-I18n {
    param([string]$Lang = 'zh')
    # English needs no dictionary: item names, notes and every report string
    # already have ASCII defaults baked into the script
    if ($Lang -eq 'en') { return $null }
    if ($Lang -eq 'auto') {
        # Best effort only, and deliberately not the default.
        # Windows resolves the UI language per process, and it was observed
        # flipping to the system locale once an earlier run had set the console
        # code page to UTF-8 - on a zh-CN user, en-US came back. Guessing wrong
        # here is silent and confusing, so callers that care pass -Lang.
        # Inconclusive detection stays Chinese: that is the shipped dictionary.
        $ui = [string]$script:UiLanguage
        $two = $ui
        if ($two.Length -gt 2) { $two = $two.Substring(0, 2) }
        if ($two -and $two.ToLowerInvariant() -ne 'zh') { return $null }
    }
    $p = Join-Path $PSScriptRoot 'i18n.zh.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
}

function Resolve-Label {
    param($Item, $I18n)
    $out = [PSCustomObject]@{ Name = $Item.Name; What = $Item.Note; Impact = 'see note' }
    if ($null -eq $I18n) { return $out }
    $key = [string]$Item.Name

    $props = @()
    if ($I18n.items) { $props = @($I18n.items.PSObject.Properties.Name) }
    if ($props -contains $key) {
        $e = $I18n.items.$key
        return [PSCustomObject]@{ Name = $e.name; What = $e.what; Impact = $e.impact }
    }
    foreach ($r in @($I18n.byPrefix)) {
        if ($null -eq $r) { continue }
        $pre = [string]$r.prefix
        if ($pre -and $key.StartsWith($pre, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rest = $key.Substring($pre.Length)
            return [PSCustomObject]@{ Name = ([string]$r.name -replace '\{rest\}', $rest); What = $r.what; Impact = $r.impact }
        }
    }
    # longest suffix first: "cef_cache" must win over the generic "Cache" rule
    $suffixRules = @($I18n.bySuffix | Where-Object { $_ -ne $null } | Sort-Object { ([string]$_.suffix).Length } -Descending)
    foreach ($r in $suffixRules) {
        $suf = [string]$r.suffix
        if ($suf -and $key.EndsWith($suf, [System.StringComparison]::OrdinalIgnoreCase)) {
            $app = $key.Substring(0, $key.Length - $suf.Length).TrimEnd([char[]]@('\', ' '))
            return [PSCustomObject]@{ Name = ([string]$r.name -replace '\{app\}', $app); What = $r.what; Impact = $r.impact }
        }
    }
    return $out
}

function Test-Excluded {
    param($Item, [string[]]$Patterns)
    if (-not $Patterns) { return $false }
    foreach ($p in $Patterns) {
        if (-not $p) { continue }
        if ($Item.Name -like $p) { return $true }
        if ($Item.Path -and $Item.Path -like $p) { return $true }
    }
    return $false
}

<#
    Second safety layer. Even if the catalog were wrong, these never get deleted.
    Deliberately specific: deleting C:\Windows\Temp is fine, deleting
    C:\Windows\System32 is not, so blanket "no paths under C:\Windows" is wrong.

    All patterns are compiled into ONE regex. This function runs once per file
    during a subtree scan - on a 100k-file cache, 40 separate -match calls is the
    difference between seconds and minutes.
#>
function Get-DenyRegex {
    if ($null -ne $script:DenyRegex) { return $script:DenyRegex }
    $deny = @(
        '^[a-z]:\\windows$',
        '\\windows\\(system32|syswow64|winsxs|installer|assembly|servicing|boot|fonts|inf|driverstore|systemapps|microsoft\.net|twain_32|web|schemas|globalization|policydefinitions)',
        '\\windows\\(explorer\.exe|notepad\.exe|regedit\.exe|system\.ini|win\.ini)',
        '\\program files',
        '\\programdata',
        'system volume information',
        '\\recovery\\',
        '\$windows\.~',
        '\$recycle\.bin',
        '\\pagefile\.sys$', '\\hiberfil\.sys$', '\\swapfile\.sys$',
        '\\bootmgr$', '\\ntldr$', '^[a-z]:\\boot\\',
        '\\documents$', '\\documents\\', '\\desktop$', '\\desktop\\',
        '\\pictures$', '\\pictures\\', '\\videos$', '\\videos\\',
        '\\music$', '\\music\\', '\\downloads$', '\\downloads\\',
        '\\onedrive', '\\\.ssh', '\\\.gnupg', '\\\.git\\',
        '\\appdata\\local$', '\\appdata\\roaming$', '\\appdata\\locallow$',
        '\\users$', '\\users\\public', '\\users\\[^\\]+$',
        # Legacy compatibility junctions every profile carries; they resolve to a
        # parent or a sibling, so anything reached "through" one is a misleading
        # duplicate of a path that may well be protected.
        # Anchored to the profile root on purpose: an unanchored '\\cookies$' also
        # matches node_modules\...\lib\web\cookies and would veto whole caches.
        '\\users\\[^\\]+\\(application data|history|temporary internet files|local settings|my documents|my music|my pictures|my videos|cookies|nethood|printhood|recent|sendto|start menu|templates)$',
        '\\appdata\\(local|roaming)\\(application data|history|temporary internet files|local settings)$',
        '\.vhdx$', '\.vhd$', '\.vmdk$', '\.iso$'
    )
    $script:DenyRegex = New-Object System.Text.RegularExpressions.Regex (($deny -join '|'), 'Compiled')
    return $script:DenyRegex
}

function Test-DeniedPath {
    param([string]$Path)
    if (-not $Path) { return $true }
    $p = (Get-PlainPath $Path).ToLowerInvariant().TrimEnd('\')
    if (-not $p) { return $true }
    if ($p -match '^[a-z]:$') { return $true }
    if ($p -match '^\\\\[^\\]+\\[^\\]+$') { return $true }

    # Known folders resolved by the OS, not by name. Name-based rules cannot see
    # a redirected or localized profile: Documents on D:\ under a non-English
    # folder name is common, and Documents on OneDrive is the Windows default.
    $null = Get-ProtectedRoots
    if ($script:DenyExact.Contains($p)) { return $true }
    foreach ($t in $script:DenyTree) {
        if ($p -eq $t) { return $true }
        if ($p.Length -gt $t.Length -and $p.StartsWith($t + '\', [System.StringComparison]::Ordinal)) { return $true }
    }

    return (Get-DenyRegex).IsMatch($p)
}

<#
    Test-DeniedPath only ever sees the path it is handed. A whitelisted root can
    still hold a protected file further down, and a recursive delete of the root
    would take that file with it - the denylist would never be consulted again.

    The concrete case: AppData\Local\Docker\wsl is a plausible-looking cache
    folder, but it contains disk\docker_data.vhdx and main\ext4.vhdx. Deleting
    the folder destroys every Docker image, container and volume, and the
    '\.vhdx$' rule never fires because it is only applied to the catalog path.

    So callers must check the whole subtree before recursing into it. Returns
    the protected descendants found; an empty result means the tree is clear.

    Uses Invoke-TreeWalk rather than Get-ChildItem -Recurse on purpose: a cache
    folder that contains a junction must not be followed through it, or the scan
    wanders off into the rest of the disk and reports paths that are not part of
    the item at all.
#>
function Get-DeniedDescendant {
    param([string]$Root, [switch]$FirstOnly)

    $hits = New-Object System.Collections.ArrayList
    if (-not $Root) { return $hits }
    if (-not [System.IO.Directory]::Exists((Get-LongPath $Root))) { return $hits }

    $state = [PSCustomObject]@{ N = 0; Stop = $false }
    $limit = 0
    if ($FirstOnly) { $limit = 1 }

    $visit = {
        param($e)
        if ($state.Stop) { return }
        if (Test-DeniedPath $e.FullName) {
            [void]$hits.Add((Get-PlainPath $e.FullName))
            $state.N++
            if ($limit -gt 0 -and $state.N -ge $limit) { $state.Stop = $true }
        }
    }.GetNewClosure()

    Invoke-TreeWalk -Path $Root -Recurse -OnFile $visit -OnDir $visit
    return $hits
}

<#
    Per-entry gate used while deleting, so a protected file cannot be unlinked
    even if the subtree pre-flight missed it (long paths past 260 chars are the
    realistic blind spot, plus anything created between the check and the delete).
    A reparse point is judged by its own path only; callers must never recurse
    through one, since its target may live outside the whitelisted root.
#>
function Test-DeletableChild {
    param([System.IO.FileSystemInfo]$Entry)
    if ($null -eq $Entry) { return $false }
    return (-not (Test-DeniedPath $Entry.FullName))
}

<#
    Empties one catalog directory and reports what happened.

    Split out of Invoke-Clean so the self-test can run the real delete path
    against a throwaway tree. That branch only executes with -Confirm, which
    otherwise means the most dangerous code in the project ships untested.

    The directory itself is always kept - the catalog entry is a cache root the
    owning application expects to still be there.
#>
function Remove-TreeContent {
    param([string]$Path, [int]$MinAgeMinutes = 0)

    $st = [PSCustomObject]@{ Ok = 0; Fail = 0; Protected = 0 }
    if (-not [System.IO.Directory]::Exists((Get-LongPath $Path))) { return $st }
    $reparse = [System.IO.FileAttributes]::ReparsePoint

    $cut = $null
    if ($MinAgeMinutes -gt 0) { $cut = (Get-Date).AddMinutes(-$MinAgeMinutes) }

    $dirs = New-Object System.Collections.ArrayList

    # Every file is gated individually rather than deleting a child directory
    # recursively. Costs one syscall per file, buys two things: a protected file
    # deep in the tree cannot be taken down with its parent, and the walk visits
    # each node exactly once instead of once per ancestor.
    $onFile = {
        param($f)
        if ($cut -and $f.LastWriteTime -gt $cut) { return }
        if (-not (Test-DeletableChild $f)) { $st.Protected++; return }
        try { [System.IO.File]::Delete((Get-LongPath $f.FullName)); $st.Ok++ } catch { $st.Fail++ }
    }.GetNewClosure()

    $onDir = {
        param($d)
        if (-not (Test-DeletableChild $d)) { $st.Protected++; return }
        # the walk never descends into a reparse point, so it lands here as a
        # leaf: unlink it, never look through it
        if (($d.Attributes -band $reparse) -ne 0) {
            try { [System.IO.Directory]::Delete((Get-LongPath $d.FullName)); $st.Ok++ } catch { $st.Fail++ }
            return
        }
        [void]$dirs.Add($d)
    }.GetNewClosure()

    Invoke-TreeWalk -Path $Path -Recurse -OnFile $onFile -OnDir $onDir

    # deepest first, so a parent becomes empty before it is tested
    foreach ($d in ($dirs | Sort-Object { $_.FullName.Length } -Descending)) {
        $lp = Get-LongPath $d.FullName
        try {
            if (-not [System.IO.Directory]::Exists($lp)) { continue }
            $n = 0
            foreach ($x in [System.IO.Directory]::EnumerateFileSystemEntries($lp)) { $n++ }
            if ($n -eq 0) { [System.IO.Directory]::Delete($lp); $st.Ok++ }
        } catch { }
    }
    return $st
}

<#
    Resolve one user-supplied reference to a live catalog item.

    Both forms are accepted because both appear in the workflow: the report lists
    IDs, the scan output lists keys. Needing to convert one into the other was
    the easiest place to get stuck, and converting wrong deletes the wrong thing.

    An ID is only meaningful together with the scan that produced it - the
    numbering follows catalog order, which shifts when a cache appears or
    disappears between runs. So a numeric token is first mapped to its key
    through the plan file, and that key is then looked up in the live catalog.
    Keys are path-derived, so they survive reordering; IDs do not.

    Keys win over IDs when both could match: an 8-character hex key made only of
    digits (about 2% of keys) would otherwise be read as an ID.
#>
function Find-CatalogItem {
    param($Catalog, [string]$Token, $Plan)

    if (-not $Catalog -or -not $Token) { return @() }
    $t = $Token.Trim()
    if (-not $t) { return @() }

    $byKey = @($Catalog | Where-Object { $_.Key -eq $t })
    if ($byKey.Count -gt 0) { return $byKey }

    if ($t -notmatch '^[0-9]{1,6}$') { return @() }
    $id = 0
    if (-not [int]::TryParse($t, [ref]$id)) { return @() }

    if ($Plan -and $Plan.Items) {
        $hit = @($Plan.Items | Where-Object { $_.Id -eq $id })
        if ($hit.Count -gt 0) {
            # the plan remembers which path this number meant; if that key no
            # longer exists the item is gone, and deleting by live numbering now
            # would hit whatever else happens to hold that number
            return @($Catalog | Where-Object { $_.Key -eq $hit[0].Key })
        }
        return @()
    }

    return @($Catalog | Where-Object { $_.Id -eq $id })
}

function Find-BackupDirs {
    $globs = @(
        (Join-Path $env:USERPROFILE '.*\workspace\sessions\*\modify_backup'),
        (Join-Path $env:USERPROFILE '.*\sessions\*\modify_backup'),
        (Join-Path $env:LOCALAPPDATA '*\*\sessions\*\modify_backup'),
        (Join-Path $env:LOCALAPPDATA '*\sessions\*\modify_backup')
    )
    $found = @()
    foreach ($g in $globs) {
        $found += Get-ChildItem -Path $g -Directory -Force -ErrorAction SilentlyContinue
    }
    return $found
}

# ---------------------------------------------------------------- catalog ----

function Add-Item {
    param($List, [string]$Name, [string]$Path, [string]$Tier, [string]$Note, [string[]]$Apps, [string]$Action = 'delete')
    [void]$List.Add([PSCustomObject]@{
            Name = $Name; Path = $Path; Tier = $Tier; Note = $Note; Apps = $Apps; Action = $Action
        })
}

function Add-CacheGlob {
    param($List, [string]$Root, [string]$Pattern, [string]$Tier, [string]$Note)
    if (-not $Root -or -not $Pattern) { return }
    $local = ([string]$env:LOCALAPPDATA).ToLowerInvariant()
    $roam = ([string]$env:APPDATA).ToLowerInvariant()

    # Escape the literal part before adding the wildcard. A profile path can
    # contain [ or ], which the provider would read as a character class and then
    # match nothing - the cache would silently vanish from the catalog.
    $glob = Join-Path ([System.Management.Automation.WildcardPattern]::Escape($Root)) $Pattern
    foreach ($d in (Get-ChildItem -Path $glob -Directory -Force -ErrorAction SilentlyContinue)) {
        if (Test-DeniedPath $d.FullName) { continue }
        $raw = $d.FullName
        $low = $raw.ToLowerInvariant()
        # show a path relative to AppData so the user can tell which app owns it
        if ($low.StartsWith($local) -and $low -ne $local) { $name = 'Local\' + $raw.Substring($local.Length + 1) }
        elseif ($low.StartsWith($roam) -and $low -ne $roam) { $name = 'Roaming\' + $raw.Substring($roam.Length + 1) }
        else { $name = $raw }
        Add-Item $List $name $raw $Tier $Note @()
    }
}

function Get-Catalog {
    $list = New-Object System.Collections.ArrayList
    $local = $env:LOCALAPPDATA
    $roam = $env:APPDATA
    $user = $env:USERPROFILE
    $win = $env:WINDIR

    # ---- safe: pure caches, no functional loss -------------------------------
    Add-Item $list 'User Temp' (Join-Path $local 'Temp') 'safe' 'Per-user temp files. Locked files are skipped automatically.' @()
    Add-Item $list 'Windows Temp' (Join-Path $win 'Temp') 'safe' 'System temp files. Most need admin rights to remove.' @()

    Add-Item $list 'npm cache' (Join-Path $local 'npm-cache\_cacache') 'safe' 'Package download cache. Re-downloaded on next install.' @('node')
    Add-Item $list 'npm cache (npx)' (Join-Path $local 'npm-cache\_npx') 'safe' 'npx throwaway installs. Re-downloaded on next run.' @('node')
    Add-Item $list 'pnpm store' (Join-Path $local 'pnpm-store') 'safe' 'Package store. Re-downloaded on next install.' @('node')
    Add-Item $list 'Yarn cache' (Join-Path $local 'Yarn\Cache') 'safe' 'Package download cache. Re-downloaded on next install.' @('node')
    Add-Item $list 'pip cache' (Join-Path $local 'pip\cache') 'safe' 'Python wheel/sdist cache. Re-downloaded on next install.' @('python')
    Add-Item $list 'go build cache' (Join-Path $local 'go-build') 'safe' 'Go build cache. Rebuilt on next build.' @('go')
    Add-Item $list 'conda pkgs (.conda)' (Join-Path $user '.conda\pkgs') 'safe' 'Conda package tarballs. Re-downloaded on next install.' @('conda')
    Add-Item $list 'conda pkgs (anaconda3)' (Join-Path $user 'anaconda3\pkgs') 'safe' 'Conda package tarballs. Re-downloaded on next install.' @('conda')
    Add-Item $list 'conda pkgs (AppData)' (Join-Path $local 'conda\conda\pkgs') 'safe' 'Conda package tarballs. Re-downloaded on next install.' @('conda')

    # Chromium browsers: only real profiles (Default / Profile N / Guest). The
    # User Data folder also holds dozens of internal component dirs, each with
    # its own Cache - walking all of them buries the useful entries in noise.
    foreach ($browser in (@(
                @('Chrome', (Join-Path $local 'Google\Chrome\User Data'), 'chrome'),
                @('Edge', (Join-Path $local 'Microsoft\Edge\User Data'), 'msedge')
            ))) {
        $bname = $browser[0]; $ud = $browser[1]; $proc = $browser[2]
        if (-not (Test-Path -LiteralPath $ud)) { continue }
        foreach ($sub in @('ShaderCache', 'GrShaderCache', 'DawnCache', 'GraphiteDawnCache')) {
            $sp = Join-Path $ud $sub
            if (Test-Path -LiteralPath $sp) {
                Add-Item $list ($bname + ' ' + $sub) $sp 'safe' 'GPU shader cache, rebuilt automatically the next time a page renders.' @($proc)
            }
        }
        foreach ($prof in (Get-ChildItem -LiteralPath $ud -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($prof.Name -ne 'Default' -and $prof.Name -ne 'Guest Profile' -and $prof.Name -notmatch '^Profile \d+$') { continue }
            foreach ($sub in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage')) {
                Add-Item $list ($bname + ' ' + $prof.Name + ' ' + $sub) (Join-Path $prof.FullName $sub) 'safe' 'Browser HTTP/code cache. Pages reload slightly slower once. Cookies, history and logins are untouched.' @($proc)
            }
        }
    }
    foreach ($prof in (Get-ChildItem (Join-Path $roam 'Mozilla\Firefox\Profiles') -Directory -Force -ErrorAction SilentlyContinue)) {
        Add-Item $list ('Firefox ' + $prof.Name + ' cache2') (Join-Path $prof.FullName 'cache2') 'safe' 'Browser HTTP cache. Pages reload slightly slower once.' @('firefox')
    }

    Add-Item $list 'Crash dumps' (Join-Path $local 'CrashDumps') 'safe' 'App crash dumps. Only useful for debugging past crashes.' @()
    Add-Item $list 'INetCache' (Join-Path $local 'Microsoft\Windows\INetCache') 'safe' 'Legacy WinINet cache.' @()
    Add-Item $list 'QQMusic stream cache' (Join-Path $roam 'Tencent\QQMusic\QQMusicCache') 'safe' 'Streaming cache of played tracks - not the user downloaded library.' @('QQMusic')
    Add-Item $list 'CloudMusic stream cache' (Join-Path $local 'NetEase\CloudMusic\Cache') 'safe' 'Streaming cache of played tracks.' @('cloudmusic')

    # ---- caution: real trade-off --------------------------------------------
    Add-Item $list 'Windows Update download' (Join-Path $win 'SoftwareDistribution\Download') 'caution' 'Downloaded update payloads. Stop wuauserv first.' @('wuauserv')
    Add-Item $list 'Delivery Optimization' (Join-Path $win 'SoftwareDistribution\DeliveryOptimization') 'caution' 'Update/Store P2P cache. Rebuilt automatically.' @()
    Add-Item $list 'Windows Logs' (Join-Path $win 'Logs') 'caution' 'CBS/DISM logs. Useful when Windows Update is broken.' @()
    Add-Item $list 'Minidump' (Join-Path $win 'Minidump') 'caution' 'Blue-screen dumps. Only useful for crash analysis.' @()
    Add-Item $list 'LiveKernelReports' (Join-Path $win 'LiveKernelReports') 'caution' 'Kernel live dumps. Only useful for driver debugging.' @()
    Add-Item $list 'Memory dump' (Join-Path $win 'MEMORY.DMP') 'caution' 'Full memory dump from a past crash.' @()
    Add-Item $list 'Prefetch' (Join-Path $win 'Prefetch') 'caution' 'Boot/app prefetch data. First launches may feel slower once.' @()
    $winOld = Join-Path (Split-Path -Parent $win) 'Windows.old'
    Add-Item $list 'Windows.old' $winOld 'caution' 'Previous Windows install. Prefer Settings > Storage, which also clears the rollback entry.' @()

    Add-Item $list 'vscode-cpptools' (Join-Path $local 'Microsoft\vscode-cpptools') 'caution' 'C/C++ IntelliSense database. Rebuilt on next open, can take minutes.' @('Code')
    foreach ($jb in (Get-ChildItem (Join-Path $local 'JetBrains') -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($sub in @('caches', 'index', 'log', 'tmp')) {
            $sp = Join-Path $jb.FullName $sub
            if (Test-Path -LiteralPath $sp) {
                Add-Item $list ('JetBrains ' + $jb.Name + '\' + $sub) $sp 'caution' 'IDE index/cache only - settings and plugins are untouched. Reindexing is slow on large projects.' @('idea64', 'pycharm64')
            }
        }
    }
    Add-Item $list 'NuGet packages' (Join-Path $user '.nuget\packages') 'caution' 'Restored NuGet packages. Re-downloaded on next restore.' @('dotnet', 'msbuild')
    Add-Item $list 'Gradle caches' (Join-Path $user '.gradle\caches') 'caution' 'Gradle dependency cache. Re-downloaded on next build.' @('java')
    Add-Item $list 'Maven repository' (Join-Path $user '.m2\repository') 'caution' 'Maven local repo. Re-downloaded on next build, can be slow.' @('java')
    # NOT a delete item. This folder holds docker_data.vhdx / ext4.vhdx, which
    # ARE the images, containers and volumes - not a cache that gets rebuilt.
    # Recursively removing it is unrecoverable, and it is not how Docker
    # reclaims space anyway: that is "docker system prune -a".
    Add-Item $list 'Docker data' (Join-Path $local 'Docker\wsl') 'action' 'Not a cache: holds docker_data.vhdx / ext4.vhdx, i.e. the images, containers and volumes themselves. Never delete this folder - reclaim space with "docker system prune -a".' @('docker') 'docker'

    # ---- generic per-app Chromium caches (tier caution: app-specific) --------
    Add-CacheGlob $list $local '*\Cache' 'caution' 'Per-app cache folder. Make sure the app holds no unsaved work.'
    Add-CacheGlob $list $local '*\cef_cache' 'caution' 'Per-app Chromium cache. Usually safe.'
    Add-CacheGlob $list $local '*\Code Cache' 'caution' 'Per-app V8 code cache. Rebuilt automatically.'
    Add-CacheGlob $list $local '*\User Data\Cache' 'caution' 'Chromium-based browser/app cache (Chrome forks, Electron apps). Does not include cookies or login data.'
    Add-CacheGlob $list $local '*\*\Cache' 'caution' 'Nested per-app cache (e.g. editor and video tools). Verify the owning app first.'

    # ---- other local user accounts on the same machine ----------------------
    # A large share of "C: is full" cases are another account's profile, or an
    # old account that was never cleaned. Reading it needs admin rights.
    foreach ($prof in (Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($prof.FullName.TrimEnd('\') -eq $env:USERPROFILE.TrimEnd('\')) { continue }
        # skip machine/service accounts: they hold no user cache worth cleaning
        if ($prof.Name -match '^(Default|defaultuser|All Users|Public|Codex|WDAGUtilityAccount)') { continue }
        if ($prof.Name -match '(AppPool|\$)$') { continue }
        Add-Item $list ('Other user Temp: ' + $prof.Name) (Join-Path $prof.FullName 'AppData\Local\Temp') 'caution' 'Another local account on this PC. Needs admin; make sure the account is not in active use before clearing.' @()
        foreach ($ud in (Get-ChildItem (Join-Path $prof.FullName 'AppData\Local') -Directory -Filter 'User Data' -Force -ErrorAction SilentlyContinue)) {
            Add-CacheGlob $list $ud.FullName '*\Cache' 'caution' 'Browser cache of another local account. Needs admin.'
        }
    }

    # ---- leak hunter: agent copy-on-delete backups ---------------------------
    foreach ($b in (Find-BackupDirs)) {
        $sessionId = Split-Path -Leaf (Split-Path -Parent $b.FullName)
        Add-Item $list ('Agent backup: ' + $sessionId) $b.FullName 'caution' 'Copy-on-delete backup from an AI coding agent. This is a very common reason why freeing 40 GB only shows 20 GB.'
    }

    # ---- special actions: never a plain delete ------------------------------
    Add-Item $list 'Recycle Bin (empty it)' '' 'action' 'Recoverable deleted files. Frees space only when emptied.' @() 'recycle'
    Add-Item $list 'hiberfil.sys (disable hibernation)' '' 'action' 'Frees roughly 40-60% of RAM size. Loses hibernate and fast startup.' @() 'hibernation'
    Add-Item $list 'pagefile.sys (move to another drive)' '' 'action' 'Never delete it. Move it to a drive with free space instead.' @() 'pagefile'

    $out = New-Object System.Collections.ArrayList
    $i = 0
    $seen = @{}
    foreach ($it in $list) {
        # several globs can match the same directory (e.g. *\User Data\Cache and
        # *\*\Cache) - keep the first registration so tiers stay predictable
        if ($it.Path) {
            $k = $it.Path.ToLowerInvariant()
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
        }
        $i++
        $key = 'special-' + $i
        if ($it.Path) { $key = Get-KeyForPath $it.Path }
        [void]$out.Add([PSCustomObject]@{
                Id = $i; Key = $key; Name = $it.Name; Path = $it.Path
                Tier = $it.Tier; Note = $it.Note; Apps = $it.Apps; Action = $it.Action
            })
    }
    return $out
}

# ---------------------------------------------------------------- scan -------

function Invoke-Scan {
    $catalog = Get-Catalog
    $running = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) { $running[$p.ProcessName.ToLowerInvariant()] = $true }

    $rows = New-Object System.Collections.ArrayList
    $idx = 0
    # Progress only when attached to a real console. Write-Progress is NOT silent
    # when output is redirected - it dumps tens of KB of escape art into logs.
    $showProgress = $false
    try { $showProgress = -not [Console]::IsOutputRedirected } catch { }
    foreach ($c in $catalog) {
        $idx++
        if ($showProgress) {
            $pct = [Math]::Min(100, [int]($idx * 100 / [Math]::Max(1, $catalog.Count)))
            [Console]::Write("`r[{0,3}%] {1,-60}" -f $pct, $c.Name)
        }
        if ($c.Action -ne 'delete') {
            # action items are never deleted, but the ones that own a real path
            # (Docker) still get measured so the user can see what is sitting
            # there and decide whether to run the proper tool
            $aSize = [int64]0; $aFiles = 0; $aExists = $false
            if ($c.Path -and (Test-PathExists $c.Path)) {
                $aExists = $true
                $am = Get-PathSize $c.Path
                $aSize = $am.Bytes; $aFiles = $am.Files
            }
            [void]$rows.Add([PSCustomObject]@{
                    Id = $c.Id; Key = $c.Key; Tier = $c.Tier; Name = $c.Name; Path = $c.Path
                    SizeBytes = [int64]$aSize; Files = $aFiles; Exists = $aExists; Locked = @(); Note = $c.Note; Action = $c.Action
                })
            continue
        }
        $exists = Test-PathExists $c.Path
        $size = 0; $files = 0
        if ($exists) {
            $m = Get-PathSize $c.Path
            $size = $m.Bytes; $files = $m.Files
        }
        $locked = @()
        foreach ($a in $c.Apps) { if ($running.ContainsKey($a.ToLowerInvariant())) { $locked += $a } }
        [void]$rows.Add([PSCustomObject]@{
                Id = $c.Id; Key = $c.Key; Tier = $c.Tier; Name = $c.Name; Path = $c.Path
                SizeBytes = [int64]$size; Files = $files; Exists = $exists; Locked = $locked
                Note = $c.Note; Action = $c.Action
            })
    }

    $planObj = [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('s'); Computer = $env:COMPUTERNAME; User = $env:USERNAME
        IsAdmin = (Get-IsAdmin); FreeBytes = (Get-FreeBytes); Items = $rows
    }
    if ($showProgress) { [Console]::Write("`r" + (' ' * 72) + "`r") }
    $planObj | ConvertTo-Json -Depth 6 | Out-File -FilePath $Plan -Encoding utf8

    $live = $rows | Where-Object { $_.Exists -and $_.SizeBytes -gt 1MB } | Sort-Object SizeBytes -Descending

    Write-Output ''
    Write-Output ('Disk free : ' + (Format-Size (Get-FreeBytes)) + '   admin: ' + (Get-IsAdmin))
    Write-Output ''
    Write-Output ('{0,-4} {1,-9} {2,10} {3,6} {4,-42} {5}' -f 'ID', 'TIER', 'SIZE', 'FILES', 'NAME', 'LOCKED')
    Write-Output ('-' * 104)
    foreach ($r in $live) {
        $nm = $r.Name; if ($nm.Length -gt 40) { $nm = $nm.Substring(0, 40) }
        Write-Output ('{0,-4} {1,-9} {2,10} {3,6} {4,-42} {5}' -f $r.Id, $r.Tier, (Format-Size $r.SizeBytes), $r.Files, $nm, ($r.Locked -join ','))
    }
    $safeSum = ($live | Where-Object { $_.Tier -eq 'safe' } | Measure-Object -Property SizeBytes -Sum).Sum
    $cautSum = ($live | Where-Object { $_.Tier -eq 'caution' } | Measure-Object -Property SizeBytes -Sum).Sum
    if ($null -eq $safeSum) { $safeSum = 0 }
    if ($null -eq $cautSum) { $cautSum = 0 }
    Write-Output ''
    Write-Output ('safe total    : ' + (Format-Size ([int64]$safeSum)))
    Write-Output ('caution total : ' + (Format-Size ([int64]$cautSum)))
    Write-Output ('plan written  : ' + $Plan)

    $map = @()
    foreach ($r in ($live | Where-Object { $_.SizeBytes -gt 10MB })) { $map += ($r.Id.ToString() + ':' + $r.Key) }
    if ($map.Count -gt 0) { Write-Output ('keys (id:key) : ' + ($map -join ' ')) }

    if ($Deep) { Invoke-DeepScan -TopFiles $TopFiles }

    Write-Output ''
    Write-Output 'Next: show the table to the user, let them choose IDs, then run'
    Write-Output '      -Mode clean -Keys <id,id>            (dry run, nothing deleted)'
    Write-Output '      -Mode clean -Keys <id,id> -Confirm   (delete)'
}

function Invoke-DeepScan {
    param([int]$TopFiles)
    Write-Output ''
    Write-Output '--- files > 500 MB under the user profile (REVIEW ONLY, never auto-deleted) ---'
    # Invoke-TreeWalk, not Get-ChildItem -Recurse: a profile contains junctions
    # to its own parent, and following them would list the same file repeatedly
    # or walk outside the profile entirely
    $big = New-Object System.Collections.ArrayList
    $collect = { param($f) if ($f.Length -gt 500MB) { [void]$big.Add($f) } }.GetNewClosure()
    Invoke-TreeWalk -Path $env:USERPROFILE -Recurse -OnFile $collect

    $big | Sort-Object Length -Descending | Select-Object -First $TopFiles | ForEach-Object {
        Write-Output ('{0,10}  {1:yyyy-MM-dd}  {2}' -f (Format-Size $_.Length), $_.LastWriteTime, (Get-PlainPath $_.FullName))
    }
    Write-Output 'Treat these as user data: propose moving them to another drive, never delete.'
}

# ---------------------------------------------------------------- clean ------

function Invoke-Clean {
    # `powershell -File cleanup.ps1 -Keys a,b` hands the whole thing over as one
    # string, so a multi-item clean would silently become a lookup for a single
    # bogus key named "a,b". Split on commas so both invocation styles match.
    if ($Keys) {
        $Keys = @($Keys | ForEach-Object { $_ -split ',' } |
                ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if (-not (Test-Path -LiteralPath $Plan)) {
        Write-Output ('Plan not found: ' + $Plan + '  -> run -Mode scan first.')
        return
    }
    if (-not $Keys -or $Keys.Count -eq 0) {
        Write-Output 'No -Keys supplied. Refusing to delete anything without an explicit selection.'
        Write-Output 'Pass the IDs shown in the report, or the keys printed by -Mode scan.'
        return
    }

    # The plan is read for one thing only: the ID -> key mapping it recorded, so
    # "-Keys 25" still means the same folder even if the numbering shifted.
    # Paths never come from the plan; they are always recomputed live.
    $pj = $null
    try { $pj = Get-Content -LiteralPath $Plan -Raw -Encoding utf8 | ConvertFrom-Json } catch { }

    $catalog = Get-Catalog
    $targets = New-Object System.Collections.ArrayList

    foreach ($k in $Keys) {
        $m0 = $null
        $got = @(Find-CatalogItem -Catalog $catalog -Token $k -Plan $pj)
        if ($got.Count -eq 0) {
            Write-Output ('REFUSED  ' + $k + ' matches no item in the live catalog')
            Write-Output '         Pass the ID from the report, or the key from the scan output.'
            continue
        }
        $m0 = $got[0]
        if (-not $m0.Action -or $m0.Action -ne 'delete') { Write-Output ('REFUSED  ' + $m0.Name + ' -> special action (' + $m0.Action + ')'); continue }
        if (Test-DeniedPath $m0.Path) { Write-Output ('REFUSED  denylist hit: ' + $m0.Path); continue }
        if (Test-Excluded -Item $m0 -Patterns $Exclude) { Write-Output ('EXCLUDED ' + $m0.Name + ' (matched -Exclude)'); continue }
        if (-not (Test-PathExists $m0.Path)) { Write-Output ('SKIP     gone already: ' + $m0.Name); continue }
        # the catalog path passed the denylist, but the subtree has not been
        # looked at yet - a vhdx sitting inside a cache-looking folder is the
        # one thing that turns "reclaim space" into "lose data".
        # @() matters: a one-element return unrolls to a bare string, and
        # $blocked[0] would then index the first character instead of the path
        $blocked = @(Get-DeniedDescendant -Root $m0.Path -FirstOnly)
        if ($blocked.Count -gt 0) {
            Write-Output ('REFUSED  protected file inside: ' + $blocked[0])
            Write-Output ('         ' + $m0.Name + ' -> deleting it recursively would take that file with it.')
            continue
        }
        [void]$targets.Add($m0)
    }

    if ($targets.Count -eq 0) { Write-Output 'Nothing eligible. Aborted.'; return }

    $total = [int64]0
    $sizes = @{}
    Write-Output ''
    Write-Output '=== deletion plan ==='
    foreach ($t in $targets) {
        $m = Get-PathSize $t.Path
        $total += $m.Bytes
        $sizes[$t.Key] = $m.Bytes
        Write-Output ('  [' + $t.Tier + '] ' + (Format-Size $m.Bytes) + '  ' + $m.Files + ' files  ' + $t.Path)
    }
    Write-Output ('  total   : ' + (Format-Size $total))
    Write-Output ''

    if (-not $Confirm) {
        Write-Output 'DRY RUN - nothing deleted. Re-run with -Confirm only after the user approves.'
        return
    }

    $freeBefore = Get-FreeBytes
    $log = New-Object System.Collections.ArrayList

    foreach ($t in $targets) {
        # .NET instead of Get-Item: the FileSystem provider fails on long paths
        $isDir = [System.IO.Directory]::Exists((Get-LongPath $t.Path))
        $isFile = [System.IO.File]::Exists((Get-LongPath $t.Path))

        $st = [PSCustomObject]@{ Ok = 0; Fail = 0; Protected = 0 }
        if ($isDir) {
            $st = Remove-TreeContent -Path $t.Path -MinAgeMinutes $MinAgeMinutes
        } elseif ($isFile) {
            try { [System.IO.File]::Delete((Get-LongPath $t.Path)); $st.Ok = 1 } catch { $st.Fail = 1 }
        }
        $ok = $st.Ok; $fail = $st.Fail; $protected = $st.Protected

        $left = Get-PathSize $t.Path
        $before = 0
        if ($sizes.ContainsKey($t.Key)) { $before = [int64]$sizes[$t.Key] }
        $freed = [int64]($before - $left.Bytes)
        if ($freed -lt 0) { $freed = 0 }
        Write-Output ('done  ' + $t.Name + '   removed=' + $ok + '  skipped=' + $fail + '  protected=' + $protected + '  freed=' + (Format-Size $freed) + '  left=' + (Format-Size $left.Bytes))
        if ($protected -gt 0) { Write-Output '      ^ protected entries were left in place on purpose (denylist)' }
        [void]$log.Add([PSCustomObject]@{
                time = (Get-Date).ToString('s'); key = $t.Key; name = $t.Name
                path = $t.Path; removed = $ok; skipped = $fail; protected = $protected
                bytesBefore = $before; bytesAfter = $left.Bytes; freedBytes = $freed
            })
    }

    foreach ($l in $log) { ($l | ConvertTo-Json -Compress) | Out-File -FilePath $script:AuditLog -Append -Encoding utf8 }

    $freeAfter = Get-FreeBytes
    Write-Output ''
    Write-Output ('free before : ' + (Format-Size $freeBefore))
    Write-Output ('free after  : ' + (Format-Size $freeAfter))
    Write-Output ('delta       : ' + (Format-Size ([int64]($freeAfter - $freeBefore))))
    Write-Output ''
    Write-Output 'Run -Mode verify to reconcile the delta against what was supposed to be freed.'
}

# ---------------------------------------------------------------- verify ----

function Invoke-Verify {
    $free = Get-FreeBytes
    Write-Output ('current free : ' + (Format-Size $free))

    # --- reconciliation: scan baseline + audit trail vs reality ---------------
    if (Test-Path -LiteralPath $Plan) {
        $pj = Get-Content -LiteralPath $Plan -Raw -Encoding utf8 | ConvertFrom-Json
        $baseFree = [int64]$pj.FreeBytes
        $sumFreed = [int64]0; $n = 0
        if (Test-Path -LiteralPath $script:AuditLog) {
            foreach ($line in (Get-Content -LiteralPath $script:AuditLog -Encoding utf8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $o = $line | ConvertFrom-Json } catch { continue }
                if ([string]$o.time -ge [string]$pj.GeneratedAt) {
                    if ($null -ne $o.freedBytes) { $sumFreed += [int64]$o.freedBytes }
                    $n++
                }
            }
        }
        $predicted = [int64]($baseFree + $sumFreed)
        Write-Output ''
        Write-Output '--- reconciliation ---'
        Write-Output ('scan baseline  : ' + (Format-Size $baseFree) + '   at ' + $pj.GeneratedAt)
        Write-Output ('audit freed    : ' + (Format-Size $sumFreed) + '   over ' + $n + ' items')
        Write-Output ('predicted free : ' + (Format-Size $predicted))
        Write-Output ('actual free    : ' + (Format-Size $free))
        $gap = [int64]($predicted - $free)
        Write-Output ('unexplained    : ' + (Format-Size $gap))
        if ([Math]::Abs($gap) -gt 300MB) {
            Write-Output '   >> Over 300 MB unexplained. See references/troubleshooting.md'
        }
    } else {
        Write-Output '(no disk-scan.json - run -Mode scan first for a reconciliation baseline)'
    }
    Write-Output ''
    Write-Output '--- leak checks ---'

    $bSum = [int64]0; $bCount = 0
    $bList = New-Object System.Collections.ArrayList
    foreach ($d in (Find-BackupDirs)) {
        $m = Get-PathSize $d.FullName
        if ($m.Bytes -le 0) { continue }
        $bSum += $m.Bytes; $bCount++
        [void]$bList.Add([PSCustomObject]@{ Path = $d.FullName; Bytes = $m.Bytes })
    }
    Write-Output ('1. agent modify_backup : ' + $bCount + ' non-empty dirs, ' + (Format-Size $bSum))
    foreach ($bp in ($bList | Sort-Object Bytes -Descending | Select-Object -First 3)) {
        Write-Output ('     ' + (Format-Size $bp.Bytes) + '  ' + $bp.Path)
    }
    if ($bSum -gt 100MB) { Write-Output '   >> This is usually the culprit. Propose clearing it, with user approval.' }

    $rbSize = [int64]0; $rbFiles = 0
    foreach ($f in (Get-ChildItem -LiteralPath ($env:SystemDrive + ':\$Recycle.Bin') -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        $rbSize += $f.Length; $rbFiles++
    }
    $rbNote = ''
    if ($rbFiles -eq 0) { $rbNote = '   (0 readable - may be empty, or needs admin to inspect)' }
    Write-Output ('2. recycle bin          : ' + (Format-Size $rbSize) + $rbNote)

    if (Get-IsAdmin) {
        $out = (vssadmin list shadowstorage 2>&1) | Out-String
        $m = [regex]::Match($out, '([0-9]+[\.,][0-9]+)\s*(GB|MB)')
        if ($m.Success) { Write-Output ('3. shadow copy storage  : ' + $m.Value + ' (first volume)') }
        else { Write-Output '3. shadow copy storage  : none / not reported' }
    } else {
        Write-Output '3. shadow copy storage  : needs admin -> -Mode admin-check'
    }

    if ($Deep) {
        $since = (Get-Date).AddMinutes(-60)
        $recent = [PSCustomObject]@{ N = 0 }
        $count = { param($f) if ($f.Length -gt 200MB -and $f.LastWriteTime -gt $since) { $recent.N++ } }.GetNewClosure()
        Invoke-TreeWalk -Path $env:USERPROFILE -Recurse -OnFile $count
        Write-Output ('4. >200MB written in last hour : ' + $recent.N)
    }

    Write-Output ''
    Write-Output 'If the delta looks too small, run -Mode scan again and compare:'
    Write-Output '  freed_expected - freed_actual ~= something still holding the blocks.'
}

# ---------------------------------------------------------------- admin ----

function Invoke-AdminCheck {
    if (-not (Get-IsAdmin)) {
        Write-Output 'Not elevated. Run this mode from an administrator PowerShell.'
        return
    }
    $report = Join-Path $script:Root 'admin-report.txt'
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('generated: ' + (Get-Date).ToString('s'))
    [void]$lines.Add('')
    [void]$lines.Add('== vssadmin list shadowstorage ==')
    [void]$lines.Add(((vssadmin list shadowstorage 2>&1) | Out-String))
    [void]$lines.Add('== vssadmin list shadows ==')
    [void]$lines.Add(((vssadmin list shadows 2>&1) | Out-String))
    [void]$lines.Add('== System Volume Information ==')
    $sv = [int64]0
    foreach ($f in (Get-ChildItem -LiteralPath ($env:SystemDrive + ':\System Volume Information') -Recurse -Force -File -ErrorAction SilentlyContinue)) { $sv += $f.Length }
    [void]$lines.Add('size: ' + (Format-Size $sv))
    [void]$lines.Add('== hibernation ==')
    [void]$lines.Add(((powercfg /a 2>&1) | Out-String))
    [void]$lines.Add('== pagefile ==')
    [void]$lines.Add(((Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage | Format-List | Out-String)))
    [void]$lines.Add('== disk free ==')
    [void]$lines.Add(((fsutil volume diskfree ($env:SystemDrive + ':') 2>&1) | Out-String))
    $lines | Out-File -FilePath $report -Encoding utf8
    Write-Output ('report written: ' + $report)
}

# ---------------------------------------------------------------- report ----

<#
    Renders a ready-to-send Chinese report from disk-scan.json.
    Keeping this in the script (instead of letting the model write the table)
    means the wording, tiering and numbers are always consistent, and the user
    sees the same explanation every run.
#>
function Invoke-Report {
    param([string]$OutPath, [int]$MinMB)
    if (-not (Test-Path -LiteralPath $Plan)) {
        Write-Output ('Plan not found: ' + $Plan + '  -> run -Mode scan first.')
        return
    }
    $pj = $null
    try { $pj = Get-Content -LiteralPath $Plan -Raw -Encoding utf8 | ConvertFrom-Json } catch { }
    if ($null -eq $pj) { Write-Output 'Cannot parse the plan file.'; return }

    $i18n = Get-I18n -Lang $Lang
    if ($MinMB -le 0) { $MinMB = 10 }
    $minBytes = [int64]$MinMB * 1MB

    $title = 'Disk cleanup report'
    $freeLabel = 'Free space'
    $askLabel = 'Reply with the numbers you want removed (e.g. "1, 3, 7").'
    $hiddenNote = '{count} more items under {min} MB omitted.'
    $neverTitle = 'Never touch these'
    $neverBody = @()
    $tierLabels = @{
        'safe'    = 'Tier 1: pure cache, no functional loss'
        'caution' = 'Tier 2: removable, with a cost'
        'action'  = 'Special actions'
    }
    # every visible string is overridable from i18n.zh.json; the defaults stay
    # ASCII because Windows PowerShell 5.1 parses a BOM-less script as ANSI and
    # non-ASCII literals would break the parser
    $scannedLabel = 'Scanned'
    $tierSummary = ' ({count} items, {size} total)'
    $tableSafeHeader = '| # | Item | Size |'
    $tableCautionHeader = '| # | Item | Size | Cost |'
    $tableDelimSafe = '|---|---|---|'
    $tableDelimCaution = '|---|---|---|---|'
    $emptyTier = 'Nothing worth cleaning was found this time.'
    $descSep = ' - '
    if ($i18n -and $i18n.report) {
        if ($i18n.report.title) { $title = [string]$i18n.report.title }
        if ($i18n.report.freeLabel) { $freeLabel = [string]$i18n.report.freeLabel }
        if ($i18n.report.askLabel) { $askLabel = [string]$i18n.report.askLabel }
        if ($i18n.report.hiddenNote) { $hiddenNote = [string]$i18n.report.hiddenNote }
        if ($i18n.report.neverTitle) { $neverTitle = [string]$i18n.report.neverTitle }
        if ($i18n.report.neverBody) { $neverBody = @($i18n.report.neverBody) }
        if ($i18n.report.scannedLabel) { $scannedLabel = [string]$i18n.report.scannedLabel }
        if ($i18n.report.tierSummary) { $tierSummary = [string]$i18n.report.tierSummary }
        if ($i18n.report.tableSafeHeader) { $tableSafeHeader = [string]$i18n.report.tableSafeHeader }
        if ($i18n.report.tableCautionHeader) { $tableCautionHeader = [string]$i18n.report.tableCautionHeader }
        if ($i18n.report.tableDelimSafe) { $tableDelimSafe = [string]$i18n.report.tableDelimSafe }
        if ($i18n.report.tableDelimCaution) { $tableDelimCaution = [string]$i18n.report.tableDelimCaution }
        if ($i18n.report.emptyTier) { $emptyTier = [string]$i18n.report.emptyTier }
        if ($i18n.report.descSeparator) { $descSep = [string]$i18n.report.descSeparator }
    }
    if ($i18n -and $i18n.tiers) {
        foreach ($k in @('safe', 'caution', 'action')) {
            if ($i18n.tiers.$k) { $tierLabels[$k] = [string]$i18n.tiers.$k }
        }
    }

    $items = @($pj.Items | Where-Object { $_.Action -eq 'delete' -and $_.Exists -and $_.SizeBytes -ge $minBytes })
    if ($Exclude) { $items = @($items | Where-Object { -not (Test-Excluded -Item $_ -Patterns $Exclude) }) }
    $smallCount = @($pj.Items | Where-Object { $_.Action -eq 'delete' -and $_.Exists -and $_.SizeBytes -gt 0 -and $_.SizeBytes -lt $minBytes }).Count

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## ' + $title)
    [void]$sb.AppendLine('')
    $stamp = [string]$pj.GeneratedAt
    if ($stamp.Length -ge 16) { $stamp = $stamp.Substring(0, 16).Replace('T', ' ') }
    [void]$sb.AppendLine('> ' + $scannedLabel + ' ' + $stamp + ' | ' + $freeLabel + ' **' + (Format-Size ([int64]$pj.FreeBytes)) + '**')
    [void]$sb.AppendLine('')

    $any = $false
    foreach ($tier in @('safe', 'caution')) {
        $group = @($items | Where-Object { $_.Tier -eq $tier } | Sort-Object SizeBytes -Descending)
        if ($group.Count -eq 0) { continue }
        $any = $true
        $sum = [int64]0
        foreach ($g in $group) { $sum += [int64]$g.SizeBytes }

        $head = $tierSummary -replace '\{count\}', $group.Count
        $head = $head -replace '\{size\}', (Format-Size $sum)
        [void]$sb.AppendLine('### ' + $tierLabels[$tier] + $head)
        [void]$sb.AppendLine('')
        if ($tier -eq 'caution') {
            [void]$sb.AppendLine($tableCautionHeader)
            [void]$sb.AppendLine($tableDelimCaution)
        } else {
            [void]$sb.AppendLine($tableSafeHeader)
            [void]$sb.AppendLine($tableDelimSafe)
        }
        foreach ($g in $group) {
            $l = Resolve-Label -Item $g -I18n $i18n
            $desc = '**' + $l.Name + '**' + $descSep + $l.What
            if ($tier -eq 'caution') {
                [void]$sb.AppendLine('| ' + $g.Id + ' | ' + $desc + ' | ' + (Format-Size $g.SizeBytes) + ' | ' + $l.Impact + ' |')
            } else {
                [void]$sb.AppendLine('| ' + $g.Id + ' | ' + $desc + ' | ' + (Format-Size $g.SizeBytes) + ' |')
            }
        }
        [void]$sb.AppendLine('')
    }
    if (-not $any) { [void]$sb.AppendLine($tierLabels['safe'] + $descSep + $emptyTier); [void]$sb.AppendLine('') }

    $actions = @($pj.Items | Where-Object { $_.Action -ne 'delete' })
    if ($actions.Count -gt 0) {
        [void]$sb.AppendLine('### ' + $tierLabels['action'])
        [void]$sb.AppendLine('')
        foreach ($a in $actions) {
            $l = Resolve-Label -Item $a -I18n $i18n
            $sz = ''
            if ($null -ne $a.SizeBytes -and [int64]$a.SizeBytes -gt 0) { $sz = ' (' + (Format-Size ([int64]$a.SizeBytes)) + ')' }
            [void]$sb.AppendLine('- **' + $l.Name + '**' + $sz + $descSep + $l.What + $descSep + $l.Impact)
        }
        [void]$sb.AppendLine('')
    }

    if ($neverBody.Count -gt 0) {
        [void]$sb.AppendLine('### ' + $neverTitle)
        [void]$sb.AppendLine('')
        foreach ($n in $neverBody) { [void]$sb.AppendLine('- ' + $n) }
        [void]$sb.AppendLine('')
    }

    if ($smallCount -gt 0) {
        [void]$sb.AppendLine(($hiddenNote -replace '\{count\}', $smallCount) -replace '\{min\}', $MinMB)
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine($askLabel)

    $text = $sb.ToString()
    if ($OutPath) {
        $text | Out-File -FilePath $OutPath -Encoding utf8
        Write-Output ('report written: ' + $OutPath)
    } else {
        Write-Output $text
    }
}

# ---------------------------------------------------------------- selftest --

function Invoke-SelfTest {
    $script:pass = 0; $script:fail = 0
    function Check {
        param([string]$Label, [bool]$Condition)
        if ($Condition) { $script:pass++; Write-Output ('  PASS  ' + $Label) }
        else { $script:fail++; Write-Output ('  FAIL  ' + $Label) }
    }

    Write-Output '=== layer 0: host environment ==='
    # These are the things that differ between machines and silently break a
    # cleanup run. Checking them first turns "it did nothing" into a reason.
    Check 'PowerShell 5.1 or newer' ($PSVersionTable.PSVersion.Major -ge 5)
    $lm = 'unknown'
    try { $lm = [string]$ExecutionContext.SessionState.LanguageMode } catch { }
    Check 'FullLanguage mode (not ConstrainedLanguage)' ($lm -eq 'FullLanguage')
    Check 'LOCALAPPDATA resolved' ([bool]$env:LOCALAPPDATA)
    Check 'APPDATA resolved' ([bool]$env:APPDATA)
    Check 'USERPROFILE resolved' ([bool]$env:USERPROFILE)
    Check 'SystemDrive resolved' ([bool]$env:SystemDrive)
    Check 'free space readable' ((Get-FreeBytes) -gt 0)
    # captured before Console.OutputEncoding was set - see the note at the top
    Check 'UI language captured at startup' ([bool]$script:UiLanguage)
    # Windows PowerShell 5.1 parses a BOM-less .ps1 as ANSI: one non-ASCII byte
    # in a comment is enough to corrupt the script on a Chinese-locale machine.
    # The shipped script must stay pure ASCII, with i18n living in JSON.
    $ascii = $false
    try {
        $ascii = $true
        foreach ($b in [System.IO.File]::ReadAllBytes($PSCommandPath)) { if ($b -gt 127) { $ascii = $false; break } }
    } catch { }
    Check 'script is pure ASCII (PS 5.1 ANSI parsing)' $ascii

    Write-Output ''
    Write-Output '=== layer 1: denylist must refuse critical paths ==='
    $u = $env:USERPROFILE
    $mustDeny = @(
        ($env:SystemDrive + '\'),
        ($env:SystemDrive + '\Windows'),
        ($env:SystemDrive + '\Windows\System32'),
        ($env:SystemDrive + '\Windows\WinSxS'),
        ($env:SystemDrive + '\Windows\Installer'),
        ($env:SystemDrive + '\Program Files\Something'),
        ($env:SystemDrive + '\ProgramData\Package Cache'),
        ($env:SystemDrive + '\System Volume Information'),
        ($env:SystemDrive + '\pagefile.sys'),
        ($env:SystemDrive + '\hiberfil.sys'),
        $u,
        (Join-Path $u 'Documents'),
        (Join-Path $u 'Desktop'),
        (Join-Path $u 'Downloads'),
        (Join-Path $u 'Pictures'),
        (Join-Path $u 'Videos'),
        (Join-Path $u 'AppData\Local'),
        (Join-Path $u 'AppData\Roaming'),
        (Join-Path $u '.ssh'),
        (Join-Path $u '.git\config'),
        (Join-Path $u 'ext4.vhdx'),
        (Join-Path $u 'OneDrive\cache')
    )
    foreach ($p in $mustDeny) { Check ('deny  ' + $p) (Test-DeniedPath $p) }

    Write-Output ''
    Write-Output '=== layer 2: legitimate cache paths must be allowed ==='
    $mustAllow = @(
        (Join-Path $env:LOCALAPPDATA 'Temp'),
        (Join-Path $env:LOCALAPPDATA 'npm-cache\_cacache'),
        (Join-Path $env:LOCALAPPDATA 'pip\cache'),
        (Join-Path $env:WINDIR 'Temp'),
        (Join-Path $env:WINDIR 'Prefetch'),
        (Join-Path $env:WINDIR 'SoftwareDistribution\Download'),
        (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache')
    )
    foreach ($p in $mustAllow) { Check ('allow ' + $p) (-not (Test-DeniedPath $p)) }

    # An over-broad rule is worse than a missing one: it vetoes a whole cache
    # because some package ships a folder called "cookies" or "boot". These
    # shapes are what real node_modules trees look like.
    $mustAllowDeep = @(
        (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx\x\node_modules\undici\lib\web\cookies'),
        (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx\x\node_modules\foo\history'),
        (Join-Path $env:LOCALAPPDATA 'SomeApp\boot\cache'),
        (Join-Path $env:LOCALAPPDATA 'SomeApp\Cache\cookies'),
        (Join-Path $env:LOCALAPPDATA 'SomeApp\templates\x')
    )
    foreach ($p in $mustAllowDeep) { Check ('allow nested ' + $p.Substring($p.LastIndexOf('\'))) (-not (Test-DeniedPath $p)) }
    # ...while the real system locations are still refused
    Check 'allowlist check: drive-root boot stays denied' (Test-DeniedPath ($env:SystemDrive + '\boot\x'))
    Check 'allowlist check: profile Cookies junction stays denied' (Test-DeniedPath (Join-Path $env:USERPROFILE 'Cookies'))

    Write-Output ''
    Write-Output '=== layer 3: no catalog item may live outside a safe root ==='
    $catalog = Get-Catalog
    # any local user profile is a legitimate cache root; personal folders inside
    # a profile are still protected by the denylist
    $roots = @(
        $env:LOCALAPPDATA,
        $env:APPDATA,
        $env:USERPROFILE,
        $env:WINDIR,
        (Join-Path $env:SystemDrive 'Users')
    )
    $bad = 0
    foreach ($c in $catalog) {
        if ($c.Action -ne 'delete') { continue }
        $inside = $false
        foreach ($r in $roots) { if ($c.Path.ToLowerInvariant().StartsWith($r.ToLowerInvariant())) { $inside = $true } }
        if (-not $inside) { $bad++; Write-Output ('  FAIL  outside roots: ' + $c.Path) }
        if (Test-DeniedPath $c.Path) { $bad++; Write-Output ('  FAIL  catalog item hits denylist: ' + $c.Path) }
    }
    if ($bad -eq 0) { $script:pass++; Write-Output ('  PASS  ' + $catalog.Count + ' catalog items validated') }
    else { $script:fail += $bad }

    # both reference forms must resolve to the same item: the report shows IDs
    # and the scan shows keys, so mixing them up would delete the wrong target
    $sample = @($catalog | Where-Object { $_.Action -eq 'delete' -and $_.Path })
    if ($sample.Count -gt 0) {
        $one = $sample[0]
        $byId = @(Find-CatalogItem -Catalog $catalog -Token ([string]$one.Id))
        $byKey = @(Find-CatalogItem -Catalog $catalog -Token $one.Key)
        Check 'an ID resolves to its catalog item' ($byId.Count -eq 1 -and $byId[0].Path -eq $one.Path)
        Check 'a key resolves to its catalog item' ($byKey.Count -eq 1 -and $byKey[0].Path -eq $one.Path)
        Check 'unknown reference resolves to nothing' (@(Find-CatalogItem -Catalog $catalog -Token 'zzzz9999').Count -eq 0)
        Check 'out-of-range ID resolves to nothing' (@(Find-CatalogItem -Catalog $catalog -Token '999999').Count -eq 0)
        $digitKeys = @($sample | Where-Object { $_.Key -match '^[0-9]+$' })
        if ($digitKeys.Count -gt 0) {
            $dk = $digitKeys[0]
            $byDigitKey = @(Find-CatalogItem -Catalog $catalog -Token $dk.Key)
            Check 'an all-digit key is read as a key, not an ID' ($byDigitKey.Count -eq 1 -and $byDigitKey[0].Path -eq $dk.Path)
        }

        # an ID must follow the scan that produced it, never the live numbering:
        # a shift between runs would otherwise delete a different folder
        $goodPlan = [PSCustomObject]@{ Items = @([PSCustomObject]@{ Id = 1; Key = $one.Key }) }
        $viaPlan = @(Find-CatalogItem -Catalog $catalog -Token '1' -Plan $goodPlan)
        Check 'ID resolves through the plan mapping' ($viaPlan.Count -eq 1 -and $viaPlan[0].Path -eq $one.Path)

        $stalePlan = [PSCustomObject]@{ Items = @([PSCustomObject]@{ Id = 1; Key = 'deadbeef' }) }
        Check 'a stale plan ID resolves to nothing' (@(Find-CatalogItem -Catalog $catalog -Token '1' -Plan $stalePlan).Count -eq 0)
    }

    Write-Output ''
    Write-Output '=== layer 4: Chinese report dictionary ==='
    # always zh here: this asserts the shipped dictionary is complete, whatever
    # language the current machine happens to report
    $i18n = Get-I18n -Lang zh
    if ($null -eq $i18n) {
        Check 'i18n dictionary loads' $false
    } else {
        Check 'i18n dictionary loads' $true
        $resolved = 0; $total = 0
        $untranslated = @()
        foreach ($c in $catalog) {
            if ($c.Action -ne 'delete') { continue }
            $total++
            $l = Resolve-Label -Item $c -I18n $i18n
            if ($l.Name -ne $c.Name) { $resolved++ } else { $untranslated += $c.Name }
        }
        $pct = 0
        if ($total -gt 0) { $pct = [int]($resolved * 100 / $total) }
        Write-Output ('  coverage: ' + $resolved + '/' + $total + ' items have a Chinese label (' + $pct + '%)')
        if ($untranslated.Count -gt 0 -and $untranslated.Count -le 15) {
            foreach ($un in $untranslated) { Write-Output ('    no label: ' + $un) }
        }
        Check 'i18n coverage >= 80%' ($pct -ge 80)
    }

    Write-Output ''
    Write-Output '=== layer 5: protected files nested inside a whitelisted root ==='
    # build a throwaway tree that mimics AppData\Local\Docker\wsl: a folder that
    # looks like a cache but holds a virtual disk. Nothing outside $env:TEMP is
    # touched, and the tree is removed in the finally block.
    $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wdc-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'disk') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'clean') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $tmpRoot 'plain.cache') -Value 'x'
        Set-Content -LiteralPath (Join-Path $tmpRoot 'clean\a.bin') -Value 'x'
        $vhdx = Join-Path $tmpRoot 'disk\docker_data.vhdx'
        Set-Content -LiteralPath $vhdx -Value 'x'

        $hits = @(Get-DeniedDescendant -Root $tmpRoot)
        Check 'subtree scan finds the nested vhdx' ($hits.Count -eq 1)
        Check 'subtree scan reports the right file' ($hits.Count -eq 1 -and $hits[0] -like '*.vhdx')
        Check 'first-only stops after one hit' (@(Get-DeniedDescendant -Root $tmpRoot -FirstOnly).Count -eq 1)
        Check 'cache-only subtree comes back clear' (@(Get-DeniedDescendant -Root (Join-Path $tmpRoot 'clean')).Count -eq 0)

        Check 'entry gate blocks the nested vhdx' (-not (Test-DeletableChild (Get-Item -LiteralPath $vhdx -Force)))
        Check 'entry gate allows a plain cache file' (Test-DeletableChild (Get-Item -LiteralPath (Join-Path $tmpRoot 'plain.cache') -Force))

        $dk = @($catalog | Where-Object { $_.Name -eq 'Docker data' })
        Check 'Docker data is a special action, not a delete' ($dk.Count -eq 1 -and $dk[0].Action -ne 'delete')
        Check 'no delete item points at a Docker wsl store' (@($catalog | Where-Object { $_.Action -eq 'delete' -and $_.Path -match '\\docker\\' }).Count -eq 0)
    } finally {
        Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Output ''
    Write-Output '=== layer 6: known folders are protected wherever they live ==='
    # Redirected and localized profiles are the reason this is not name-based:
    # Documents on D:\ (or named in a non-English locale) must still be refused.
    # Tree roots refuse their children too; exact roots only refuse themselves,
    # because legitimate cache locations live underneath them.
    $roots = @(Get-ProtectedRoots)
    $rootBad = 0
    foreach ($r in $roots) {
        if (-not $r.Path) { continue }
        if (-not (Test-DeniedPath $r.Path)) {
            $rootBad++
            Write-Output ('  FAIL  protected root not denied: ' + $r.Path)
        }
        if ($r.Tree -and -not (Test-DeniedPath (Join-Path $r.Path 'somefile.docx'))) {
            $rootBad++
            Write-Output ('  FAIL  child of protected root not denied: ' + $r.Path)
        }
    }
    if ($rootBad -eq 0) {
        $script:pass++
        Write-Output ('  PASS  ' + $roots.Count + ' known folders refused')
    } else { $script:fail += $rootBad }
    Check 'Downloads is among the protected roots' (@($roots | Where-Object { $_.Path -like '*downloads' }).Count -ge 1)
    Check 'the profile root itself is refused' (Test-DeniedPath $env:USERPROFILE)
    Check 'a nested cache under AppData is still allowed' (-not (Test-DeniedPath (Join-Path $env:LOCALAPPDATA 'Temp')))

    Write-Output ''
    Write-Output '=== layer 7: junctions must not be walked through ==='
    # A self-referential junction is what every Windows profile carries
    # (AppData\Local\Application Data). If the walk follows it, the subtree scan
    # either loops forever or inspects directories it was never asked about.
    $jRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wdc-junc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path (Join-Path $jRoot 'real') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $jRoot 'real\a.bin') -Value 'x'
        $made = $false
        try {
            New-Item -ItemType Junction -Path (Join-Path $jRoot 'loop') -Target $jRoot -ErrorAction Stop | Out-Null
            $made = $true
        } catch { }
        if ($made) {
            $jh = @(Get-DeniedDescendant -Root $jRoot)
            Check 'subtree scan terminates on a self-referential junction' $true
            Check 'subtree scan does not wander through the junction' ($jh.Count -eq 0)
            $sz = Get-PathSize $jRoot
            Check 'size walk counts the real file exactly once' ($sz.Files -eq 1)
        } else {
            Write-Output '  SKIP  junction creation not permitted on this host'
        }
        Check 'legacy junction names are on the denylist' (Test-DeniedPath (Join-Path $env:LOCALAPPDATA 'Application Data'))
    } finally {
        Remove-Item -LiteralPath $jRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Output ''
    Write-Output '=== layer 8: the delete path itself, on a throwaway tree ==='
    # This is the only layer that actually removes files. Without it the delete
    # branch would ship untested, since it only runs with -Confirm.
    $dRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('wdc-del-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $dOut = Join-Path $dRoot 'outside'
    $dTarget = Join-Path $dRoot 'target'
    try {
        New-Item -ItemType Directory -Path (Join-Path $dTarget 'sub') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $dTarget 'disk') -Force | Out-Null
        New-Item -ItemType Directory -Path $dOut -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dTarget 'plain.cache') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dTarget 'sub\deep.cache') -Value 'x'
        $dvhdx = Join-Path $dTarget 'disk\docker_data.vhdx'
        Set-Content -LiteralPath $dvhdx -Value 'x'
        Set-Content -LiteralPath (Join-Path $dOut 'keep.txt') -Value 'x'

        $res = Remove-TreeContent -Path $dTarget
        Check 'delete removes a plain cache file' (-not (Test-Path -LiteralPath (Join-Path $dTarget 'plain.cache')))
        Check 'delete removes a nested cache subtree' (-not (Test-Path -LiteralPath (Join-Path $dTarget 'sub')))
        Check 'delete leaves the cache root itself in place' (Test-Path -LiteralPath $dTarget)
        Check 'delete refuses a subtree holding a vhdx' (Test-Path -LiteralPath $dvhdx)
        Check 'refusal is counted, not silently ignored' ($res.Protected -eq 1)
        Check 'delete reports at least two removals' ($res.Ok -ge 2)

        # a junction is unlinked, never followed: the target must be untouched
        $linkMade = $false
        try {
            New-Item -ItemType Junction -Path (Join-Path $dTarget 'link') -Target $dOut -ErrorAction Stop | Out-Null
            $linkMade = $true
        } catch { }
        if ($linkMade) {
            $null = Remove-TreeContent -Path $dTarget
            Check 'junction target survives a delete through its parent' (Test-Path -LiteralPath (Join-Path $dOut 'keep.txt'))
            Check 'the junction link itself is gone' (-not (Test-Path -LiteralPath (Join-Path $dTarget 'link')))
        } else {
            Write-Output '  SKIP  junction creation not permitted on this host'
        }

        # -MinAgeMinutes keeps anything newer than the cutoff
        Set-Content -LiteralPath (Join-Path $dTarget 'old.tmp') -Value 'x'
        Set-Content -LiteralPath (Join-Path $dTarget 'fresh.tmp') -Value 'x'
        (Get-Item -LiteralPath (Join-Path $dTarget 'old.tmp')).LastWriteTime = (Get-Date).AddHours(-2)
        $res2 = Remove-TreeContent -Path $dTarget -MinAgeMinutes 60
        Check 'age filter deletes the old file' (-not (Test-Path -LiteralPath (Join-Path $dTarget 'old.tmp')))
        Check 'age filter keeps the fresh file' (Test-Path -LiteralPath (Join-Path $dTarget 'fresh.tmp'))
        Check 'age filter still protects the vhdx' (Test-Path -LiteralPath $dvhdx)
        Check 'age filter reports one removal' ($res2.Ok -eq 1)
    } finally {
        # the junction must go first, or the recursive remove follows it
        $lnk = Join-Path $dTarget 'link'
        if (Test-Path -LiteralPath $lnk) { [System.IO.Directory]::Delete((Get-LongPath $lnk)) }
        Remove-Item -LiteralPath $dRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Output ''
    Write-Output ('=== result: ' + $script:pass + ' passed, ' + $script:fail + ' failed ===')
    if ($script:fail -gt 0) { Write-Output 'SELFTEST FAILED - do not use this build.' }
    else { Write-Output 'SELFTEST OK' }
}

# ---------------------------------------------------------------- dispatch --

# Every mode ends with an explicit exit code. Without it the process inherits
# $LASTEXITCODE from whichever native command ran last inside the mode -
# vssadmin, powercfg, fsutil - and a harmless "access denied" from one of them
# would make a perfectly successful verify look like a failure to any caller.
# GitHub Actions appends `exit $LASTEXITCODE` to a PowerShell step, so this is
# not theoretical: it turned a green verify step red.
switch ($Mode) {
    'scan' { Invoke-Scan; exit 0 }
    'clean' { Invoke-Clean; exit 0 }
    'verify' { Invoke-Verify; exit 0 }
    'admin-check' { Invoke-AdminCheck; exit 0 }
    'selftest' {
        Invoke-SelfTest
        if ($script:fail -gt 0) { exit 1 } else { exit 0 }
    }
    'report' { Invoke-Report -OutPath $OutFile -MinMB $MinMB; exit 0 }
}
