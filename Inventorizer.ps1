<#
================================================================================

    C O V E R T   P C   I N V E N T O R I Z E R
    -------------------------------------------
    A self-contained system inventory console by COVERT.
    Sweeps installed software, drivers and system state into
    timestamped snapshot reports (TXT + JSON + HTML), diffs
    snapshots over time, tracks drift against a baseline, and
    restores software selectively via winget.

    Engine  : Windows PowerShell 5.1+  (no dependencies)
    Usage   : .\Inventorizer.ps1                 interactive console
              .\Inventorizer.ps1 -Full          immediate full sweep
              .\Inventorizer.ps1 -Full -Silent  headless (Task Scheduler)
              .\Inventorizer.ps1 -Categories SYSTEM,SERVICES
              .\Inventorizer.ps1 -OutputPath D:\Snapshots -NoElevate
              .\Inventorizer.ps1 -Compare "older,newer"   headless diff
              .\Inventorizer.ps1 -Find "steam"            search snapshots
              .\Inventorizer.ps1 -Schedule weekly         auto-sweep task
              .\Inventorizer.ps1 -RemoveSchedule          remove the task
              .\Inventorizer.ps1 -SafeMode        boot with default config
                                 (or press S in the 2s window at launch)

================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$Silent,
    [string]$OutputPath,
    [string[]]$Categories,
    [string[]]$Compare,
    [string]$Find,
    [string]$Schedule,
    [string]$ScheduleTime,
    [switch]$RemoveSchedule,
    [switch]$NoElevate,
    [switch]$NoLogo,
    [switch]$SafeMode
)

$ErrorActionPreference = 'Continue'
$Script:BoundParams = $PSBoundParameters
$Script:Esc     = [string][char]27
$Script:Rst     = ''
$Script:AnsiOn  = $false
$Script:Interactive = $false
$Script:SafeMode = $false
$Script:PaletteTouched = $false
$Script:StartCwd = $PSScriptRoot

# Versioning follows the COVERT scheme: vYY.MAJOR.PATCH
#   YY    = two-digit release year (26 = 2026); first release of a new year resets MAJOR to 1
#   MAJOR = feature release counter within the year (new categories, reworked systems)
#   PATCH = small fixes / adjustments within that major release
$Script:Brand = @{
    Company   = 'COVERT'
    Product   = 'PC INVENTORIZER'
    Name      = 'COVERT PC INVENTORIZER'
    Short     = 'INVENTORIZER'
    Sigil     = 'CxT'
    Tagline   = 'TOTAL SYSTEM AWARENESS'
    Version   = '26.7.2'
    Platform  = 'Windows'
    Arch      = ''
    UpdateUrl = ''   # point at a hosted version.json when the repo goes live (see update-manifest.sample.json)
}

# Machine architecture (WOW64-aware); unreadable -> product-flavored failsafe placeholder
$Script:Brand.Arch = $Script:Brand.Sigil
try {
    $archRaw = "$env:PROCESSOR_ARCHITEW6432"
    if (-not $archRaw) { $archRaw = "$env:PROCESSOR_ARCHITECTURE" }
    $archRaw = $archRaw.Trim().ToUpper()
    if     ($archRaw -eq 'AMD64') { $Script:Brand.Arch = 'x64' }
    elseif ($archRaw -eq 'ARM64') { $Script:Brand.Arch = 'ARM64' }
    elseif ($archRaw -eq 'X86')   { $Script:Brand.Arch = 'x86' }
    elseif ($archRaw)             { $Script:Brand.Arch = $archRaw }
} catch { }

function Get-BuildString {
    return ('v{0} ({1}) {2}' -f $Script:Brand.Version, $Script:Brand.Platform, $Script:Brand.Arch)
}

$Script:ConfigDir  = Join-Path $PSScriptRoot 'config'
$Script:ConfigPath = Join-Path $Script:ConfigDir 'settings.json'

#region ============================ CONSOLE CORE ==============================

function Initialize-Console {
    try {
        $Script:Interactive = (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) -and (-not $Silent)
    } catch { $Script:Interactive = $false }
    if ($Silent) { return }
    try { if ([Console]::IsOutputRedirected) { return } } catch { return }
    try {
        if (-not ('Inv.VtConsole' -as [type])) {
            Add-Type -Namespace 'Inv' -Name 'VtConsole' -ErrorAction Stop -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
        }
        $h = [Inv.VtConsole]::GetStdHandle(-11)
        $mode = [uint32]0
        if ([Inv.VtConsole]::GetConsoleMode($h, [ref]$mode)) {
            if ([Inv.VtConsole]::SetConsoleMode($h, $mode -bor 0x0004)) { $Script:AnsiOn = $true }
        }
    } catch { $Script:AnsiOn = $false }
    if ($Script:AnsiOn) { $Script:Rst = "$($Script:Esc)[0m" }
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    try {
        $Script:OrigBg = [Console]::BackgroundColor
        $Script:OrigFg = [Console]::ForegroundColor
    } catch { $Script:OrigBg = $null; $Script:OrigFg = $null }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-SelfElevation {
    # Relaunch this script elevated, forwarding all bound parameters. Returns $true on success.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $Script:BoundParams.Keys) {
        if ($k -eq 'NoElevate') { continue }
        $v = $Script:BoundParams[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList += "-$k" }
        } elseif ($v -is [array]) {
            $argList += "-$k"; $argList += ('"{0}"' -f ($v -join ','))
        } else {
            $argList += "-$k"; $argList += ('"{0}"' -f $v)
        }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-ConWidth {
    try { return [Math]::Max(60, [Console]::WindowWidth) } catch { return 100 }
}

function Get-CenterPad([int]$Len) {
    $p = [Math]::Floor(((Get-ConWidth) - $Len) / 2)
    if ($p -lt 0) { $p = 0 }
    return (' ' * $p)
}

function Read-InvPrompt([string]$Prompt) {
    # A Read-Host whose prompt is indented toward center (like the identity block:
    # centered as a group, text still reading left-to-right) instead of hugging
    # the far-left edge. Handles the cursor visibility toggle for callers.
    $width = $Prompt.Length + 26
    if ($width -lt 48) { $width = 48 }
    try { [Console]::CursorVisible = $true } catch { }
    Write-Host -NoNewline (Get-CenterPad $width)
    $v = Read-Host $Prompt
    try { [Console]::CursorVisible = $false } catch { }
    return $v
}

function Clear-KeyBuffer {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}

function Test-KeyAvailable {
    try { return [Console]::KeyAvailable } catch { return $false }
}

function Read-KeyOrResize {
    # Blocks until a key arrives OR the window is resized.
    # Returns the ConsoleKeyInfo, or $null on resize (caller should redraw).
    $w0 = 0; $h0 = 0
    try { $w0 = [Console]::WindowWidth; $h0 = [Console]::WindowHeight } catch { }
    while ($true) {
        if (Test-KeyAvailable) { return [Console]::ReadKey($true) }
        $w1 = $w0; $h1 = $h0
        try { $w1 = [Console]::WindowWidth; $h1 = [Console]::WindowHeight } catch { }
        if ($w1 -ne $w0 -or $h1 -ne $h0) { return $null }
        Start-Sleep -Milliseconds 60
    }
}

function Format-InvDuration([double]$Seconds) {
    # 873ms / 4.2s / 2m 05s - invariant culture so no locale decimal commas
    if ($Seconds -lt 0) { $Seconds = 0 }
    if ($Seconds -lt 1) { return ('{0}ms' -f [int][Math]::Round($Seconds * 1000)) }
    if ($Seconds -lt 60) {
        return ($Seconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + 's')
    }
    $m = [int][Math]::Floor($Seconds / 60)
    $s = [int][Math]::Round($Seconds - ($m * 60))
    if ($s -ge 60) { $m++; $s -= 60 }
    return ('{0}m {1:d2}s' -f $m, $s)
}

function Format-InvBytes([long]$Bytes) {
    # 812 MB / 1.2 GB - invariant culture so no locale decimal commas
    if ($Bytes -ge 1GB) { return (($Bytes / 1GB).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + ' GB') }
    if ($Bytes -ge 1MB) { return ('{0} MB' -f [int][Math]::Round($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0} KB' -f [int][Math]::Round($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Format-InvAge([datetime]$When) {
    # Day-granularity age: today / yesterday / 5d ago / 3w ago / 2mo ago
    $days = ([DateTime]::Now.Date - $When.Date).Days
    if ($days -le 0) { return 'today' }
    if ($days -eq 1) { return 'yesterday' }
    if ($days -lt 14) { return ('{0}d ago' -f $days) }
    if ($days -lt 60) { return ('{0}w ago' -f [int][Math]::Floor($days / 7)) }
    return ('{0}mo ago' -f [int][Math]::Floor($days / 30))
}

function Get-InvUserName {
    # Account display: "Full Name (samname)" when a full name exists, else samname.
    # FAILSAFE chain: Get-LocalUser -> WMI -> plain env var.
    if ($Script:UserNameCache) { return $Script:UserNameCache }
    $sam = "$env:USERNAME"
    $disp = ''
    try {
        $u = Get-LocalUser -Name $sam -ErrorAction Stop
        if ($u.FullName) { $disp = "$($u.FullName)".Trim() }
    } catch {
        try {
            $wu = Get-CimInstance Win32_UserAccount -Filter ("Name='{0}' AND LocalAccount=TRUE" -f ($sam -replace "'", "''")) -ErrorAction Stop
            if ($wu.FullName) { $disp = "$($wu.FullName)".Trim() }
        } catch { }
    }
    if ($disp -and $disp -ne $sam) { $Script:UserNameCache = ('{0} ({1})' -f $disp, $sam) }
    else                           { $Script:UserNameCache = $sam }
    return $Script:UserNameCache
}

function Invoke-Nap([int]$Ms) {
    # Animation sleep; returns $true if the user pressed a key (skip signal).
    if (-not $Script:Interactive) { return $false }
    if (-not $Script:Settings.animations) { return $false }
    $end = [DateTime]::Now.AddMilliseconds($Ms)
    while ([DateTime]::Now -lt $end) {
        try { if ([Console]::KeyAvailable) { return $true } } catch { }
        Start-Sleep -Milliseconds 10
    }
    return $false
}

#endregion

#region ============================ SETTINGS ==================================

function Get-DefaultSettings {
    return [ordered]@{
        logo           = 'pyramid'
        theme          = 'void'
        animations     = $true
        bootSequence   = $true
        exportJson     = $true
        htmlReport     = $true
        restoreScript  = $true
        updateCheck    = $true
        skippedVersion = ''
        outputRoot     = 'snapshots'
        retentionKeep  = 0
        baselineSnapshot = ''
        bootStyle      = 'pillar'
        barStyle       = 'density'
        machineAlias   = ''
        tagline        = ''
        customTheme    = [ordered]@{ a = '#F5B8E0'; b = '#8B7BF7'; c = '#7FE3F0' }
        customTexture  = 'stardust'
        firstRunDone   = $false
    }
}

function Get-BootStyleNames { return @('pillar', 'starfield', 'matrix', 'pyramid', 'random', 'none') }
function Get-BarStyleNames  { return @('density', 'blocks', 'dots', 'arrows') }

function Repair-InvSettings($S) {
    # Verification pass: every field is validated against known-good shapes and
    # rolled back to its default when broken. Returns the number of repairs.
    $def = Get-DefaultSettings
    $fixed = 0
    if ((Get-LogoNames) -notcontains ([string]$S.logo)) { $S.logo = $def.logo; $fixed++ }
    if ([string]$S.theme -eq 'mono') { $S.theme = 'monochrome' }   # renamed in 26.7.0
    if ((Get-ThemeNames) -notcontains ([string]$S.theme)) { $S.theme = $def.theme; $fixed++ }
    foreach ($k in @('animations', 'bootSequence', 'exportJson', 'htmlReport', 'restoreScript', 'updateCheck')) {
        if ($S[$k] -isnot [bool]) {
            $v = $null
            try { $v = [System.Convert]::ToBoolean($S[$k]) } catch { }
            if ($null -eq $v) { $v = [bool]$def[$k] }
            $S[$k] = $v
            $fixed++
        }
    }
    if ($S['skippedVersion'] -isnot [string]) { $S['skippedVersion'] = "$($S['skippedVersion'])"; $fixed++ }
    $keep = 0
    try { $keep = [int]$S['retentionKeep'] } catch { $keep = -1 }
    if ($keep -lt 0 -or $keep -gt 999) { $S['retentionKeep'] = [int]$def.retentionKeep; $fixed++ }
    else { $S['retentionKeep'] = $keep }
    if ($S['baselineSnapshot'] -isnot [string]) { $S['baselineSnapshot'] = "$($S['baselineSnapshot'])"; $fixed++ }
    $root = [string]$S['outputRoot']
    $rootOk = $false
    if ($root -and $root.Trim() -ne '') {
        try { $rootOk = Test-Path -Path $root -IsValid } catch { }
    }
    if (-not $rootOk) { $S['outputRoot'] = $def.outputRoot; $fixed++ }
    if ([string]$S['bootStyle'] -eq 'wall') { $S['bootStyle'] = 'pillar' }   # renamed in 26.7.1
    if ((Get-BootStyleNames) -notcontains ([string]$S['bootStyle'])) { $S['bootStyle'] = $def.bootStyle; $fixed++ }
    if ((Get-BarStyleNames)  -notcontains ([string]$S['barStyle']))  { $S['barStyle']  = $def.barStyle;  $fixed++ }
    foreach ($k in @('machineAlias', 'tagline')) {
        if ($S[$k] -isnot [string]) { $S[$k] = "$($S[$k])"; $fixed++ }
        if ("$($S[$k])".Length -gt 40) { $S[$k] = "$($S[$k])".Substring(0, 40); $fixed++ }
    }
    if ($S['firstRunDone'] -isnot [bool]) {
        $v = $null
        try { $v = [System.Convert]::ToBoolean($S['firstRunDone']) } catch { }
        if ($null -eq $v) { $v = $false }
        $S['firstRunDone'] = $v; $fixed++
    }
    # customTheme: normalize to an ordered dict of three valid hex strings
    $ctFixed = $false
    $ct = [ordered]@{ a = $def.customTheme.a; b = $def.customTheme.b; c = $def.customTheme.c }
    $src = $S['customTheme']
    foreach ($key in @('a', 'b', 'c')) {
        $hex = $null
        if ($src -is [hashtable] -or $src -is [System.Collections.Specialized.OrderedDictionary]) { $hex = $src[$key] }
        elseif ($src) { $p = $src.PSObject.Properties[$key]; if ($p) { $hex = $p.Value } }
        $rgb = ConvertFrom-HexColor ([string]$hex)
        if ($null -ne $rgb) { $ct[$key] = (ConvertTo-HexColor $rgb) } else { $ctFixed = $true }
    }
    $S['customTheme'] = $ct
    if ($ctFixed) { $fixed++ }
    if ((Get-TextureNames) -notcontains ([string]$S['customTexture'])) { $S['customTexture'] = [string]$def.customTexture; $fixed++ }
    return $fixed
}

function Import-InvSettings {
    # Load order: settings.json -> settings.backup.json -> built-in defaults.
    # A corrupt primary file is quarantined so it can never brick another launch.
    $s = Get-DefaultSettings
    $loaded = $null
    foreach ($cand in @($Script:ConfigPath, (Join-Path $Script:ConfigDir 'settings.backup.json'))) {
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        try {
            $j = Get-Content -LiteralPath $cand -Raw | ConvertFrom-Json
            if ($null -ne $j) { $loaded = $j; break }
        } catch {
            if ($cand -eq $Script:ConfigPath) {
                try { Copy-Item -LiteralPath $cand -Destination (Join-Path $Script:ConfigDir 'settings.corrupt.json') -Force } catch { }
            }
        }
    }
    if ($loaded) {
        foreach ($k in @($s.Keys)) {
            $p = $loaded.PSObject.Properties[$k]
            if ($null -ne $p) { $s[$k] = $p.Value }
        }
    }
    [void](Repair-InvSettings $s)
    return $s
}

function Save-InvSettings {
    # Verified atomic save: write to a temp file, prove it parses back, keep a
    # backup of the last good config, then swap. A failed write changes nothing.
    try {
        if (-not (Test-Path -LiteralPath $Script:ConfigDir)) {
            New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null
        }
        $tmp = $Script:ConfigPath + '.tmp'
        Write-TextFile -Path $tmp -Content ($Script:Settings | ConvertTo-Json -Depth 5)
        $check = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        if ($null -eq $check -or $null -eq $check.PSObject.Properties['logo']) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return
        }
        if (Test-Path -LiteralPath $Script:ConfigPath) {
            Copy-Item -LiteralPath $Script:ConfigPath -Destination (Join-Path $Script:ConfigDir 'settings.backup.json') -Force
        }
        Move-Item -LiteralPath $tmp -Destination $Script:ConfigPath -Force
    } catch { }
}

function Write-TextFile([string]$Path, [string]$Content) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Get-OutputRoot {
    $root = [string]$Script:Settings.outputRoot
    if ($OutputPath) { $root = $OutputPath }
    if (-not [IO.Path]::IsPathRooted($root)) { $root = Join-Path $PSScriptRoot $root }
    return $root
}

#endregion

#region ============================ COLOR + THEME ENGINE ======================

$Script:DensityRamp = ' .:-=+*#%@'

# Theme presets: the chosen background statically decides every other color -
# no runtime background detection, text is readable by construction.
# Roles: Bg/Fg (16-color console enforcement), BgHex (Windows Terminal OSC 11),
#        Ramp (3 gradient stops), Txt/Dim/Faint/Accent/Warn/Violet (RGB).
$Script:Themes = [ordered]@{
    void = @{
        Label  = 'black'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Gray;  BgHex = '#0c0c11'
        Ramp   = @( @(245,184,224), @(139,123,247), @(127,227,240) )
        Txt    = @(200,200,214); Dim = @(118,118,140); Faint = @(70,70,88)
        Accent = @(127,227,240); Warn = @(245,150,200); Violet = @(155,140,250)
    }
    midnight = @{
        Label  = 'midnight'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Gray;  BgHex = '#05060f'
        Ramp   = @( @(120,132,214), @(150,168,236), @(198,214,250) )
        Txt    = @(196,204,228); Dim = @(112,122,166); Faint = @(64,72,112)
        Accent = @(150,180,255); Warn = @(226,158,190); Violet = @(168,164,238)
    }
    ivory = @{
        Label  = 'light'
        Bg     = [ConsoleColor]::White;    Fg = [ConsoleColor]::Black; BgHex = '#f2f0ec'
        Ramp   = @( @(196,58,146), @(96,76,220), @(0,138,162) )
        Txt    = @(45,45,58);    Dim = @(118,118,136); Faint = @(172,172,186)
        Accent = @(0,128,152);   Warn = @(192,40,112);  Violet = @(108,88,228)
    }
    gold = @{
        Label  = 'black & gold'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::DarkYellow; BgHex = '#050403'
        Ramp   = @( @(150,108,32), @(224,182,80), @(252,232,158) )
        Txt    = @(224,206,166); Dim = @(150,128,84); Faint = @(84,70,40)
        Accent = @(244,204,96);  Warn = @(232,150,72);  Violet = @(210,170,104)
    }
    matrix = @{
        Label  = 'black & green'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Green; BgHex = '#000400'
        Ramp   = @( @(0,110,20), @(0,235,70), @(120,255,140) )
        Txt    = @(96,244,120); Dim = @(40,150,64);   Faint = @(24,78,36)
        Accent = @(48,255,90);  Warn = @(214,224,66);  Violet = @(40,224,150)
    }
    ember = @{
        Label  = 'ember'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::DarkRed; BgHex = '#080302'
        Ramp   = @( @(150,26,12), @(244,110,32), @(255,204,96) )
        Txt    = @(236,204,182); Dim = @(154,104,80); Faint = @(96,58,42)
        Accent = @(252,150,66);  Warn = @(250,104,72);  Violet = @(232,120,96)
    }
    synthwave = @{
        Label  = 'synthwave'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Magenta; BgHex = '#170a2a'
        Ramp   = @( @(255,110,200), @(180,120,255), @(110,200,255) )
        Txt    = @(228,212,242); Dim = @(152,132,182); Faint = @(98,82,128)
        Accent = @(255,142,222); Warn = @(255,140,160); Violet = @(172,142,255)
    }
    arctic = @{
        Label  = 'arctic'
        Bg     = [ConsoleColor]::White;    Fg = [ConsoleColor]::Black; BgHex = '#eef4f9'
        Ramp   = @( @(24,118,186), @(46,150,208), @(120,192,232) )
        Txt    = @(30,52,70);    Dim = @(96,124,146); Faint = @(176,196,210)
        Accent = @(0,122,198);   Warn = @(190,58,86);   Violet = @(64,104,190)
    }
    monochrome = @{
        Label  = 'monochrome'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Gray; BgHex = '#0b0b0b'
        Ramp   = @( @(140,140,140), @(192,192,192), @(242,242,242) )
        Txt    = @(214,214,214); Dim = @(124,124,124); Faint = @(72,72,72)
        Accent = @(244,244,244); Warn = @(198,198,198); Violet = @(170,170,170)
    }
    abyss = @{
        Label  = 'deep water'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Cyan; BgHex = '#020a14'
        Ramp   = @( @(0,92,120), @(0,158,186), @(96,214,232) )
        Txt    = @(150,206,222); Dim = @(78,132,152); Faint = @(34,68,88)
        Accent = @(84,222,236); Warn = @(238,178,108); Violet = @(108,178,228)
    }
    custom = @{
        Label  = 'your palette'
        Bg     = [ConsoleColor]::Black;    Fg = [ConsoleColor]::Gray; BgHex = '#0c0c11'
        Ramp   = @( @(245,184,224), @(139,123,247), @(127,227,240) )
        Txt    = @(200,200,214); Dim = @(118,118,140); Faint = @(70,70,88)
        Accent = @(127,227,240); Warn = @(245,150,200); Violet = @(155,140,250)
    }
}
$Script:Theme = $Script:Themes['void']

# Curated color set the Theme Studio cycles through for each gradient anchor.
$Script:ColorSwatches = [ordered]@{
    pink    = @(245,184,224); rose    = @(245,120,170); red     = @(235,90,90)
    ember   = @(245,140,70);  amber   = @(240,190,90);  gold    = @(212,175,74)
    lime    = @(170,230,90);  green   = @(80,210,110);  emerald = @(40,200,140)
    teal    = @(60,210,210);  cyan    = @(127,227,240); sky     = @(110,180,250)
    blue    = @(100,140,250); indigo  = @(130,110,245); violet  = @(170,140,250)
    magenta = @(230,110,220); white   = @(230,230,235); silver  = @(170,170,182)
}

function ConvertFrom-HexColor([string]$Hex) {
    # '#RRGGBB' or 'RRGGBB' -> @(r,g,b); returns $null when unparseable.
    $h = "$Hex".Trim().TrimStart('#')
    if ($h.Length -ne 6) { return $null }
    $ok = $true
    $vals = @(0, 0, 0)
    for ($i = 0; $i -lt 3; $i++) {
        $byte = 0
        if ([int]::TryParse($h.Substring($i * 2, 2), [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$byte)) { $vals[$i] = $byte }
        else { $ok = $false }
    }
    if (-not $ok) { return $null }
    return @($vals[0], $vals[1], $vals[2])
}

function ConvertTo-HexColor($Rgb) {
    return ('#{0:X2}{1:X2}{2:X2}' -f [int]$Rgb[0], [int]$Rgb[1], [int]$Rgb[2])
}

function Get-CustomAnchors {
    # Reads settings.customTheme (three hex strings a/b/c) into three RGB anchors,
    # falling back to the COVERT gradient for any missing/broken value.
    $def = @( @(245,184,224), @(139,123,247), @(127,227,240) )
    $ct = $null
    try { $ct = $Script:Settings.customTheme } catch { }
    $out = @()
    foreach ($pair in @(@('a', 0), @('b', 1), @('c', 2))) {
        $key = $pair[0]; $ix = $pair[1]
        $rgb = $null
        if ($ct) {
            $hex = $null
            if ($ct -is [hashtable] -or $ct -is [System.Collections.Specialized.OrderedDictionary]) { $hex = $ct[$key] }
            else { $p = $ct.PSObject.Properties[$key]; if ($p) { $hex = $p.Value } }
            if ($hex) { $rgb = ConvertFrom-HexColor ([string]$hex) }
        }
        if ($null -eq $rgb) { $rgb = $def[$ix] }
        $out += , $rgb
    }
    return $out
}

function Build-CustomTheme {
    # The custom theme: user-chosen gradient anchors drive Ramp/Accent/Violet,
    # while Txt/Dim/Faint/Warn stay neutral-readable so any palette stays legible.
    $a = @(Get-CustomAnchors)
    return @{
        Label  = 'your palette'
        Bg     = [ConsoleColor]::Black; Fg = [ConsoleColor]::Gray; BgHex = '#0c0c11'
        Ramp   = @( $a[0], $a[1], $a[2] )
        Txt    = @(202,202,214); Dim = @(120,120,142); Faint = @(72,72,90)
        Accent = $a[2]; Warn = @(244,158,110); Violet = $a[1]
    }
}

function Get-ThemeNames { return @($Script:Themes.Keys | ForEach-Object { "$_" }) }

function Apply-InvTheme([string]$Name) {
    # Swaps the active theme and repaints the console (the "rendering update").
    $t = $null
    if ($Name -eq 'custom') { $t = Build-CustomTheme }
    else { $t = $Script:Themes[$Name] }
    if ($null -eq $t) { $t = $Script:Themes['void'] }
    $Script:Theme = $t
    if ($Silent -or -not $Script:Interactive) { return }
    try {
        [Console]::BackgroundColor = $t.Bg
        [Console]::ForegroundColor = $t.Fg
    } catch { }
    if ($Script:AnsiOn) {
        # Seamless background: three things must agree on the same black, or the
        # screen shows two shades (Clear-Host fills with the 16-color PALETTE black,
        # while ANSI resets/OSC-11 show the terminal's DEFAULT background).
        #  - OSC 11 sets the default background (shows through resets).
        #  - OSC 4 redefines the exact palette index Clear-Host fills with, so the
        #    16-color fill matches the truecolor default. Result: one uniform black.
        try { Write-Host -NoNewline ("$($Script:Esc)]11;" + $t.BgHex + [string][char]7) } catch { }
        try {
            $bgIdx = [int]$t.Bg
            Write-Host -NoNewline ("$($Script:Esc)]4;$bgIdx;" + $t.BgHex + [string][char]7)
            $Script:PaletteTouched = $true
        } catch { }
    }
    try { Clear-Host } catch { }
}

function Restore-ConsoleColors {
    try {
        if ($null -ne $Script:OrigBg) { [Console]::BackgroundColor = $Script:OrigBg }
        if ($null -ne $Script:OrigFg) { [Console]::ForegroundColor = $Script:OrigFg }
    } catch { }
    if ($Script:AnsiOn) {
        # OSC 111: reset the default background to the terminal's own setting.
        # OSC 104: restore the palette entry we redefined for a seamless fill.
        try { Write-Host -NoNewline ("$($Script:Esc)]111" + [string][char]7) } catch { }
        if ($Script:PaletteTouched) {
            try { Write-Host -NoNewline ("$($Script:Esc)]104" + [string][char]7) } catch { }
        }
    }
}

function Get-AnsiFg([int]$R, [int]$G, [int]$B) {
    if (-not $Script:AnsiOn) { return '' }
    return "$($Script:Esc)[38;2;$R;$G;$($B)m"
}

function Get-RampColor([double]$T) {
    if ($T -lt 0) { $T = 0 }
    if ($T -gt 1) { $T = 1 }
    $pal = $Script:Theme.Ramp
    $seg = $T * 2.0
    if ($seg -le 1.0) { $ca = $pal[0]; $cb = $pal[1]; $f = $seg }
    else              { $ca = $pal[1]; $cb = $pal[2]; $f = $seg - 1.0 }
    $r = [int]($ca[0] + ($cb[0] - $ca[0]) * $f)
    $g = [int]($ca[1] + ($cb[1] - $ca[1]) * $f)
    $b = [int]($ca[2] + ($cb[2] - $ca[2]) * $f)
    return @($r, $g, $b)
}

function Format-GradientText([string]$Text, [double]$T0 = 0.0, [double]$T1 = 1.0) {
    if (-not $Script:AnsiOn -or $Text.Length -eq 0) { return $Text }
    $sb = New-Object System.Text.StringBuilder
    $n = $Text.Length
    for ($i = 0; $i -lt $n; $i++) {
        $t = $T0
        if ($n -gt 1) { $t = $T0 + ($T1 - $T0) * ($i / [double]($n - 1)) }
        $c = Get-RampColor $t
        [void]$sb.Append((Get-AnsiFg $c[0] $c[1] $c[2])).Append($Text[$i])
    }
    [void]$sb.Append($Script:Rst)
    return $sb.ToString()
}

function Get-RoleColor([string]$Role, [string]$Text) {
    $c = $Script:Theme[$Role]
    if ($null -eq $c) { return $Text }
    return (Get-AnsiFg $c[0] $c[1] $c[2]) + $Text + $Script:Rst
}
function Get-Dim([string]$Text)    { return (Get-RoleColor 'Dim'    $Text) }
function Get-Faint([string]$Text)  { return (Get-RoleColor 'Faint'  $Text) }
function Get-Txt([string]$Text)    { return (Get-RoleColor 'Txt'    $Text) }
function Get-Accent([string]$Text) { return (Get-RoleColor 'Accent' $Text) }
function Get-Warn([string]$Text)   { return (Get-RoleColor 'Warn'   $Text) }
function Get-Violet([string]$Text) { return (Get-RoleColor 'Violet' $Text) }

function Write-GradLine([string]$Text, [double]$T0 = 0.0, [double]$T1 = 1.0, [switch]$Center) {
    $out = Format-GradientText $Text $T0 $T1
    if ($Center) { $pad = Get-CenterPad $Text.Length; Record-MenuSpan $pad.Length $Text.Length; $out = $pad + $out }
    Write-Host $out
}

function Write-DimLine([string]$Text, [switch]$Center) {
    $out = Get-Dim $Text
    if ($Center) { $pad = Get-CenterPad $Text.Length; Record-MenuSpan $pad.Length $Text.Length; $out = $pad + $out }
    Write-Host $out
}

function Write-TxtLine([string]$Text, [switch]$Center) {
    $out = Get-Txt $Text
    if ($Center) { $pad = Get-CenterPad $Text.Length; Record-MenuSpan $pad.Length $Text.Length; $out = $pad + $out }
    Write-Host $out
}

#endregion

#region ============================ WORDMARK ENGINE ===========================

$Script:MiniFont = @{
    'A' = @(' ## ', '#  #', '####', '#  #', '#  #')
    'C' = @(' ###', '#   ', '#   ', '#   ', ' ###')
    'D' = @('### ', '#  #', '#  #', '#  #', '### ')
    'E' = @('####', '#   ', '### ', '#   ', '####')
    'I' = @('###', ' # ', ' # ', ' # ', '###')
    'N' = @('#  #', '## #', '# ##', '#  #', '#  #')
    'O' = @(' ## ', '#  #', '#  #', '#  #', ' ## ')
    'P' = @('### ', '#  #', '### ', '#   ', '#   ')
    'R' = @('### ', '#  #', '### ', '# # ', '#  #')
    'S' = @(' ###', '#   ', ' ## ', '   #', '### ')
    'T' = @('###', ' # ', ' # ', ' # ', ' # ')
    'V' = @('#  #', '#  #', '#  #', '#  #', ' ## ')
    'W' = @('#   #', '#   #', '# # #', '## ##', '#   #')
    'X' = @('#  #', '#  #', ' ## ', '#  #', '#  #')
    'Z' = @('####', '  # ', ' ## ', '#   ', '####')
    ' ' = @('  ', '  ', '  ', '  ', '  ')
}

function Build-Wordmark([string]$Text, [int]$Scale = 1) {
    $rows = @('', '', '', '', '')
    foreach ($ch in $Text.ToUpper().ToCharArray()) {
        $glyph = $Script:MiniFont[[string]$ch]
        if ($null -eq $glyph) { $glyph = $Script:MiniFont[' '] }
        for ($r = 0; $r -lt 5; $r++) {
            $rows[$r] = $rows[$r] + $glyph[$r] + ' '
        }
    }
    $out = @()
    foreach ($row in $rows) {
        $line = ''
        foreach ($c in $row.ToCharArray()) { $line += ([string]$c * $Scale) }
        for ($v = 0; $v -lt $Scale; $v++) { $out += $line }
    }
    return $out
}

#endregion

#region ============================ LOGO REGISTRY =============================

function Get-LogoNames { return @('cxt', 'covert', 'pyramid', 'wordmark', 'minimal') }

function Get-LogoLabel([string]$Name) {
    switch ($Name) {
        'pyramid'  { return 'inventorizer (pyramid)' }
        'wordmark' { return 'inventorizer (wordmark)' }
        'minimal'  { return 'inventorizer (minimal)' }
        default    { return $Name }
    }
}

function Get-LogoArt([string]$Name) {
    switch ($Name) {
        'cxt' {
            return @(
                '              .:=+*#%@@@@@@%#*+=:.              '
                '           .=*@@@@@@@@@@@@@@@@@@@@*=.           '
                '         .+@@@@@%#*+==--------==+*#@@@%+.       '
                '        =@@@@#=.                    .=#@@@=     '
                '      .*@@@%-        ________________________   '
                '     .#@@@#.        |%%%%%%%%%@@@@@@%%%%%%%%%|  '
                '     =@@@@:         |====:    @@@@@@    :====|  '
                '     #@@@%.                   @@@@@@            '
                '     %@@@%     :#=    =#:     @@@@@@            '
                '     %@@@%      .#=  =#.      @@@@@@            '
                '     %@@@%        =@@=        @@@@@@            '
                '     %@@@%      .#=  =#.      @@@@@@            '
                '     #@@@%.    :#=    =#:     @@@@@@            '
                '     =@@@@:                   @@@@@@            '
                '     .#@@@#.                  =@@@@=            '
                '      .*@@@%-                  #@@#             '
                '        =@@@@#=.               .@@.             '
                '         .+@@@@@%#*+==--:       ++              '
                '           .=*@@@@@@@@@@@@*=.                   '
                '              .:=+*#%@@%#*=:.                   '
            )
        }
        'wordmark' {
            $wm = @(Build-Wordmark $Script:Brand.Short 1)
            $w = 0
            foreach ($l in $wm) { if ($l.Length -gt $w) { $w = $l.Length } }
            # NOTE: parens are load-bearing - PS comma binds tighter than * and +
            return @(('=' * $w), '') + $wm + @('', ('=' * $w))
        }
        'covert' {
            # Bold recreation of the COVERT wordmark: heavy geometric letterforms,
            # 7 rows tall with 2-row bars and 4-wide stems.
            $L = @{
                C = @(' @@@@@@@@', '@@@@@@@@@', '@@@@     ', '@@@@     ', '@@@@     ', '@@@@@@@@@', ' @@@@@@@@')
                O = @(' @@@@@@@ ', '@@@@@@@@@', '@@@@ @@@@', '@@@@ @@@@', '@@@@ @@@@', '@@@@@@@@@', ' @@@@@@@ ')
                V = @('@@@@ @@@@', '@@@@ @@@@', '@@@@ @@@@', '@@@@ @@@@', '@@@@ @@@@', ' @@@@@@@ ', '  @@@@@  ')
                E = @('@@@@@@@@', '@@@@@@@@', '@@@@    ', '@@@@@@@ ', '@@@@    ', '@@@@@@@@', '@@@@@@@@')
                R = @('@@@@@@@@ ', '@@@@@@@@@', '@@@@ @@@@', '@@@@@@@@@', '@@@@@@@@ ', '@@@@ @@@@', '@@@@ @@@@')
                T = @('@@@@@@@@@', '@@@@@@@@@', '  @@@@@  ', '  @@@@@  ', '  @@@@@  ', '  @@@@@  ', '  @@@@@  ')
            }
            $seq = 'C', 'O', 'V', 'E', 'R', 'T'
            $lines = @()
            for ($r = 0; $r -lt 7; $r++) {
                $parts = @()
                foreach ($ch in $seq) { $parts += $L[$ch][$r] }
                $lines += ($parts -join '  ')
            }
            return $lines
        }
        'pyramid' {
            # THE REFRACTION PYRAMID - the Inventorizer product mark. One huge
            # 3D monument (apex to base, no floating pieces): an open line-art
            # face and a shaded face maturing through the density ramp. Raw
            # binary arcs down from the sky, steepening as it falls, and pours
            # through the open face into the heart; ordered report rays arc out
            # of the shaded face into .txt files. Engraved plaque underneath.
            # Plotted on a character grid so the geometry stays exact.
            $W = 66
            $H = 13
            $g = @()
            for ($r = 0; $r -lt $H; $r++) { $g += , ((' ' * $W).ToCharArray()) }
            $plot = {
                param([int]$X, [int]$Y, [string]$S)
                for ($i = 0; $i -lt $S.Length; $i++) {
                    $xx = $X + $i
                    if ($xx -ge 0 -and $xx -lt $W -and $Y -ge 0 -and $Y -lt $H) { $g[$Y][$xx] = $S[$i] }
                }
            }
            # the monument: 10 rows, left face slope 3, inner edge slope 1,
            # outer right edge slope 2 - a single apex, no capstone gap
            $shade = '*', '*', '#', '#', '%', '%', '@', '@'
            for ($i = 0; $i -le 9; $i++) {
                $r = 1 + $i
                $lc = 34 - (3 * $i)
                $rg = 35 + $i
                $rc = 35 + (2 * $i)
                & $plot $lc $r '/'
                if ($i -eq 9) {
                    for ($x = $lc + 1; $x -lt $rg; $x++) { $g[$r][$x] = '_' }
                }
                & $plot $rg $r '\'
                if ($i -ge 2) {
                    for ($x = $rg + 1; $x -lt $rc; $x++) { $g[$r][$x] = [char]([string]$shade[$i - 2])[0] }
                }
                if ($rc -gt $rg) { & $plot $rc $r '\' }
            }
            # binary arc: horizontal drift shrinks as the fall accelerates,
            # crossing the open face and diving into the pyramid's heart
            $arcX = 2, 7, 12, 16, 19, 22, 23, 25, 26, 27
            $arcY = 0, 0, 0, 1, 2, 3, 4, 5, 6, 7
            $bits = '0110100101'
            for ($i = 0; $i -lt $arcX.Count; $i++) {
                & $plot ([int]$arcX[$i]) ([int]$arcY[$i]) ([string]$bits[$i])
            }
            # report rays arcing out of the shaded face at mid-height
            & $plot 43 4 '_.-=';  & $plot 49 4 'sys.txt'
            & $plot 45 5 '===--'; & $plot 52 5 'app.txt'
            & $plot 47 6 "'-._";  & $plot 53 6 'drv.txt'
            # ground line + engraved plaque
            & $plot 4 11 ('.' + ('-' * 51) + '.')
            & $plot 19 12 'I N V E N T O R I Z E R'
            $lines = @()
            for ($r = 0; $r -lt $H; $r++) { $lines += (-join $g[$r]) }
            return $lines
        }
        'minimal' {
            return @('.-===<[ INVENTORIZER ]>===-.')
        }
        default { return Get-LogoArt 'cxt' }
    }
}

function Show-Logo([string]$Name, [int]$LineDelayMs = 0) {
    # FAILSAFE: never let broken logo art take the console down. If the art for
    # the *configured* logo cannot be produced, roll the config back to 'cxt'.
    $art = @()
    try { $art = @(Get-LogoArt $Name | ForEach-Object { "$_" }) } catch { $art = @() }
    if ($art.Count -eq 0) {
        $art = @('.-===<[ INVENTORIZER ]>===-.')
        $healTo = [string](Get-DefaultSettings).logo
        if ($Script:Settings -and $Name -eq [string]$Script:Settings.logo -and $Name -ne $healTo) {
            $Script:Settings.logo = $healTo
            Save-InvSettings
        }
    }
    $maxw = 0
    foreach ($l in $art) { if ($l.Length -gt $maxw) { $maxw = $l.Length } }
    if ($maxw -ge (Get-ConWidth)) {
        # window too narrow for this art - swap to the one-liner instead of wrapping
        $art = @('.-===<[ INVENTORIZER ]>===-.')
        $maxw = $art[0].Length
    }
    $pad = Get-CenterPad $maxw
    $n = $art.Count
    for ($i = 0; $i -lt $n; $i++) {
        $tv = 0.0
        if ($n -gt 1) { $tv = $i / [double]($n - 1) }
        $t0 = $tv * 0.8
        Record-MenuSpan $pad.Length $art[$i].Length
        Write-Host ($pad + (Format-GradientText $art[$i] $t0 ($t0 + 0.2)))
        if ($LineDelayMs -gt 0) {
            if (Invoke-Nap $LineDelayMs) { $LineDelayMs = 0 }
        }
    }
}

#endregion

#region ============================ AMBIENT TEXTURES ==========================
# Per-theme animated backdrops that play behind the main menu while it is idle.
# The menu is drawn normally; as it draws, each centered line records the screen
# cells it occupies (its "span"). The texture then animates only in the cells
# OUTSIDE those spans - so the menu text is never touched or redrawn, there is no
# flicker, and the cost is a few short writes per row per frame.
#
# FAILSAFES: everything is gated by the animations setting AND the theme having a
# texture; any console fault latches $Script:AmbientDisabled and the menu silently
# falls back to the plain (static) wait. Texture stops instantly on any keypress.

$Script:MenuSpans      = @{}
$Script:AmbientCapture = $false
$Script:AmbientDisabled = $false
# Matrix rain glyphs - digits, letters and symbols like the film (source stays ASCII)
$Script:MatrixCharset = '0123456789ABCDEFGHJKLMNPQRSTUVWXYZ<>=*+:.$#%&/\|'

# Selectable backdrop textures. Every preset theme owns a fixed texture
# (Get-ThemeTexture); a custom theme picks one of these in the Theme Studio. The
# id is the same token the Draw-TextureFrame switch understands, so any choice
# here renders in the custom palette's own colors with no extra wiring.
$Script:TextureCatalog = @(
    @{ Id = 'none';      Label = 'none';       Blurb = 'a still background - no motion behind the menu' },
    @{ Id = 'stardust';  Label = 'stardust';   Blurb = 'slow points of light drifting downward' },
    @{ Id = 'rain';      Label = 'code rain';  Blurb = 'falling glyph columns, matrix-style' },
    @{ Id = 'stars';     Label = 'starfield';  Blurb = 'a calm field of twinkling stars' },
    @{ Id = 'flames';    Label = 'embers';     Blurb = 'flames rising from the base of the screen' },
    @{ Id = 'snow';      Label = 'snowfall';   Blurb = 'soft flakes falling from the top' },
    @{ Id = 'drift';     Label = 'drift';      Blurb = 'faint characters sliding quietly down' },
    @{ Id = 'shine';     Label = 'shine';      Blurb = 'a bright band sweeping across' },
    @{ Id = 'grid';      Label = 'neon grid';  Blurb = 'a scrolling synthwave grid' },
    @{ Id = 'blueprint'; Label = 'blueprint';  Blurb = 'a faint grid of technical guide lines' },
    @{ Id = 'bubbles';   Label = 'deep water'; Blurb = 'bubbles rising smoothly from the depths' }
)

function Get-TextureNames { return @($Script:TextureCatalog | ForEach-Object { $_.Id }) }

function Get-TextureLabel([string]$Id) {
    foreach ($t in $Script:TextureCatalog) { if ($t.Id -eq $Id) { return $t.Label } }
    return $Id
}

function Record-MenuSpan([int]$Pad, [int]$Len) {
    # Called by the centered writers while the menu is drawing: remembers that
    # columns [Pad, Pad+Len) on the current row hold text (the texture skips them).
    if (-not $Script:AmbientCapture) { return }
    try {
        $r = [Console]::CursorTop
        $c0 = $Pad
        $c1 = $Pad + $Len
        if ($Script:MenuSpans.ContainsKey($r)) {
            $ex = $Script:MenuSpans[$r]
            if ($c0 -lt $ex[0]) { $ex[0] = $c0 }
            if ($c1 -gt $ex[1]) { $ex[1] = $c1 }
        } else {
            $Script:MenuSpans[$r] = @($c0, $c1)
        }
    } catch { $Script:AmbientCapture = $false }
}

function Get-ThemeTexture {
    # Maps the active theme to its backdrop id ('' = none).
    switch ([string]$Script:Settings.theme) {
        'matrix'     { return 'rain' }
        'midnight'   { return 'stars' }
        'ember'      { return 'flames' }
        'arctic'     { return 'snow' }
        'gold'       { return 'shine' }
        'monochrome' { return 'drift' }
        'synthwave'  { return 'grid' }
        'void'       { return 'stardust' }
        'ivory'      { return 'blueprint' }
        'abyss'      { return 'bubbles' }
        'custom'     {
            $ct = [string]$Script:Settings.customTexture
            if ($ct -eq '' -or $ct -eq 'none') { return '' }
            if ((Get-TextureNames) -contains $ct) { return $ct }
            return ''
        }
        default      { return '' }
    }
}

function Get-RainColumn([int]$Col, [int]$H, [int]$Frame) {
    # Deterministic falling-drop state for one column: @(headRow, length).
    $seed = ($Col * 1103515245 + 12345) -band 0x7FFFFFFF
    $len = 4 + [int]($seed % 11)
    $period = $H + $len + [int](($seed -shr 3) % 18)
    if ($period -lt 1) { $period = 1 }
    $head = [int](($Frame + [int](($seed -shr 5) % $period)) % $period)
    return @($head, $len)
}

function Draw-TextureFrame([int]$Frame) {
    # Paints one frame of the active theme's backdrop into the cells AROUND the
    # menu. A readability halo fades it toward the background near the interface,
    # and a hard 1-cell clear border is always kept around the focused window so
    # the menu reads as a bordered panel floating in the texture.
    if (-not $Script:Interactive -or $Script:AmbientDisabled) { return }
    $tex = Get-ThemeTexture
    if ($tex -eq '') { return }
    $tid = 0
    switch ($tex) {
        'rain' { $tid = 1 } 'stars' { $tid = 2 } 'flames' { $tid = 3 } 'snow' { $tid = 4 }
        'stardust' { $tid = 5 } 'drift' { $tid = 6 } 'shine' { $tid = 7 } 'grid' { $tid = 8 }
        'blueprint' { $tid = 9 } 'bubbles' { $tid = 10 }
    }
    if ($tid -eq 0) { return }
    $w = 0; $h = 0
    try { $w = [Console]::WindowWidth; $h = [Console]::WindowHeight } catch { return }
    if ($w -lt 8 -or $h -lt 6) { return }
    $acc = $Script:Theme.Accent
    $fnt = $Script:Theme.Faint
    $dim = $Script:Theme.Dim
    $bg = ConvertFrom-HexColor $Script:Theme.BgHex
    if ($null -eq $bg) { $bg = @(0, 0, 0) }

    # bounding box of the menu, for the halo + hard clear border
    $haveBox = $false
    $minR = 999999; $maxR = -1; $minC = 999999; $maxC = -1
    foreach ($rk in $Script:MenuSpans.Keys) {
        $sp = $Script:MenuSpans[$rk]
        if ($rk -lt $minR) { $minR = $rk }
        if ($rk -gt $maxR) { $maxR = $rk }
        if ($sp[0] -lt $minC) { $minC = $sp[0] }
        if ($sp[1] -gt $maxC) { $maxC = $sp[1] }
        $haveBox = $true
    }
    $halo = 7.0
    $clearPad = 1   # guaranteed clear cells on every side of the focused window

    # per-frame precompute per texture
    $heads = $null; $lens = $null; $ftop = $null; $hl = $null
    $horizon = 0; $cx = 0; $slope = 0.55; $nrays = 7
    if ($tid -eq 1) {
        $heads = New-Object 'int[]' $w; $lens = New-Object 'int[]' $w
        for ($c = 0; $c -lt $w; $c++) { $rc = Get-RainColumn $c $h $Frame; $heads[$c] = $rc[0]; $lens[$c] = $rc[1] }
    } elseif ($tid -eq 3) {
        $ftop = New-Object 'int[]' $w
        $baseH = [int]($h * 0.40)
        for ($c = 0; $c -lt $w; $c++) {
            $osc = ((($c * 73856093) -bxor (($Frame -shr 1) * 19349663)) -band 0x7FFFFFFF) % 6
            $osc2 = ((($c * 19349663) -bxor ($Frame * 83492791)) -band 0x7FFFFFFF) % 3
            $ft = $h - ($baseH + $osc + $osc2)
            if ($ft -lt 0) { $ft = 0 }
            $ftop[$c] = $ft
        }
    } elseif ($tid -eq 8) {
        $horizon = [int]($h * 0.46); $cx = [int]($w / 2)
        $hl = @{}
        $prevI = -999999
        for ($rr = $horizon; $rr -lt $h; $rr++) {
            $depth = $rr - $horizon + 1
            $val = [Math]::Sqrt([double]$depth) * 2.4 - $Frame * 0.14
            $iv = [int][Math]::Floor($val)
            if ($rr -gt $horizon -and $iv -ne $prevI) { $hl[$rr] = $true }
            $prevI = $iv
        }
    }

    # SINGLE-WRITE: build the whole frame as one string (absolute cursor moves per
    # row, and a cursor-forward jump over the menu text so it is never overwritten),
    # then emit it in ONE write. This is what makes it smooth at full-screen.
    $sb = New-Object System.Text.StringBuilder
    $esc = $Script:Esc
    $rowMax = $h - 1   # never paint the final row (would scroll the buffer)
    for ($r = 0; $r -lt $rowMax; $r++) {
        $span = $null
        if ($Script:MenuSpans.ContainsKey($r)) { $span = $Script:MenuSpans[$r] }
        $dy = 0
        if ($haveBox) {
            if ($r -lt $minR) { $dy = $minR - $r } elseif ($r -gt $maxR) { $dy = $r - $maxR }
        }
        [void]$sb.Append($esc).Append('[').Append($r + 1).Append(';1H')   # row r+1, col 1
        $lastKey = -999
        $c = 0
        while ($c -lt $w) {
            if ($span -and $c -ge $span[0] -and $c -lt $span[1]) {
                # jump the cursor over the menu text (preserves it), never overwrite
                $skip = $span[1] - $c
                [void]$sb.Append($esc).Append('[').Append($skip).Append('C')
                $c = $span[1]; $lastKey = -999
                continue
            }
            $hit = $false; $ch = ' '; $br = 0; $bgc = 0; $bb = 0
            if ($tid -eq 1) {
                # matrix code rain - falling glyphs (digits/letters/symbols)
                $d = $heads[$c] - $r
                if ($d -ge 0 -and $d -lt $lens[$c]) {
                    $hit = $true
                    $ci = ((($c * 73856093) -bxor ((($r * 7) + $Frame) * 19349663)) -band 0x7FFFFFFF) % $Script:MatrixCharset.Length
                    $ch = $Script:MatrixCharset[$ci]
                    if ($d -eq 0) { $br = 224; $bgc = 255; $bb = 224 }
                    else {
                        $tt = 1.0 - ($d / [double]$lens[$c])
                        $br = [int]($fnt[0] + ($acc[0] - $fnt[0]) * $tt)
                        $bgc = [int]($fnt[1] + ($acc[1] - $fnt[1]) * $tt)
                        $bb = [int]($fnt[2] + ($acc[2] - $fnt[2]) * $tt)
                    }
                }
            }
            elseif ($tid -eq 2) {
                # starry night - twinkling, denser toward the top
                $dens = 9 + $r * 3
                $hh = (($c * 73856093) -bxor ($r * 19349663)) -band 0x7FFFFFFF
                if (($hh % $dens) -eq 0) {
                    $ph = ($hh + $Frame * 5) % 44
                    if ($ph -lt 22) { $tw = $ph / 22.0 } else { $tw = (44 - $ph) / 22.0 }
                    $b = 0.30 + 0.70 * $tw
                    if ($tw -gt 0.75) { $ch = '*' } elseif ($tw -gt 0.4) { $ch = '+' } else { $ch = '.' }
                    $hit = $true
                    $br = [int]($fnt[0] + ($acc[0] - $fnt[0]) * $b)
                    $bgc = [int]($fnt[1] + ($acc[1] - $fnt[1]) * $b)
                    $bb = [int]($fnt[2] + ($acc[2] - $fnt[2]) * $b)
                }
            }
            elseif ($tid -eq 3) {
                # ember flames - rising from the base, hot/dense low, cool/sparse high
                if ($r -ge $ftop[$c]) {
                    $denom = ($h - 1 - $ftop[$c]); if ($denom -lt 1) { $denom = 1 }
                    $inten = ($r - $ftop[$c]) / [double]$denom
                    $flk = (((($c * 40503) -bxor (($r + $Frame) * 68917)) -band 0x7FFFFFFF) % 100) / 100.0
                    $inten = $inten * (0.6 + 0.4 * $flk)
                    if ($inten -gt 1) { $inten = 1 }
                    $show = $true
                    if ($inten -lt 0.30 -and ((((($c * 12345) -bxor (($r + $Frame) * 6789)) -band 0x7FFFFFFF) % 4) -ne 0)) { $show = $false }
                    if ($show) {
                        $hit = $true
                        if ($inten -lt 0.2) { $ch = ',' } elseif ($inten -lt 0.4) { $ch = ':' } elseif ($inten -lt 0.62) { $ch = '*' } elseif ($inten -lt 0.82) { $ch = '#' } else { $ch = '%' }
                        $col = Get-RampColor $inten
                        $br = $col[0]; $bgc = $col[1]; $bb = $col[2]
                    }
                }
            }
            elseif ($tid -eq 4) {
                # arctic snow - sparse flakes falling slowly (blue-grey on the light bg)
                $yy = $r - ($Frame -shr 1)
                $xx = $c + (($Frame -shr 3) % 4)
                $hh = (($xx * 73856093) -bxor ($yy * 19349663)) -band 0x7FFFFFFF
                if (($hh % 34) -eq 0) {
                    $hit = $true
                    if (($hh % 3) -eq 0) { $ch = '*' } else { $ch = '.' }
                    $b = 0.45 + 0.55 * (($hh % 10) / 10.0)
                    $br = [int]($fnt[0] + ($acc[0] - $fnt[0]) * $b)
                    $bgc = [int]($fnt[1] + ($acc[1] - $fnt[1]) * $b)
                    $bb = [int]($fnt[2] + ($acc[2] - $fnt[2]) * $b)
                }
            }
            elseif ($tid -eq 5) {
                # void stardust - very sparse, slow, pastel motes drifting down
                $yy = $r - ($Frame -shr 2)
                $hh = (($c * 73856093) -bxor ($yy * 19349663)) -band 0x7FFFFFFF
                if (($hh % 74) -eq 0) {
                    $hit = $true
                    $m = $hh % 3
                    if ($m -eq 0) { $ch = '.' } elseif ($m -eq 1) { $ch = "'" } else { $ch = '*' }
                    $col = Get-RampColor (($c % $w) / [double]$w)
                    $b = 0.4 + 0.5 * (($hh % 10) / 10.0)
                    $br = [int]($bg[0] + ($col[0] - $bg[0]) * $b)
                    $bgc = [int]($bg[1] + ($col[1] - $bg[1]) * $b)
                    $bb = [int]($bg[2] + ($col[2] - $bg[2]) * $b)
                }
            }
            elseif ($tid -eq 6) {
                # monochrome drift - minimal faint grey specks drifting down
                $yy = $r - ($Frame -shr 1)
                $hh = (($c * 73856093) -bxor ($yy * 19349663)) -band 0x7FFFFFFF
                if (($hh % 58) -eq 0) {
                    $hit = $true; $ch = '.'
                    $b = 0.3 + 0.4 * (($hh % 10) / 10.0)
                    $br = [int]($fnt[0] + ($dim[0] - $fnt[0]) * $b)
                    $bgc = [int]($fnt[1] + ($dim[1] - $fnt[1]) * $b)
                    $bb = [int]($fnt[2] + ($dim[2] - $fnt[2]) * $b)
                }
            }
            elseif ($tid -eq 7) {
                # gold shine - clean field with an occasional diagonal shine sweep
                $sp2 = $Frame % 170
                $inBand = $false; $bandB = 0.0
                if ($sp2 -lt 55) {
                    $prog = $sp2 / 55.0
                    $bandCenter = -20 + $prog * ($w + $h + 40)
                    $ddd = [Math]::Abs(($c + $r) - $bandCenter)
                    if ($ddd -lt 6) { $inBand = $true; $bandB = 1.0 - ($ddd / 6.0) }
                }
                if ($inBand) {
                    $hit = $true
                    if ($bandB -gt 0.6) { $ch = '#' } elseif ($bandB -gt 0.3) { $ch = '*' } else { $ch = '.' }
                    $br = [int]($acc[0] + (255 - $acc[0]) * $bandB)
                    $bgc = [int]($acc[1] + (238 - $acc[1]) * $bandB)
                    $bb = [int]($acc[2] + (190 - $acc[2]) * $bandB)
                } else {
                    $hh = (($c * 73856093) -bxor (($r + ($Frame -shr 3)) * 19349663)) -band 0x7FFFFFFF
                    if (($hh % 60) -eq 0) {
                        $hit = $true; $ch = '.'
                        $br = [int]($bg[0] + ($acc[0] - $bg[0]) * 0.28)
                        $bgc = [int]($bg[1] + ($acc[1] - $bg[1]) * 0.28)
                        $bb = [int]($bg[2] + ($acc[2] - $bg[2]) * 0.28)
                    }
                }
            }
            elseif ($tid -eq 8) {
                # synthwave - a neon perspective grid receding to a horizon
                if ($r -ge $horizon) {
                    $depth = $r - $horizon + 1
                    $onLine = $false
                    if ($hl.ContainsKey($r)) { $onLine = $true }
                    else {
                        $span2 = [double]$depth * $slope
                        if ($span2 -gt 0.01) {
                            $kf = ($c - $cx) / $span2
                            $kr = [Math]::Round($kf)
                            if ([Math]::Abs($kr) -le $nrays -and [Math]::Abs($c - ($cx + $kr * $span2)) -lt 0.6) { $onLine = $true }
                        }
                    }
                    if ($onLine) {
                        $hit = $true
                        if ($hl.ContainsKey($r)) { $ch = '-' } else { $ch = '.' }
                        $col = Get-RampColor (($c % $w) / [double]$w)
                        $br = $col[0]; $bgc = $col[1]; $bb = $col[2]
                    }
                }
            }
            elseif ($tid -eq 9) {
                # ivory blueprint - a faint drafting-paper grid that breathes
                $onV = (($c % 8) -eq 0)
                $onH = (($r % 8) -eq 0)
                if ($onV -or $onH) {
                    $hit = $true
                    if ($onV -and $onH) { $ch = '+' } elseif ($onV) { $ch = '|' } else { $ch = '-' }
                    $breathe = 0.52 + 0.16 * [Math]::Sin($Frame * 0.08)
                    $br = [int]($bg[0] + ($dim[0] - $bg[0]) * $breathe)
                    $bgc = [int]($bg[1] + ($dim[1] - $bg[1]) * $breathe)
                    $bb = [int]($bg[2] + ($dim[2] - $bg[2]) * $breathe)
                }
            }
            elseif ($tid -eq 10) {
                # deep water - bubbles rising slowly from the depths, wobbling
                $yy = $r + ($Frame -shr 1)
                $xx = $c + ((($yy) -shr 2) % 3)
                $hh = (($xx * 73856093) -bxor ($yy * 19349663)) -band 0x7FFFFFFF
                if (($hh % 44) -eq 0) {
                    $hit = $true
                    $m = $hh % 4
                    if ($m -eq 0) { $ch = 'o' } elseif ($m -eq 1) { $ch = 'O' } elseif ($m -eq 2) { $ch = [char]0x00B0 } else { $ch = '.' }
                    $b = 0.4 + 0.55 * (($hh % 10) / 10.0)
                    $br = [int]($fnt[0] + ($acc[0] - $fnt[0]) * $b)
                    $bgc = [int]($fnt[1] + ($acc[1] - $fnt[1]) * $b)
                    $bb = [int]($fnt[2] + ($acc[2] - $fnt[2]) * $b)
                }
            }

            if (-not $hit) { [void]$sb.Append(' '); $lastKey = -999; $c++; continue }
            # readability halo + guaranteed clear border around the menu
            $fade = 1.0
            if ($haveBox) {
                $dx = 0
                if ($c -lt $minC) { $dx = $minC - $c } elseif ($c -gt $maxC) { $dx = $c - $maxC }
                $dist = $dx; if ($dy -gt $dist) { $dist = $dy }
                if ($dist -le $clearPad) { $fade = 0.0 }
                elseif ($dist -lt ($halo + $clearPad)) { $fade = ($dist - $clearPad) / $halo }
            }
            if ($fade -le 0.12) { [void]$sb.Append(' '); $lastKey = -999; $c++; continue }
            if ($fade -lt 1.0) {
                $br = [int]($bg[0] + ($br - $bg[0]) * $fade)
                $bgc = [int]($bg[1] + ($bgc - $bg[1]) * $fade)
                $bb = [int]($bg[2] + ($bb - $bg[2]) * $fade)
            }
            if ($br -lt 0) { $br = 0 } elseif ($br -gt 255) { $br = 255 }
            if ($bgc -lt 0) { $bgc = 0 } elseif ($bgc -gt 255) { $bgc = 255 }
            if ($bb -lt 0) { $bb = 0 } elseif ($bb -gt 255) { $bb = 255 }
            $key = $br * 65536 + $bgc * 256 + $bb
            if ($key -ne $lastKey) { [void]$sb.Append((Get-AnsiFg $br $bgc $bb)); $lastKey = $key }
            [void]$sb.Append($ch)
            $c++
        }
    }
    [void]$sb.Append($Script:Rst)
    # ONE write; a resize mid-frame just aborts this frame (Invoke-AmbientWait then
    # detects the new size and redraws) - it never latches the texture off.
    try { Write-Host -NoNewline $sb.ToString() } catch { return }
}

function Invoke-AmbientWait {
    # Animates the theme's backdrop around the menu until a key or resize.
    # Returns the ConsoleKeyInfo, or $null on resize (caller redraws recentered).
    $w0 = 0; $h0 = 0
    try { $w0 = [Console]::WindowWidth; $h0 = [Console]::WindowHeight } catch { return (Read-KeyOrResize) }
    $frame = 0
    while ($true) {
        if ($Script:AmbientDisabled) { return (Read-KeyOrResize) }
        try { if ([Console]::WindowWidth -ne $w0 -or [Console]::WindowHeight -ne $h0) { return $null } } catch { }
        if (Test-KeyAvailable) { return (Read-KeyOrResize) }
        Draw-TextureFrame $frame
        $frame++
        $end = [DateTime]::Now.AddMilliseconds(55)   # ~18fps, matching the boot rain
        while ([DateTime]::Now -lt $end) { if (Test-KeyAvailable) { break }; Start-Sleep -Milliseconds 8 }
    }
}

#endregion

#region ============================ ANIMATIONS ================================

function Get-BarStyleChars {
    # Each style: Empty char, 5 maturation Stages, and the Full char. Unicode
    # glyphs are built from code points so the script source stays pure ASCII.
    $style = 'density'
    try { $style = [string]$Script:Settings.barStyle } catch { }
    if ($style -eq 'blocks') {
        $lt = [string][char]0x2591; $md = [string][char]0x2592; $dk = [string][char]0x2593; $fl = [string][char]0x2588
        return @{ Empty = $lt; Stages = @($lt, $md, $md, $dk, $dk); Full = $fl }
    }
    if ($style -eq 'dots') {
        $fl = [string][char]0x25CF
        return @{ Empty = '.'; Stages = @('.', 'o', 'o', 'O', 'O'); Full = $fl }
    }
    if ($style -eq 'arrows') {
        return @{ Empty = '.'; Stages = @('.', '-', '-', '=', '='); Full = '>' }
    }
    return @{ Empty = '.'; Stages = @('.', ':', '=', '#', '%'); Full = '@' }   # density (default)
}

function Get-BarString([double]$Frac, [int]$Cells = 20) {
    # Cell-maturation bar: each cell owns an equal slice of the total (20 cells =
    # 5% each) and matures through the active style's ramp as its slice completes.
    # A full bar is solid Full glyphs; untouched cells are faint Empty glyphs.
    if ($Frac -lt 0) { $Frac = 0 }
    if ($Frac -gt 1) { $Frac = 1 }
    $sc = Get-BarStyleChars
    $stages = $sc.Stages
    $per = 1.0 / $Cells
    $eps = 0.000001   # float-noise guard so stage thresholds land exactly
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Cells; $i++) {
        $sub = ($Frac - ($i * $per)) / $per
        if ($sub -ge (1 - $eps)) {
            $ch = $sc.Full
        } elseif ($sub -le 0) {
            $ch = $sc.Empty
        } else {
            $ch = $stages[[Math]::Min(4, [int][Math]::Floor($sub * 5 + $eps))]
        }
        if ($Script:AnsiOn) {
            if ($sub -le 0) {
                $f = $Script:Theme.Faint
                [void]$sb.Append((Get-AnsiFg $f[0] $f[1] $f[2]))
            } else {
                $c = Get-RampColor ($i / [double][Math]::Max(1, $Cells - 1))
                [void]$sb.Append((Get-AnsiFg $c[0] $c[1] $c[2]))
            }
        }
        [void]$sb.Append($ch)
    }
    if ($Script:AnsiOn) { [void]$sb.Append($Script:Rst) }
    return $sb.ToString()
}

function Show-GradientWall {
    # Full-screen density cascade: pours diagonal ramp bands down the ENTIRE
    # terminal, then keeps printing past the bottom so the natural scroll of the
    # console animates the wall (the symbols shift as the screen moves).
    if (-not $Script:Settings.animations) { return }
    $ramp = $Script:DensityRamp
    $h = 30
    try { $h = [Math]::Max(12, [Console]::WindowHeight) } catch { }
    $w = (Get-ConWidth) - 2   # fill the width so the backdrop is seamless
    $rows = ($h - 1) + [int][Math]::Floor($h / 2)   # fill the screen, then scroll half a screen more
    $cycle = 36.0
    $pad = Get-CenterPad $w
    # precompute per-column gradient + edge-taper envelope once - the row loop
    # must stay cheap. The envelope thins the symbols non-linearly toward BOTH
    # sides, so the scrolling bands read as a 3D spiral descending a tube.
    $colPrefix = New-Object 'string[]' $w
    $colEnv = New-Object 'double[]' $w
    for ($c = 0; $c -lt $w; $c++) {
        $colPrefix[$c] = ''
        if ($Script:AnsiOn) {
            $col = Get-RampColor ($c / [double]$w)
            $colPrefix[$c] = Get-AnsiFg $col[0] $col[1] $col[2]
        }
        $x = $c / [double]([Math]::Max(1, $w - 1))
        $colEnv[$c] = [Math]::Pow([Math]::Sin([Math]::PI * $x), 1.7)
    }
    for ($r = 0; $r -lt $rows; $r++) {
        $sb = New-Object System.Text.StringBuilder
        for ($c = 0; $c -lt $w; $c++) {
            $phase = (($c + ($r * 5)) % $cycle) / $cycle
            $idx = [int][Math]::Round($phase * 9 * $colEnv[$c])
            if ($idx -lt 0) { $idx = 0 }
            if ($idx -gt 9) { $idx = 9 }
            [void]$sb.Append($colPrefix[$c]).Append($ramp[$idx])
        }
        if ($Script:AnsiOn) { [void]$sb.Append($Script:Rst) }
        Write-Host ($pad + $sb.ToString())
        if (Invoke-Nap 12) { return }
    }
    [void](Invoke-Nap 320)
}

function Get-StarfieldLine([int]$Width) {
    # Faint ambient backdrop strip - deterministic scatter, reads as a watermark.
    $chars = '.', '+', '*', "'", '.', '`'
    $sb = New-Object System.Text.StringBuilder
    $seed = 137
    for ($i = 0; $i -lt $Width; $i++) {
        $seed = ($seed * 1103515245 + 12345) -band 0x7FFFFFFF
        if (($seed % 17) -eq 0) { [void]$sb.Append($chars[$seed % 6]) }
        else { [void]$sb.Append(' ') }
    }
    return $sb.ToString()
}

function Get-IdentityRows {
    # Structured label/value rows; Role decides value coloring.
    if ($null -eq $Script:OsCache) {
        try { $Script:OsCache = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { $Script:OsCache = $null }
    }
    $osName = 'Windows'
    $osBuild = ''
    if ($Script:OsCache) {
        $osName = ([string]$Script:OsCache.Caption).Trim()
        $osBuild = [string]$Script:OsCache.BuildNumber
    }
    $osLine = $osName
    if ($osBuild) { $osLine = ('{0}  (build {1})' -f $osName, $osBuild) }
    $mode = 'LIMITED'
    if (Test-IsAdmin) { $mode = 'ELEVATED' }
    $hostVal = "$env:COMPUTERNAME"
    $alias = [string]$Script:Settings.machineAlias
    if ($alias) { $hostVal = ('{0}  ({1})' -f $alias, $env:COMPUTERNAME) }
    return @(
        @{ Label = 'HOST';   Value = $hostVal;                                 Role = 'txt' },
        @{ Label = 'USER';   Value = (Get-InvUserName);                         Role = 'txt' },
        @{ Label = 'OS';     Value = $osLine;                                   Role = 'txt' },
        @{ Label = 'MODE';   Value = ('[ ' + $mode + ' ]');                     Role = 'mode' },
        @{ Label = 'ENGINE'; Value = ('PowerShell ' + $PSVersionTable.PSVersion); Role = 'txt' },
        @{ Label = 'BUILD';  Value = (Get-BuildString);                         Role = 'txt' }
    )
}

function Show-IdentityBlock {
    # One fact per line: dim label column, faint divider, value. The block is
    # left-aligned internally but centered on screen as a whole.
    $rows = @(Get-IdentityRows)
    $labW = 0
    $maxLen = 0
    foreach ($r in $rows) { if ($r.Label.Length -gt $labW) { $labW = $r.Label.Length } }
    foreach ($r in $rows) {
        $len = $labW + 6 + $r.Value.Length
        if ($len -gt $maxLen) { $maxLen = $len }
    }
    $pad = Get-CenterPad $maxLen
    foreach ($r in $rows) {
        $val = Get-Txt $r.Value
        if ($r.Role -eq 'mode') {
            if ($r.Value -match 'ELEVATED') { $val = Get-Accent $r.Value }
            else { $val = Get-Warn $r.Value }
        }
        Record-MenuSpan $pad.Length ($labW + 6 + $r.Value.Length)
        Write-Host ($pad + (Get-Dim $r.Label.PadRight($labW)) + (Get-Faint '  ::  ') + $val)
    }
}

function Get-InvTagline {
    $t = [string]$Script:Settings.tagline
    if ($t) { return $t }
    return [string]$Script:Brand.Tagline
}

function Show-StarfieldBoot {
    # Sparse drifting starfield: prints ~1.5 screens of scattered stars so the
    # console's natural scroll carries them upward (a calm, deep-space intro).
    if (-not $Script:Settings.animations) { return }
    $w = (Get-ConWidth) - 2   # fill the width so the backdrop is seamless
    $h = 30
    try { $h = [Math]::Max(12, [Console]::WindowHeight) } catch { }
    $rows = ($h - 1) + [int][Math]::Floor($h / 2)
    $pad = Get-CenterPad $w
    $rnd = New-Object System.Random 20260720
    $starChars = @('.', "'", '.', '+', '.', '*')
    for ($r = 0; $r -lt $rows; $r++) {
        $sb = New-Object System.Text.StringBuilder
        for ($c = 0; $c -lt $w; $c++) {
            if ($rnd.Next(0, 100) -lt 6) {
                $ch = $starChars[$rnd.Next(0, $starChars.Count)]
                if ($Script:AnsiOn) {
                    if ($rnd.Next(0, 100) -lt 18) { $col = Get-RampColor ($c / [double]$w); [void]$sb.Append((Get-AnsiFg $col[0] $col[1] $col[2])) }
                    else { $fn = $Script:Theme.Faint; [void]$sb.Append((Get-AnsiFg $fn[0] $fn[1] $fn[2])) }
                }
                [void]$sb.Append($ch)
            } else { [void]$sb.Append(' ') }
        }
        if ($Script:AnsiOn) { [void]$sb.Append($Script:Rst) }
        Write-Host ($pad + $sb.ToString())
        if (Invoke-Nap 14) { return }
    }
    [void](Invoke-Nap 200)
}

function Show-MatrixRain {
    # Falling code rain, tinted to the ACTIVE palette (bright head, trail fading
    # from Accent to Faint). Full-frame repaint from the top each tick.
    if (-not $Script:Settings.animations) { return }
    $w = (Get-ConWidth) - 2   # fill the width so the backdrop is seamless
    $h = 22
    try { $h = [Math]::Max(12, [Console]::WindowHeight - 2) } catch { }
    $pad = Get-CenterPad $w
    $charset = '01{}[]<>/\|=+*!$#0123456789ABCDEF'
    $rnd = New-Object System.Random
    $head = New-Object 'int[]' $w
    $len = New-Object 'int[]' $w
    for ($c = 0; $c -lt $w; $c++) { $head[$c] = -$rnd.Next(0, $h); $len[$c] = 5 + $rnd.Next(0, 12) }
    $acc = $Script:Theme.Accent
    $fnt = $Script:Theme.Faint
    try { [Console]::CursorVisible = $false } catch { }
    for ($f = 0; $f -lt 42; $f++) {
        $sb = New-Object System.Text.StringBuilder
        for ($r = 0; $r -lt $h; $r++) {
            [void]$sb.Append($pad)
            for ($c = 0; $c -lt $w; $c++) {
                $d = $head[$c] - $r
                if ($d -ge 0 -and $d -lt $len[$c]) {
                    $ch = $charset[$rnd.Next(0, $charset.Length)]
                    if ($Script:AnsiOn) {
                        if ($d -eq 0) { [void]$sb.Append((Get-AnsiFg 224 255 224)) }
                        else {
                            $t = 1.0 - ($d / [double]$len[$c])
                            $rr = [int]($fnt[0] + ($acc[0] - $fnt[0]) * $t)
                            $gg = [int]($fnt[1] + ($acc[1] - $fnt[1]) * $t)
                            $bb = [int]($fnt[2] + ($acc[2] - $fnt[2]) * $t)
                            [void]$sb.Append((Get-AnsiFg $rr $gg $bb))
                        }
                    }
                    [void]$sb.Append($ch)
                } else { [void]$sb.Append(' ') }
            }
            if ($Script:AnsiOn) { [void]$sb.Append($Script:Rst) }
            if ($r -lt $h - 1) { [void]$sb.Append("`r`n") }
        }
        try { [Console]::SetCursorPosition(0, 0) } catch { return }
        Write-Host -NoNewline $sb.ToString()
        for ($c = 0; $c -lt $w; $c++) {
            $head[$c]++
            if (($head[$c] - $len[$c]) -gt $h) { $head[$c] = -$rnd.Next(0, 6); $len[$c] = 5 + $rnd.Next(0, 12) }
        }
        if (Invoke-Nap 55) { return }
    }
}

function Show-PyramidBuild {
    # The pyramid mark assembling itself, apex-first (the capstone leads). This is
    # the animated debut of the product mark, driven by the same grid art.
    if (-not $Script:Settings.animations) { return }
    $art = @(Get-LogoArt 'pyramid')
    $w = 0
    foreach ($l in $art) { if ($l.Length -gt $w) { $w = $l.Length } }
    $pad = Get-CenterPad $w
    Clear-Host
    Write-Host ''
    Write-Host ''
    foreach ($ln in $art) {
        Write-Host ($pad + (Format-GradientText $ln))
        if (Invoke-Nap 70) { break }
    }
    [void](Invoke-Nap 1050)   # let the finished mark linger a beat before the console loads
}

function Show-BootAnimation {
    # Dispatches the configured boot visual; guarded so a renderer fault can never
    # block the console (the caller clears the screen afterward regardless).
    if (-not $Script:Settings.animations) { return }
    $style = [string]$Script:Settings.bootStyle
    if ($style -eq 'random') {
        $opts = @('pillar', 'starfield', 'matrix', 'pyramid')
        $style = $opts[(New-Object System.Random).Next(0, $opts.Count)]
    }
    try {
        if     ($style -eq 'none')      { return }
        elseif ($style -eq 'starfield') { Show-StarfieldBoot }
        elseif ($style -eq 'matrix')    { Show-MatrixRain }
        elseif ($style -eq 'pyramid')   { Show-PyramidBuild }
        else                            { Show-GradientWall }
    } catch { }
}

function Show-BootSequence {
    if (-not $Script:Interactive) { return }
    if (-not $Script:Settings.bootSequence -or $NoLogo) { return }
    Clear-Host
    try { [Console]::CursorVisible = $false } catch { }
    Write-Host ''
    Show-BootAnimation
    Clear-Host
    Write-Host ''
    $sf = Get-StarfieldLine ([Math]::Min((Get-ConWidth) - 4, 72))
    Write-Host ((Get-CenterPad $sf.Length) + (Get-Faint $sf))
    $delay = 24
    if (-not $Script:Settings.animations) { $delay = 0 }
    Show-Logo $Script:Settings.logo $delay
    Write-Host ((Get-CenterPad $sf.Length) + (Get-Faint $sf))
    Write-Host ''
    Write-GradLine ('::  ' + $Script:Brand.Name + '  ::') -Center
    Write-DimLine ((Get-BuildString) + '  //  ' + (Get-InvTagline)) -Center
    Write-Host ''
    Show-IdentityBlock
    Write-Host ''
    [void](Invoke-Nap 700)
    Clear-KeyBuffer
}

#endregion

#region ============================ COLLECTORS ===============================
# Every collector returns an array of section hashtables:
#   @{ Name = 'SECTION TITLE'; View = 'Table'|'List'; Props = @(...); Rows = @(...) }

function Collect-System {
    $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $cs   = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $cpus = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $bb   = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $mem  = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue)

    $ramGB = 0
    if ($mem.Count -gt 0) { $ramGB = [Math]::Round((($mem | Measure-Object -Property Capacity -Sum).Sum) / 1GB, 1) }
    $cpu0 = $null
    if ($cpus.Count -gt 0) { $cpu0 = $cpus[0] }
    $uptime = (Get-Date) - $os.LastBootUpTime

    $cpuName = ''
    $cpuCores = ''
    if ($cpu0) {
        $cpuName  = ([string]$cpu0.Name).Trim()
        $cpuCores = ('{0} cores / {1} threads' -f $cpu0.NumberOfCores, $cpu0.NumberOfLogicalProcessors)
    }
    $ident = [PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        User         = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        OS           = ([string]$os.Caption).Trim()
        Version      = ('{0}  (build {1})' -f $os.Version, $os.BuildNumber)
        Architecture = $os.OSArchitecture
        InstallDate  = $os.InstallDate.ToString('yyyy-MM-dd')
        LastBoot     = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        Uptime       = ('{0}d {1}h {2}m' -f [int]$uptime.Days, $uptime.Hours, $uptime.Minutes)
        Manufacturer = "$($cs.Manufacturer)"
        Model        = "$($cs.Model)"
        CPU          = $cpuName
        Cores        = $cpuCores
        RAM          = ('{0} GB  ({1} modules)' -f $ramGB, $mem.Count)
        BIOS         = ('{0} {1}' -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion)
        Motherboard  = ('{0} {1}' -f $bb.Manufacturer, $bb.Product)
        TimeZone     = (Get-TimeZone).DisplayName
    }

    $gpuRows = @(foreach ($g in $gpus) {
        $res = ''
        if ($g.CurrentHorizontalResolution) { $res = ('{0}x{1}' -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution) }
        [PSCustomObject]@{
            Name          = $g.Name
            DriverVersion = $g.DriverVersion
            Resolution    = $res
        }
    })
    $memRows = @(foreach ($m in $mem) {
        [PSCustomObject]@{
            Slot         = $m.DeviceLocator
            CapacityGB   = [Math]::Round($m.Capacity / 1GB, 1)
            SpeedMTs     = $m.Speed
            Manufacturer = "$($m.Manufacturer)".Trim()
            PartNumber   = "$($m.PartNumber)".Trim()
        }
    })
    return @(
        @{ Name = 'MACHINE IDENTITY';  View = 'List';  Rows = @($ident) },
        @{ Name = 'GRAPHICS ADAPTERS'; View = 'Table'; Props = @('Name','DriverVersion','Resolution'); Rows = $gpuRows },
        @{ Name = 'MEMORY MODULES';    View = 'Table'; Props = @('Slot','CapacityGB','SpeedMTs','Manufacturer','PartNumber'); Rows = $memRows }
    )
}

function Collect-InstalledApps {
    $sources = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Src = 'HKLM64' },
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Src = 'HKLM32' },
        @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*';             Src = 'HKCU'   }
    )
    $rows = @()
    foreach ($s in $sources) {
        $items = @(Get-ItemProperty -Path $s.Path -ErrorAction SilentlyContinue)
        foreach ($it in $items) {
            if (-not $it.DisplayName) { continue }
            if ($it.SystemComponent -eq 1) { continue }
            $date = ''
            if ($it.InstallDate -and ("$($it.InstallDate)" -match '^\d{8}$')) {
                try { $date = [datetime]::ParseExact("$($it.InstallDate)", 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { $date = "$($it.InstallDate)" }
            }
            $size = ''
            if ($it.EstimatedSize) { $size = [Math]::Round($it.EstimatedSize / 1024, 1) }
            $rows += [PSCustomObject]@{
                Name        = "$($it.DisplayName)".Trim()
                Version     = "$($it.DisplayVersion)"
                Publisher   = "$($it.Publisher)"
                InstallDate = $date
                SizeMB      = $size
                Src         = $s.Src
            }
        }
    }
    $rows = @($rows | Group-Object { $_.Name + '|' + $_.Version } | ForEach-Object { $_.Group[0] } | Sort-Object Name)
    return @(
        @{ Name = 'INSTALLED PROGRAMS'; View = 'Table'; Props = @('Name','Version','Publisher','InstallDate','SizeMB','Src'); Rows = $rows }
    )
}

function Collect-StoreApps {
    $elev = Test-IsAdmin
    if ($elev) { $pk = @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
    else       { $pk = @(Get-AppxPackage -ErrorAction Stop) }
    $mk = {
        param($p)
        [PSCustomObject]@{
            Name         = $p.Name
            Version      = "$($p.Version)"
            Architecture = "$($p.Architecture)"
            Publisher    = "$($p.Publisher)"
        }
    }
    $apps = @($pk | Where-Object { -not $_.IsFramework } | ForEach-Object { & $mk $_ } | Sort-Object Name)
    $fw   = @($pk | Where-Object { $_.IsFramework }      | ForEach-Object { & $mk $_ } | Sort-Object Name -Unique)
    $scope = ' (ALL USERS)'
    if (-not $elev) { $scope = ' (CURRENT USER ONLY - run elevated for all users)' }
    return @(
        @{ Name = ('STORE / UWP APPS' + $scope); View = 'Table'; Props = @('Name','Version','Architecture','Publisher'); Rows = $apps },
        @{ Name = 'FRAMEWORK PACKAGES';          View = 'Table'; Props = @('Name','Version','Architecture'); Rows = $fw }
    )
}

function Collect-DriversSigned {
    $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName })
    $rows = @(foreach ($d in $drv) {
        $date = ''
        if ($d.DriverDate) { try { $date = $d.DriverDate.ToString('yyyy-MM-dd') } catch { } }
        [PSCustomObject]@{
            Device   = "$($d.DeviceName)".Trim()
            Provider = "$($d.DriverProviderName)"
            Version  = "$($d.DriverVersion)"
            Date     = $date
            Class    = "$($d.DeviceClass)"
            Inf      = "$($d.InfName)"
        }
    })
    $rows = @($rows | Group-Object { $_.Device + '|' + $_.Version + '|' + $_.Inf } |
        ForEach-Object { $_.Group[0] } | Sort-Object Class, Device)
    return @(
        @{ Name = 'SIGNED DEVICE DRIVERS'; View = 'Table'; Props = @('Device','Provider','Version','Date','Class','Inf'); Rows = $rows }
    )
}

function Collect-DriverStore {
    $raw = @(& pnputil.exe /enum-drivers)
    if (-not $raw -or $raw.Count -lt 3) { throw 'pnputil returned no data' }
    $rows = @()
    $block = @{}
    $flush = {
        if ($block.Count -gt 0) {
            $vals = @($block.Values)
            $get = { param($k) if ($block.ContainsKey($k)) { return [string]$block[$k] } return '' }
            $r = [PSCustomObject]@{
                Published = & $get 'Published Name'
                Original  = & $get 'Original Name'
                Provider  = & $get 'Provider Name'
                Class     = & $get 'Class Name'
                Version   = & $get 'Driver Version'
            }
            if (-not $r.Published -and $vals.Count -gt 0) { $r.Published = [string]$vals[0] }
            $Script:__dsRows += $r
        }
    }
    $Script:__dsRows = @()
    foreach ($line in $raw) {
        $l = "$line".Trim()
        if ($l -eq '') { & $flush; $block = @{} ; continue }
        if ($l -match '^(.+?):\s+(.*)$') {
            $block[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    & $flush
    $rows = @($Script:__dsRows | Where-Object { $_.Published -match '\.inf$' -or $_.Original } | Sort-Object Provider, Original)
    Remove-Variable -Name '__dsRows' -Scope Script -ErrorAction SilentlyContinue
    return @(
        @{ Name = 'DRIVER STORE PACKAGES'; View = 'Table'; Props = @('Published','Original','Provider','Class','Version'); Rows = $rows }
    )
}

function Collect-WindowsFeatures {
    $f = @(Get-WindowsOptionalFeature -Online -ErrorAction Stop)
    $mk = { param($x) [PSCustomObject]@{ FeatureName = $x.FeatureName; State = "$($x.State)" } }
    $on  = @($f | Where-Object { "$($_.State)" -eq 'Enabled' }  | ForEach-Object { & $mk $_ } | Sort-Object FeatureName)
    $off = @($f | Where-Object { "$($_.State)" -ne 'Enabled' }  | ForEach-Object { & $mk $_ } | Sort-Object FeatureName)
    return @(
        @{ Name = 'ENABLED FEATURES';  View = 'Table'; Props = @('FeatureName','State'); Rows = $on },
        @{ Name = 'DISABLED FEATURES'; View = 'Table'; Props = @('FeatureName','State'); Rows = $off }
    )
}

function Collect-WindowsCapabilities {
    $c = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { "$($_.State)" -eq 'Installed' })
    $rows = @($c | ForEach-Object { [PSCustomObject]@{ Name = $_.Name; State = "$($_.State)" } } | Sort-Object Name)
    return @(
        @{ Name = 'INSTALLED CAPABILITIES'; View = 'Table'; Props = @('Name','State'); Rows = $rows }
    )
}

function Collect-Updates {
    $hot = @(Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending)
    $hotRows = @(foreach ($h in $hot) {
        $d = ''
        if ($h.InstalledOn) { try { $d = $h.InstalledOn.ToString('yyyy-MM-dd') } catch { } }
        [PSCustomObject]@{
            HotFixID    = $h.HotFixID
            Description = "$($h.Description)"
            InstalledOn = $d
            InstalledBy = "$($h.InstalledBy)"
        }
    })
    $histRows = @()
    try {
        $sess = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher = $sess.CreateUpdateSearcher()
        $total = $searcher.GetTotalHistoryCount()
        $take = [Math]::Min($total, 300)
        if ($take -gt 0) {
            $hist = $searcher.QueryHistory(0, $take)
            $resultMap = @{ 0 = 'NotStarted'; 1 = 'InProgress'; 2 = 'Succeeded'; 3 = 'SucceededWithErrors'; 4 = 'Failed'; 5 = 'Aborted' }
            foreach ($e in $hist) {
                if (-not $e.Title) { continue }
                $res = "$($e.ResultCode)"
                if ($resultMap.ContainsKey([int]$e.ResultCode)) { $res = $resultMap[[int]$e.ResultCode] }
                $histRows += [PSCustomObject]@{
                    Date   = $e.Date.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                    Result = $res
                    Title  = "$($e.Title)"
                }
            }
        }
    } catch { }
    return @(
        @{ Name = 'INSTALLED HOTFIXES';             View = 'Table'; Props = @('HotFixID','Description','InstalledOn','InstalledBy'); Rows = $hotRows },
        @{ Name = 'WINDOWS UPDATE HISTORY (LATEST 300)'; View = 'Table'; Props = @('Date','Result','Title'); Rows = $histRows }
    )
}

function Collect-Services {
    $svc = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    $rows = @($svc | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            State       = "$($_.State)"
            StartMode   = "$($_.StartMode)"
            DisplayName = "$($_.DisplayName)"
            Account     = "$($_.StartName)"
            Path        = "$($_.PathName)"
        }
    } | Sort-Object Name)
    return @(
        @{ Name = 'SERVICES'; View = 'Table'; Props = @('Name','State','StartMode','DisplayName'); Rows = $rows }
    )
}

function Collect-Startup {
    $rows = @()
    $regSpots = @(
        @{ K = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 L = 'HKLM Run' },
        @{ K = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';             L = 'HKLM RunOnce' },
        @{ K = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     L = 'HKLM Run (32-bit)' },
        @{ K = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 L = 'HKCU Run' },
        @{ K = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce';             L = 'HKCU RunOnce' }
    )
    foreach ($spot in $regSpots) {
        $p = Get-ItemProperty -Path $spot.K -ErrorAction SilentlyContinue
        if ($null -eq $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -match '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { continue }
            $rows += [PSCustomObject]@{ Entry = $prop.Name; Command = "$($prop.Value)"; Location = $spot.L }
        }
    }
    $folders = @(
        @{ P = [Environment]::GetFolderPath('Startup');       L = 'Startup folder (user)' },
        @{ P = [Environment]::GetFolderPath('CommonStartup'); L = 'Startup folder (common)' }
    )
    foreach ($f in $folders) {
        if ($f.P -and (Test-Path -LiteralPath $f.P)) {
            foreach ($file in @(Get-ChildItem -LiteralPath $f.P -File -ErrorAction SilentlyContinue)) {
                if ($file.Name -eq 'desktop.ini') { continue }
                $rows += [PSCustomObject]@{ Entry = $file.Name; Command = $file.FullName; Location = $f.L }
            }
        }
    }
    $wmiRows = @()
    try {
        $wmiRows = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ Entry = $_.Name; Command = "$($_.Command)"; Location = "$($_.Location)"; User = "$($_.User)" }
        })
    } catch { }
    return @(
        @{ Name = 'STARTUP ENTRIES (REGISTRY + FOLDERS)'; View = 'Table'; Props = @('Entry','Command','Location'); Rows = @($rows | Sort-Object Location, Entry) },
        @{ Name = 'WMI STARTUP VIEW';                      View = 'Table'; Props = @('Entry','Command','Location','User'); Rows = $wmiRows }
    )
}

function Collect-ScheduledTasks {
    $tasks = @(Get-ScheduledTask -ErrorAction Stop)
    $mk = { param($t) [PSCustomObject]@{ TaskName = $t.TaskName; State = "$($t.State)"; TaskPath = $t.TaskPath } }
    $custom = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object { & $mk $_ } | Sort-Object TaskPath, TaskName)
    $all    = @($tasks | ForEach-Object { & $mk $_ } | Sort-Object TaskPath, TaskName)
    return @(
        @{ Name = 'THIRD-PARTY AND CUSTOM TASKS'; View = 'Table'; Props = @('TaskName','State','TaskPath'); Rows = $custom },
        @{ Name = 'FULL TASK LIST';               View = 'Table'; Props = @('TaskName','State','TaskPath'); Rows = $all }
    )
}

function Collect-Network {
    $adRows = @()
    try {
        $adRows = @(Get-NetAdapter -ErrorAction Stop | Sort-Object ifIndex | ForEach-Object {
            [PSCustomObject]@{
                Name        = $_.Name
                Status      = "$($_.Status)"
                LinkSpeed   = "$($_.LinkSpeed)"
                MacAddress  = "$($_.MacAddress)"
                Description = "$($_.InterfaceDescription)"
            }
        })
    } catch { }
    $ipRows = @()
    try {
        $ipRows = @(Get-NetIPConfiguration -ErrorAction Stop | ForEach-Object {
            $dns = @()
            foreach ($d in @($_.DNSServer)) { $dns += @($d.ServerAddresses) }
            $gw = @()
            foreach ($g in @($_.IPv4DefaultGateway)) { if ($g) { $gw += "$($g.NextHop)" } }
            [PSCustomObject]@{
                Interface = $_.InterfaceAlias
                IPv4      = (@($_.IPv4Address | ForEach-Object { "$($_.IPAddress)" }) -join ', ')
                Gateway   = ($gw -join ', ')
                DNS       = (@($dns | Select-Object -Unique) -join ', ')
            }
        })
    } catch { }
    return @(
        @{ Name = 'NETWORK ADAPTERS';  View = 'Table'; Props = @('Name','Status','LinkSpeed','MacAddress','Description'); Rows = $adRows },
        @{ Name = 'IP CONFIGURATION';  View = 'Table'; Props = @('Interface','IPv4','Gateway','DNS'); Rows = $ipRows }
    )
}

function Collect-Storage {
    $diskRows = @()
    $volRows = @()
    try {
        $diskRows = @(Get-Disk -ErrorAction Stop | Sort-Object Number | ForEach-Object {
            [PSCustomObject]@{
                Number = $_.Number
                Model  = "$($_.FriendlyName)"
                Bus    = "$($_.BusType)"
                SizeGB = [Math]::Round($_.Size / 1GB, 1)
                Style  = "$($_.PartitionStyle)"
                Health = "$($_.HealthStatus)"
            }
        })
        $volRows = @(Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
            $pct = ''
            if ($_.Size -gt 0) { $pct = [Math]::Round(($_.SizeRemaining / $_.Size) * 100, 0) }
            [PSCustomObject]@{
                Drive   = "$($_.DriveLetter):"
                Label   = "$($_.FileSystemLabel)"
                FS      = "$($_.FileSystem)"
                SizeGB  = [Math]::Round($_.Size / 1GB, 1)
                FreeGB  = [Math]::Round($_.SizeRemaining / 1GB, 1)
                FreePct = $pct
            }
        })
    } catch {
        $volRows = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
            [PSCustomObject]@{
                Drive   = $_.DeviceID
                Label   = "$($_.VolumeName)"
                FS      = "$($_.FileSystem)"
                SizeGB  = [Math]::Round($_.Size / 1GB, 1)
                FreeGB  = [Math]::Round($_.FreeSpace / 1GB, 1)
                FreePct = ''
            }
        })
    }
    return @(
        @{ Name = 'PHYSICAL DISKS'; View = 'Table'; Props = @('Number','Model','Bus','SizeGB','Style','Health'); Rows = $diskRows },
        @{ Name = 'VOLUMES';        View = 'Table'; Props = @('Drive','Label','FS','SizeGB','FreeGB','FreePct'); Rows = $volRows }
    )
}

function Collect-DevRuntimes {
    $rows = @()
    $rows += [PSCustomObject]@{ Tool = 'PowerShell'; Version = "$($PSVersionTable.PSVersion)"; Detail = "$($PSVersionTable.PSEdition) edition" }
    try {
        $ndp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        $rows += [PSCustomObject]@{ Tool = '.NET Framework'; Version = "$($ndp.Version)"; Detail = "Release $($ndp.Release)" }
    } catch { }
    $probes = @(
        @{ Cmd = 'dotnet'; Args = @('--version');  Tool = '.NET SDK (active)' },
        @{ Cmd = 'winget'; Args = @('--version');  Tool = 'winget' },
        @{ Cmd = 'git';    Args = @('--version');  Tool = 'git' },
        @{ Cmd = 'node';   Args = @('--version');  Tool = 'Node.js' },
        @{ Cmd = 'python'; Args = @('--version');  Tool = 'Python' },
        @{ Cmd = 'choco';  Args = @('--version');  Tool = 'Chocolatey' }
    )
    foreach ($p in $probes) {
        $gc = Get-Command $p.Cmd -ErrorAction SilentlyContinue
        if ($null -eq $gc) { continue }
        $verOut = @()
        try { $verOut = @(cmd /c ($p.Cmd + ' ' + ($p.Args -join ' ') + ' 2>nul')) } catch { }
        if ($LASTEXITCODE -ne 0) { continue }
        $ver = ([string](($verOut | Where-Object { $_ }) -join ' ')).Trim()
        if (-not $ver) { $ver = 'detected' }
        $src = ''
        try { $src = $gc.Source } catch { }
        $rows += [PSCustomObject]@{ Tool = $p.Tool; Version = $ver; Detail = $src }
    }
    if (Get-Command 'scoop' -ErrorAction SilentlyContinue) {
        $rows += [PSCustomObject]@{ Tool = 'Scoop'; Version = 'detected'; Detail = "$env:USERPROFILE\scoop" }
    }
    $sdkRows = @()
    if (Get-Command 'dotnet' -ErrorAction SilentlyContinue) {
        try {
            $sdkOut = @(cmd /c 'dotnet --list-sdks 2>nul')
            if ($LASTEXITCODE -eq 0) {
                foreach ($l in $sdkOut) {
                    if ("$l" -match '^(\S+)\s+\[(.+)\]$') {
                        $sdkRows += [PSCustomObject]@{ Kind = 'SDK'; Version = $Matches[1]; Path = $Matches[2] }
                    }
                }
            }
            $rtOut = @(cmd /c 'dotnet --list-runtimes 2>nul')
            if ($LASTEXITCODE -eq 0) {
                foreach ($l in $rtOut) {
                    if ("$l" -match '^(\S+)\s+(\S+)\s+\[(.+)\]$') {
                        $sdkRows += [PSCustomObject]@{ Kind = $Matches[1]; Version = $Matches[2]; Path = $Matches[3] }
                    }
                }
            }
        } catch { }
    }
    $modRows = @()
    foreach ($root in ($env:PSModulePath -split ';')) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $ver = ''
            $sub = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
                Sort-Object { [version]$_.Name } -Descending)
            if ($sub.Count -gt 0) { $ver = $sub[0].Name }
            $modRows += [PSCustomObject]@{ Name = $dir.Name; Version = $ver; Location = $root }
        }
    }
    $modRows = @($modRows | Group-Object Name | ForEach-Object { $_.Group[0] } | Sort-Object Name)
    return @(
        @{ Name = 'TOOLING AND RUNTIMES';   View = 'Table'; Props = @('Tool','Version','Detail'); Rows = $rows },
        @{ Name = '.NET SDKS AND RUNTIMES'; View = 'Table'; Props = @('Kind','Version','Path'); Rows = $sdkRows },
        @{ Name = 'POWERSHELL MODULES';     View = 'Table'; Props = @('Name','Version','Location'); Rows = $modRows }
    )
}

function Collect-Environment {
    $mk = {
        param($dict)
        $out = @()
        foreach ($k in ($dict.Keys | Sort-Object)) {
            $out += [PSCustomObject]@{ Name = $k; Value = "$($dict[$k])" }
        }
        return $out
    }
    $mach = & $mk ([Environment]::GetEnvironmentVariables('Machine'))
    $user = & $mk ([Environment]::GetEnvironmentVariables('User'))
    $pathM = @()
    $pathU = @()
    try { $pathM = @(([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';') | Where-Object { $_ } | ForEach-Object { [PSCustomObject]@{ Entry = $_ } }) } catch { }
    try { $pathU = @(([Environment]::GetEnvironmentVariable('Path', 'User') -split ';')    | Where-Object { $_ } | ForEach-Object { [PSCustomObject]@{ Entry = $_ } }) } catch { }
    return @(
        @{ Name = 'MACHINE VARIABLES'; View = 'Table'; Props = @('Name','Value'); Rows = @($mach) },
        @{ Name = 'USER VARIABLES';    View = 'Table'; Props = @('Name','Value'); Rows = @($user) },
        @{ Name = 'PATH (MACHINE)';    View = 'Table'; Props = @('Entry'); Rows = $pathM },
        @{ Name = 'PATH (USER)';       View = 'Table'; Props = @('Entry'); Rows = $pathU }
    )
}

function Collect-Security {
    # Every probe is individually guarded - a missing module or denied read
    # becomes an informational row, never a dead category.
    $defRows = @()
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $defRows += [PSCustomObject]@{ Setting = 'Antivirus enabled';       Value = "$($mp.AntivirusEnabled)" }
        $defRows += [PSCustomObject]@{ Setting = 'Real-time protection';    Value = "$($mp.RealTimeProtectionEnabled)" }
        $defRows += [PSCustomObject]@{ Setting = 'Tamper protection';       Value = "$($mp.IsTamperProtected)" }
        $defRows += [PSCustomObject]@{ Setting = 'Antivirus signature age'; Value = ("$($mp.AntivirusSignatureAge) days") }
        $defRows += [PSCustomObject]@{ Setting = 'Last quick scan end';     Value = "$($mp.QuickScanEndTime)" }
    } catch { $defRows += [PSCustomObject]@{ Setting = 'Defender status'; Value = ('unavailable - ' + "$($_.Exception.Message)".Trim()) } }

    $excRows = @()
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        foreach ($p in @($pref.ExclusionPath))      { if ($p) { $excRows += [PSCustomObject]@{ Kind = 'Path';      Exclusion = "$p" } } }
        foreach ($p in @($pref.ExclusionExtension)) { if ($p) { $excRows += [PSCustomObject]@{ Kind = 'Extension'; Exclusion = "$p" } } }
        foreach ($p in @($pref.ExclusionProcess))   { if ($p) { $excRows += [PSCustomObject]@{ Kind = 'Process';   Exclusion = "$p" } } }
        if ($excRows.Count -eq 0) { $excRows += [PSCustomObject]@{ Kind = '-'; Exclusion = 'no exclusions configured' } }
    } catch { $excRows += [PSCustomObject]@{ Kind = '-'; Exclusion = ('unavailable - ' + "$($_.Exception.Message)".Trim()) } }

    $fwRows = @()
    try {
        foreach ($p in @(Get-NetFirewallProfile -ErrorAction Stop)) {
            $fwRows += [PSCustomObject]@{ Profile = "$($p.Name)"; Enabled = "$($p.Enabled)"; Inbound = "$($p.DefaultInboundAction)"; Outbound = "$($p.DefaultOutboundAction)" }
        }
    } catch { $fwRows += [PSCustomObject]@{ Profile = '-'; Enabled = ('unavailable - ' + "$($_.Exception.Message)".Trim()); Inbound = ''; Outbound = '' } }

    $blRows = @()
    try {
        foreach ($v in @(Get-BitLockerVolume -ErrorAction Stop)) {
            $blRows += [PSCustomObject]@{ Volume = "$($v.MountPoint)"; Protection = "$($v.ProtectionStatus)"; Method = "$($v.EncryptionMethod)"; Encrypted = ("$($v.EncryptionPercentage)%") }
        }
    } catch { $blRows += [PSCustomObject]@{ Volume = '-'; Protection = 'unavailable - requires elevation'; Method = ''; Encrypted = '' } }

    $plRows = @()
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        $plRows += [PSCustomObject]@{ Item = 'TPM present'; Value = "$($tpm.TpmPresent)" }
        $plRows += [PSCustomObject]@{ Item = 'TPM ready';   Value = "$($tpm.TpmReady)" }
    } catch { $plRows += [PSCustomObject]@{ Item = 'TPM'; Value = 'unavailable - requires elevation' } }
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        $plRows += [PSCustomObject]@{ Item = 'Secure Boot'; Value = "$sb" }
    } catch { $plRows += [PSCustomObject]@{ Item = 'Secure Boot'; Value = 'unsupported (legacy BIOS) or requires elevation' } }
    try {
        $uac = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
        $plRows += [PSCustomObject]@{ Item = 'UAC enabled';               Value = "$([bool][int]$uac.EnableLUA)" }
        $plRows += [PSCustomObject]@{ Item = 'UAC admin prompt behavior'; Value = "$($uac.ConsentPromptBehaviorAdmin)" }
    } catch { $plRows += [PSCustomObject]@{ Item = 'UAC'; Value = 'unavailable' } }

    return @(
        @{ Name = 'MICROSOFT DEFENDER';  View = 'Table'; Props = @('Setting','Value');                         Rows = @($defRows) },
        @{ Name = 'DEFENDER EXCLUSIONS'; View = 'Table'; Props = @('Kind','Exclusion');                        Rows = @($excRows) },
        @{ Name = 'FIREWALL PROFILES';   View = 'Table'; Props = @('Profile','Enabled','Inbound','Outbound');  Rows = @($fwRows) },
        @{ Name = 'DRIVE ENCRYPTION';    View = 'Table'; Props = @('Volume','Protection','Method','Encrypted'); Rows = @($blRows) },
        @{ Name = 'PLATFORM SECURITY';   View = 'Table'; Props = @('Item','Value');                            Rows = @($plRows) }
    )
}

function Get-ChromiumProfileDirs([string]$Root) {
    # Chrome/Edge/Brave keep profiles under "User Data\<Default|Profile N>";
    # Opera and Opera GX ARE the profile folder (Extensions sits at the root).
    $out = @()
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    if (Test-Path -LiteralPath (Join-Path $Root 'Extensions')) { $out += @{ Name = 'Default'; Path = $Root } }
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name -eq 'Default' -or $d.Name -like 'Profile *') {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'Extensions')) { $out += @{ Name = $d.Name; Path = $d.FullName } }
        }
    }
    return @($out)
}

function Resolve-ChromiumExtName([string]$VerDir, $Manifest) {
    # Localized names look like __MSG_appName__ - resolve via _locales messages.
    $name = [string]$Manifest.name
    if ($name -notmatch '^__MSG_(.+)__$') { return $name }
    $key = $Matches[1]
    $locales = @()
    if ($Manifest.default_locale) { $locales += [string]$Manifest.default_locale }
    $locales += 'en', 'en_US'
    foreach ($loc in @($locales | Select-Object -Unique)) {
        $mp = Join-Path $VerDir ('_locales\' + $loc + '\messages.json')
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        try {
            $msgs = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            $prop = @($msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key }) | Select-Object -First 1
            if ($prop -and $prop.Value.message) { return [string]$prop.Value.message }
        } catch { }
    }
    return ''
}

function Collect-BrowserExtensions {
    # Per-user inventory (the current profile). Chromium family + Firefox.
    $browsers = @(
        @{ B = 'Chrome';   Root = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') },
        @{ B = 'Edge';     Root = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') },
        @{ B = 'Brave';    Root = (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data') },
        @{ B = 'Opera';    Root = (Join-Path $env:APPDATA 'Opera Software\Opera Stable') },
        @{ B = 'Opera GX'; Root = (Join-Path $env:APPDATA 'Opera Software\Opera GX Stable') }
    )
    $sections = @()
    foreach ($br in $browsers) {
        $rows = @()
        foreach ($prof in @(Get-ChromiumProfileDirs ([string]$br.Root))) {
            $extRoot = Join-Path $prof.Path 'Extensions'
            foreach ($extDir in @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) {
                if ($extDir.Name -eq 'Temp') { continue }
                $verDirs = @(Get-ChildItem -LiteralPath $extDir.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                if ($verDirs.Count -eq 0) { continue }
                $manPath = Join-Path $verDirs[0].FullName 'manifest.json'
                if (-not (Test-Path -LiteralPath $manPath)) { continue }
                $man = $null
                try { $man = Get-Content -LiteralPath $manPath -Raw | ConvertFrom-Json } catch { }
                if ($null -eq $man) { continue }
                $nm = Resolve-ChromiumExtName ([string]$verDirs[0].FullName) $man
                if (-not $nm) { $nm = $extDir.Name }
                $rows += [PSCustomObject]@{ Profile = $prof.Name; Name = $nm; Version = "$($man.version)"; Id = $extDir.Name }
            }
        }
        if ($rows.Count -gt 0) {
            $sections += @{ Name = ($br.B.ToUpper() + ' EXTENSIONS'); View = 'Table'; Props = @('Profile','Name','Version','Id'); Rows = @($rows | Sort-Object Name) }
        }
    }
    $ffRows = @()
    $ffRoot = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ffRoot) {
        foreach ($prof in @(Get-ChildItem -LiteralPath $ffRoot -Directory -ErrorAction SilentlyContinue)) {
            $extFile = Join-Path $prof.FullName 'extensions.json'
            if (-not (Test-Path -LiteralPath $extFile)) { continue }
            try {
                $j = Get-Content -LiteralPath $extFile -Raw | ConvertFrom-Json
                foreach ($a in @($j.addons)) {
                    if ("$($a.type)" -ne 'extension') { continue }
                    $nm = ''
                    if ($a.defaultLocale -and $a.defaultLocale.name) { $nm = [string]$a.defaultLocale.name }
                    if (-not $nm) { $nm = [string]$a.id }
                    $ffRows += [PSCustomObject]@{ Profile = $prof.Name; Name = $nm; Version = "$($a.version)"; Enabled = "$($a.active)" }
                }
            } catch { }
        }
    }
    if ($ffRows.Count -gt 0) {
        $sections += @{ Name = 'FIREFOX EXTENSIONS'; View = 'Table'; Props = @('Profile','Name','Version','Enabled'); Rows = @($ffRows | Sort-Object Name) }
    }
    if ($sections.Count -eq 0) {
        $sections += @{ Name = 'BROWSER EXTENSIONS'; View = 'Table'; Props = @('Info'); Rows = @([PSCustomObject]@{ Info = 'no supported browser profiles found for the current user' }) }
    }
    return @($sections)
}

$Script:CollectorRegistry = @(
    @{ Num = '01'; Id = 'SYSTEM';               Title = 'SYSTEM OVERVIEW';        Admin = $false; Fn = { Collect-System } },
    @{ Num = '02'; Id = 'APPS_INSTALLED';       Title = 'INSTALLED PROGRAMS';     Admin = $false; Fn = { Collect-InstalledApps } },
    @{ Num = '03'; Id = 'APPS_STORE';           Title = 'MICROSOFT STORE APPS';   Admin = $true;  Fn = { Collect-StoreApps } },
    @{ Num = '04'; Id = 'DRIVERS_SIGNED';       Title = 'DEVICE DRIVERS';         Admin = $false; Fn = { Collect-DriversSigned } },
    @{ Num = '05'; Id = 'DRIVER_STORE';         Title = 'DRIVER STORE';           Admin = $true;  Fn = { Collect-DriverStore } },
    @{ Num = '06'; Id = 'WINDOWS_FEATURES';     Title = 'WINDOWS FEATURES';       Admin = $true;  Fn = { Collect-WindowsFeatures } },
    @{ Num = '07'; Id = 'WINDOWS_CAPABILITIES'; Title = 'WINDOWS CAPABILITIES';   Admin = $true;  Fn = { Collect-WindowsCapabilities } },
    @{ Num = '08'; Id = 'UPDATES';              Title = 'UPDATES AND HOTFIXES';   Admin = $false; Fn = { Collect-Updates } },
    @{ Num = '09'; Id = 'SERVICES';             Title = 'SERVICES';               Admin = $false; Fn = { Collect-Services } },
    @{ Num = '10'; Id = 'STARTUP';              Title = 'STARTUP ITEMS';          Admin = $false; Fn = { Collect-Startup } },
    @{ Num = '11'; Id = 'SCHEDULED_TASKS';      Title = 'SCHEDULED TASKS';        Admin = $false; Fn = { Collect-ScheduledTasks } },
    @{ Num = '12'; Id = 'NETWORK';              Title = 'NETWORK';                Admin = $false; Fn = { Collect-Network } },
    @{ Num = '13'; Id = 'STORAGE';              Title = 'STORAGE';                Admin = $false; Fn = { Collect-Storage } },
    @{ Num = '14'; Id = 'DEV_RUNTIMES';         Title = 'DEV RUNTIMES + TOOLING'; Admin = $false; Fn = { Collect-DevRuntimes } },
    @{ Num = '15'; Id = 'ENVIRONMENT';          Title = 'ENVIRONMENT VARIABLES';  Admin = $false; Fn = { Collect-Environment } },
    @{ Num = '16'; Id = 'SECURITY';             Title = 'SECURITY POSTURE';       Admin = $true;  Fn = { Collect-Security } },
    @{ Num = '17'; Id = 'BROWSER_EXTENSIONS';   Title = 'BROWSER EXTENSIONS';     Admin = $false; Fn = { Collect-BrowserExtensions } }
)

#endregion

#region ============================ REPORT WRITERS ===========================

$Script:ReportWidth = 100

function Format-TextTable([object[]]$Rows, [string[]]$Props, [int]$MaxWidth = 96) {
    if (-not $Rows -or @($Rows).Count -eq 0) { return @('  (none)') }
    $strRows = @()
    foreach ($r in $Rows) {
        $vals = @()
        foreach ($p in $Props) {
            $v = $r.$p
            if ($null -eq $v) { $v = '' }
            elseif ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd') }
            $vals += ("$v" -replace '[\r\n\t]+', ' ')
        }
        $strRows += , $vals
    }
    $widths = @()
    for ($i = 0; $i -lt $Props.Count; $i++) {
        $w = $Props[$i].Length
        foreach ($vals in $strRows) { if ($vals[$i].Length -gt $w) { $w = $vals[$i].Length } }
        if ($w -gt 64) { $w = 64 }
        $widths += $w
    }
    $gap = 2
    $guard = 0
    while ($true) {
        $total = ($widths | Measure-Object -Sum).Sum + $gap * ($Props.Count - 1)
        if ($total -le $MaxWidth -or $guard -ge 600) { break }
        $mi = 0
        for ($i = 1; $i -lt $widths.Count; $i++) { if ($widths[$i] -gt $widths[$mi]) { $mi = $i } }
        if ($widths[$mi] -le 8) { break }
        $widths[$mi] = $widths[$mi] - 1
        $guard++
    }
    $fit = {
        param([string]$S, [int]$W)
        if ($S.Length -gt $W) {
            if ($W -gt 2) { return $S.Substring(0, $W - 2) + '..' }
            return $S.Substring(0, $W)
        }
        return $S.PadRight($W)
    }
    $lines = @()
    $hdr = @()
    $sep = @()
    for ($i = 0; $i -lt $Props.Count; $i++) {
        $hdr += (& $fit $Props[$i].ToUpper() $widths[$i])
        $sep += ('-' * $widths[$i])
    }
    $lines += ('  ' + ($hdr -join '  '))
    $lines += ('  ' + ($sep -join '  '))
    foreach ($vals in $strRows) {
        $cells = @()
        for ($i = 0; $i -lt $Props.Count; $i++) { $cells += (& $fit $vals[$i] $widths[$i]) }
        $lines += ('  ' + ($cells -join '  '))
    }
    return $lines
}

function Format-TextList([object[]]$Rows) {
    $lines = @()
    foreach ($r in $Rows) {
        foreach ($p in $r.PSObject.Properties) {
            $lines += ('  {0,-14}: {1}' -f $p.Name, $p.Value)
        }
        $lines += ''
    }
    if ($lines.Count -eq 0) { $lines = @('  (none)') }
    return $lines
}

function New-ReportHeaderLines([string]$CatLabel, [int]$Count) {
    $W = $Script:ReportWidth
    $mode = 'LIMITED'
    if (Test-IsAdmin) { $mode = 'ELEVATED' }
    $edge = '+' + ('=' * ($W - 2)) + '+'
    $box = {
        param([string]$S)
        if ($S.Length -gt ($W - 4)) { $S = $S.Substring(0, $W - 4) }
        return ('|  ' + $S.PadRight($W - 4) + '|')
    }
    return @(
        $edge,
        (& $box ('{0}  ::  {1}  ::  {2}' -f $Script:Brand.Name, (Get-BuildString), $Script:Brand.Tagline)),
        (& $box $CatLabel),
        $edge,
        (& $box ('HOST {0}  USER {1}  DATE {2}  MODE {3}  ITEMS {4}' -f $env:COMPUTERNAME, (Get-InvUserName), (Get-Date -Format 'yyyy-MM-dd HH:mm'), $mode, $Count)),
        $edge
    )
}

function New-SectionRule([string]$Name, [int]$Count) {
    $W = $Script:ReportWidth
    $label = (':::[ {0} ({1}) ]' -f $Name, $Count)
    return $label + (':' * [Math]::Max(4, $W - $label.Length))
}

function Convert-SectionsToText($Cat, $Sections) {
    $count = 0
    foreach ($s in $Sections) { $count += @($s.Rows).Count }
    $lines = @(New-ReportHeaderLines ('CATEGORY {0}  ::  {1}' -f $Cat.Num, $Cat.Title) $count)
    if ($Cat.Admin -and -not (Test-IsAdmin)) {
        $lines += ''
        $lines += '  [ LIMITED ] This category is richer when run elevated.'
    }
    foreach ($s in $Sections) {
        $lines += ''
        $lines += (New-SectionRule $s.Name @($s.Rows).Count)
        $lines += ''
        if ($s.View -eq 'List') { $lines += Format-TextList @($s.Rows) }
        elseif ($s.View -eq 'Error') { $lines += ('  COLLECTION FAILED :: ' + $s.Message) }
        else { $lines += Format-TextTable @($s.Rows) $s.Props }
    }
    $lines += ''
    $lines += ('  // END OF CATEGORY {0} :: generated by {1} v{2}' -f $Cat.Id, $Script:Brand.Short, $Script:Brand.Version)
    return (($lines -join "`r`n") + "`r`n")
}

function Convert-SectionsToJson($Cat, $Sections) {
    $obj = [ordered]@{
        category = $Cat.Id
        num      = $Cat.Num
        title    = $Cat.Title
        host     = $env:COMPUTERNAME
        date     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        sections = [ordered]@{}
    }
    foreach ($s in $Sections) { $obj.sections[[string]$s.Name] = @($s.Rows) }
    return ($obj | ConvertTo-Json -Depth 6)
}

function Write-FullInventory([string]$SnapDir, $SelectedCats, $Counts) {
    $total = 0
    foreach ($k in $Counts.Keys) { $total += [int]$Counts[$k] }
    $lines = @('')
    $fullArt = @()
    try { $fullArt = @(Get-LogoArt $Script:Settings.logo | ForEach-Object { "$_" }) } catch { }
    foreach ($a in $fullArt) { $lines += ('        ' + $a) }
    $lines += ''
    $lines += New-ReportHeaderLines ('FULL SYSTEM INVENTORY  ::  ALL CATEGORIES COMBINED') $total
    $lines += ''
    $lines += (New-SectionRule 'CONTENTS' $SelectedCats.Count)
    $lines += ''
    foreach ($cat in $SelectedCats) {
        $lines += ('  {0}  {1,-28} {2,6} items    -> {0}_{3}.txt' -f $cat.Num, $cat.Title, [int]$Counts[$cat.Id], $cat.Id)
    }
    $body = ($lines -join "`r`n") + "`r`n"
    foreach ($cat in $SelectedCats) {
        $body += "`r`n`r`n" + ('#' * $Script:ReportWidth) + "`r`n`r`n"
        $body += $Script:SweepText[$cat.Id]
    }
    Write-TextFile -Path (Join-Path $SnapDir '00_FULL_INVENTORY.txt') -Content $body
}

function Write-SnapshotManifest([string]$SnapDir, $Counts) {
    $apps = @()
    if ($Script:SweepData.ContainsKey('APPS_INSTALLED')) {
        foreach ($r in @($Script:SweepData['APPS_INSTALLED'][0].Rows)) {
            $apps += [ordered]@{ name = "$($r.Name)"; version = "$($r.Version)"; publisher = "$($r.Publisher)"; source = 'registry' }
        }
    }
    if ($Script:SweepData.ContainsKey('APPS_STORE')) {
        foreach ($r in @($Script:SweepData['APPS_STORE'][0].Rows)) {
            $apps += [ordered]@{ name = "$($r.Name)"; version = "$($r.Version)"; publisher = "$($r.Publisher)"; source = 'store' }
        }
    }
    $drivers = @()
    if ($Script:SweepData.ContainsKey('DRIVERS_SIGNED')) {
        foreach ($r in @($Script:SweepData['DRIVERS_SIGNED'][0].Rows)) {
            $drivers += [ordered]@{ device = "$($r.Device)"; provider = "$($r.Provider)"; version = "$($r.Version)"; inf = "$($r.Inf)" }
        }
    }
    if ($null -eq $Script:OsCache) {
        try { $Script:OsCache = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    }
    $os = ''
    $build = ''
    if ($Script:OsCache) { $os = ([string]$Script:OsCache.Caption).Trim(); $build = "$($Script:OsCache.BuildNumber)" }
    $man = [ordered]@{
        tool       = $Script:Brand.Name
        company    = $Script:Brand.Company
        version    = $Script:Brand.Version
        platform   = $Script:Brand.Platform
        arch       = $Script:Brand.Arch
        build      = (Get-BuildString)
        host       = $env:COMPUTERNAME
        user       = (Get-InvUserName)
        os         = $os
        osBuild    = $build
        elevated   = (Test-IsAdmin)
        date       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
        categories = $Counts
        apps       = $apps
        drivers    = $drivers
    }
    Write-TextFile -Path (Join-Path $SnapDir 'manifest.json') -Content ($man | ConvertTo-Json -Depth 6)
}

#endregion

#region ============================ RESTORE SCRIPT ============================

function Get-ManualMatchList([string[]]$Ids, $Rows) {
    # Registry programs winget could not match to any exported package id.
    # Token heuristic: first word (>=4 chars) of the program name vs the id blob.
    # Rows need Name/Version/Publisher (JSON manifest apps match case-insensitively).
    $out = @()
    $idBlob = ($Ids -join ' ').ToLower()
    foreach ($r in @($Rows)) {
        $token = @((("$($r.Name)" -replace '[^A-Za-z0-9]', ' ') -split '\s+') | Where-Object { $_.Length -ge 4 })
        $hit = $false
        if ($token.Count -gt 0 -and $idBlob.Contains(($token[0]).ToLower())) { $hit = $true }
        if (-not $hit) { $out += ('{0}  {1}  ({2})' -f $r.Name, $r.Version, $r.Publisher) }
    }
    return @($out)
}

function New-RestoreScript([string]$SnapDir) {
    $ids = @()
    $haveWinget = $null -ne (Get-Command 'winget' -ErrorAction SilentlyContinue)
    if ($haveWinget) {
        $tmp = Join-Path $SnapDir 'winget_export.json'
        try {
            $null = cmd /c "winget export -o `"$tmp`" --accept-source-agreements 2>nul"
            if (Test-Path -LiteralPath $tmp) {
                $ex = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
                foreach ($src in @($ex.Sources)) {
                    foreach ($p in @($src.Packages)) {
                        if ($p.PackageIdentifier) { $ids += [string]$p.PackageIdentifier }
                    }
                }
            }
        } catch { }
    }
    $ids = @($ids | Sort-Object -Unique)

    $manualEntries = @()
    if ($Script:SweepData.ContainsKey('APPS_INSTALLED')) {
        $manualEntries = @(Get-ManualMatchList $ids @($Script:SweepData['APPS_INSTALLED'][0].Rows))
    }

    $pkgBlock = '    # (winget not available or no packages exported)'
    if ($ids.Count -gt 0) {
        $pkgBlock = (@($ids | ForEach-Object { "    '" + ($_ -replace "'", "''") + "'" }) -join ",`r`n")
    }
    $manualBlock = ''
    if ($manualEntries.Count -gt 0) {
        $manualBlock = (@($manualEntries | ForEach-Object { "    '" + ($_ -replace "'", "''") + "'" }) -join ",`r`n")
    }

    $template = @'
<#
================================================================================
  INVENTORIZER RESTORE SCRIPT
  Generated by {{TOOL}} {{VER}} on {{DATE}} from host {{HOST}}.

  Rebuilds this machine's software on a fresh Windows install - selectively.
  Usage:
      .\restore.ps1              interactive: pick exactly what to reinstall
      .\restore.ps1 -All         install everything without asking
      .\restore.ps1 -DryRun      preview only - no installs (combinable with -All)
================================================================================
#>
param([switch]$DryRun, [switch]$All)

function Expand-Selection([string]$Spec, [int]$Max) {
    # '1,4,7-10' -> list of valid numbers
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($Spec -split ',')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        if ($p -match '^(\d+)-(\d+)$') {
            for ($n = [int]$Matches[1]; $n -le [int]$Matches[2]; $n++) {
                if ($n -ge 1 -and $n -le $Max) { [void]$out.Add($n) }
            }
        } elseif ($p -match '^\d+$') {
            $n = [int]$p
            if ($n -ge 1 -and $n -le $Max) { [void]$out.Add($n) }
        }
    }
    return $out
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host 'winget is not available on this machine. Install "App Installer" from the Microsoft Store first.'
    exit 1
}

$ids = @(
{{PKG}}
)

# Programs the sweep found in the registry that winget could NOT match to any
# package (neither the winget repo nor the msstore source) - manual reinstalls:
$manual = @(
{{MANUAL}}
)

Write-Host ('INVENTORIZER RESTORE :: {0} winget packages captured, {1} manual-only programs' -f $ids.Count, $manual.Count)
if ($ids.Count -eq 0) {
    Write-Host 'nothing to install via winget - see the manual list below.'
    $All = $true
}

$selected = @($ids)
if (-not $All -and $ids.Count -gt 0) {
    Write-Host ''
    for ($i = 0; $i -lt $ids.Count; $i++) { Write-Host ('  [{0,3}]  {1}' -f ($i + 1), $ids[$i]) }
    Write-Host ''
    Write-Host 'Choose what to reinstall:'
    Write-Host '  A  or blank   = everything'
    Write-Host '  1,4,7-10      = only these numbers'
    Write-Host '  x2,5          = everything EXCEPT these numbers'
    Write-Host '  Q             = quit without installing'
    $answer = Read-Host 'selection'
    $answer = "$answer".Trim()
    if ($answer -match '^[qQ]$') { Write-Host 'nothing installed.'; exit 0 }
    if ($answer -and $answer -notmatch '^[aA]$') {
        if ($answer -match '^[xX]') {
            $excl = Expand-Selection $answer.Substring(1) $ids.Count
            $selected = @()
            for ($i = 0; $i -lt $ids.Count; $i++) {
                if (-not $excl.Contains($i + 1)) { $selected += $ids[$i] }
            }
        } else {
            $incl = Expand-Selection $answer $ids.Count
            $selected = @($incl | Sort-Object -Unique | ForEach-Object { $ids[$_ - 1] })
        }
        if ($selected.Count -eq 0) { Write-Host 'selection matched nothing - nothing installed.'; exit 0 }
    }
}

Write-Host ''
Write-Host ('installing {0} of {1} packages...' -f $selected.Count, $ids.Count)
$fail = @()
foreach ($id in $selected) {
    if ($DryRun) {
        Write-Host ('[DRY]  winget install --id {0} --exact' -f $id)
        continue
    }
    Write-Host ('[>>>]  installing {0}' -f $id)
    winget install --id $id --exact --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { $fail += $id }
}
if ($fail.Count -gt 0) {
    Write-Host ''
    Write-Host ('The following {0} packages did not install cleanly:' -f $fail.Count)
    $fail | ForEach-Object { Write-Host ('    ' + $_) }
}
if ($manual.Count -gt 0) {
    Write-Host ''
    Write-Host ('{0} programs were NOT found by winget - reinstall these manually (installer / vendor site):' -f $manual.Count)
    $manual | ForEach-Object { Write-Host ('    ' + $_) }
}
'@
    $out = $template.Replace('{{TOOL}}', [string]$Script:Brand.Name)
    $out = $out.Replace('{{VER}}', (Get-BuildString))
    $out = $out.Replace('{{DATE}}', (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    $out = $out.Replace('{{HOST}}', [string]$env:COMPUTERNAME)
    $out = $out.Replace('{{PKG}}', $pkgBlock)
    $out = $out.Replace('{{MANUAL}}', $manualBlock)
    Write-TextFile -Path (Join-Path $SnapDir 'restore.ps1') -Content $out
    return $ids.Count
}

#endregion

#region ============================ HTML REPORT ===============================

function ConvertTo-HtmlSafe([string]$S) {
    if ($null -eq $S) { return '' }
    return $S.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function New-HtmlReport([string]$SnapDir, $SelectedCats, $Counts, [double]$Seconds, $Drift = $null, [string]$DriftBase = '') {
    $sb = New-Object System.Text.StringBuilder
    $mode = 'LIMITED'
    if (Test-IsAdmin) { $mode = 'ELEVATED' }

    # Derive every report color from the ACTIVE theme so the HTML matches the app.
    $T = $Script:Theme
    $rgb = { param($c) if ($null -eq $c) { return 'inherit' }; return ('rgb({0},{1},{2})' -f [int]$c[0], [int]$c[1], [int]$c[2]) }
    $rgba = { param($c, $a) ('rgba({0},{1},{2},{3})' -f [int]$c[0], [int]$c[1], [int]$c[2], $a) }
    $bg = [string]$T.BgHex
    $txt = & $rgb $T.Txt
    $dim = & $rgb $T.Dim
    $faint = & $rgb $T.Faint
    $accent = & $rgb $T.Accent
    $violet = & $rgb $T.Violet
    $warn = & $rgb $T.Warn
    $g0 = & $rgb $T.Ramp[0]; $g1 = & $rgb $T.Ramp[1]; $g2 = & $rgb $T.Ramp[2]
    $grad = ('linear-gradient(90deg,{0},{1},{2})' -f $g0, $g1, $g2)
    $line = & $rgba $T.Faint '0.35'
    $lineFaint = & $rgba $T.Faint '0.18'
    $hover = & $rgba $T.Txt '0.05'

    [void]$sb.AppendLine('<!doctype html><html><head><meta charset="utf-8">')
    [void]$sb.AppendLine(('<title>{0} :: {1}</title>' -f (ConvertTo-HtmlSafe $Script:Brand.Short), (ConvertTo-HtmlSafe $env:COMPUTERNAME)))
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(('  body { background:' + $bg + '; color:' + $txt + '; font-family:Consolas,"Cascadia Mono",ui-monospace,monospace; margin:0; padding:0 0 80px 0; }'))
    [void]$sb.AppendLine('  .wrap { max-width:1200px; margin:0 auto; padding:0 24px; }')
    [void]$sb.AppendLine(('  header { padding:40px 0 16px 0; border-bottom:1px solid ' + $line + '; }'))
    [void]$sb.AppendLine(('  pre.mark { margin:0 0 14px 0; font-size:10px; line-height:1.05; background:' + $grad + '; -webkit-background-clip:text; background-clip:text; color:transparent; white-space:pre; overflow-x:auto; }'))
    [void]$sb.AppendLine(('  h1 { font-size:26px; letter-spacing:2px; margin:0 0 6px 0; background:' + $grad + '; -webkit-background-clip:text; background-clip:text; color:transparent; }'))
    [void]$sb.AppendLine(('  .meta { color:' + $dim + '; font-size:13px; }'))
    [void]$sb.AppendLine(('  .stats { display:flex; flex-wrap:wrap; gap:26px; margin:22px 0 6px 0; }'))
    [void]$sb.AppendLine(('  .stat .n { font-size:24px; color:' + $accent + '; }'))
    [void]$sb.AppendLine(('  .stat .l { font-size:11px; color:' + $faint + '; letter-spacing:1px; }'))
    [void]$sb.AppendLine(('  .chart { margin:14px 0 8px 0; }'))
    [void]$sb.AppendLine(('  .bar { display:flex; align-items:center; gap:10px; margin:3px 0; font-size:12px; }'))
    [void]$sb.AppendLine(('  .bar .lab { width:230px; color:' + $dim + '; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }'))
    [void]$sb.AppendLine(('  .bar .track { flex:1; height:9px; background:' + $lineFaint + '; border-radius:5px; overflow:hidden; }'))
    [void]$sb.AppendLine(('  .bar .fill { display:block; height:100%; background:' + $grad + '; }'))
    [void]$sb.AppendLine(('  .bar .num { width:56px; text-align:right; color:' + $txt + '; }'))
    [void]$sb.AppendLine(('  .drift { display:flex; flex-wrap:wrap; gap:20px; margin:12px 0; }'))
    [void]$sb.AppendLine(('  .drift .d { font-size:13px; } .drift .add { color:' + $accent + '; } .drift .rem { color:' + $warn + '; } .drift .chg { color:' + $violet + '; }'))
    [void]$sb.AppendLine(('  nav { position:sticky; top:0; background:' + $bg + '; padding:10px 0; border-bottom:1px solid ' + $line + '; z-index:5; }'))
    [void]$sb.AppendLine(('  nav a { color:' + $violet + '; text-decoration:none; font-size:12px; margin-right:14px; white-space:nowrap; }'))
    [void]$sb.AppendLine(('  nav a:hover { color:' + $accent + '; }'))
    [void]$sb.AppendLine(('  h2 { font-size:16px; letter-spacing:1px; color:' + $txt + '; margin:42px 0 4px 0; }'))
    [void]$sb.AppendLine(('  h2 .cnt { color:' + $accent + '; font-weight:normal; font-size:13px; }'))
    [void]$sb.AppendLine(('  h3 { font-size:13px; color:' + $violet + '; letter-spacing:1px; margin:24px 0 8px 0; }'))
    [void]$sb.AppendLine('  table { border-collapse:collapse; width:100%; font-size:12px; }')
    [void]$sb.AppendLine(('  th { text-align:left; color:' + $faint + '; border-bottom:1px solid ' + $line + '; padding:4px 10px 4px 0; font-weight:normal; letter-spacing:1px; }'))
    [void]$sb.AppendLine(('  td { border-bottom:1px solid ' + $lineFaint + '; padding:3px 10px 3px 0; vertical-align:top; word-break:break-word; }'))
    [void]$sb.AppendLine(('  tr:hover td { background:' + $hover + '; }'))
    [void]$sb.AppendLine(('  .lim { color:' + $warn + '; font-size:12px; }'))
    [void]$sb.AppendLine(('  footer { margin-top:60px; color:' + $faint + '; font-size:11px; }'))
    [void]$sb.AppendLine('</style></head><body><div class="wrap">')
    [void]$sb.AppendLine('<header>')
    $mark = @(Get-LogoArt 'pyramid')
    [void]$sb.AppendLine('<pre class="mark">')
    foreach ($ln in $mark) { [void]$sb.AppendLine((ConvertTo-HtmlSafe $ln)) }
    [void]$sb.AppendLine('</pre>')
    [void]$sb.AppendLine(('<h1>{0}</h1>' -f (ConvertTo-HtmlSafe $Script:Brand.Name)))
    $hostLabel = "$env:COMPUTERNAME"
    if ([string]$Script:Settings.machineAlias) { $hostLabel = ('{0} ({1})' -f $Script:Settings.machineAlias, $env:COMPUTERNAME) }
    [void]$sb.AppendLine(('<div class="meta">HOST {0} &nbsp;//&nbsp; USER {1} &nbsp;//&nbsp; {2} &nbsp;//&nbsp; MODE {3} &nbsp;//&nbsp; swept in {4} &nbsp;//&nbsp; {5}</div>' -f `
        (ConvertTo-HtmlSafe $hostLabel), (ConvertTo-HtmlSafe (Get-InvUserName)), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $mode, (Format-InvDuration $Seconds), (ConvertTo-HtmlSafe (Get-BuildString))))

    # overview: stat tiles + a category breakdown bar chart
    $totalItems = 0
    foreach ($cat in $SelectedCats) { $totalItems += [int]$Counts[$cat.Id] }
    [void]$sb.AppendLine('<div class="stats">')
    [void]$sb.AppendLine(('<div class="stat"><div class="n">{0}</div><div class="l">ITEMS CATALOGUED</div></div>' -f $totalItems))
    [void]$sb.AppendLine(('<div class="stat"><div class="n">{0}</div><div class="l">CATEGORIES</div></div>' -f @($SelectedCats).Count))
    [void]$sb.AppendLine(('<div class="stat"><div class="n">{0}</div><div class="l">SWEEP TIME</div></div>' -f (ConvertTo-HtmlSafe (Format-InvDuration $Seconds))))
    if ($Drift) {
        [void]$sb.AppendLine(('<div class="stat"><div class="n">{0}</div><div class="l">APPS DRIFTED VS BASELINE</div></div>' -f ([int]$Drift.AppAdd + [int]$Drift.AppRem + [int]$Drift.AppChg)))
    }
    [void]$sb.AppendLine('</div>')

    if ($Drift) {
        [void]$sb.AppendLine(('<div class="meta">drift vs baseline <b>{0}</b></div>' -f (ConvertTo-HtmlSafe $DriftBase)))
        [void]$sb.AppendLine('<div class="drift">')
        [void]$sb.AppendLine(('<span class="d">apps <span class="add">+{0}</span> <span class="rem">-{1}</span> <span class="chg">~{2}</span></span>' -f $Drift.AppAdd, $Drift.AppRem, $Drift.AppChg))
        [void]$sb.AppendLine(('<span class="d">drivers <span class="add">+{0}</span> <span class="rem">-{1}</span> <span class="chg">~{2}</span></span>' -f $Drift.DrvAdd, $Drift.DrvRem, $Drift.DrvChg))
        [void]$sb.AppendLine('</div>')
    }

    $maxCount = 1
    foreach ($cat in $SelectedCats) { if ([int]$Counts[$cat.Id] -gt $maxCount) { $maxCount = [int]$Counts[$cat.Id] } }
    [void]$sb.AppendLine('<div class="chart">')
    foreach ($cat in $SelectedCats) {
        $n = [int]$Counts[$cat.Id]
        $pct = [int]([Math]::Round(100.0 * $n / $maxCount))
        [void]$sb.AppendLine(('<div class="bar"><span class="lab">{0} {1}</span><span class="track"><span class="fill" style="width:{2}%"></span></span><span class="num">{3}</span></div>' -f `
            $cat.Num, (ConvertTo-HtmlSafe $cat.Title), $pct, $n))
    }
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</header>')
    [void]$sb.AppendLine('<nav>')
    foreach ($cat in $SelectedCats) {
        [void]$sb.AppendLine(('<a href="#{0}">{1} {2}</a>' -f $cat.Id, $cat.Num, (ConvertTo-HtmlSafe $cat.Title)))
    }
    [void]$sb.AppendLine('</nav>')
    foreach ($cat in $SelectedCats) {
        $sections = $Script:SweepData[$cat.Id]
        [void]$sb.AppendLine(('<section id="{0}"><h2>{1} :: {2} <span class="cnt">{3} items</span></h2>' -f $cat.Id, $cat.Num, (ConvertTo-HtmlSafe $cat.Title), [int]$Counts[$cat.Id]))
        foreach ($s in $sections) {
            [void]$sb.AppendLine(('<h3>{0} ({1})</h3>' -f (ConvertTo-HtmlSafe ([string]$s.Name)), @($s.Rows).Count))
            if ($s.View -eq 'Error') {
                [void]$sb.AppendLine(('<div class="lim">COLLECTION FAILED :: {0}</div>' -f (ConvertTo-HtmlSafe ([string]$s.Message))))
                continue
            }
            $rows = @($s.Rows)
            if ($rows.Count -eq 0) { [void]$sb.AppendLine('<div class="meta">(none)</div>'); continue }
            $props = $s.Props
            if ($s.View -eq 'List' -or $null -eq $props) {
                $props = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
            }
            if ($s.View -eq 'List') {
                [void]$sb.AppendLine('<table>')
                foreach ($r in $rows) {
                    foreach ($p in $props) {
                        [void]$sb.AppendLine(('<tr><th style="width:200px">{0}</th><td>{1}</td></tr>' -f (ConvertTo-HtmlSafe $p), (ConvertTo-HtmlSafe ("$($r.$p)"))))
                    }
                }
                [void]$sb.AppendLine('</table>')
            } else {
                [void]$sb.AppendLine('<table><tr>')
                foreach ($p in $props) { [void]$sb.AppendLine(('<th>{0}</th>' -f (ConvertTo-HtmlSafe $p.ToUpper()))) }
                [void]$sb.AppendLine('</tr>')
                foreach ($r in $rows) {
                    [void]$sb.Append('<tr>')
                    foreach ($p in $props) { [void]$sb.Append(('<td>{0}</td>' -f (ConvertTo-HtmlSafe ("$($r.$p)")))) }
                    [void]$sb.AppendLine('</tr>')
                }
                [void]$sb.AppendLine('</table>')
            }
        }
        [void]$sb.AppendLine('</section>')
    }
    [void]$sb.AppendLine(('<footer>generated by {0} v{1} :: {2}</footer>' -f (ConvertTo-HtmlSafe $Script:Brand.Name), $Script:Brand.Version, (ConvertTo-HtmlSafe (Get-InvTagline))))
    [void]$sb.AppendLine('</div></body></html>')
    Write-TextFile -Path (Join-Path $SnapDir 'report.html') -Content $sb.ToString()
}

function Get-SnapshotApps([string]$Dir) {
    # Installed apps from a snapshot's manifest (name/version/publisher/source).
    $apps = @()
    $mp = Join-Path $Dir 'manifest.json'
    if (Test-Path -LiteralPath $mp) {
        try {
            $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            foreach ($a in @($m.apps)) {
                $apps += [PSCustomObject]@{ Name = "$($a.name)"; Version = "$($a.version)"; Publisher = "$($a.publisher)"; Source = "$($a.source)" }
            }
        } catch { }
    }
    return @($apps)
}

function Find-WingetIdForApp([string]$Name, [string[]]$Ids) {
    # Best-effort: match the app's first significant word to a winget id.
    $token = @((("$Name" -replace '[^A-Za-z0-9]', ' ') -split '\s+') | Where-Object { $_.Length -ge 4 })
    if ($token.Count -eq 0) { return $null }
    $tk = $token[0].ToLower()
    foreach ($id in $Ids) { if ($id.ToLower().Contains($tk)) { return $id } }
    return $null
}

function New-ReinstallPlanHtml([string]$Dir, $Apps) {
    # A follow-along reinstall checklist: themed, with tick-off checkboxes that
    # persist in the browser, a winget batch block, and a manual-reinstall list.
    $T = $Script:Theme
    $rgb = { param($c) if ($null -eq $c) { return 'inherit' }; return ('rgb({0},{1},{2})' -f [int]$c[0], [int]$c[1], [int]$c[2]) }
    $rgba = { param($c, $a) ('rgba({0},{1},{2},{3})' -f [int]$c[0], [int]$c[1], [int]$c[2], $a) }
    $bg = [string]$T.BgHex; $txt = & $rgb $T.Txt; $dim = & $rgb $T.Dim; $faint = & $rgb $T.Faint
    $accent = & $rgb $T.Accent; $warn = & $rgb $T.Warn
    $g0 = & $rgb $T.Ramp[0]; $g1 = & $rgb $T.Ramp[1]; $g2 = & $rgb $T.Ramp[2]
    $grad = ('linear-gradient(90deg,{0},{1},{2})' -f $g0, $g1, $g2)
    $line = & $rgba $T.Faint '0.35'; $lineFaint = & $rgba $T.Faint '0.18'; $hover = & $rgba $T.Txt '0.05'

    $ids = @()
    $wx = Join-Path $Dir 'winget_export.json'
    if (Test-Path -LiteralPath $wx) {
        try {
            $ex = Get-Content -LiteralPath $wx -Raw | ConvertFrom-Json
            foreach ($src in @($ex.Sources)) { foreach ($p in @($src.Packages)) { if ($p.PackageIdentifier) { $ids += "$($p.PackageIdentifier)" } } }
        } catch { }
    }
    $ids = @($ids | Sort-Object -Unique)

    # classify selected apps into winget-installable vs manual
    $winApps = @(); $manApps = @()
    foreach ($a in @($Apps)) {
        $id = Find-WingetIdForApp $a.Name $ids
        if ($id) { $winApps += [PSCustomObject]@{ App = $a; Id = $id } }
        else { $manApps += $a }
    }
    $batch = (@($winApps | ForEach-Object { 'winget install --id ' + $_.Id + ' --exact' }) -join "`n")
    $planId = ($env:COMPUTERNAME + '_' + (Get-Date -Format 'yyyyMMddHHmm'))

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<!doctype html><html><head><meta charset="utf-8">')
    [void]$sb.AppendLine(('<title>Reinstall Plan :: {0}</title>' -f (ConvertTo-HtmlSafe $env:COMPUTERNAME)))
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<style>')
    [void]$sb.AppendLine(('  body { background:' + $bg + '; color:' + $txt + '; font-family:Consolas,"Cascadia Mono",ui-monospace,monospace; margin:0; padding:0 0 80px 0; }'))
    [void]$sb.AppendLine('  .wrap { max-width:1000px; margin:0 auto; padding:0 24px; }')
    [void]$sb.AppendLine(('  header { padding:36px 0 14px 0; border-bottom:1px solid ' + $line + '; }'))
    [void]$sb.AppendLine(('  pre.mark { margin:0 0 12px 0; font-size:9px; line-height:1.05; background:' + $grad + '; -webkit-background-clip:text; background-clip:text; color:transparent; white-space:pre; overflow-x:auto; }'))
    [void]$sb.AppendLine(('  h1 { font-size:24px; letter-spacing:2px; margin:0 0 6px 0; background:' + $grad + '; -webkit-background-clip:text; background-clip:text; color:transparent; }'))
    [void]$sb.AppendLine(('  .meta { color:' + $dim + '; font-size:13px; }'))
    [void]$sb.AppendLine(('  .progwrap { margin:16px 0 4px 0; height:10px; background:' + $lineFaint + '; border-radius:6px; overflow:hidden; }'))
    [void]$sb.AppendLine(('  #bar { height:100%; width:0; background:' + $grad + '; transition:width .2s; }'))
    [void]$sb.AppendLine(('  #prog { color:' + $accent + '; font-size:13px; }'))
    [void]$sb.AppendLine(('  h2 { font-size:15px; letter-spacing:1px; color:' + $txt + '; margin:36px 0 8px 0; }'))
    [void]$sb.AppendLine(('  p.note { color:' + $dim + '; font-size:13px; margin:4px 0 12px 0; }'))
    [void]$sb.AppendLine(('  pre.cmd { background:' + $lineFaint + '; color:' + $txt + '; padding:12px 14px; border-radius:8px; font-size:12px; overflow-x:auto; white-space:pre; }'))
    [void]$sb.AppendLine(('  button { font-family:inherit; font-size:12px; color:' + $bg + '; background:' + $accent + '; border:0; padding:6px 14px; border-radius:6px; cursor:pointer; margin:8px 0; }'))
    [void]$sb.AppendLine('  table { border-collapse:collapse; width:100%; font-size:13px; }')
    [void]$sb.AppendLine(('  th { text-align:left; color:' + $faint + '; border-bottom:1px solid ' + $line + '; padding:6px 10px 6px 0; font-weight:normal; letter-spacing:1px; }'))
    [void]$sb.AppendLine(('  td { border-bottom:1px solid ' + $lineFaint + '; padding:6px 10px 6px 0; vertical-align:top; }'))
    [void]$sb.AppendLine(('  tr:hover td { background:' + $hover + '; }'))
    [void]$sb.AppendLine(('  tr.done td { color:' + $faint + '; text-decoration:line-through; }'))
    [void]$sb.AppendLine('  td.cmd { text-decoration:none; }')
    [void]$sb.AppendLine('  input.chk { width:16px; height:16px; cursor:pointer; }')
    [void]$sb.AppendLine(('  code { color:' + $accent + '; }'))
    [void]$sb.AppendLine(('  .man { color:' + $warn + '; }'))
    [void]$sb.AppendLine(('  footer { margin-top:50px; color:' + $faint + '; font-size:11px; }'))
    [void]$sb.AppendLine(('</style></head><body data-plan="' + (ConvertTo-HtmlSafe $planId) + '"><div class="wrap">'))
    [void]$sb.AppendLine('<header>')
    $mark = @(Get-LogoArt 'pyramid')
    [void]$sb.AppendLine('<pre class="mark">')
    foreach ($ln in $mark) { [void]$sb.AppendLine((ConvertTo-HtmlSafe $ln)) }
    [void]$sb.AppendLine('</pre>')
    [void]$sb.AppendLine('<h1>REINSTALL PLAN</h1>')
    [void]$sb.AppendLine(('<div class="meta">{0} &nbsp;//&nbsp; {1} apps to reinstall &nbsp;//&nbsp; prepared {2} &nbsp;//&nbsp; tick each off as you go (saved in this browser)</div>' -f `
        (ConvertTo-HtmlSafe $env:COMPUTERNAME), @($Apps).Count, (Get-Date -Format 'yyyy-MM-dd HH:mm')))
    [void]$sb.AppendLine('<div class="progwrap"><div id="bar"></div></div>')
    [void]$sb.AppendLine('<div id="prog">0 of ' + @($Apps).Count + ' done</div>')
    [void]$sb.AppendLine('</header>')

    if ($batch) {
        [void]$sb.AppendLine('<h2>winget batch install</h2>')
        [void]$sb.AppendLine('<p class="note">Open a terminal and paste this to reinstall the winget-matched apps in one go. Then tick them off below.</p>')
        [void]$sb.AppendLine(('<pre class="cmd" id="cmd">' + (ConvertTo-HtmlSafe $batch) + '</pre>'))
        [void]$sb.AppendLine('<button id="copy">copy</button>')
    }

    $idx = 0
    if ($winApps.Count -gt 0) {
        [void]$sb.AppendLine(('<h2>winget apps ({0})</h2>' -f $winApps.Count))
        [void]$sb.AppendLine('<table><tr><th></th><th>APP</th><th>VERSION</th><th>PUBLISHER</th><th>COMMAND</th></tr>')
        foreach ($w in $winApps) {
            $a = $w.App
            [void]$sb.AppendLine(('<tr><td><input class="chk" type="checkbox" data-k="{0}"></td><td>{1}</td><td>{2}</td><td>{3}</td><td class="cmd"><code>winget install --id {4}</code></td></tr>' -f `
                $idx, (ConvertTo-HtmlSafe $a.Name), (ConvertTo-HtmlSafe $a.Version), (ConvertTo-HtmlSafe $a.Publisher), (ConvertTo-HtmlSafe $w.Id)))
            $idx++
        }
        [void]$sb.AppendLine('</table>')
    }
    if ($manApps.Count -gt 0) {
        [void]$sb.AppendLine(('<h2>manual reinstalls ({0})</h2>' -f $manApps.Count))
        [void]$sb.AppendLine('<p class="note">winget could not match these - reinstall from the vendor site or the Microsoft Store.</p>')
        [void]$sb.AppendLine('<table><tr><th></th><th>APP</th><th>VERSION</th><th>PUBLISHER</th><th>SOURCE</th></tr>')
        foreach ($a in $manApps) {
            [void]$sb.AppendLine(('<tr><td><input class="chk" type="checkbox" data-k="{0}"></td><td>{1}</td><td>{2}</td><td>{3}</td><td class="man">{4}</td></tr>' -f `
                $idx, (ConvertTo-HtmlSafe $a.Name), (ConvertTo-HtmlSafe $a.Version), (ConvertTo-HtmlSafe $a.Publisher), (ConvertTo-HtmlSafe $a.Source)))
            $idx++
        }
        [void]$sb.AppendLine('</table>')
    }

    [void]$sb.AppendLine(('<footer>prepared by {0} v{1} :: this plan lives only in this file and your browser</footer>' -f (ConvertTo-HtmlSafe $Script:Brand.Name), $Script:Brand.Version))
    $js = @'
<script>
(function(){
  var KEY='covert_reinstall_'+(document.body.getAttribute('data-plan')||'plan');
  var saved={}; try{ saved=JSON.parse(localStorage.getItem(KEY)||'{}'); }catch(e){}
  var boxes=Array.prototype.slice.call(document.querySelectorAll('input.chk'));
  function update(){
    var done=0;
    boxes.forEach(function(b){ var tr=b.closest('tr'); if(b.checked){done++; if(tr)tr.classList.add('done');} else if(tr){tr.classList.remove('done');} });
    var p=document.getElementById('prog'); if(p){ p.textContent=done+' of '+boxes.length+' done'; }
    var bar=document.getElementById('bar'); if(bar){ bar.style.width=(boxes.length?(100*done/boxes.length):0)+'%'; }
  }
  boxes.forEach(function(b){
    var k=b.getAttribute('data-k');
    if(saved[k]){ b.checked=true; }
    b.addEventListener('change',function(){ saved[k]=b.checked; try{localStorage.setItem(KEY,JSON.stringify(saved));}catch(e){} update(); });
  });
  update();
  var cp=document.getElementById('copy');
  if(cp){ cp.addEventListener('click',function(){ var t=(document.getElementById('cmd')||{}).textContent||''; if(navigator.clipboard){ navigator.clipboard.writeText(t).then(function(){ cp.textContent='copied'; setTimeout(function(){cp.textContent='copy';},1500); }); } }); }
})();
</script>
'@
    [void]$sb.AppendLine($js)
    [void]$sb.AppendLine('</div></body></html>')
    $out = Join-Path $Dir 'reinstall_plan.html'
    Write-TextFile -Path $out -Content $sb.ToString()
    return $out
}

#endregion

#region ============================ SWEEP RUNNER ==============================

# --- sweep screen helpers -----------------------------------------------------
# Fixed rows near the top of the screen: bar row + transient status row; result
# lines accumulate below. $Script:SweepRows nulls itself on any cursor fault and
# everything degrades to plain appended output (FAILSAFE).

function Draw-SweepBar([double]$Frac) {
    if (-not $Script:Interactive -or $null -eq $Script:SweepRows) { return }
    $pct = ('{0,3}%' -f [int]($Frac * 100))
    $plainLen = 20 + 2 + $pct.Length
    try {
        [Console]::SetCursorPosition(0, $Script:SweepRows.Bar)
        $w = Get-ConWidth
        $padN = [Math]::Max(0, [Math]::Floor(($w - $plainLen) / 2))
        Write-Host -NoNewline ((' ' * $padN) + (Get-BarString $Frac 20) + '  ' + (Get-Dim $pct) + (' ' * [Math]::Max(0, $w - 1 - $padN - $plainLen)))
    } catch { $Script:SweepRows = $null }
}

function Set-SweepStatus([string]$Msg) {
    # Transient step line - shows what is happening right now, then vanishes.
    if (-not $Script:Interactive -or $null -eq $Script:SweepRows) { return }
    try {
        [Console]::SetCursorPosition(0, $Script:SweepRows.Status)
        $w = Get-ConWidth
        $txt = ''
        if ($Msg) { $txt = '>>  ' + $Msg }
        if ($txt.Length -gt ($w - 4)) { $txt = $txt.Substring(0, $w - 6) + '..' }
        $padN = [Math]::Max(0, [Math]::Floor(($w - $txt.Length) / 2))
        Write-Host -NoNewline ((' ' * $padN) + (Get-Dim $txt) + (' ' * [Math]::Max(0, $w - 1 - $padN - $txt.Length)))
    } catch { $Script:SweepRows = $null }
}

function Add-SweepResult([string]$Line, [string]$Role) {
    # Role: ok | warn | lock. Centered, appended under the status area.
    if (-not $Script:Interactive) { return }
    $colored = Get-Accent $Line
    if ($Role -eq 'warn') { $colored = Get-Warn $Line }
    if ($Role -eq 'lock') { $colored = Get-Dim $Line }
    if ($Script:SweepRows) {
        try {
            [Console]::SetCursorPosition(0, $Script:SweepRows.Next)
            $padN = [Math]::Max(0, [Math]::Floor(((Get-ConWidth) - $Line.Length) / 2))
            Write-Host ((' ' * $padN) + $colored)
            $Script:SweepRows.Next = $Script:SweepRows.Next + 1
            return
        } catch { $Script:SweepRows = $null }
    }
    Write-Host $colored
}

function Show-SweepBarAnimation([double]$From, [double]$To) {
    if (-not $Script:Interactive -or $null -eq $Script:SweepRows) { return }
    if (-not $Script:Settings.animations) { Draw-SweepBar $To; return }
    $steps = 12
    for ($s = 1; $s -le $steps; $s++) {
        Draw-SweepBar ($From + ($To - $From) * ($s / [double]$steps))
        Start-Sleep -Milliseconds 8
    }
}

function Invoke-Sweep([string[]]$Ids) {
    $selected = @($Script:CollectorRegistry | Where-Object { $Ids -contains $_.Id })
    if ($selected.Count -eq 0) { return $null }
    $root = Get-OutputRoot
    $snapDir = Join-Path $root ('{0}_{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    $jsonDir = Join-Path $snapDir 'json'
    if ($Script:Settings.exportJson) { New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null }

    $Script:SweepData = @{}
    $Script:SweepText = [ordered]@{}
    $counts = [ordered]@{}
    $log = New-Object System.Collections.Generic.List[string]
    $mode = 'LIMITED'
    if (Test-IsAdmin) { $mode = 'ELEVATED' }
    $log.Add(('[{0}] SWEEP START :: {1} {2} :: {3} :: {4} categories :: mode {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Script:Brand.Name, (Get-BuildString), (Split-Path $snapDir -Leaf), $selected.Count, $mode))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ui = $Script:Interactive
    $Script:SweepRows = $null

    if ($ui) {
        Clear-Host
        try { [Console]::CursorVisible = $false } catch { }
        Write-Host ''
        $sweepTitle = '::  SYSTEM SWEEP IN PROGRESS  ::'
        if ($selected.Count -eq @($Script:CollectorRegistry).Count) { $sweepTitle = '::  FULL SYSTEM SWEEP IN PROGRESS  ::' }
        Write-GradLine $sweepTitle -Center
        Write-DimLine ('host ' + $env:COMPUTERNAME + '  //  ' + $selected.Count + ' categories  //  ' + (Split-Path $snapDir -Leaf)) -Center
        Write-Host ''
        # fixed layout only when the window is tall enough; otherwise plain append
        $tallEnough = $false
        try { $tallEnough = ([Console]::WindowHeight -ge (12 + $selected.Count)) } catch { }
        if ($tallEnough) {
            try {
                $barRow = [Console]::CursorTop
                Write-Host ''
                Write-Host ''
                $statusRow = [Console]::CursorTop
                Write-Host ''
                Write-Host ''
                $Script:SweepRows = @{ Bar = $barRow; Status = $statusRow; Next = [Console]::CursorTop }
            } catch { $Script:SweepRows = $null }
        }
        Draw-SweepBar 0
    } else {
        Write-Host ('[SWEEP] {0} categories -> {1}' -f $selected.Count, $snapDir)
    }

    $done = 0
    foreach ($cat in $selected) {
        $frac0 = $done / [double]$selected.Count
        if ($ui) { Set-SweepStatus ('SCANNING  ' + $cat.Num + '  ' + $cat.Title) }
        $t0 = [DateTime]::Now
        $sections = @()
        $err = $null
        $locked = $false
        try { $sections = @(& $cat.Fn) } catch { $err = "$($_.Exception.Message)".Trim() }
        if ($err -or $sections.Count -eq 0) {
            if (-not $err) { $err = 'collector returned no data' }
            if ($cat.Admin -and -not (Test-IsAdmin)) {
                $locked = $true
                $err = 'requires elevation - run the Inventorizer elevated to unlock this category'
                $sections = @(@{ Name = 'LOCKED'; View = 'Error'; Rows = @(); Message = $err })
            } else {
                $sections = @(@{ Name = 'ERROR'; View = 'Error'; Rows = @(); Message = $err })
            }
        }
        $secs = ([DateTime]::Now - $t0).TotalSeconds
        $n = 0
        foreach ($s in $sections) { $n += @($s.Rows).Count }
        $counts[$cat.Id] = $n
        $Script:SweepData[$cat.Id] = $sections
        $txt = Convert-SectionsToText $cat $sections
        $Script:SweepText[$cat.Id] = $txt
        Write-TextFile -Path (Join-Path $snapDir ('{0}_{1}.txt' -f $cat.Num, $cat.Id)) -Content $txt
        if ($Script:Settings.exportJson) {
            Write-TextFile -Path (Join-Path $jsonDir ($cat.Id.ToLower() + '.json')) -Content (Convert-SectionsToJson $cat $sections)
        }
        $done++
        $frac1 = $done / [double]$selected.Count
        $status = '[ OK ]'
        $role = 'ok'
        if ($err) { $status = '[FAIL]'; $role = 'warn' }
        if ($locked) { $status = '[LOCK]'; $role = 'lock' }
        $dur = Format-InvDuration $secs
        $itemLine = ('{0}  {1}  {2,-26} {3,6} items   {4,8}' -f $status, $cat.Num, $cat.Title, $n, ('(' + $dur + ')'))
        if ($err) { $itemLine += '  :: ' + $err }
        $log.Add(('[{0}] {1} {2} {3} :: {4} items :: {5}' -f (Get-Date -Format 'HH:mm:ss'), $status, $cat.Num, $cat.Id, $n, $dur))
        if ($err) { $log.Add('           ' + $err) }
        if ($ui) {
            Add-SweepResult $itemLine $role
            Show-SweepBarAnimation $frac0 $frac1
        } else {
            Write-Host $itemLine
        }
    }

    # Post steps: shown only in the transient status line (visual), always kept in sweep.log
    $post = {
        param([string]$Msg)
        $log.Add(('[{0}] STEP :: {1}' -f (Get-Date -Format 'HH:mm:ss'), $Msg))
        if ($ui) { Set-SweepStatus $Msg }
        else { Write-Host ('        ' + $Msg) }
    }

    & $post 'compiling 00_FULL_INVENTORY.txt ...'
    Write-FullInventory $snapDir $selected $counts
    & $post 'writing manifest.json ...'
    Write-SnapshotManifest $snapDir $counts
    if ($Script:Settings.restoreScript) {
        & $post 'generating restore.ps1 (winget export) ...'
        $null = New-RestoreScript $snapDir
    }

    # Baseline drift: compare this sweep against the pinned baseline snapshot
    # (computed before the HTML report so the report can include the drift panel)
    $drift = $null
    $driftBase = ''
    $bl = ([string]$Script:Settings.baselineSnapshot).Trim()
    if ($bl -and $bl -ne (Split-Path $snapDir -Leaf)) {
        $blPath = Join-Path $root $bl
        if (Test-Path -LiteralPath (Join-Path $blPath 'manifest.json')) {
            & $post 'comparing against the baseline snapshot ...'
            try {
                $drift = Invoke-SnapshotDiff $blPath $snapDir
                $driftBase = $bl
                $inSnap = Join-Path $snapDir 'drift_vs_baseline.txt'
                try { Move-Item -LiteralPath $drift.Path -Destination $inSnap -Force; $drift.Path = $inSnap } catch { }
                $log.Add(('[{0}] DRIFT vs {1} :: apps +{2} -{3} ~{4} :: drivers +{5} -{6} ~{7}' -f (Get-Date -Format 'HH:mm:ss'), $bl, $drift.AppAdd, $drift.AppRem, $drift.AppChg, $drift.DrvAdd, $drift.DrvRem, $drift.DrvChg))
            } catch { $drift = $null }
        } else {
            $log.Add(('[{0}] DRIFT :: baseline {1} not found - comparison skipped' -f (Get-Date -Format 'HH:mm:ss'), $bl))
        }
    }

    if ($Script:Settings.htmlReport) {
        & $post 'rendering report.html ...'
        New-HtmlReport $snapDir $selected $counts $sw.Elapsed.TotalSeconds $drift $driftBase
    }

    # Retention: prune the oldest snapshots beyond the keep count (baseline exempt)
    $pruned = 0
    $keep = 0
    try { $keep = [int]$Script:Settings.retentionKeep } catch { }
    if ($keep -gt 0) {
        try {
            $kept = 0
            foreach ($s in @(Get-SnapshotList)) {   # newest first (list sorts by name descending)
                if ($s.Name -eq $bl) { continue }
                $kept++
                if ($kept -gt $keep) {
                    try {
                        Remove-Item -LiteralPath $s.Path -Recurse -Force
                        $pruned++
                        $log.Add(('[{0}] RETENTION :: pruned {1}' -f (Get-Date -Format 'HH:mm:ss'), $s.Name))
                    } catch { }
                }
            }
        } catch { }
    }
    $sw.Stop()

    $total = 0
    foreach ($k in $counts.Keys) { $total += [int]$counts[$k] }
    $log.Add(('[{0}] SWEEP COMPLETE :: {1} items :: {2}' -f (Get-Date -Format 'HH:mm:ss'), $total, (Format-InvDuration $sw.Elapsed.TotalSeconds)))
    try { Write-TextFile -Path (Join-Path $snapDir 'sweep.log') -Content (($log -join "`r`n") + "`r`n") } catch { }
    Reset-VaultStatus

    if ($ui) {
        Set-SweepStatus ''
        Draw-SweepBar 1.0
        if ($Script:SweepRows) {
            try { [Console]::SetCursorPosition(0, $Script:SweepRows.Next) } catch { }
        }
        Write-Host ''
    }
    return [PSCustomObject]@{
        Dir      = $snapDir
        Counts   = $counts
        Total    = $total
        Seconds  = $sw.Elapsed.TotalSeconds
        Cats     = $selected
        Drift    = $drift
        Baseline = $driftBase
        Pruned   = $pruned
    }
}

#endregion

#region ============================ SNAPSHOT DIFF =============================

function Get-SnapshotList {
    $root = Get-OutputRoot
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    $out = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $mp = Join-Path $d.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        try {
            $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            $out += [PSCustomObject]@{
                Name    = $d.Name
                Path    = $d.FullName
                Date    = "$($m.date)"
                Apps    = @($m.apps).Count
                Drivers = @($m.drivers).Count
            }
        } catch { }
    }
    return $out
}

function Get-VaultStatus {
    # Cached vault summary for the main menu. Call Reset-VaultStatus after
    # anything that adds or removes snapshots.
    if ($null -ne $Script:VaultStatusCache) { return $Script:VaultStatusCache }
    $snaps = @(Get-SnapshotList)
    $size = [long]0
    $newest = $null
    foreach ($s in $snaps) {
        try {
            $sum = (Get-ChildItem -LiteralPath $s.Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($sum) { $size += [long]$sum }
        } catch { }
        $d = $null
        try { $d = [datetime]$s.Date } catch { }
        if ($d -and (-not $newest -or $d -gt $newest)) { $newest = $d }
    }
    $Script:VaultStatusCache = [PSCustomObject]@{ Count = $snaps.Count; Newest = $newest; Bytes = $size }
    return $Script:VaultStatusCache
}

function Reset-VaultStatus { $Script:VaultStatusCache = $null }

function Get-SnapshotNote([string]$SnapPath) {
    # A snapshot's label, stored as plain note.txt (human-editable). '' when none.
    $p = Join-Path $SnapPath 'note.txt'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try {
        $t = (Get-Content -LiteralPath $p -Raw)
        return "$t".Trim()
    } catch { return '' }
}

function Set-SnapshotNote([string]$SnapPath, [string]$Note) {
    $p = Join-Path $SnapPath 'note.txt'
    $n = "$Note".Trim()
    try {
        if ($n -eq '') { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
        else { Write-TextFile -Path $p -Content ($n + "`r`n") }
        return $true
    } catch { return $false }
}

function Read-SnapshotNoteInput([string]$SnapPath, [string]$Current) {
    # Shared prompt for adding/editing a snapshot note. Returns $true if changed.
    Write-Host ''
    if ($Current) { Write-DimLine ('current note: ' + $Current) -Center }
    $v = Read-InvPrompt 'note for this snapshot (blank = keep, a single - clears it)'
    if ($v -eq '-') { [void](Set-SnapshotNote $SnapPath ''); return $true }
    if ($v -and $v.Trim() -ne '') { [void](Set-SnapshotNote $SnapPath $v.Trim()); return $true }
    return $false
}

function Get-InvSparkline($Vals) {
    # Compact block-glyph trend (chars built from code points to keep source ASCII).
    $v = @($Vals)
    if ($v.Count -eq 0) { return '' }
    $blocks = @()
    for ($i = 0x2581; $i -le 0x2588; $i++) { $blocks += [string][char]$i }
    $min = ($v | Measure-Object -Minimum).Minimum
    $max = ($v | Measure-Object -Maximum).Maximum
    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $v) {
        if ($max -eq $min) { $ix = 3 } else { $ix = [int][Math]::Round(($n - $min) / [double]($max - $min) * 7) }
        if ($ix -lt 0) { $ix = 0 }
        if ($ix -gt 7) { $ix = 7 }
        [void]$sb.Append($blocks[$ix])
    }
    return $sb.ToString()
}

function Get-VaultStats {
    # Aggregate lifetime stats + a chronological app-count series for the trend.
    $snaps = @(Get-SnapshotList | Sort-Object Name)   # oldest first
    $series = @()
    $names = @{}
    $first = ''
    $last = ''
    foreach ($s in $snaps) {
        $mp = Join-Path $s.Path 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        $m = $null
        try { $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json } catch { }
        if ($null -eq $m) { continue }
        $apps = @($m.apps)
        $series += [PSCustomObject]@{ Name = $s.Name; Date = "$($m.date)"; Apps = $apps.Count }
        foreach ($a in $apps) { $nm = "$($a.name)".ToLower(); if ($nm) { $names[$nm] = $true } }
        if (-not $first) { $first = "$($m.date)" }
        $last = "$($m.date)"
    }
    $bytes = [long]0
    try { $bytes = (Get-VaultStatus).Bytes } catch { }
    return [PSCustomObject]@{
        Count        = $snaps.Count
        Bytes        = $bytes
        DistinctApps = $names.Count
        First        = $first
        Last         = $last
        Baseline     = [string]$Script:Settings.baselineSnapshot
        Series       = @($series)
    }
}

function Find-InSnapshots([string]$Term) {
    # Walk every snapshot's manifest chronologically and build a per-app timeline:
    # first seen, still-present-or-last-seen, and the deduped version history.
    # Matches app name OR publisher, case-insensitive substring. Apps only.
    $term = "$Term".Trim().ToLower()
    if (-not $term) { return @() }
    $snaps = @(Get-SnapshotList | Sort-Object Name)   # names sort chronologically (oldest first)
    if ($snaps.Count -eq 0) { return @() }
    $latestName = $snaps[$snaps.Count - 1].Name
    $acc = [ordered]@{}
    foreach ($s in $snaps) {
        $mp = Join-Path $s.Path 'manifest.json'
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        $m = $null
        try { $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json } catch { }
        if ($null -eq $m) { continue }
        $date = "$($m.date)"
        foreach ($a in @($m.apps)) {
            $nm = "$($a.name)"
            if (-not $nm) { continue }
            $pub = "$($a.publisher)"
            if (-not ($nm.ToLower().Contains($term) -or $pub.ToLower().Contains($term))) { continue }
            $key = $nm.ToLower()
            if (-not $acc.Contains($key)) {
                $acc[$key] = [PSCustomObject]@{
                    Name         = $nm
                    FirstDate    = $date
                    LastSnap     = $s.Name
                    LastDate     = $date
                    Observations = (New-Object System.Collections.Generic.List[object])
                }
            }
            $e = $acc[$key]
            $e.Name = $nm            # keep the most recently seen display name/casing
            $e.LastSnap = $s.Name
            $e.LastDate = $date
            $e.Observations.Add([PSCustomObject]@{ Version = "$($a.version)"; Date = $date })
        }
    }
    $out = @()
    foreach ($key in @($acc.Keys)) {
        $e = $acc[$key]
        $vers = @()
        $prev = $null
        foreach ($ob in $e.Observations) {
            if ($null -eq $prev -or $prev -ne $ob.Version) { $vers += [PSCustomObject]@{ Version = $ob.Version; Date = $ob.Date } }
            $prev = $ob.Version
        }
        $presence = 'still present'
        if ($e.LastSnap -ne $latestName) { $presence = ('last seen ' + $e.LastDate) }
        $out += [PSCustomObject]@{
            Name      = $e.Name
            FirstDate = $e.FirstDate
            Presence  = $presence
            Versions  = @($vers)
        }
    }
    return @($out | Sort-Object Name)
}

function Invoke-SnapshotDiff([string]$PathA, [string]$PathB) {
    # A = baseline (older), B = comparison (newer)
    $ma = Get-Content -LiteralPath (Join-Path $PathA 'manifest.json') -Raw | ConvertFrom-Json
    $mb = Get-Content -LiteralPath (Join-Path $PathB 'manifest.json') -Raw | ConvertFrom-Json
    $mapOf = {
        param($items, [string]$KeyProp)
        $d = @{}
        foreach ($it in @($items)) {
            $k = ("$($it.$KeyProp)").ToLower()
            if ($k -and -not $d.ContainsKey($k)) { $d[$k] = $it }
        }
        return $d
    }
    $da = & $mapOf $ma.apps 'name'
    $db = & $mapOf $mb.apps 'name'
    $appAdd = @(); $appRem = @(); $appChg = @()
    foreach ($k in $db.Keys) {
        if (-not $da.ContainsKey($k)) { $appAdd += $db[$k] }
        elseif ("$($da[$k].version)" -ne "$($db[$k].version)") {
            $appChg += [PSCustomObject]@{ name = $db[$k].name; from = "$($da[$k].version)"; to = "$($db[$k].version)" }
        }
    }
    foreach ($k in $da.Keys) { if (-not $db.ContainsKey($k)) { $appRem += $da[$k] } }

    $keyDrv = {
        param($items)
        $d = @{}
        foreach ($it in @($items)) {
            $k = (("$($it.device)") + '|' + ("$($it.inf)")).ToLower()
            if (-not $d.ContainsKey($k)) { $d[$k] = $it }
        }
        return $d
    }
    $va = & $keyDrv $ma.drivers
    $vb = & $keyDrv $mb.drivers
    $drvAdd = @(); $drvRem = @(); $drvChg = @()
    foreach ($k in $vb.Keys) {
        if (-not $va.ContainsKey($k)) { $drvAdd += $vb[$k] }
        elseif ("$($va[$k].version)" -ne "$($vb[$k].version)") {
            $drvChg += [PSCustomObject]@{ device = $vb[$k].device; from = "$($va[$k].version)"; to = "$($vb[$k].version)" }
        }
    }
    foreach ($k in $va.Keys) { if (-not $vb.ContainsKey($k)) { $drvRem += $va[$k] } }

    $nameA = Split-Path $PathA -Leaf
    $nameB = Split-Path $PathB -Leaf
    $lines = @(New-ReportHeaderLines ('SNAPSHOT DIFF  ::  {0}  ->  {1}' -f $nameA, $nameB) (@($appAdd).Count + @($appRem).Count + @($appChg).Count + @($drvAdd).Count + @($drvRem).Count + @($drvChg).Count))
    $lines += ''
    $lines += ('  BASELINE   : {0}   ({1})' -f $nameA, "$($ma.date)")
    $lines += ('  COMPARISON : {0}   ({1})' -f $nameB, "$($mb.date)")
    $emit = {
        param([string]$Title, $Items, [string[]]$Cols)
        $Script:__diffLines += ''
        $Script:__diffLines += (New-SectionRule $Title @($Items).Count)
        $Script:__diffLines += ''
        if (@($Items).Count -eq 0) { $Script:__diffLines += '  (none)'; return }
        $Script:__diffLines += (Format-TextTable @($Items) $Cols)
    }
    $Script:__diffLines = $lines
    & $emit '+ APPS INSTALLED'   $appAdd @('name', 'version', 'publisher', 'source')
    & $emit '- APPS REMOVED'     $appRem @('name', 'version', 'publisher', 'source')
    & $emit '~ APPS UPDATED'     $appChg @('name', 'from', 'to')
    & $emit '+ DRIVERS ADDED'    $drvAdd @('device', 'provider', 'version')
    & $emit '- DRIVERS REMOVED'  $drvRem @('device', 'provider', 'version')
    & $emit '~ DRIVERS UPDATED'  $drvChg @('device', 'from', 'to')
    $lines = $Script:__diffLines
    Remove-Variable -Name '__diffLines' -Scope Script -ErrorAction SilentlyContinue
    $lines += ''
    $lines += ('  // generated by {0} v{1}' -f $Script:Brand.Short, $Script:Brand.Version)

    $outPath = Join-Path (Get-OutputRoot) ('DIFF_{0}_vs_{1}.txt' -f $nameA, $nameB)
    Write-TextFile -Path $outPath -Content (($lines -join "`r`n") + "`r`n")
    return [PSCustomObject]@{
        Path    = $outPath
        AppAdd  = @($appAdd).Count
        AppRem  = @($appRem).Count
        AppChg  = @($appChg).Count
        DrvAdd  = @($drvAdd).Count
        DrvRem  = @($drvRem).Count
        DrvChg  = @($drvChg).Count
    }
}

#endregion

#region ============================ RESTORE WIZARD =============================

# In-app step-by-step reinstall from any snapshot. FAILSAFES: nothing installs
# until the plan is reviewed AND the final gate is armed with Y; Q aborts the run
# between packages; every run is appended to the snapshot's restore.log.

function Get-RestorePlan([string]$SnapPath) {
    # A snapshot's restore data: winget package ids + the manual-only program list.
    $ids = @()
    $wx = Join-Path $SnapPath 'winget_export.json'
    if (Test-Path -LiteralPath $wx) {
        try {
            $ex = Get-Content -LiteralPath $wx -Raw | ConvertFrom-Json
            foreach ($src in @($ex.Sources)) {
                foreach ($p in @($src.Packages)) {
                    if ($p.PackageIdentifier) { $ids += [string]$p.PackageIdentifier }
                }
            }
        } catch { }
    }
    $ids = @($ids | Sort-Object -Unique)
    $manual = @()
    $mp = Join-Path $SnapPath 'manifest.json'
    if (Test-Path -LiteralPath $mp) {
        try {
            $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            $reg = @(@($m.apps) | Where-Object { "$($_.source)" -eq 'registry' })
            $manual = @(Get-ManualMatchList $ids $reg)
        } catch { }
    }
    return @{ Ids = $ids; Manual = $manual }
}

function Show-RestoreNotice([string[]]$Lines) {
    Clear-Host
    Write-Host ''
    Write-GradLine '::  RESTORE FROM SNAPSHOT  ::' -Center
    Write-Host ''
    foreach ($l in $Lines) { Write-DimLine $l -Center }
    Write-Host ''
    Write-FaintLine 'any key to return' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Show-PackagePicker([string[]]$Ids, $Checked) {
    # Scrollable checkbox list - 50+ packages never fit a static screen.
    # Returns $true on enter (choices live in $Checked), $null on esc.
    $sel = 0
    $top = 0
    while ($true) {
        $vis = 10
        try { $vis = [Math]::Max(5, [Console]::WindowHeight - 12) } catch { }
        if ($vis -gt $Ids.Count) { $vis = $Ids.Count }
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $vis) { $top = $sel - $vis + 1 }
            if ($top -lt 0) { $top = 0 }
            Clear-Host
            Write-Host ''
            Write-GradLine '::  SELECT PACKAGES TO REINSTALL  ::' -Center
            Write-Host ''
            $maxw = 0
            foreach ($o in $Ids) { if ($o.Length -gt $maxw) { $maxw = $o.Length } }
            $pad = Get-CenterPad ($maxw + 14)
            if ($top -gt 0) { Write-FaintLine ('^  {0} more above  ^' -f $top) -Center } else { Write-Host '' }
            for ($i = $top; $i -lt ($top + $vis); $i++) {
                $mark = '[ ]'
                if ($Checked[$Ids[$i]]) { $mark = '[x]' }
                $line = ('{0}  [{1,3}]  {2}' -f $mark, ($i + 1), $Ids[$i])
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>> ' + $line))) }
                elseif ($Checked[$Ids[$i]]) { Write-Host ($pad + (Get-Txt ('   ' + $line))) }
                else { Write-Host ($pad + (Get-Dim ('   ' + $line))) }
            }
            $below = $Ids.Count - ($top + $vis)
            if ($below -gt 0) { Write-FaintLine ('v  {0} more below  v' -f $below) -Center } else { Write-Host '' }
            Write-Host ''
            $n = 0
            foreach ($id in $Ids) { if ($Checked[$id]) { $n++ } }
            Write-DimLine ('{0} of {1} packages marked for reinstall' -f $n, $Ids.Count) -Center
            Write-FaintLine 'space toggle  //  A all  //  N none  //  I invert  //  pgup/pgdn jump  //  enter continue  //  esc back' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $Ids.Count - 1) % $Ids.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $Ids.Count }
        elseif ($k.Key -eq [ConsoleKey]::PageUp)    { $sel = [Math]::Max(0, $sel - $vis) }
        elseif ($k.Key -eq [ConsoleKey]::PageDown)  { $sel = [Math]::Min($Ids.Count - 1, $sel + $vis) }
        elseif ($k.Key -eq [ConsoleKey]::Home)      { $sel = 0 }
        elseif ($k.Key -eq [ConsoleKey]::End)       { $sel = $Ids.Count - 1 }
        elseif ($k.Key -eq [ConsoleKey]::Spacebar)  { $Checked[$Ids[$sel]] = -not $Checked[$Ids[$sel]] }
        elseif ([string]$k.KeyChar -match '^[aA]$') { foreach ($id in $Ids) { $Checked[$id] = $true } }
        elseif ([string]$k.KeyChar -match '^[nN]$') { foreach ($id in $Ids) { $Checked[$id] = $false } }
        elseif ([string]$k.KeyChar -match '^[iI]$') { foreach ($id in $Ids) { $Checked[$id] = -not $Checked[$id] } }
        elseif ($k.Key -eq [ConsoleKey]::Escape)    { return $null }
        elseif ($k.Key -eq [ConsoleKey]::Enter)     { return $true }
    }
}

function Show-RestoreReview([string]$SnapName, [string[]]$Sel, [int]$TotalIds, [int]$ManualCount) {
    # Confirmation 1 of 2. Returns 'go' | 'dry' | 'back' | 'quit'.
    while ($true) {
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            Write-Host ''
            Write-GradLine '::  RESTORE PLAN REVIEW  ::' -Center
            Write-Host ''
            Write-DimLine ('source snapshot  ::  ' + $SnapName) -Center
            Write-TxtLine ('{0} of {1} winget packages selected for reinstall' -f $Sel.Count, $TotalIds) -Center
            if ($ManualCount -gt 0) { Write-DimLine ('+ {0} manual-only programs (checklist offered at the end)' -f $ManualCount) -Center }
            Write-Host ''
            foreach ($s in @($Sel | Select-Object -First 10)) { Write-DimLine $s -Center }
            if ($Sel.Count -gt 10) { Write-FaintLine ('... and {0} more' -f ($Sel.Count - 10)) -Center }
            Write-Host ''
            if (-not (Test-IsAdmin)) {
                $w = 'not elevated - some installers may prompt or fail; consider relaunching elevated'
                Write-Host ((Get-CenterPad $w.Length) + (Get-Warn $w))
                Write-Host ''
            }
            Write-FaintLine '[ENTER] continue to final confirmation  //  [D] dry run preview  //  [B] back to selection  //  [ESC] cancel' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::Enter)     { return 'go' }
        elseif ([string]$k.KeyChar -match '^[dD]$') { return 'dry' }
        elseif ([string]$k.KeyChar -match '^[bB]$') { return 'back' }
        elseif ($k.Key -eq [ConsoleKey]::Escape -or [string]$k.KeyChar -match '^[qQ]$') { return 'quit' }
    }
}

function Show-RestoreArm([int]$Count) {
    # Confirmation 2 of 2 - the ONLY gate that can start a live install.
    Clear-Host
    Write-Host ''
    Write-GradLine '::  FINAL CONFIRMATION  ::' -Center
    Write-Host ''
    $l1 = ('winget is about to install {0} packages on this machine.' -f $Count)
    Write-Host ((Get-CenterPad $l1.Length) + (Get-Warn $l1))
    Write-DimLine 'installers will download and run - this changes this PC.' -Center
    Write-Host ''
    Write-FaintLine '[Y] begin the restore  //  any other key goes back' -Center
    Clear-KeyBuffer
    $k = [Console]::ReadKey($true)
    return ([string]$k.KeyChar -match '^[yY]$')
}

function Invoke-RestoreRun([string]$SnapPath, [string[]]$Sel, [bool]$DryRun) {
    $snapName = Split-Path $SnapPath -Leaf
    $mode = 'LIVE'
    if ($DryRun) { $mode = 'DRY RUN' }
    $log = New-Object System.Collections.Generic.List[string]
    $log.Add(('[{0}] RESTORE START :: {1} {2} :: {3} :: {4} packages :: {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Script:Brand.Name, (Get-BuildString), $snapName, $Sel.Count, $mode))
    $sw = [Diagnostics.Stopwatch]::StartNew()

    Clear-Host
    try { [Console]::CursorVisible = $false } catch { }
    Write-Host ''
    $title = '::  RESTORE IN PROGRESS  ::'
    if ($DryRun) { $title = '::  RESTORE DRY RUN  ::' }
    Write-GradLine $title -Center
    Write-DimLine ('source ' + $snapName + '  //  ' + $Sel.Count + ' packages  //  ' + $mode) -Center
    if (-not $DryRun) { Write-FaintLine 'press Q to stop between packages - the current install always finishes' -Center }
    Write-Host ''
    $Script:SweepRows = $null
    $tallEnough = $false
    try { $tallEnough = ([Console]::WindowHeight -ge (13 + $Sel.Count)) } catch { }
    if ($tallEnough) {
        try {
            $barRow = [Console]::CursorTop
            Write-Host ''
            Write-Host ''
            $statusRow = [Console]::CursorTop
            Write-Host ''
            Write-Host ''
            $Script:SweepRows = @{ Bar = $barRow; Status = $statusRow; Next = [Console]::CursorTop }
        } catch { $Script:SweepRows = $null }
    }
    Draw-SweepBar 0

    $done = 0
    $okN = 0
    $skipN = 0
    $failIds = @()
    $aborted = $false
    foreach ($id in $Sel) {
        if (-not $DryRun -and (Test-KeyAvailable)) {
            while (Test-KeyAvailable) {
                $kk = [Console]::ReadKey($true)
                if ([string]$kk.KeyChar -match '^[qQ]$' -or $kk.Key -eq [ConsoleKey]::Escape) { $aborted = $true }
            }
            if ($aborted) { break }
        }
        $frac0 = $done / [double]$Sel.Count
        Set-SweepStatus ('INSTALLING  {0}/{1}  {2}' -f ($done + 1), $Sel.Count, $id)
        $t0 = [DateTime]::Now
        $status = '[ OK ]'
        $role = 'ok'
        if ($DryRun) {
            $status = '[DRY ]'
            $role = 'lock'
            $log.Add(('[{0}] [DRY ] winget install --id {1} --exact' -f (Get-Date -Format 'HH:mm:ss'), $id))
            $null = Invoke-Nap 40   # nap returns a skip-signal bool - never let it leak into the return
            $okN++
        } else {
            $outTxt = ''
            $code = 0
            try {
                # captured via cmd so winget's progress spinner cannot shred the fixed layout
                $outTxt = ((cmd /c "winget install --id `"$id`" --exact --silent --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1") -join ' ')
                $code = $LASTEXITCODE
            } catch { $code = -1; $outTxt = "$($_.Exception.Message)" }
            if ($code -eq 0) { $okN++ }
            elseif ($code -eq -1978335189 -or $outTxt -match 'already installed') { $status = '[SKIP]'; $role = 'lock'; $skipN++ }
            else { $status = '[FAIL]'; $role = 'warn'; $failIds += $id }
            $log.Add(('[{0}] {1} {2} :: exit {3}' -f (Get-Date -Format 'HH:mm:ss'), $status, $id, $code))
            if ($status -eq '[FAIL]' -and $outTxt) {
                $tail = $outTxt
                if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
                $log.Add('           ' + $tail.Trim())
            }
        }
        $done++
        $dur = Format-InvDuration (([DateTime]::Now - $t0).TotalSeconds)
        $line = ('{0}  {1,-46} {2,10}' -f $status, $id, ('(' + $dur + ')'))
        if ($Script:Interactive) {
            Add-SweepResult $line $role
            Show-SweepBarAnimation $frac0 ($done / [double]$Sel.Count)
        } else {
            Write-Host $line
        }
    }
    $sw.Stop()

    if ($aborted) { $log.Add(('[{0}] RESTORE STOPPED BY USER :: {1} of {2} processed' -f (Get-Date -Format 'HH:mm:ss'), $done, $Sel.Count)) }
    $log.Add(('[{0}] RESTORE COMPLETE :: {1} ok / {2} skipped / {3} failed :: {4}' -f (Get-Date -Format 'HH:mm:ss'), $okN, $skipN, $failIds.Count, (Format-InvDuration $sw.Elapsed.TotalSeconds)))
    try {
        [IO.File]::AppendAllText((Join-Path $SnapPath 'restore.log'), (($log -join "`r`n") + "`r`n`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

    Set-SweepStatus ''
    if (-not $aborted) { Draw-SweepBar 1.0 }
    if ($Script:SweepRows) {
        try { [Console]::SetCursorPosition(0, $Script:SweepRows.Next) } catch { }
    }
    return [PSCustomObject]@{
        Ok      = $okN
        Skip    = $skipN
        Fail    = @($failIds)
        Aborted = $aborted
        Dry     = $DryRun
        Done    = $done
        Total   = $Sel.Count
        Seconds = $sw.Elapsed.TotalSeconds
    }
}

function Show-ManualChecklist([string[]]$Manual) {
    # Pager for the programs winget could not match - reinstall these by hand.
    $i = 0
    while ($i -lt $Manual.Count) {
        Clear-Host
        Write-Host ''
        Write-GradLine '::  MANUAL REINSTALL CHECKLIST  ::' -Center
        Write-DimLine 'winget could not match these - reinstall from the vendor installer or MS Store' -Center
        Write-Host ''
        $page = 15
        try { $page = [Math]::Max(5, [Console]::WindowHeight - 10) } catch { }
        foreach ($m in @($Manual | Select-Object -Skip $i -First $page)) { Write-DimLine $m -Center }
        $i += $page
        Write-Host ''
        if ($i -lt $Manual.Count) { Write-FaintLine ('{0} more  //  any key = next page  //  esc = done' -f ($Manual.Count - $i)) -Center }
        else { Write-FaintLine 'end of checklist  //  any key to return' -Center }
        Clear-KeyBuffer
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Escape) { return }
    }
}

function Show-RestoreSummary($Res, [string[]]$Manual) {
    if ($null -eq $Res) { return }
    Write-Host ''
    $title = '::  RESTORE COMPLETE  ::'
    if ($Res.Dry) { $title = '::  DRY RUN COMPLETE - NOTHING WAS INSTALLED  ::' }
    if ($Res.Aborted) { $title = '::  RESTORE STOPPED  ::' }
    Write-GradLine $title -Center
    Write-Host ''
    Write-TxtLine ('{0} ok  //  {1} skipped (already present)  //  {2} failed  //  {3}' -f $Res.Ok, $Res.Skip, @($Res.Fail).Count, (Format-InvDuration $Res.Seconds)) -Center
    if ($Res.Aborted) { Write-DimLine ('stopped after {0} of {1} - finished installs are kept; re-run the wizard to continue' -f $Res.Done, $Res.Total) -Center }
    if (@($Res.Fail).Count -gt 0) {
        Write-Host ''
        Write-DimLine 'did not install cleanly (output tail kept in restore.log):' -Center
        foreach ($f in @($Res.Fail | Select-Object -First 8)) { Write-Host ((Get-CenterPad $f.Length) + (Get-Warn $f)) }
        if (@($Res.Fail).Count -gt 8) { Write-FaintLine ('... and {0} more - see restore.log' -f (@($Res.Fail).Count - 8)) -Center }
    }
    Write-Host ''
    if ($Manual.Count -gt 0) { Write-FaintLine ('[M] manual checklist ({0} programs)  //  any other key to return' -f $Manual.Count) -Center }
    else { Write-FaintLine 'any key to return' -Center }
    Clear-KeyBuffer
    $k = [Console]::ReadKey($true)
    if ($Manual.Count -gt 0 -and [string]$k.KeyChar -match '^[mM]$') { Show-ManualChecklist $Manual }
}

function Show-RestoreWizard {
    if ($null -eq (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
        Show-RestoreNotice @('winget is not available on this machine.', 'install "App Installer" from the Microsoft Store, then return here.')
        return
    }
    $snaps = @(Get-SnapshotList)
    $usable = @()
    $plans = @{}
    foreach ($s in $snaps) {
        $plan = Get-RestorePlan $s.Path
        if ($plan.Ids.Count -gt 0 -or $plan.Manual.Count -gt 0) {
            $usable += $s
            $plans[$s.Path] = $plan
        }
    }
    if ($usable.Count -eq 0) {
        Show-RestoreNotice @(('no snapshot with restore data found in ' + (Get-OutputRoot)), 'run a FULL SYSTEM SWEEP (with the restore script toggle ON) first.')
        return
    }
    $opts = @($usable | ForEach-Object { ('{0}   {1,3} winget pkgs   {2,3} manual-only' -f $_.Name, $plans[$_.Path].Ids.Count, $plans[$_.Path].Manual.Count) })
    $ix = Show-ListPicker 'RESTORE  ::  SELECT SOURCE SNAPSHOT' $opts 'enter select  //  esc back'
    if ($ix -lt 0) { return }
    $snap = $usable[$ix]
    $plan = $plans[$snap.Path]
    if ($plan.Ids.Count -eq 0) {
        Show-ManualChecklist $plan.Manual
        return
    }
    $checked = @{}
    foreach ($id in $plan.Ids) { $checked[$id] = $true }
    while ($true) {
        $r = Show-PackagePicker $plan.Ids $checked
        if ($null -eq $r) { return }
        $sel = @($plan.Ids | Where-Object { $checked[$_] })
        if ($sel.Count -eq 0) { continue }   # nothing marked -> stay in the picker
        $review = $true
        while ($review) {
            $act = Show-RestoreReview $snap.Name $sel $plan.Ids.Count $plan.Manual.Count
            if ($act -eq 'back') { $review = $false }
            elseif ($act -eq 'quit') { return }
            elseif ($act -eq 'dry') {
                $res = Invoke-RestoreRun $snap.Path $sel $true
                Show-RestoreSummary $res $plan.Manual
            }
            elseif ($act -eq 'go') {
                if (Show-RestoreArm $sel.Count) {
                    $res = Invoke-RestoreRun $snap.Path $sel $false
                    Show-RestoreSummary $res $plan.Manual
                    return
                }
            }
        }
    }
}

#endregion

#region ============================ SCHEDULER =================================

# Windows Task Scheduler integration. The registered task itself is the single
# source of truth - no schedule state is stored in settings.json.

$Script:ScheduleTaskName = 'COVERT Inventorizer Sweep'

function Get-SweepSchedule {
    # $null when no task exists; otherwise @{ State; NextRun }
    try {
        $t = Get-ScheduledTask -TaskName $Script:ScheduleTaskName -ErrorAction Stop
        $next = ''
        try {
            $info = Get-ScheduledTaskInfo -TaskName $Script:ScheduleTaskName -ErrorAction Stop
            if ($info.NextRunTime) { $next = "$($info.NextRunTime)" }
        } catch { }
        return @{ State = "$($t.State)"; NextRun = $next }
    } catch { return $null }
}

function Install-SweepSchedule([string]$Freq, [string]$Time) {
    # Freq: daily | weekly. Returns '' on success, otherwise an error message.
    # FAILSAFE: registration is verified by querying the task back.
    $Freq = "$Freq".Trim().ToLower()
    if (@('daily', 'weekly') -notcontains $Freq) { return ("unknown frequency '" + $Freq + "' - use daily or weekly") }
    $t = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact("$Time", 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)) {
        return ("invalid time '" + $Time + "' - use 24h HH:mm")
    }
    if (-not (Test-IsAdmin)) { return 'creating the scheduled task requires elevation - relaunch as administrator' }
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Full -Silent' -f $PSCommandPath) `
            -WorkingDirectory (Split-Path $PSCommandPath -Parent)
        $trigger = $null
        if ($Freq -eq 'daily') { $trigger = New-ScheduledTaskTrigger -Daily -At $t }
        else { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $t }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
        $principal = New-ScheduledTaskPrincipal -UserId ("$env:USERDOMAIN\$env:USERNAME") -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $Script:ScheduleTaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        if ($null -eq (Get-SweepSchedule)) { return 'task registration could not be verified - check Task Scheduler' }
        return ''
    } catch { return ('task registration failed - ' + "$($_.Exception.Message)".Trim()) }
}

function Remove-SweepSchedule {
    # Returns '' on success, otherwise an error message.
    try {
        Unregister-ScheduledTask -TaskName $Script:ScheduleTaskName -Confirm:$false -ErrorAction Stop
        return ''
    } catch { return ('task removal failed - ' + "$($_.Exception.Message)".Trim()) }
}

function Show-ScheduleScreen {
    $freqs = @('weekly', 'daily')
    $fi = 0
    $hour = 9
    $msg = ''
    $msgOk = $false
    while ($true) {
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            Write-Host ''
            Write-GradLine '::  SCHEDULED SWEEPS  ::' -Center
            Write-Host ''
            $cur = Get-SweepSchedule
            if ($cur) {
                Write-TxtLine ('a scheduled sweep task exists  ::  state ' + $cur.State) -Center
                if ($cur.NextRun) { Write-DimLine ('next run  ::  ' + $cur.NextRun) -Center }
            } else {
                Write-DimLine 'no scheduled sweep task exists on this machine.' -Center
            }
            Write-Host ''
            Write-TxtLine ('new task  ::  {0}  at  {1:d2}:00' -f $freqs[$fi].ToUpper(), $hour) -Center
            Write-DimLine 'runs a silent full sweep in the background while you are logged on' -Center
            if (-not (Test-IsAdmin)) {
                $w = 'creating or removing the task requires elevation'
                Write-Host ((Get-CenterPad $w.Length) + (Get-Warn $w))
            }
            if ($msg) {
                $colored = Get-Warn $msg
                if ($msgOk) { $colored = Get-Accent $msg }
                Write-Host ((Get-CenterPad $msg.Length) + $colored)
            }
            Write-Host ''
            Write-FaintLine '[F] frequency  //  [H] hour  //  [A] apply - create/replace task  //  [R] remove task  //  esc back' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        $msg = ''
        $msgOk = $false
        if     ([string]$k.KeyChar -match '^[fF]$') { $fi = ($fi + 1) % $freqs.Count }
        elseif ([string]$k.KeyChar -match '^[hH]$') { $hour = ($hour + 1) % 24 }
        elseif ([string]$k.KeyChar -match '^[aA]$') {
            $err = Install-SweepSchedule $freqs[$fi] ('{0:d2}:00' -f $hour)
            if ($err) { $msg = $err } else { $msg = 'scheduled sweep task created.'; $msgOk = $true }
        }
        elseif ([string]$k.KeyChar -match '^[rR]$') {
            if ($null -eq (Get-SweepSchedule)) { $msg = 'no task to remove.' }
            else {
                $err = Remove-SweepSchedule
                if ($err) { $msg = $err } else { $msg = 'scheduled sweep task removed.'; $msgOk = $true }
            }
        }
        elseif ($k.Key -eq [ConsoleKey]::Escape) { return }
    }
}

#endregion

#region ============================ UPDATE ENGINE =============================

function Compare-InvVersion([string]$A, [string]$B) {
    # -1 if A < B, 0 if equal, 1 if A > B. Numeric per component, tolerates 'v' prefixes.
    $pa = @(("$A".TrimStart('v', 'V') -split '\.') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    $pb = @(("$B".TrimStart('v', 'V') -split '\.') | ForEach-Object { $n = 0; [void][int]::TryParse($_, [ref]$n); $n })
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { $x = $pa[$i] }
        if ($i -lt $pb.Count) { $y = $pb[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function Get-UpdateManifest {
    $url = ("$($Script:Brand.UpdateUrl)").Trim()
    if (-not $url) { return $null }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $content = $resp.Content
        if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        return ("$content" | ConvertFrom-Json)
    } catch { return $null }
}

function Test-ForUpdate {
    # $null when up to date, channel unreachable, or no channel configured.
    $man = Get-UpdateManifest
    if ($null -eq $man -or -not $man.version) { return $null }
    if ((Compare-InvVersion $Script:Brand.Version "$($man.version)") -ge 0) { return $null }
    $newer = @()
    foreach ($e in @($man.changelog)) {
        if ($e.version -and (Compare-InvVersion $Script:Brand.Version "$($e.version)") -lt 0) { $newer += $e }
    }
    $highlights = @()
    foreach ($e in $newer) {
        foreach ($h in @($e.highlights)) { if ("$h") { $highlights += "$h" } }
    }
    if ($highlights.Count -eq 0) {
        foreach ($e in $newer) { foreach ($nt in @($e.notes)) { if ("$nt") { $highlights += "$nt" } } }
        $highlights = @($highlights | Select-Object -First 6)
    }
    return [PSCustomObject]@{
        Latest     = "$($man.version)".TrimStart('v', 'V')
        ScriptUrl  = "$($man.scriptUrl)"
        Sha256     = "$($man.sha256)"
        Highlights = $highlights
        Entries    = $newer
    }
}

function Show-ChangelogScreen($Upd) {
    Clear-Host
    Write-Host ''
    Write-GradLine '::  FULL CHANGELOG  ::' -Center
    Write-DimLine ('every build between v' + $Script:Brand.Version + ' and v' + $Upd.Latest) -Center
    Write-Host ''
    foreach ($e in @($Upd.Entries)) {
        $date = ''
        if ($e.date) { $date = '   (' + "$($e.date)" + ')' }
        Write-Host ('  ' + (Format-GradientText ('v' + ("$($e.version)".TrimStart('v', 'V')) + $date)))
        foreach ($h in @($e.highlights)) { if ("$h") { Write-Host ('    ' + (Get-Accent ('*  ' + "$h"))) } }
        foreach ($nt in @($e.notes))     { if ("$nt") { Write-Host ('    ' + (Get-Dim    ('-  ' + "$nt"))) } }
        Write-Host ''
    }
    Write-FaintLine 'any key to return' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Invoke-SelfUpdate($Upd) {
    # Downloads, verifies (sha256 + syntax parse), backs up, replaces this script and relaunches.
    # Only ever returns on failure.
    Clear-Host
    Write-Host ''
    Write-GradLine '::  SELF-UPDATE IN PROGRESS  ::' -Center
    Write-Host ''
    $fail = {
        param([string]$Msg)
        Write-Host ''
        Write-Host ((Get-CenterPad $Msg.Length) + (Get-Warn $Msg))
        Write-FaintLine 'any key to return' -Center
        Clear-KeyBuffer
        [void][Console]::ReadKey($true)
        return $false
    }
    if (-not ("$($Upd.ScriptUrl)").Trim()) { return (& $fail 'the update manifest has no scriptUrl - cannot update automatically.') }
    $tmp = Join-Path $env:TEMP ('inv_update_' + ([guid]::NewGuid().ToString('N')) + '.ps1')
    try {
        Write-DimLine ('downloading v' + $Upd.Latest + ' ...') -Center
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
        Invoke-WebRequest -Uri $Upd.ScriptUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        if (("$($Upd.Sha256)").Trim()) {
            $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
            if ($hash -ne ("$($Upd.Sha256)").Trim().ToUpper()) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
                return (& $fail 'integrity check FAILED - download hash does not match the manifest. update aborted.')
            }
            Write-DimLine 'integrity verified :: sha256 match' -Center
        }
        $perrs = $null; $ptoks = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$ptoks, [ref]$perrs)
        if ($perrs.Count -gt 0) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return (& $fail 'downloaded script failed syntax validation - update aborted.')
        }
        Write-DimLine 'syntax validated' -Center
        $bakDir = Join-Path $Script:ConfigDir 'backup'
        New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
        Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $bakDir ('Inventorizer_v' + $Script:Brand.Version + '.ps1')) -Force
        Copy-Item -LiteralPath $tmp -Destination $PSCommandPath -Force
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-DimLine ('previous build archived -> config\backup\Inventorizer_v' + $Script:Brand.Version + '.ps1') -Center
        Write-Host ''
        Write-GradLine ('::  UPDATED TO v' + $Upd.Latest + '  //  RELAUNCHING  ::') -Center
        Start-Sleep -Milliseconds 1100
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        exit
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return (& $fail ('update failed :: ' + $_.Exception.Message))
    }
}

function Show-UpdateScreen($Upd) {
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-GradLine '::  UPDATE AVAILABLE  ::' -Center
        Write-Host ''
        Write-TxtLine ('a newer version is available  ::  v{0}  ->  v{1}' -f $Script:Brand.Version, $Upd.Latest) -Center
        Write-Host ''
        if (@($Upd.Highlights).Count -gt 0) {
            Write-DimLine 'what this machine is missing out on:' -Center
            Write-Host ''
            $maxw = 0
            foreach ($h in $Upd.Highlights) { if ("$h".Length -gt $maxw) { $maxw = "$h".Length } }
            $pad = Get-CenterPad ($maxw + 3)
            foreach ($h in $Upd.Highlights) { Write-Host ($pad + (Get-Accent ('>  ' + "$h"))) }
            Write-Host ''
        }
        Write-FaintLine '[U] update now  //  [C] full changelog  //  [S] skip this version  //  any key later' -Center
        Clear-KeyBuffer
        $k = [Console]::ReadKey($true)
        $ch = [string]$k.KeyChar
        if ($ch -match '^[uU]$') {
            [void](Invoke-SelfUpdate $Upd)   # exits + relaunches on success; falls through on failure
        } elseif ($ch -match '^[cC]$') {
            Show-ChangelogScreen $Upd
        } elseif ($ch -match '^[sS]$') {
            $Script:Settings.skippedVersion = $Upd.Latest
            Save-InvSettings
            return
        } else {
            return
        }
    }
}

#endregion

#region ============================ FAILSAFES =================================

function Enable-SafeMode {
    # In-memory rescue state: built-in defaults, no animations, no boot art.
    # The saved config file is deliberately left untouched - inspect or reset it
    # from SETTINGS > RESET CONFIG TO DEFAULTS.
    $Script:SafeMode = $true
    $Script:Settings = Get-DefaultSettings
    $Script:Settings.logo = 'minimal'
    $Script:Settings.theme = 'void'
    $Script:Settings.animations = $false
    $Script:Settings.bootSequence = $false
    $Script:Settings.updateCheck = $false
    Apply-InvTheme 'void'
}

function Invoke-SafeModeGate {
    # 2-second boot window: press S to start with a clean default config.
    if (-not $Script:Interactive -or $Script:SafeMode) { return }
    $line = ('booting ' + $Script:Brand.Name + ' ' + (Get-BuildString) + '  //  press [S] within 2s for SAFE MODE')
    Write-Host ''
    Write-Host ((Get-CenterPad $line.Length) + (Get-Dim $line))
    $end = [DateTime]::Now.AddSeconds(2)
    while ([DateTime]::Now -lt $end) {
        try {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ([string]$k.KeyChar -match '^[sS]$') {
                    Enable-SafeMode
                    $note = '[ SAFE MODE ] defaults loaded - your saved config file was not touched.'
                    Write-Host ((Get-CenterPad $note.Length) + (Get-Warn $note))
                    Start-Sleep -Milliseconds 1200
                    return
                }
            }
        } catch { return }
        Start-Sleep -Milliseconds 40
    }
}

function Show-CrashScreen($ErrRecord) {
    # Containment for unexpected UI faults: show the error instead of dying,
    # offer safe mode as a rollback. $true = keep running, $false = quit.
    if (-not $Script:Interactive) { return $false }
    try {
        Clear-Host
        Write-Host ''
        Write-GradLine '::  UNEXPECTED ERROR  ::' -Center
        Write-Host ''
        $msg = 'unknown fault'
        $where = ''
        try { $msg = "$($ErrRecord.Exception.Message)".Trim() } catch { }
        try { $where = ('at line ' + $ErrRecord.InvocationInfo.ScriptLineNumber) } catch { }
        if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 88) + '..' }
        Write-Host ((Get-CenterPad $msg.Length) + (Get-Warn $msg))
        if ($where) { Write-DimLine $where -Center }
        Write-Host ''
        Write-DimLine 'the error was caught before it could close the application.' -Center
        Write-Host ''
        Write-FaintLine '[S] continue in SAFE MODE (defaults)  //  [Q] quit  //  any other key: retry as-is' -Center
        Clear-KeyBuffer
        $k = [Console]::ReadKey($true)
        $ch = [string]$k.KeyChar
        if ($ch -match '^[qQ]$') { return $false }
        if ($ch -match '^[sS]$') { Enable-SafeMode }
        return $true
    } catch { return $false }
}

#endregion

#region ============================ UI SCREENS ===============================

function Get-AllCollectorIds { return @($Script:CollectorRegistry | ForEach-Object { $_.Id }) }

function Write-FaintLine([string]$Text, [switch]$Center) {
    $out = Get-Faint $Text
    if ($Center) { $pad = Get-CenterPad $Text.Length; Record-MenuSpan $pad.Length $Text.Length; $out = $pad + $out }
    Write-Host $out
}

function Show-ListPicker([string]$Title, [string[]]$Options, [string]$Footer, [int]$Preselect = 0, $OnPreview = $null) {
    # $OnPreview (optional): a scriptblock called with the highlighted index when
    # the user presses P - used by the setup wizard to preview themes/logos/boots.
    $sel = $Preselect
    if ($sel -lt 0 -or $sel -ge $Options.Count) { $sel = 0 }
    while ($true) {
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            Write-Host ''
            Write-GradLine ('::  ' + $Title + '  ::') -Center
            Write-Host ''
            $maxw = 0
            foreach ($o in $Options) { if ($o.Length -gt $maxw) { $maxw = $o.Length } }
            $pad = Get-CenterPad ($maxw + 5)
            for ($i = 0; $i -lt $Options.Count; $i++) {
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>> ' + $Options[$i]))) }
                else             { Write-Host ($pad + (Get-Dim       ('   ' + $Options[$i]))) }
            }
            Write-Host ''
            Write-FaintLine $Footer -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $Options.Count - 1) % $Options.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $Options.Count }
        elseif ($k.Key -eq [ConsoleKey]::Enter)     { return $sel }
        elseif ($k.Key -eq [ConsoleKey]::Escape)    { return -1 }
        elseif ($OnPreview -and [string]$k.KeyChar -match '^[pP]$') { try { & $OnPreview $sel } catch { } }
    }
}

function Show-ThemePreviewMock {
    # A representative screen drawn in whatever theme is active - so a preview
    # shows the palette on real-looking content (logo, identity, bar, roles).
    Clear-Host
    Write-Host ''
    $logoName = [string]$Script:Settings.logo
    try { if ([Console]::WindowHeight -lt 34 -and $logoName -ne 'minimal') { $logoName = 'minimal' } } catch { }
    Show-Logo $logoName
    Write-Host ''
    Write-GradLine '::  THEME PREVIEW  ::' -Center
    Write-Host ''
    Show-IdentityBlock
    Write-Host ''
    Write-Host ((Get-CenterPad 24) + (Get-BarString 0.7 20) + (Get-Dim ' 70%'))
    Write-Host ''
    Write-Host ((Get-CenterPad 46) + (Get-Accent '[ OK ]') + (Get-Dim '  ') + (Get-Txt 'INSTALLED PROGRAMS') + (Get-Dim '   113 items') + (Get-Faint '  (0.4s)'))
    Write-Host ((Get-CenterPad 30) + (Format-GradientText '  >>  [1]  FULL SYSTEM SWEEP'))
    Write-Host ((Get-CenterPad 42) + (Get-Warn '- APPS REMOVED   2') + (Get-Dim '   //   ') + (Get-Violet '~ APPS UPDATED   9'))
    Write-Host ''
    Write-FaintLine 'any key to return to the picker' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Preview-InvTheme([string]$Name) {
    $saved = [string]$Script:Settings.theme
    Apply-InvTheme $Name
    Show-ThemePreviewMock
    Apply-InvTheme $saved   # restore the theme the picker is running in
}

function Preview-InvLogo([string]$Name) {
    Clear-Host
    Write-Host ''
    Write-Host ''
    Show-Logo $Name
    Write-Host ''
    Write-DimLine (Get-LogoLabel $Name) -Center
    Write-Host ''
    Write-FaintLine 'any key to return to the picker' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Preview-InvBoot([string]$Name) {
    if ($Name -eq 'none' -or $Name -eq 'random') {
        Clear-Host
        Write-Host ''
        if ($Name -eq 'none') { Write-DimLine 'the "none" option shows no boot animation - straight to the logo.' -Center }
        else { Write-DimLine 'the "random" option plays a different one of the animations each launch.' -Center }
        Write-Host ''
        Write-FaintLine 'any key to return to the picker' -Center
        Clear-KeyBuffer
        [void][Console]::ReadKey($true)
        return
    }
    $savedBoot = [string]$Script:Settings.bootStyle
    $savedAnim = [bool]$Script:Settings.animations
    $Script:Settings.bootStyle = $Name
    $Script:Settings.animations = $true
    try { Show-BootAnimation } catch { }
    $Script:Settings.bootStyle = $savedBoot
    $Script:Settings.animations = $savedAnim
}

function Show-FirstRunWizard {
    # One-time guided setup on first launch. A step machine so esc walks BACK a
    # question (esc on the welcome screen skips the whole thing); [P] previews the
    # highlighted theme/logo/boot; enter confirms and advances. Sets firstRunDone.
    $themeNames = @(Get-ThemeNames)
    $themeLabels = @($themeNames | ForEach-Object { $th = $Script:Themes[$_]; if ($th) { ('{0}  ({1})' -f $_, $th.Label) } else { "$_" } })
    $logoNames = @(Get-LogoNames)
    $logoLabels = @($logoNames | ForEach-Object { Get-LogoLabel $_ })
    $bootNames = @(Get-BootStyleNames)
    $snaps = @(Get-SnapshotList)
    $ti = [Array]::IndexOf($themeNames, [string]$Script:Settings.theme); if ($ti -lt 0) { $ti = 0 }
    $li = [Array]::IndexOf($logoNames, [string]$Script:Settings.logo); if ($li -lt 0) { $li = 0 }
    $bi = [Array]::IndexOf($bootNames, [string]$Script:Settings.bootStyle); if ($bi -lt 0) { $bi = 0 }
    $baseYes = $false
    $schedYes = $false
    $step = 0
    while ($true) {
        if ($step -eq 0) {
            Clear-Host
            Write-Host ''
            Show-Logo 'pyramid'
            Write-Host ''
            Write-GradLine ('::  WELCOME TO ' + $Script:Brand.Name + '  ::') -Center
            Write-Host ''
            Write-DimLine 'a quick one-time setup to make it yours - takes about 20 seconds.' -Center
            Write-DimLine '[P] previews a choice   //   esc steps back   //   enter confirms' -Center
            Write-Host ''
            Write-FaintLine 'any key to begin  //  esc to skip and use the defaults' -Center
            Clear-KeyBuffer
            $k0 = [Console]::ReadKey($true)
            if ($k0.Key -eq [ConsoleKey]::Escape) { $Script:Settings.firstRunDone = $true; Save-InvSettings; return }
            $step = 1
        }
        elseif ($step -eq 1) {
            $r = Show-ListPicker 'CHOOSE A THEME' $themeLabels 'enter select  //  P preview  //  esc back' $ti { param($i) Preview-InvTheme $themeNames[$i] }
            if ($r -lt 0) { $step = 0 } else { $ti = $r; $Script:Settings.theme = $themeNames[$ti]; Apply-InvTheme $Script:Settings.theme; $step = 2 }
        }
        elseif ($step -eq 2) {
            $r = Show-ListPicker 'CHOOSE A LOGO' $logoLabels 'enter select  //  P preview  //  esc back' $li { param($i) Preview-InvLogo $logoNames[$i] }
            if ($r -lt 0) { $step = 1 } else { $li = $r; $Script:Settings.logo = $logoNames[$li]; $step = 3 }
        }
        elseif ($step -eq 3) {
            $r = Show-ListPicker 'CHOOSE A BOOT ANIMATION' $bootNames 'enter select  //  P preview  //  esc back' $bi { param($i) Preview-InvBoot $bootNames[$i] }
            if ($r -lt 0) { $step = 2 } else { $bi = $r; $Script:Settings.bootStyle = $bootNames[$bi]; $step = 4 }
        }
        elseif ($step -eq 4) {
            if ($snaps.Count -eq 0) { $step = 5; continue }
            $pre = 1; if ($baseYes) { $pre = 0 }
            $r = Show-ListPicker ('PIN A BASELINE?  (most recent: ' + $snaps[0].Name + ')') @('yes - track drift from this snapshot', 'no - not now') 'enter select  //  esc back' $pre
            if ($r -lt 0) { $step = 3 } else { $baseYes = ($r -eq 0); $step = 5 }
        }
        elseif ($step -eq 5) {
            $pre = 1; if ($schedYes) { $pre = 0 }
            $r = Show-ListPicker 'SCHEDULE AUTOMATIC SWEEPS?' @('yes - a silent full sweep every week', 'no - I will run them myself') 'enter select  //  esc back' $pre
            if ($r -lt 0) { if ($snaps.Count -gt 0) { $step = 4 } else { $step = 3 } } else { $schedYes = ($r -eq 0); $step = 6 }
        }
        else {
            if ($baseYes -and $snaps.Count -gt 0) { $Script:Settings.baselineSnapshot = $snaps[0].Name }
            $schedMsg = ''
            if ($schedYes) {
                $err = Install-SweepSchedule 'weekly' '09:00'
                if ($err) { $schedMsg = 'schedule not created: ' + $err } else { $schedMsg = 'weekly sweep scheduled for 09:00.' }
            }
            $Script:Settings.firstRunDone = $true
            Save-InvSettings
            Clear-Host
            Write-Host ''
            Write-GradLine '::  YOU ARE ALL SET  ::' -Center
            Write-Host ''
            Write-TxtLine 'your choices are saved. change anything anytime in SETTINGS.' -Center
            if ($schedMsg) { Write-DimLine $schedMsg -Center }
            Write-DimLine 'press ? at the main menu for the keyboard reference.' -Center
            Write-Host ''
            Write-FaintLine 'any key to enter the console' -Center
            Clear-KeyBuffer
            [void][Console]::ReadKey($true)
            return
        }
    }
}

function Show-HelpScreen {
    Clear-Host
    Write-Host ''
    Write-GradLine '::  KEYBOARD REFERENCE  ::' -Center
    Write-Host ''
    $pad = Get-CenterPad 60
    $rows = @(
        @('MAIN MENU', ''),
        @('  arrows / 1-8', 'move and pick an entry'),
        @('  Q  or  esc', 'exit the application'),
        @('  ?', 'open this reference'),
        @('', ''),
        @('LISTS & PICKERS', ''),
        @('  arrows / pgup / pgdn', 'move and jump a page'),
        @('  space', 'toggle an item'),
        @('  A / N / I', 'all / none / invert'),
        @('  esc', 'back'),
        @('', ''),
        @('SNAPSHOT MANAGER', ''),
        @('  B / N', 'set baseline / add a note'),
        @('  O / D / R', 'open / delete / cycle retention'),
        @('', ''),
        @('RESTORE WIZARD', ''),
        @('  D / enter', 'dry-run preview / continue'),
        @('  Y / Q', 'final confirm / stop between packages'),
        @('', ''),
        @('THEME STUDIO', ''),
        @('  up/down / left/right', 'pick anchor / change its color'),
        @('  H / R', 'type a hex / reset to COVERT')
    )
    foreach ($r in $rows) {
        if ($r[1] -eq '' -and $r[0] -ne '') { Write-Host ($pad + (Get-Accent $r[0])) }
        elseif ($r[0] -eq '') { Write-Host '' }
        else { Write-Host ($pad + (Get-Txt ($r[0].PadRight(26))) + (Get-Dim $r[1])) }
    }
    Write-Host ''
    Write-FaintLine 'any key to return' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Show-MainMenu {
    $items = @(
        @{ A = 'full';     Label = 'FULL SYSTEM SWEEP';   Hint = 'inventory all 17 categories into a new snapshot' },
        @{ A = 'pick';     Label = 'SELECT CATEGORIES';   Hint = 'choose exactly what gets swept' },
        @{ A = 'diff';     Label = 'COMPARE SNAPSHOTS';   Hint = 'what changed on this machine between two sweeps' },
        @{ A = 'restore';  Label = 'RESTORE FROM SNAPSHOT'; Hint = 'wizard: selectively reinstall captured software via winget' },
        @{ A = 'search';   Label = 'SEARCH SNAPSHOTS';    Hint = 'find an app across every snapshot - when it appeared, how it changed' },
        @{ A = 'dashboard'; Label = 'VAULT DASHBOARD';    Hint = 'lifetime stats and the trend of apps tracked over time' },
        @{ A = 'manager';  Label = 'SNAPSHOT MANAGER';    Hint = 'browse, delete, set the baseline, retention policy' },
        @{ A = 'settings'; Label = 'SETTINGS';            Hint = 'logo, theme, exports, scheduled sweeps, output folder' },
        @{ A = 'quit';     Label = 'EXIT INVENTORIZER';   Hint = 'close the application' }
    )
    $sel = 0
    while ($true) {
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            $Script:MenuSpans = @{}          # ambient textures paint around these
            $Script:AmbientCapture = $true
            Write-Host ''
            $logoName = [string]$Script:Settings.logo
            try { if ([Console]::WindowHeight -lt 36 -and $logoName -ne 'minimal') { $logoName = 'minimal' } } catch { }
            Show-Logo $logoName
            Write-Host ''
            Write-GradLine '::  MAIN MENU  ::' -Center
            Write-Host ''
            Show-IdentityBlock
            $vsLine = 'no snapshots yet - run your first sweep'
            $vs = $null
            try { $vs = Get-VaultStatus } catch { }
            if ($vs -and $vs.Count -gt 0) {
                $age = 'unknown'
                if ($vs.Newest) { $age = Format-InvAge $vs.Newest }
                $vsLine = ('snapshots  ::  {0}  //  last sweep {1}  //  {2}' -f $vs.Count, $age, (Format-InvBytes $vs.Bytes))
            }
            Write-Host ''
            Write-DimLine $vsLine -Center
            if ($Script:SafeMode) {
                $sm = '[ SAFE MODE ] defaults active - saved config untouched (SETTINGS > RESET to persist a fix)'
                Record-MenuSpan (Get-CenterPad $sm.Length).Length $sm.Length
                Write-Host ((Get-CenterPad $sm.Length) + (Get-Warn $sm))
            }
            Write-Host ''
            $maxLab = 0
            foreach ($it in $items) { if ($it.Label.Length -gt $maxLab) { $maxLab = $it.Label.Length } }
            $pad = Get-CenterPad ($maxLab + 11)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $num = [string]($i + 1)
                if ($i -eq $items.Count - 1) { $num = 'Q' }
                $line = ('[{0}]  {1}' -f $num, $items[$i].Label)
                Record-MenuSpan $pad.Length (6 + $line.Length)
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('  >>  ' + $line))) }
                else             { Write-Host ($pad + (Get-Dim       ('      ' + $line))) }
            }
            Write-Host ''
            Write-DimLine $items[$sel].Hint -Center
            Write-Host ''
            Write-FaintLine 'arrows navigate  //  enter select  //  1-8 quick keys  //  ? help  //  Q exit' -Center
            $Script:AmbientCapture = $false
        }
        # ambient backdrop while idle (matrix rain etc.); failsafe -> plain wait
        $useAmbient = ($Script:Interactive -and $Script:Settings.animations -and -not $Script:AmbientDisabled -and (Get-ThemeTexture) -ne '')
        $k = $null
        if ($useAmbient) {
            try { $k = Invoke-AmbientWait } catch { $Script:AmbientDisabled = $true; $k = Read-KeyOrResize }
        } else {
            $k = Read-KeyOrResize
        }
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $items.Count - 1) % $items.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $items.Count }
        elseif ($k.Key -eq [ConsoleKey]::Enter)     { return $items[$sel].A }
        elseif ([string]$k.KeyChar -match '^[1-8]$') { return $items[[int]([string]$k.KeyChar) - 1].A }
        elseif ([string]$k.KeyChar -eq '?') { return 'help' }
        elseif ([string]$k.KeyChar -match '^[qQ]$' -or $k.Key -eq [ConsoleKey]::Escape) { return 'quit' }
    }
}

function Show-CategoryPicker {
    $cats = $Script:CollectorRegistry
    $checked = @{}
    foreach ($c in $cats) { $checked[$c.Id] = $true }
    $sel = 0
    while ($true) {
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            Write-Host ''
            Write-GradLine '::  SELECT SWEEP CATEGORIES  ::' -Center
            Write-Host ''
            $pad = Get-CenterPad 44
            for ($i = 0; $i -lt $cats.Count; $i++) {
                $c = $cats[$i]
                $mark = '[ ]'
                if ($checked[$c.Id]) { $mark = '[x]' }
                $adm = '   '
                if ($c.Admin) { $adm = ' * ' }
                $line = ('{0}  {1}  {2}{3}' -f $mark, $c.Num, $c.Title, $adm)
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>> ' + $line))) }
                else {
                    if ($checked[$c.Id]) { Write-Host ($pad + (Get-Txt ('   ' + $line))) }
                    else                 { Write-Host ($pad + (Get-Dim ('   ' + $line))) }
                }
            }
            Write-Host ''
            $n = 0
            foreach ($c in $cats) { if ($checked[$c.Id]) { $n++ } }
            Write-DimLine ('{0} of {1} categories selected    ( * = richer when elevated )' -f $n, $cats.Count) -Center
            Write-FaintLine 'space toggle  //  A all  //  N none  //  enter start sweep  //  esc back' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $cats.Count - 1) % $cats.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $cats.Count }
        elseif ($k.Key -eq [ConsoleKey]::Spacebar)  { $checked[$cats[$sel].Id] = -not $checked[$cats[$sel].Id] }
        elseif ([string]$k.KeyChar -match '^[aA]$') { foreach ($c in $cats) { $checked[$c.Id] = $true } }
        elseif ([string]$k.KeyChar -match '^[nN]$') { foreach ($c in $cats) { $checked[$c.Id] = $false } }
        elseif ($k.Key -eq [ConsoleKey]::Escape)    { return $null }
        elseif ($k.Key -eq [ConsoleKey]::Enter) {
            $ids = @($cats | Where-Object { $checked[$_.Id] } | ForEach-Object { $_.Id })
            if ($ids.Count -gt 0) { return $ids }
        }
    }
}

function Get-NearestSwatch($Rgb) {
    # Returns the swatch name closest to an RGB triple (Euclidean), for display.
    $best = ''
    $bestD = [double]::MaxValue
    foreach ($name in @($Script:ColorSwatches.Keys)) {
        $s = $Script:ColorSwatches[$name]
        $d = [Math]::Pow($s[0] - $Rgb[0], 2) + [Math]::Pow($s[1] - $Rgb[1], 2) + [Math]::Pow($s[2] - $Rgb[2], 2)
        if ($d -lt $bestD) { $bestD = $d; $best = $name }
    }
    if ($bestD -gt 100) { return 'custom' }   # not close to any named swatch
    return $best
}

function Show-ThemeStudio {
    # Live gradient editor: three anchors, each cycles the curated swatch set (or
    # takes a typed hex), with the whole console repainting on every change.
    $swNames = @($Script:ColorSwatches.Keys)
    $anchors = @(Get-CustomAnchors)     # three mutable RGB arrays (start/mid/end)
    $keys = @('a', 'b', 'c')
    $titles = @('anchor 1  (start)', 'anchor 2  (mid)  ', 'anchor 3  (end)  ')
    $sel = 0

    $commit = {
        # write anchors back to settings, switch to custom, repaint live
        $ct = [ordered]@{ a = (ConvertTo-HexColor $anchors[0]); b = (ConvertTo-HexColor $anchors[1]); c = (ConvertTo-HexColor $anchors[2]) }
        $Script:Settings.customTheme = $ct
        $Script:Settings.theme = 'custom'
        Apply-InvTheme 'custom'
    }
    & $commit   # entering the studio previews (and adopts) the custom palette

    while ($true) {
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            Write-Host ''
            Write-GradLine '::  THEME STUDIO  ::' -Center
            Write-Host ''
            Write-DimLine 'your palette - the gradient flows start -> mid -> end across the whole console' -Center
            Write-Host ''
            $pad = Get-CenterPad 46
            for ($i = 0; $i -lt 3; $i++) {
                $hex = ConvertTo-HexColor $anchors[$i]
                $nm = Get-NearestSwatch $anchors[$i]
                $line = ('{0}   {1,-8}  {2}' -f $titles[$i], $nm, $hex)
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>> ' + $line))) }
                else             { Write-Host ($pad + (Get-Txt ('   ' + $line))) }
            }
            Write-Host ''
            # live preview strip
            $bar = ('  ' + (Format-GradientText ([string][char]0x2588 * 34)))
            Write-Host ((Get-CenterPad 36) + $bar)
            Write-Host ''
            Write-GradLine ('::  ' + $Script:Brand.Name + '  ::') -Center
            $sample = (Get-Accent 'accent') + (Get-Dim '   //   ') + (Get-Violet 'updated') + (Get-Dim '   //   ') + (Get-Warn 'warning') + (Get-Dim '   //   ') + (Get-Faint 'faint')
            Write-Host ((Get-CenterPad 44) + $sample)
            Write-Host ''
            $texLbl = Get-TextureLabel ([string]$Script:Settings.customTexture)
            Write-Host ((Get-CenterPad 40) + (Get-Dim 'backdrop texture   ') + (Get-Accent $texLbl) + (Get-Faint '   [T] change'))
            Write-Host ''
            Write-FaintLine 'up/down anchor  //  left/right color  //  [H] hex  //  [T] texture  //  [R] reset  //  esc done' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + 2) % 3 }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % 3 }
        elseif ($k.Key -eq [ConsoleKey]::LeftArrow -or $k.Key -eq [ConsoleKey]::RightArrow) {
            $cur = Get-NearestSwatch $anchors[$sel]
            $ix = [Array]::IndexOf($swNames, $cur)
            if ($ix -lt 0) { $ix = 0 }
            $step = 1
            if ($k.Key -eq [ConsoleKey]::LeftArrow) { $step = $swNames.Count - 1 }
            $ix = ($ix + $step) % $swNames.Count
            $anchors[$sel] = @($Script:ColorSwatches[$swNames[$ix]])
            & $commit
        }
        elseif ([string]$k.KeyChar -match '^[hH]$') {
            Write-Host ''
            $entry = Read-InvPrompt ('hex color for ' + $titles[$sel].Trim() + ' (e.g. #F5B8E0; blank = keep)')
            $rgb = ConvertFrom-HexColor $entry
            if ($null -ne $rgb) { $anchors[$sel] = $rgb; & $commit }
        }
        elseif ([string]$k.KeyChar -match '^[tT]$') {
            Show-TexturePicker    # live backdrop chooser; theme is already 'custom' here
        }
        elseif ([string]$k.KeyChar -match '^[rR]$') {
            $anchors = @( @(245,184,224), @(139,123,247), @(127,227,240) )
            & $commit
        }
        elseif ($k.Key -eq [ConsoleKey]::Escape) {
            Save-InvSettings
            return
        }
    }
}

function Show-TexturePicker {
    # Live backdrop chooser for the custom theme. The highlighted texture animates
    # behind the list in real time (theme is already 'custom' when we get here, and
    # Get-ThemeTexture reads $Script:Settings.customTexture) - so browsing the list
    # IS the preview. Enter keeps the choice; esc reverts to what was set on entry.
    $cat = @($Script:TextureCatalog)
    $orig = [string]$Script:Settings.customTexture
    $sel = 0
    for ($i = 0; $i -lt $cat.Count; $i++) { if ([string]$cat[$i].Id -eq $orig) { $sel = $i; break } }
    while ($true) {
        $Script:Settings.customTexture = [string]$cat[$sel].Id   # live backdrop follows the selection
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            Clear-Host
            $Script:MenuSpans = @{}          # the texture paints around these
            $Script:AmbientCapture = $true
            Write-Host ''
            Write-GradLine '::  BACKDROP TEXTURE  ::' -Center
            Write-Host ''
            Write-DimLine 'the animated backdrop behind the main menu for your custom theme' -Center
            Write-Host ''
            $maxw = 0
            foreach ($t in $cat) { if ($t.Label.Length -gt $maxw) { $maxw = $t.Label.Length } }
            $pad = Get-CenterPad ($maxw + 8)
            for ($i = 0; $i -lt $cat.Count; $i++) {
                $line = ('  ' + $cat[$i].Label)
                Record-MenuSpan $pad.Length ($line.Length + 4)
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>>' + $line))) }
                else             { Write-Host ($pad + (Get-Dim       ('  ' + $line))) }
            }
            Write-Host ''
            Write-DimLine $cat[$sel].Blurb -Center
            Write-Host ''
            Write-FaintLine 'up/down choose  //  it plays live behind this list  //  enter keep  //  esc cancel' -Center
            $Script:AmbientCapture = $false
        }
        # animate the highlighted texture while idle; failsafe -> plain wait
        $useAmbient = ($Script:Interactive -and $Script:Settings.animations -and -not $Script:AmbientDisabled -and (Get-ThemeTexture) -ne '')
        $k = $null
        if ($useAmbient) {
            try { $k = Invoke-AmbientWait } catch { $Script:AmbientDisabled = $true; $k = Read-KeyOrResize }
        } else {
            $k = Read-KeyOrResize
        }
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $cat.Count - 1) % $cat.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $cat.Count }
        elseif ($k.Key -eq [ConsoleKey]::Enter) {
            $Script:Settings.customTexture = [string]$cat[$sel].Id
            Save-InvSettings
            return
        }
        elseif ($k.Key -eq [ConsoleKey]::Escape) {
            $Script:Settings.customTexture = $orig
            return
        }
    }
}

function Get-SettingsPreviewRender([string]$Key) {
    # Ready-to-print, centered+colored lines previewing the highlighted setting,
    # shown above the list so the choice is visible without leaving the screen.
    $out = @()
    if ($Key -eq 'logo') {
        $name = [string]$Script:Settings.logo
        $short = $false
        try { if ([Console]::WindowHeight -lt 30) { $short = $true } } catch { }
        if ($short) { $name = 'minimal' }
        $art = @(Get-LogoArt $name)
        $maxw = 0
        foreach ($l in $art) { if ($l.Length -gt $maxw) { $maxw = $l.Length } }
        if ($maxw -ge (Get-ConWidth)) { $art = @('.-===<[ INVENTORIZER ]>===-.'); $maxw = $art[0].Length }
        $pad = Get-CenterPad $maxw
        $n = $art.Count
        for ($i = 0; $i -lt $n; $i++) {
            $tv = 0.0; if ($n -gt 1) { $tv = $i / [double]($n - 1) }
            $t0 = $tv * 0.8
            $out += ($pad + (Format-GradientText $art[$i] $t0 ($t0 + 0.2)))
        }
    }
    elseif ($Key -eq 'barStyle') {
        $out += ((Get-CenterPad 30) + (Get-BarString 0.7 20) + (Get-Dim ('  ' + [string]$Script:Settings.barStyle + '   (P to preview)')))
    }
    elseif ($Key -eq 'theme' -or $Key -eq 'themeStudio') {
        $out += ((Get-CenterPad 24) + (Format-GradientText ([string][char]0x2588 * 24)))
        $out += ((Get-CenterPad 44) + (Get-Accent 'accent') + (Get-Dim '  ') + (Get-Violet 'updated') + (Get-Dim '  ') + (Get-Warn 'warning') + (Get-Dim '  ') + (Get-Txt 'text') + (Get-Dim '  ') + (Get-Faint 'faint'))
    }
    elseif ($Key -eq 'bootStyle') {
        $out += ((Get-CenterPad 46) + (Get-Dim ('boot animation: ' + [string]$Script:Settings.bootStyle + '   -   press P to play it')))
    }
    return @($out)
}

function Preview-InvBar([string]$Name) {
    # Animate a sample sweep bar in the given style, then restore.
    $saved = [string]$Script:Settings.barStyle
    $Script:Settings.barStyle = $Name
    Clear-Host
    Write-Host ''
    Write-GradLine '::  BAR STYLE PREVIEW  ::' -Center
    Write-DimLine ('style: ' + $Name) -Center
    Write-Host ''
    $row = 0
    try { $row = [Console]::CursorTop } catch { }
    $pad = Get-CenterPad 26
    for ($p = 0; $p -le 100; $p += 4) {
        try { [Console]::SetCursorPosition(0, $row) } catch { }
        Write-Host ($pad + (Get-BarString ($p / 100.0) 20) + (Get-Dim (' {0,3}%' -f $p)))
        if (Test-KeyAvailable) { break }
        Start-Sleep -Milliseconds 28
    }
    $Script:Settings.barStyle = $saved
    Write-Host ''
    Write-FaintLine 'any key to return' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Show-SettingsScreen {
    $sel = 0
    $top = 0
    $logoNames = @(Get-LogoNames)
    while ($true) {
        $onOff = {
            param($v)
            if ($v) { return 'ON' }
            return 'OFF'
        }
        $thVal = [string]$Script:Settings.theme
        $thObj = $Script:Themes[$thVal]
        if ($thObj) { $thVal = ('{0} / {1}' -f $thVal, $thObj.Label) }
        $aliasVal = [string]$Script:Settings.machineAlias
        if (-not $aliasVal) { $aliasVal = '(' + $env:COMPUTERNAME + ')' }
        $tagVal = [string]$Script:Settings.tagline
        if (-not $tagVal) { $tagVal = '(' + $Script:Brand.Tagline + ')' }
        $items = @(
            @{ K = 'logo';          Kind = 'cycle';  Label = 'LOGO';          Val = (Get-LogoLabel ([string]$Script:Settings.logo)); Hint = 'the ASCII product mark shown on boot and menus' },
            @{ K = 'theme';         Kind = 'cycle';  Label = 'THEME';         Val = $thVal; Hint = 'color palette - background and every text color' },
            @{ K = 'themeStudio';   Kind = 'nav';    Label = 'THEME STUDIO >'; Val = ''; Hint = 'design your own gradient palette, live' },
            @{ K = 'bootStyle';     Kind = 'cycle';  Label = 'BOOT ANIMATION'; Val = [string]$Script:Settings.bootStyle; Hint = 'the visual that plays at launch' },
            @{ K = 'bootSequence';  Kind = 'toggle'; Label = 'BOOT SEQUENCE'; Val = (& $onOff $Script:Settings.bootSequence); Hint = 'play the boot animation at all' },
            @{ K = 'barStyle';      Kind = 'cycle';  Label = 'BAR STYLE';     Val = [string]$Script:Settings.barStyle; Hint = 'fill character set of the sweep progress bar' },
            @{ K = 'animations';    Kind = 'toggle'; Label = 'ANIMATIONS';    Val = (& $onOff $Script:Settings.animations); Hint = 'motion throughout the app (bars, transitions)' },
            @{ K = 'machineAlias';  Kind = 'edit';   Label = 'MACHINE ALIAS'; Val = $aliasVal; Hint = 'a nickname shown for this machine' },
            @{ K = 'tagline';       Kind = 'edit';   Label = 'TAGLINE';       Val = $tagVal; Hint = 'your own banner line under the boot logo' },
            @{ K = 'exportJson';    Kind = 'toggle'; Label = 'JSON EXPORT';   Val = (& $onOff $Script:Settings.exportJson); Hint = 'write machine-readable JSON mirrors' },
            @{ K = 'htmlReport';    Kind = 'toggle'; Label = 'HTML REPORT';   Val = (& $onOff $Script:Settings.htmlReport); Hint = 'render a themed single-file HTML report' },
            @{ K = 'restoreScript'; Kind = 'toggle'; Label = 'RESTORE SCRIPT'; Val = (& $onOff $Script:Settings.restoreScript); Hint = 'generate restore.ps1 in each snapshot' },
            @{ K = 'updateCheck';   Kind = 'toggle'; Label = 'UPDATE CHECK';  Val = (& $onOff $Script:Settings.updateCheck); Hint = 'check the update channel on launch' },
            @{ K = 'outputRoot';    Kind = 'edit';   Label = 'OUTPUT FOLDER'; Val = [string]$Script:Settings.outputRoot; Hint = 'where snapshots are written' },
            @{ K = 'scheduledSweeps'; Kind = 'nav';  Label = 'SCHEDULED SWEEPS >'; Val = ''; Hint = 'run a silent full sweep automatically' },
            @{ K = 'checkNow';      Kind = 'action'; Label = 'CHECK FOR UPDATES NOW'; Val = ''; Hint = 'poll the update channel right now' },
            @{ K = 'resetConfig';   Kind = 'action'; Label = 'RESET CONFIG TO DEFAULTS'; Val = ''; Hint = 'restore every setting to its default' },
            @{ K = 'back';          Kind = 'action'; Label = 'BACK';          Val = ''; Hint = 'return to the main menu' }
        )
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            $preview = @(Get-SettingsPreviewRender $items[$sel].K)
            $paneH = $preview.Count
            $chrome = 9
            if ($paneH -gt 0) { $chrome = $chrome + $paneH + 1 }
            $vis = 12
            try { $vis = [Math]::Max(4, [Console]::WindowHeight - $chrome) } catch { }
            if ($vis -gt $items.Count) { $vis = $items.Count }
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $vis) { $top = $sel - $vis + 1 }
            if ($top -lt 0) { $top = 0 }
            Clear-Host
            Write-Host ''
            Write-GradLine '::  SETTINGS  ::' -Center
            foreach ($pl in $preview) { Write-Host $pl }
            if ($paneH -gt 0) { Write-Host '' }
            $pad = Get-CenterPad 52
            if ($top -gt 0) { Write-FaintLine ('^  {0} more above  ^' -f $top) -Center } else { Write-Host '' }
            for ($i = $top; $i -lt ($top + $vis); $i++) {
                $it = $items[$i]
                $line = $it.Label
                $valTxt = $it.Val
                if ($it.Kind -eq 'cycle' -or $it.Kind -eq 'toggle' -or $it.Kind -eq 'edit') { $line = ('{0}  <  {1}  >' -f $it.Label.PadRight(16), $valTxt) }
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>> ' + $line))) }
                else {
                    if ($valTxt -eq 'OFF') { Write-Host ($pad + (Get-Dim ('   ' + $line))) }
                    else                   { Write-Host ($pad + (Get-Txt ('   ' + $line))) }
                }
            }
            $below = $items.Count - ($top + $vis)
            if ($below -gt 0) { Write-FaintLine ('v  {0} more below  v' -f $below) -Center } else { Write-Host '' }
            Write-Host ''
            Write-DimLine $items[$sel].Hint -Center
            Write-FaintLine 'up/down move  //  left/right or enter change  //  P preview  //  esc back  //  saved to config\settings.json' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        $key = $items[$sel].K
        $changed = $false
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $items.Count - 1) % $items.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $items.Count }
        elseif ($k.Key -eq [ConsoleKey]::Escape)    { return }
        elseif ([string]$k.KeyChar -match '^[pP]$') {
            if     ($key -eq 'logo')      { Preview-InvLogo ([string]$Script:Settings.logo) }
            elseif ($key -eq 'theme')     { Preview-InvTheme ([string]$Script:Settings.theme) }
            elseif ($key -eq 'bootStyle') { Preview-InvBoot ([string]$Script:Settings.bootStyle) }
            elseif ($key -eq 'barStyle')  { Preview-InvBar ([string]$Script:Settings.barStyle) }
        }
        elseif ($k.Key -eq [ConsoleKey]::Enter -or $k.Key -eq [ConsoleKey]::Spacebar -or $k.Key -eq [ConsoleKey]::LeftArrow -or $k.Key -eq [ConsoleKey]::RightArrow) {
            if ($key -eq 'back' -and $k.Key -eq [ConsoleKey]::Enter) { return }
            if ($key -eq 'logo') {
                $idx = [Array]::IndexOf($logoNames, [string]$Script:Settings.logo)
                if ($idx -lt 0) { $idx = 0 }
                $step = 1
                if ($k.Key -eq [ConsoleKey]::LeftArrow) { $step = $logoNames.Count - 1 }
                $Script:Settings.logo = $logoNames[($idx + $step) % $logoNames.Count]
                $changed = $true
            } elseif ($key -eq 'theme') {
                $themeNames = @(Get-ThemeNames)
                $idx = [Array]::IndexOf($themeNames, [string]$Script:Settings.theme)
                if ($idx -lt 0) { $idx = 0 }
                $step = 1
                if ($k.Key -eq [ConsoleKey]::LeftArrow) { $step = $themeNames.Count - 1 }
                $Script:Settings.theme = $themeNames[($idx + $step) % $themeNames.Count]
                Apply-InvTheme $Script:Settings.theme   # instant repaint with the new palette
                $changed = $true
            } elseif ($key -eq 'themeStudio') {
                if ($k.Key -eq [ConsoleKey]::Enter) { Show-ThemeStudio }
            } elseif ($key -eq 'bootStyle') {
                $bn = @(Get-BootStyleNames)
                $idx = [Array]::IndexOf($bn, [string]$Script:Settings.bootStyle)
                if ($idx -lt 0) { $idx = 0 }
                $step = 1
                if ($k.Key -eq [ConsoleKey]::LeftArrow) { $step = $bn.Count - 1 }
                $Script:Settings.bootStyle = $bn[($idx + $step) % $bn.Count]
                $changed = $true
            } elseif ($key -eq 'barStyle') {
                $bn = @(Get-BarStyleNames)
                $idx = [Array]::IndexOf($bn, [string]$Script:Settings.barStyle)
                if ($idx -lt 0) { $idx = 0 }
                $step = 1
                if ($k.Key -eq [ConsoleKey]::LeftArrow) { $step = $bn.Count - 1 }
                $Script:Settings.barStyle = $bn[($idx + $step) % $bn.Count]
                $changed = $true
            } elseif ($key -eq 'machineAlias') {
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    Write-Host ''
                    $v = Read-InvPrompt 'machine alias (blank = keep, a single - clears it)'
                    if ($v -eq '-') { $Script:Settings.machineAlias = ''; $changed = $true }
                    elseif ($v -and $v.Trim() -ne '') { $Script:Settings.machineAlias = $v.Trim(); $changed = $true }
                }
            } elseif ($key -eq 'tagline') {
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    Write-Host ''
                    $v = Read-InvPrompt 'tagline (blank = keep, a single - clears it)'
                    if ($v -eq '-') { $Script:Settings.tagline = ''; $changed = $true }
                    elseif ($v -and $v.Trim() -ne '') { $Script:Settings.tagline = $v.Trim(); $changed = $true }
                }
            } elseif ($key -eq 'outputRoot') {
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    Write-Host ''
                    $newRoot = Read-InvPrompt 'new output folder (blank = keep current)'
                    if ($newRoot -and $newRoot.Trim() -ne '') {
                        $Script:Settings.outputRoot = $newRoot.Trim()
                        $changed = $true
                    }
                }
            } elseif ($key -eq 'scheduledSweeps') {
                if ($k.Key -eq [ConsoleKey]::Enter) { Show-ScheduleScreen }
            } elseif ($key -eq 'checkNow') {
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    Clear-Host
                    Write-Host ''
                    Write-GradLine '::  CHECKING FOR UPDATES  ::' -Center
                    Write-Host ''
                    $handled = $false
                    if (-not (("$($Script:Brand.UpdateUrl)").Trim())) {
                        Write-DimLine 'no update channel configured yet.' -Center
                        Write-DimLine 'set UpdateUrl in the $Brand block once the repo goes live.' -Center
                    } else {
                        $upd = Test-ForUpdate
                        if ($null -eq $upd) {
                            Write-DimLine ('v' + $Script:Brand.Version + ' is the latest build - the channel has nothing newer.') -Center
                        } else {
                            $handled = $true
                            Show-UpdateScreen $upd
                        }
                    }
                    if (-not $handled) {
                        Write-Host ''
                        Write-FaintLine 'any key to return' -Center
                        Clear-KeyBuffer
                        [void][Console]::ReadKey($true)
                    }
                }
            } elseif ($key -eq 'resetConfig') {
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    $Script:Settings = Get-DefaultSettings
                    Save-InvSettings
                    $Script:SafeMode = $false
                    Apply-InvTheme ([string]$Script:Settings.theme)
                    Write-Host ''
                    $ok = 'config reset to defaults and saved.'
                    Write-Host ((Get-CenterPad $ok.Length) + (Get-Accent $ok))
                    Start-Sleep -Milliseconds 900
                }
            } elseif ($key -ne 'back') {
                $Script:Settings[$key] = -not [bool]$Script:Settings[$key]
                $changed = $true
            }
        }
        if ($changed) { Save-InvSettings }
    }
}

function Confirm-SnapshotDelete($Snap) {
    Clear-Host
    Write-Host ''
    Write-GradLine '::  DELETE SNAPSHOT  ::' -Center
    Write-Host ''
    $l1 = ('permanently delete ' + $Snap.Name + '?')
    Write-Host ((Get-CenterPad $l1.Length) + (Get-Warn $l1))
    Write-DimLine 'this removes the folder and every report inside it.' -Center
    Write-Host ''
    Write-FaintLine '[Y] delete  //  any other key cancels' -Center
    Clear-KeyBuffer
    $k = [Console]::ReadKey($true)
    return ([string]$k.KeyChar -match '^[yY]$')
}

function Show-SnapshotManager {
    $sel = 0
    $top = 0
    $msg = ''
    $reload = $true
    $snaps = @()
    $sizes = @{}
    $notes = @{}
    while ($true) {
        if ($reload) {
            $snaps = @(Get-SnapshotList)
            $sizes = @{}
            $notes = @{}
            foreach ($s in $snaps) {
                $b = [long]0
                try {
                    $sum = (Get-ChildItem -LiteralPath $s.Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                    if ($sum) { $b = [long]$sum }
                } catch { }
                $sizes[$s.Path] = $b
                $notes[$s.Path] = (Get-SnapshotNote $s.Path)
            }
            if ($sel -ge $snaps.Count) { $sel = [Math]::Max(0, $snaps.Count - 1) }
            $reload = $false
        }
        if (-not (Test-KeyAvailable)) {   # coalesce redraws while input is flooding in
            $retVal = 'OFF'
            if ([int]$Script:Settings.retentionKeep -gt 0) { $retVal = ('keep newest ' + [int]$Script:Settings.retentionKeep) }
            Clear-Host
            Write-Host ''
            Write-GradLine '::  SNAPSHOT MANAGER  ::' -Center
            Write-Host ''
            if ($snaps.Count -eq 0) {
                Write-DimLine ('no snapshots found in ' + (Get-OutputRoot)) -Center
                Write-DimLine 'run a sweep to create your first one.' -Center
                Write-Host ''
                Write-FaintLine '[O] open snapshots folder  //  esc back' -Center
            } else {
                $vis = 10
                try { $vis = [Math]::Max(4, [Console]::WindowHeight - 13) } catch { }
                if ($vis -gt $snaps.Count) { $vis = $snaps.Count }
                if ($sel -lt $top) { $top = $sel }
                if ($sel -ge $top + $vis) { $top = $sel - $vis + 1 }
                if ($top -lt 0) { $top = 0 }
                $bl = [string]$Script:Settings.baselineSnapshot
                $maxw = 0
                foreach ($s in $snaps) { if ($s.Name.Length -gt $maxw) { $maxw = $s.Name.Length } }
                $pad = Get-CenterPad ($maxw + 40)
                if ($top -gt 0) { Write-FaintLine ('^  {0} more above  ^' -f $top) -Center } else { Write-Host '' }
                for ($i = $top; $i -lt ($top + $vis); $i++) {
                    $s = $snaps[$i]
                    $age = ''
                    try { $age = Format-InvAge ([datetime]$s.Date) } catch { }
                    $tag = ''
                    if ($s.Name -eq $bl) { $tag = '[BASELINE]' }
                    $noteMark = '   '
                    if ($notes[$s.Path]) { $noteMark = ' * ' }
                    $line = ('{0}  {1,10}  {2,9}  {3}{4}' -f $s.Name.PadRight($maxw), $age, (Format-InvBytes $sizes[$s.Path]), $noteMark, $tag)
                    if ($i -eq $sel)  { Write-Host ($pad + (Format-GradientText ('>> ' + $line))) }
                    elseif ($tag)     { Write-Host ($pad + (Get-Accent ('   ' + $line))) }
                    else              { Write-Host ($pad + (Get-Txt    ('   ' + $line))) }
                }
                $below = $snaps.Count - ($top + $vis)
                if ($below -gt 0) { Write-FaintLine ('v  {0} more below  v' -f $below) -Center } else { Write-Host '' }
                Write-Host ''
                $selNote = $notes[$snaps[$sel].Path]
                if ($selNote) { Write-DimLine ('note:  ' + $selNote) -Center } else { Write-Host '' }
                Write-DimLine ('{0} snapshots  //  retention: {1} (auto-prunes after each sweep; the baseline is always kept)' -f $snaps.Count, $retVal) -Center
                if ($msg) { Write-Host ((Get-CenterPad $msg.Length) + (Get-Warn $msg)) }
                Write-FaintLine '[B] baseline  //  [N] note  //  [O] open  //  [D] delete  //  [R] retention  //  esc back' -Center
            }
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }   # window resized -> redraw recentered
        $msg = ''
        if ($snaps.Count -eq 0) {
            if ([string]$k.KeyChar -match '^[oO]$') {
                $r = Get-OutputRoot
                New-Item -ItemType Directory -Path $r -Force | Out-Null
                try { Invoke-Item $r } catch { }
            } elseif ($k.Key -eq [ConsoleKey]::Escape) { return }
            continue
        }
        $vis2 = 10
        try { $vis2 = [Math]::Max(4, [Console]::WindowHeight - 13) } catch { }
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $snaps.Count - 1) % $snaps.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $snaps.Count }
        elseif ($k.Key -eq [ConsoleKey]::PageUp)    { $sel = [Math]::Max(0, $sel - $vis2) }
        elseif ($k.Key -eq [ConsoleKey]::PageDown)  { $sel = [Math]::Min($snaps.Count - 1, $sel + $vis2) }
        elseif ($k.Key -eq [ConsoleKey]::Home)      { $sel = 0 }
        elseif ($k.Key -eq [ConsoleKey]::End)       { $sel = $snaps.Count - 1 }
        elseif ([string]$k.KeyChar -match '^[oO]$') { try { Invoke-Item $snaps[$sel].Path } catch { } }
        elseif ([string]$k.KeyChar -match '^[bB]$') {
            if ([string]$Script:Settings.baselineSnapshot -eq $snaps[$sel].Name) { $Script:Settings.baselineSnapshot = '' }
            else { $Script:Settings.baselineSnapshot = $snaps[$sel].Name }
            Save-InvSettings
        }
        elseif ([string]$k.KeyChar -match '^[rR]$') {
            $steps = @(0, 5, 10, 20)
            $ix = [Array]::IndexOf($steps, [int]$Script:Settings.retentionKeep)
            $Script:Settings.retentionKeep = $steps[($ix + 1) % $steps.Count]
            Save-InvSettings
        }
        elseif ([string]$k.KeyChar -match '^[nN]$') {
            [void](Read-SnapshotNoteInput $snaps[$sel].Path $notes[$snaps[$sel].Path])
            $notes[$snaps[$sel].Path] = (Get-SnapshotNote $snaps[$sel].Path)
        }
        elseif ([string]$k.KeyChar -match '^[dD]$') {
            if ($snaps[$sel].Name -eq [string]$Script:Settings.baselineSnapshot) {
                $msg = 'the baseline snapshot cannot be deleted - unset the baseline first'
            } elseif (Confirm-SnapshotDelete $snaps[$sel]) {
                try {
                    Remove-Item -LiteralPath $snaps[$sel].Path -Recurse -Force
                    Reset-VaultStatus
                } catch { $msg = ('delete failed - ' + "$($_.Exception.Message)".Trim()) }
                $reload = $true
            }
        }
        elseif ($k.Key -eq [ConsoleKey]::Escape) { return }
    }
}

function Show-DashboardScreen {
    Clear-Host
    Write-Host ''
    Write-GradLine '::  VAULT DASHBOARD  ::' -Center
    Write-Host ''
    $st = Get-VaultStats
    if ($st.Count -eq 0) {
        Write-DimLine ('no snapshots yet in ' + (Get-OutputRoot)) -Center
        Write-DimLine 'run a sweep to start building the history this dashboard reflects.' -Center
        Write-Host ''
        Write-FaintLine 'any key to return' -Center
        Clear-KeyBuffer
        [void][Console]::ReadKey($true)
        return
    }

    Write-TxtLine ('{0} sweeps   //   {1} distinct apps tracked   //   {2}' -f $st.Count, $st.DistinctApps, (Format-InvBytes $st.Bytes)) -Center
    $firstShort = ("$($st.First)" -split 'T')[0]
    $lastAge = ''
    try { $lastAge = ' (' + (Format-InvAge ([datetime]$st.Last)) + ')' } catch { }
    $lastShort = ("$($st.Last)" -split 'T')[0]
    Write-DimLine ('first sweep {0}   //   latest {1}{2}' -f $firstShort, $lastShort, $lastAge) -Center

    $baseTxt = 'none'
    if ($st.Baseline) { $baseTxt = $st.Baseline }
    $retTxt = 'off'
    if ([int]$Script:Settings.retentionKeep -gt 0) { $retTxt = ('keep ' + [int]$Script:Settings.retentionKeep) }
    $schedTxt = 'not scheduled'
    try { if ($null -ne (Get-SweepSchedule)) { $schedTxt = 'scheduled' } } catch { }
    Write-DimLine ('baseline :: {0}   //   retention :: {1}   //   auto-sweep :: {2}' -f $baseTxt, $retTxt, $schedTxt) -Center
    Write-Host ''

    # app-count trend (last ~48 sweeps to fit the width)
    $series = @($st.Series)
    if ($series.Count -ge 2) {
        $tail = @($series | Select-Object -Last 48)
        $vals = @($tail | ForEach-Object { $_.Apps })
        $spark = Get-InvSparkline $vals
        $min = ($vals | Measure-Object -Minimum).Minimum
        $max = ($vals | Measure-Object -Maximum).Maximum
        Write-DimLine 'installed apps over time' -Center
        Write-Host ((Get-CenterPad $spark.Length) + (Format-GradientText $spark))
        Write-FaintLine ('low {0}   //   high {1}   //   latest {2}' -f $min, $max, $vals[$vals.Count - 1]) -Center
        Write-Host ''
    }

    # recent sweeps
    $recent = @($series | Select-Object -Last 6)
    [array]::Reverse($recent)
    Write-DimLine 'recent sweeps' -Center
    foreach ($r in $recent) {
        $tag = ''
        if ($r.Name -eq $st.Baseline) { $tag = '   [BASELINE]' }
        $note = ''
        try { $note = Get-SnapshotNote (Join-Path (Get-OutputRoot) $r.Name) } catch { }
        $line = ('{0}   {1,4} apps{2}' -f $r.Name, $r.Apps, $tag)
        if ($tag) { Write-Host ((Get-CenterPad $line.Length) + (Get-Accent $line)) }
        else      { Write-Host ((Get-CenterPad $line.Length) + (Get-Txt $line)) }
        if ($note) { Write-DimLine ('    "' + $note + '"') -Center }
    }
    Write-Host ''
    Write-FaintLine 'any key to return' -Center
    Clear-KeyBuffer
    [void][Console]::ReadKey($true)
}

function Show-SearchScreen {
    Clear-Host
    Write-Host ''
    Write-GradLine '::  SEARCH SNAPSHOTS  ::' -Center
    Write-Host ''
    Write-DimLine 'find an application across every snapshot - when it appeared, how its version changed' -Center
    Write-Host ''
    $term = Read-InvPrompt 'search term (app name or publisher; blank to cancel)'
    if (-not $term -or $term.Trim() -eq '') { return }
    $term = $term.Trim()

    Clear-Host
    Write-Host ''
    Write-GradLine '::  SEARCHING  ::' -Center
    Write-DimLine ('scanning snapshots for "' + $term + '" ...') -Center
    $hits = @(Find-InSnapshots $term)

    # Flatten into role-tagged rows for the pager.
    $rows = New-Object System.Collections.Generic.List[object]
    if ($hits.Count -eq 0) {
        $rows.Add(@{ T = ('no application matching "' + $term + '" was found in any snapshot.'); R = 'dim' })
    } else {
        foreach ($h in $hits) {
            $rows.Add(@{ T = $h.Name; R = 'accent' })
            $rows.Add(@{ T = ('first seen ' + $h.FirstDate + '   //   ' + $h.Presence); R = 'dim' })
            foreach ($v in @($h.Versions)) { $rows.Add(@{ T = ('v' + $v.Version + '   (' + $v.Date + ')'); R = 'txt' }) }
            $rows.Add(@{ T = ''; R = 'blank' })
        }
    }

    $i = 0
    while ($true) {
        Clear-Host
        Write-Host ''
        Write-GradLine ('::  SEARCH RESULTS  ::') -Center
        Write-DimLine ('"' + $term + '"   //   ' + $hits.Count + ' match(es)') -Center
        Write-Host ''
        $page = 16
        try { $page = [Math]::Max(6, [Console]::WindowHeight - 9) } catch { }
        $shown = 0
        while ($i -lt $rows.Count -and $shown -lt $page) {
            $r = $rows[$i]
            if     ($r.R -eq 'accent') { Write-Host ((Get-CenterPad $r.T.Length) + (Get-Accent $r.T)) }
            elseif ($r.R -eq 'dim')    { Write-DimLine $r.T -Center }
            elseif ($r.R -eq 'txt')    { Write-TxtLine $r.T -Center }
            else                       { Write-Host '' }
            $i++; $shown++
        }
        Write-Host ''
        if ($i -lt $rows.Count) { Write-FaintLine (($rows.Count - $i).ToString() + ' more lines  //  any key = next page  //  esc = done') -Center }
        else { Write-FaintLine 'end of results  //  any key to return' -Center }
        Clear-KeyBuffer
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq [ConsoleKey]::Escape) { return }
        if ($i -ge $rows.Count) { return }
    }
}

function Show-DiffScreen {
    $snaps = @(Get-SnapshotList)
    if ($snaps.Count -lt 2) {
        Clear-Host
        Write-Host ''
        Write-GradLine '::  COMPARE SNAPSHOTS  ::' -Center
        Write-Host ''
        Write-DimLine 'at least two snapshots with manifests are required.' -Center
        Write-DimLine ('found {0} in {1}' -f $snaps.Count, (Get-OutputRoot)) -Center
        Write-Host ''
        Write-FaintLine 'run a couple of sweeps first  //  any key to return' -Center
        [void][Console]::ReadKey($true)
        return
    }
    $opts = @($snaps | ForEach-Object { ('{0}   apps {1,4}   drivers {2,4}' -f $_.Name, $_.Apps, $_.Drivers) })
    $ia = Show-ListPicker 'SELECT BASELINE (the older snapshot)' $opts 'enter select  //  esc back'
    if ($ia -lt 0) { return }
    $ib = Show-ListPicker 'SELECT COMPARISON (the newer snapshot)' $opts 'enter select  //  esc back' ([Math]::Max(0, $ia - 1))
    if ($ib -lt 0) { return }
    if ($ia -eq $ib) { return }
    $res = Invoke-SnapshotDiff $snaps[$ia].Path $snaps[$ib].Path
    Clear-Host
    Write-Host ''
    Write-GradLine '::  SNAPSHOT COMPARISON  ::' -Center
    Write-Host ''
    Write-DimLine ('{0}  ->  {1}' -f $snaps[$ia].Name, $snaps[$ib].Name) -Center
    Write-Host ''
    $pad = Get-CenterPad 34
    Write-Host ($pad + (Get-Accent ('+ APPS INSTALLED    {0,5}' -f $res.AppAdd)))
    Write-Host ($pad + (Get-Warn   ('- APPS REMOVED      {0,5}' -f $res.AppRem)))
    Write-Host ($pad + (Get-Violet ('~ APPS UPDATED      {0,5}' -f $res.AppChg)))
    Write-Host ($pad + (Get-Accent ('+ DRIVERS ADDED     {0,5}' -f $res.DrvAdd)))
    Write-Host ($pad + (Get-Warn   ('- DRIVERS REMOVED   {0,5}' -f $res.DrvRem)))
    Write-Host ($pad + (Get-Violet ('~ DRIVERS UPDATED   {0,5}' -f $res.DrvChg)))
    Write-Host ''
    Write-DimLine ('full report -> ' + $res.Path) -Center
    Write-Host ''
    Write-FaintLine '[O] open report  //  any other key to return' -Center
    $k = [Console]::ReadKey($true)
    if ([string]$k.KeyChar -match '^[oO]$') { try { Invoke-Item $res.Path } catch { } }
}

function Show-ReinstallPlanBuilder([string]$Dir) {
    # Pick which installed apps to include, then write a follow-along HTML plan.
    $apps = @(Get-SnapshotApps $Dir | Sort-Object Name)
    if ($apps.Count -eq 0) {
        Clear-Host; Write-Host ''
        Write-GradLine '::  REINSTALL PLAN  ::' -Center
        Write-Host ''
        Write-DimLine 'no installed-program data in this snapshot to build a plan from.' -Center
        Write-Host ''
        Write-FaintLine 'any key to return' -Center
        Clear-KeyBuffer; [void][Console]::ReadKey($true); return
    }
    $checked = @{}
    for ($i = 0; $i -lt $apps.Count; $i++) { $checked[$i] = $true }
    $sel = 0; $top = 0
    while ($true) {
        $vis = 12
        try { $vis = [Math]::Max(6, [Console]::WindowHeight - 12) } catch { }
        if ($vis -gt $apps.Count) { $vis = $apps.Count }
        if (-not (Test-KeyAvailable)) {
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $vis) { $top = $sel - $vis + 1 }
            if ($top -lt 0) { $top = 0 }
            Clear-Host; Write-Host ''
            Write-GradLine '::  PREPARE REINSTALL PLAN  ::' -Center
            Write-DimLine 'tick the apps you want in the plan - it becomes an HTML checklist you follow later' -Center
            Write-Host ''
            $maxw = 0
            foreach ($a in $apps) { if ($a.Name.Length -gt $maxw) { $maxw = $a.Name.Length } }
            if ($maxw -gt 48) { $maxw = 48 }
            $pad = Get-CenterPad ($maxw + 22)
            if ($top -gt 0) { Write-FaintLine ('^  {0} more above  ^' -f $top) -Center } else { Write-Host '' }
            for ($i = $top; $i -lt ($top + $vis); $i++) {
                $a = $apps[$i]
                $mark = '[ ]'; if ($checked[$i]) { $mark = '[x]' }
                $nm = $a.Name; if ($nm.Length -gt 48) { $nm = $nm.Substring(0, 46) + '..' }
                $lineTxt = ('{0}  {1}  {2}' -f $mark, $nm.PadRight($maxw), $a.Version)
                if ($i -eq $sel) { Write-Host ($pad + (Format-GradientText ('>> ' + $lineTxt))) }
                elseif ($checked[$i]) { Write-Host ($pad + (Get-Txt ('   ' + $lineTxt))) }
                else { Write-Host ($pad + (Get-Dim ('   ' + $lineTxt))) }
            }
            $below = $apps.Count - ($top + $vis)
            if ($below -gt 0) { Write-FaintLine ('v  {0} more below  v' -f $below) -Center } else { Write-Host '' }
            Write-Host ''
            $n = 0
            foreach ($kk in $checked.Keys) { if ($checked[$kk]) { $n++ } }
            Write-DimLine ('{0} of {1} apps selected for the plan' -f $n, $apps.Count) -Center
            Write-FaintLine 'space toggle  //  A all  //  N none  //  I invert  //  enter build the plan  //  esc cancel' -Center
        }
        $k = Read-KeyOrResize
        if ($null -eq $k) { continue }
        $vis2 = 12; try { $vis2 = [Math]::Max(6, [Console]::WindowHeight - 12) } catch { }
        if     ($k.Key -eq [ConsoleKey]::UpArrow)   { $sel = ($sel + $apps.Count - 1) % $apps.Count }
        elseif ($k.Key -eq [ConsoleKey]::DownArrow) { $sel = ($sel + 1) % $apps.Count }
        elseif ($k.Key -eq [ConsoleKey]::PageUp)    { $sel = [Math]::Max(0, $sel - $vis2) }
        elseif ($k.Key -eq [ConsoleKey]::PageDown)  { $sel = [Math]::Min($apps.Count - 1, $sel + $vis2) }
        elseif ($k.Key -eq [ConsoleKey]::Home)      { $sel = 0 }
        elseif ($k.Key -eq [ConsoleKey]::End)       { $sel = $apps.Count - 1 }
        elseif ($k.Key -eq [ConsoleKey]::Spacebar)  { $checked[$sel] = -not $checked[$sel] }
        elseif ([string]$k.KeyChar -match '^[aA]$') { for ($i = 0; $i -lt $apps.Count; $i++) { $checked[$i] = $true } }
        elseif ([string]$k.KeyChar -match '^[nN]$') { for ($i = 0; $i -lt $apps.Count; $i++) { $checked[$i] = $false } }
        elseif ([string]$k.KeyChar -match '^[iI]$') { for ($i = 0; $i -lt $apps.Count; $i++) { $checked[$i] = -not $checked[$i] } }
        elseif ($k.Key -eq [ConsoleKey]::Escape)    { return }
        elseif ($k.Key -eq [ConsoleKey]::Enter) {
            $selApps = @()
            for ($i = 0; $i -lt $apps.Count; $i++) { if ($checked[$i]) { $selApps += $apps[$i] } }
            if ($selApps.Count -eq 0) { continue }
            Clear-Host; Write-Host ''
            Write-GradLine '::  BUILDING PLAN  ::' -Center
            Write-DimLine ('writing reinstall_plan.html for ' + $selApps.Count + ' apps ...') -Center
            $path = ''
            try { $path = New-ReinstallPlanHtml $Dir $selApps } catch { }
            Write-Host ''
            if ($path) {
                Write-TxtLine 'reinstall plan saved.' -Center
                Write-DimLine $path -Center
                Write-Host ''
                Write-FaintLine '[O] open it now  //  any other key to return' -Center
                Clear-KeyBuffer
                $ko = [Console]::ReadKey($true)
                if ([string]$ko.KeyChar -match '^[oO]$') { try { Invoke-Item $path } catch { } }
            } else {
                Write-Host ((Get-CenterPad 30) + (Get-Warn 'could not write the plan.'))
                Write-FaintLine 'any key to return' -Center
                Clear-KeyBuffer; [void][Console]::ReadKey($true)
            }
            return
        }
    }
}

function Show-SummaryScreen($Sum) {
    if ($null -eq $Sum) { return }
    if (-not $Script:Interactive) {
        Write-Host ('[DONE] {0} items across {1} categories in {2}' -f $Sum.Total, $Sum.Cats.Count, (Format-InvDuration $Sum.Seconds))
        Write-Host ('[DONE] snapshot -> {0}' -f $Sum.Dir)
        if ($Sum.Drift) { Write-Host ('[DRIFT] vs {0} :: apps +{1} -{2} ~{3} // drivers +{4} -{5} ~{6}' -f $Sum.Baseline, $Sum.Drift.AppAdd, $Sum.Drift.AppRem, $Sum.Drift.AppChg, $Sum.Drift.DrvAdd, $Sum.Drift.DrvRem, $Sum.Drift.DrvChg) }
        if ([int]$Sum.Pruned -gt 0) { Write-Host ('[RETENTION] pruned {0} snapshot(s)' -f $Sum.Pruned) }
        return
    }
    Write-Host ''
    Write-GradLine '::  SNAPSHOT COMPLETE  ::' -Center
    Write-Host ''
    Write-TxtLine ('{0} items catalogued across {1} categories in {2}' -f $Sum.Total, $Sum.Cats.Count, (Format-InvDuration $Sum.Seconds)) -Center
    Write-DimLine ('saved to  ' + $Sum.Dir) -Center
    if ($Sum.Drift) {
        Write-Host ''
        Write-TxtLine ('drift vs baseline {0}' -f $Sum.Baseline) -Center
        Write-DimLine ('apps +{0} -{1} ~{2}   //   drivers +{3} -{4} ~{5}' -f $Sum.Drift.AppAdd, $Sum.Drift.AppRem, $Sum.Drift.AppChg, $Sum.Drift.DrvAdd, $Sum.Drift.DrvRem, $Sum.Drift.DrvChg) -Center
        Write-DimLine ('full drift report  ->  drift_vs_baseline.txt in the snapshot') -Center
    }
    if ([int]$Sum.Pruned -gt 0) { Write-DimLine ('retention pruned {0} older snapshot(s)' -f $Sum.Pruned) -Center }
    Write-Host ''
    Write-FaintLine '[R] prepare a reinstall plan  //  [N] add a note  //  [O] open folder  //  any other key to continue' -Center
    Clear-KeyBuffer
    while ($true) {
        $k = [Console]::ReadKey($true)
        if ([string]$k.KeyChar -match '^[oO]$') { try { Invoke-Item $Sum.Dir } catch { }; continue }
        if ([string]$k.KeyChar -match '^[rR]$') {
            Show-ReinstallPlanBuilder $Sum.Dir
            return
        }
        if ([string]$k.KeyChar -match '^[nN]$') {
            [void](Read-SnapshotNoteInput $Sum.Dir (Get-SnapshotNote $Sum.Dir))
            $note = Get-SnapshotNote $Sum.Dir
            if ($note) { Write-DimLine ('note saved: ' + $note) -Center }
            Write-FaintLine 'any other key to continue' -Center
            continue
        }
        break
    }
}

#endregion

#region ============================ MAIN ======================================

function Invoke-Main {
    Initialize-Console
    $Script:Settings = Import-InvSettings
    if (-not (Test-Path -LiteralPath $Script:ConfigPath)) { Save-InvSettings }
    # runtime-only overrides (never persisted)
    if ($Silent) {
        $Script:Settings.animations = $false
        $Script:Settings.bootSequence = $false
    }
    if ($SafeMode) { Enable-SafeMode }
    else { Apply-InvTheme ([string]$Script:Settings.theme) }

    # powershell.exe -File passes "a,b" as one literal string - normalize array params
    if ($Categories) { $Script:CatList = @($Categories | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { $Script:CatList = $null }
    if ($Compare)    { $Compare = @($Compare | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    # Headless snapshot diff: -Compare <baseline>,<comparison> (names under the output root, or full paths)
    if ($Compare) {
        if (@($Compare).Count -ne 2) {
            Write-Host (Get-Warn '  -Compare requires exactly two snapshot names or paths (baseline first).')
            return
        }
        $resolved = @()
        foreach ($c in $Compare) {
            $p = "$c"
            if (-not ([IO.Path]::IsPathRooted($p) -and (Test-Path -LiteralPath $p))) { $p = Join-Path (Get-OutputRoot) "$c" }
            if (-not (Test-Path -LiteralPath (Join-Path $p 'manifest.json'))) {
                Write-Host (Get-Warn ('  no manifest.json found in ' + $p))
                return
            }
            $resolved += $p
        }
        $res = Invoke-SnapshotDiff $resolved[0] $resolved[1]
        Write-Host ('[DIFF] apps +{0} -{1} ~{2}   //   drivers +{3} -{4} ~{5}' -f $res.AppAdd, $res.AppRem, $res.AppChg, $res.DrvAdd, $res.DrvRem, $res.DrvChg)
        Write-Host ('[DIFF] report -> ' + $res.Path)
        return
    }

    # Headless search: -Find "<term>" (no elevation - reads existing snapshots only)
    if ($PSBoundParameters.ContainsKey('Find') -and "$Find".Trim() -ne '') {
        $hits = @(Find-InSnapshots ("$Find".Trim()))
        if ($hits.Count -eq 0) {
            Write-Host ('[FIND] no app matching "{0}" in any snapshot.' -f "$Find".Trim())
            return
        }
        Write-Host ('[FIND] {0} match(es) for "{1}":' -f $hits.Count, "$Find".Trim())
        foreach ($h in $hits) {
            Write-Host ('  {0}' -f $h.Name)
            Write-Host ('      first seen {0}  //  {1}  //  {2} version(s)' -f $h.FirstDate, $h.Presence, @($h.Versions).Count)
            foreach ($v in @($h.Versions)) { Write-Host ('        v{0}   ({1})' -f $v.Version, $v.Date) }
        }
        return
    }

    # Self-elevation (skipped in silent mode - schedule the task elevated instead)
    if (-not (Test-IsAdmin) -and -not $NoElevate -and -not $Silent) {
        if (Invoke-SelfElevation) { return }
        if ($Script:Interactive) {
            Write-Host (Get-Warn '  [ LIMITED ] elevation declined - continuing without admin rights.')
            Start-Sleep -Milliseconds 1200
        }
    }

    # Headless schedule management: -Schedule <daily|weekly> [-ScheduleTime HH:mm] / -RemoveSchedule
    if ($RemoveSchedule) {
        if ($null -eq (Get-SweepSchedule)) { Write-Host '[SCHEDULE] no scheduled sweep task exists.' }
        else {
            $err = Remove-SweepSchedule
            if ($err) { Write-Host (Get-Warn ('[SCHEDULE] ' + $err)) } else { Write-Host '[SCHEDULE] scheduled sweep task removed.' }
        }
        return
    }
    if ($PSBoundParameters.ContainsKey('Schedule') -and "$Schedule".Trim() -ne '') {
        $when = '09:00'
        if ($PSBoundParameters.ContainsKey('ScheduleTime') -and "$ScheduleTime".Trim() -ne '') { $when = "$ScheduleTime".Trim() }
        $err = Install-SweepSchedule ("$Schedule".Trim()) $when
        if ($err) { Write-Host (Get-Warn ('[SCHEDULE] ' + $err)) }
        else {
            $s = Get-SweepSchedule
            $nr = ''
            if ($s -and $s.NextRun) { $nr = ('  //  next run ' + $s.NextRun) }
            Write-Host ('[SCHEDULE] {0} sweep at {1} created.{2}' -f "$Schedule".Trim().ToLower(), $when, $nr)
        }
        return
    }

    # FAILSAFE: 2-second safe-mode window (runs in whichever instance survived elevation)
    Invoke-SafeModeGate

    # Resolve requested categories
    $runIds = $null
    if ($Script:CatList) {
        $valid = Get-AllCollectorIds
        $runIds = @()
        $bad = @()
        foreach ($c in $Script:CatList) {
            $cu = "$c".Trim().ToUpper()
            if ($valid -contains $cu) { $runIds += $cu } else { $bad += "$c" }
        }
        if ($bad.Count -gt 0) {
            Write-Host (Get-Warn ('  unknown categories: ' + ($bad -join ', ')))
            Write-Host (Get-Dim  ('  valid ids: ' + ($valid -join ', ')))
            if ($runIds.Count -eq 0) { return }
        }
    }
    if (-not $runIds -and ($Full -or -not $Script:Interactive)) { $runIds = Get-AllCollectorIds }

    if ($runIds) {
        if ($Script:Interactive) {
            try { Show-BootSequence } catch { Clear-Host }
        }
        $sum = Invoke-Sweep $runIds
        Show-SummaryScreen $sum
        return
    }

    # First-run guided setup (once, unless skipped). Never in safe mode.
    if ($Script:Interactive -and -not $SafeMode -and -not [bool]$Script:Settings.firstRunDone) {
        try { Show-FirstRunWizard } catch { $Script:Settings.firstRunDone = $true; Save-InvSettings }
    }

    # Interactive console (boot art is cosmetic - a fault there must never block the menu)
    try { Show-BootSequence } catch { Clear-Host }
    # Quiet update check - only interrupts when something newer is actually on the channel
    if ($Script:Settings.updateCheck -and (("$($Script:Brand.UpdateUrl)").Trim() -ne '')) {
        $upd = $null
        try { $upd = Test-ForUpdate } catch { }
        if ($upd -and ("$($Script:Settings.skippedVersion)" -ne $upd.Latest)) {
            try { Show-UpdateScreen $upd } catch { }
        }
    }
    # FAILSAFE: every screen runs inside a crash guard - an unexpected fault shows
    # a containment screen (with a safe-mode rollback) instead of killing the console.
    while ($true) {
        $action = $null
        try { $action = Show-MainMenu } catch {
            if (Show-CrashScreen $_) { continue } else { break }
        }
        try {
            if ($action -eq 'quit') { break }
            elseif ($action -eq 'full') {
                $sum = Invoke-Sweep (Get-AllCollectorIds)
                Show-SummaryScreen $sum
            }
            elseif ($action -eq 'pick') {
                $ids = Show-CategoryPicker
                if ($ids) {
                    $sum = Invoke-Sweep $ids
                    Show-SummaryScreen $sum
                }
            }
            elseif ($action -eq 'diff')     { Show-DiffScreen }
            elseif ($action -eq 'restore')  { Show-RestoreWizard }
            elseif ($action -eq 'search')   { Show-SearchScreen }
            elseif ($action -eq 'dashboard') { Show-DashboardScreen }
            elseif ($action -eq 'help')     { Show-HelpScreen }
            elseif ($action -eq 'manager')  { Show-SnapshotManager }
            elseif ($action -eq 'settings') { Show-SettingsScreen }
        } catch {
            if (-not (Show-CrashScreen $_)) { break }
        }
    }
    Clear-Host
    Write-Host ''
    Write-GradLine ('::  ' + $Script:Brand.Name + '  //  session ended  ::') -Center
    Write-Host ''
}

# Dot-sourcing the script loads all functions without running anything (for tests/tooling)
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Main
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
        if ($Script:AnsiOn) { Write-Host -NoNewline $Script:Rst }
        Restore-ConsoleColors
    }
}

#endregion
