<#
    Self-test for Inventorizer's update flow and typed input. The Check workflow
    runs it on every push to main, and the Release workflow runs it before
    anything is published, on Windows PowerShell 5.1.

    It drives the real code in a real console window: the script is loaded by
    dot-sourcing (which runs nothing), keys are typed into the console, and the
    screen is read back. The update channel and the download are faked, so
    nothing touches the network or this checkout.
#>
param([switch]$Child, [string]$Work, [string]$Out)
$ErrorActionPreference = 'Stop'

if (-not $Child) {
    # ---- parent: a throwaway install, the child in its own console window, then the checks
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).ProviderPath
    $work = Join-Path ([IO.Path]::GetTempPath()) ('inv-selftest-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $work)
    $install = Join-Path $work 'Inventorizer.ps1'
    Copy-Item -LiteralPath (Join-Path $repo 'Inventorizer.ps1') -Destination $install
    $versionLine = [regex]"(?m)^([ \t]*Version[ \t]*=[ \t]*')([^']*)'"
    $current = $versionLine.Match([IO.File]::ReadAllText($install)).Groups[2].Value
    # the build the fake channel offers: this script, one version up
    [IO.File]::WriteAllText((Join-Path $work 'next.ps1'), $versionLine.Replace([IO.File]::ReadAllText($install), '${1}99.0.0''', 1))
    $before = (Get-FileHash -LiteralPath $install -Algorithm SHA256).Hash
    $out = Join-Path $work 'results.json'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), '-Child', '-Work', ('"{0}"' -f $work), '-Out', ('"{0}"' -f $out))
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru
    $finished = $p.WaitForExit(180000)
    if (-not $finished) { $p.Kill() }
    if (Test-Path -LiteralPath ($out + '.log')) { Get-Content -LiteralPath ($out + '.log') | ForEach-Object { Write-Host "  child  $_" } }
    if (-not $finished) { Write-Host '::error::self-test: the console run hung'; exit 1 }
    if (-not (Test-Path -LiteralPath $out)) { Write-Host '::error::self-test: the console run left no results'; exit 1 }
    $r = Get-Content -LiteralPath $out -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($r.error) { Write-Host "::error::self-test: $($r.error)"; exit 1 }

    $script:failed = 0
    function Check([string]$What, [bool]$Ok) {
        if ($Ok) { Write-Host "  ok    $What" } else { Write-Host "  FAIL  $What"; Write-Host "::error::self-test: $What"; $script:failed++ }
    }
    function Read-Snap([string]$Name) {
        $f = Join-Path $work $Name
        if (-not (Test-Path -LiteralPath $f)) { return @() }
        return @([IO.File]::ReadAllText($f) -split "`n")
    }
    function Show-Snap([string]$Title, [string[]]$Lines) {
        Write-Host "  --- $Title"
        foreach ($l in $Lines) { if ($l.Trim()) { Write-Host ('  | ' + $l) } }
    }
    function Test-HangingIndent([string[]]$Lines, [string]$Start) {
        # The line holding $Start, and the one after it, begin their text at the same column.
        for ($i = 0; $i -lt $Lines.Count - 1; $i++) {
            $at = $Lines[$i].IndexOf($Start)
            if ($at -lt 0) { continue }
            $next = $Lines[$i + 1]
            return ($next.Trim() -and ($next.Length - $next.TrimStart().Length) -eq $at)
        }
        return $false
    }
    $width = [int]$r.width

    Write-Host 'loading'
    Check "the script loads without starting the app (v$($r.version))" ($r.version -eq $current)

    Write-Host 'typed input'
    Check "Right / Up at the end of a field add nothing: '$($r.note)'" ($r.note -ceq 'v26.7.3 test')

    Write-Host 'countdown'
    Check "runs its full time with no key ($($r.countdownFullMs) ms for 2 s)" ($r.countdownFullMs -ge 1800 -and $r.countdownFullMs -le 3500)
    Check "any key ends it early ($($r.countdownSkipMs) ms of 5 s)" ($r.countdownSkipMs -lt 2500)

    Write-Host 'update offer'
    Check "the channel offers v99.0.0 with 6 highlights ($($r.offered), $($r.highlights))" ($r.offered -eq '99.0.0' -and [int]$r.highlights -eq 6)
    $u = Read-Snap 'snap-update.txt'
    Show-Snap 'update screen' $u
    Check 'title and versions' ((($u -join "`n") -match 'UPDATE AVAILABLE') -and (($u -join "`n") -match ('v' + [regex]::Escape($current) + '  ->  v99\.0\.0')))
    Check 'four highlights shown' (@($u | Where-Object { $_.TrimStart().StartsWith('>  ') }).Count -eq 4)
    Check 'the rest are pointed to' (($u -join "`n") -match '\.\.\. and 2 more in the full changelog')
    Check 'the tag leads the first highlight' (@($u | Where-Object { $_ -match '^\s*>  INPUT :: typed fields' }).Count -eq 1)
    Check 'a long highlight wraps with its lines aligned' (Test-HangingIndent $u 'INPUT ::')
    Check "no line runs to the window edge ($width columns)" (@($u | Where-Object { $_.Length -ge ($width - 1) }).Count -eq 0)

    Write-Host 'full changelog'
    $c = Read-Snap 'snap-changelog.txt'
    Show-Snap 'changelog screen' $c
    $ct = $c -join "`n"
    Check 'both versions, newest first' ($ct.IndexOf('v99.0.0') -ge 0 -and $ct.IndexOf('v98.0.0') -gt $ct.IndexOf('v99.0.0'))
    Check 'highlights and notes are marked' (($ct -match '\*  INPUT :: ') -and ($ct -match '-  a note that is long enough'))
    Check 'a long note wraps with its lines aligned' (Test-HangingIndent $c 'a note that is long enough')
    Check "no line runs to the window edge ($width columns)" (@($c | Where-Object { $_.Length -ge ($width - 1) }).Count -eq 0)

    Write-Host 'update'
    $f = Read-Snap 'snap-final.txt'
    Show-Snap 'after updating' $f
    $ft = $f -join "`n"
    Check 'says what happened' (($ft -match 'UPDATED TO v99\.0\.0') -and ($ft -match 'previous build archived') -and ($ft -match 'reopens in a new window'))
    Check 'shows the countdown' ($ft -match 'relaunching in \ds  //  any key to relaunch now')
    Check "waits about 8 s before relaunching ($($r.countdownMs) ms)" ($r.countdownMs -ge 7000 -and $r.countdownMs -le 12000)
    Check 'relaunches the updated script' ("$($r.relaunch)" -like ('*' + (Split-Path -Leaf $work) + '\Inventorizer.ps1*'))
    Check 'the script was replaced with the new build' ((Get-FileHash -LiteralPath $install -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath (Join-Path $work 'next.ps1') -Algorithm SHA256).Hash)
    $backup = Join-Path $work ('config\backup\Inventorizer_v' + $current + '.ps1')
    Check 'the old build was archived' ((Test-Path -LiteralPath $backup) -and (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -eq $before)

    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    if ($script:failed -gt 0) { Write-Host "$($script:failed) check(s) failed"; exit 1 }
    Write-Host 'all self-test checks passed'
    exit 0
}

# ---- child: runs in its own console window
$log = $Out + '.log'
function Trace([string]$Message) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'HH:mm:ss.fff') + '  ' + $Message) }
$r = [ordered]@{}
function Save-Results { $r | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Out -Encoding UTF8 }
trap { $r.error = $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage; Trace ('TRAP: ' + $r.error); Save-Results; break }
Trace 'child started'

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class Console2 {
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct INPUT_RECORD {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKeyCode;
        [FieldOffset(12)] public ushort VirtualScanCode;
        [FieldOffset(14)] public char UnicodeChar;
        [FieldOffset(16)] public uint ControlKeyState;
    }
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct BUFFER_INFO { public COORD Size; public COORD Cursor; public ushort Attributes; public SMALL_RECT Window; public COORD MaxWindow; }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, COORD at, out uint read);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out BUFFER_INFO info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern short VkKeyScanW(char ch);
    [DllImport("user32.dll")] static extern uint MapVirtualKeyW(uint code, uint mapType);
    static void Send(ushort vk, char ch, uint state) {
        var recs = new INPUT_RECORD[2];
        for (int i = 0; i < 2; i++) {
            recs[i].EventType = 1; recs[i].KeyDown = (i == 0) ? 1 : 0; recs[i].RepeatCount = 1;
            recs[i].VirtualKeyCode = vk; recs[i].VirtualScanCode = (ushort)MapVirtualKeyW(vk, 0);
            recs[i].UnicodeChar = ch; recs[i].ControlKeyState = state;
        }
        uint n;
        if (!WriteConsoleInputW(GetStdHandle(-10), recs, 2, out n)) throw new Win32Exception();
    }
    public static void Text(string s) {
        foreach (char c in s) { short k = VkKeyScanW(c); Send((ushort)(k & 0xff), c, ((k >> 8) & 1) != 0 ? 0x10u : 0u); }
    }
    public static void Key(string name, int times) {
        ushort vk; char ch = '\0'; uint st = 0x100;
        switch (name) {
            case "Enter": vk = 0x0D; ch = '\r'; st = 0; break;
            case "Right": vk = 0x27; break;
            case "Up":    vk = 0x26; break;
            default: throw new ArgumentException(name);
        }
        for (int i = 0; i < times; i++) Send(vk, ch, st);
    }
    // The text of every row from the top of the buffer down to the cursor.
    public static string Screen() {
        IntPtr h = GetStdHandle(-11);
        BUFFER_INFO info;
        if (!GetConsoleScreenBufferInfo(h, out info)) throw new Win32Exception();
        var sb = new StringBuilder();
        int bottom = Math.Max((int)info.Cursor.Y, (int)info.Window.Bottom);
        for (int y = 0; y <= bottom; y++) {
            var buf = new char[info.Size.X]; uint read;
            var at = new COORD(); at.X = 0; at.Y = (short)y;
            if (!ReadConsoleOutputCharacterW(h, buf, (uint)buf.Length, at, out read)) throw new Win32Exception();
            sb.Append(new string(buf, 0, (int)read).TrimEnd()).Append('\n');
        }
        return sb.ToString();
    }
    // Steps on a background thread, while the script waits for keys:
    // wait:<ms>, type:<text>, snap:<file>, stamp:<file>.
    public static void Run(string[] steps, string log) {
        var t = new Thread(() => {
            foreach (var step in steps) {
                int i = step.IndexOf(':'); string op = step.Substring(0, i), arg = step.Substring(i + 1);
                try {
                    if (op == "wait") Thread.Sleep(int.Parse(arg));
                    else if (op == "type") Text(arg);
                    else if (op == "snap") File.WriteAllText(arg, Screen());
                    else if (op == "stamp") File.WriteAllText(arg, DateTime.UtcNow.Ticks.ToString());
                } catch (Exception e) { File.AppendAllText(log, "step " + step + ": " + e.Message + Environment.NewLine); }
            }
        });
        t.IsBackground = true;
        t.Start();
    }
}
'@

# the real script, loaded without running anything (it checks for dot-sourcing)
. (Join-Path $Work 'Inventorizer.ps1')
$ErrorActionPreference = 'Stop'
Initialize-Console
$r.version = $Script:Brand.Version
$r.width = [Console]::WindowWidth
Trace ("loaded v{0}, ansi {1}, window {2}x{3}" -f $Script:Brand.Version, $Script:AnsiOn, [Console]::WindowWidth, [Console]::WindowHeight)

# 1. typed input: the console's own line editor must not leak an earlier answer
[Console2]::Text('People deserve better.'); [Console2]::Key('Enter', 1)
[void](Read-Host 'tagline')
[Console2]::Text('v26.7.3 test'); [Console2]::Key('Right', 10); [Console2]::Key('Up', 2); [Console2]::Key('Enter', 1)
$r.note = Read-InvPrompt 'note for this snapshot'
Trace ('note: ' + $r.note)

# 2. countdown: full length with no key, cut short by a key
Clear-Host
$clock = [Diagnostics.Stopwatch]::StartNew()
Show-Countdown 2 'test countdown {0}s'
$r.countdownFullMs = $clock.ElapsedMilliseconds
[Console2]::Run(@('wait:700', 'type:k'), $log)
$clock.Restart()
Show-Countdown 5 'test countdown {0}s'
$r.countdownSkipMs = $clock.ElapsedMilliseconds
Trace ("countdown full {0} ms, skipped {1} ms" -f $r.countdownFullMs, $r.countdownSkipMs)

# 3. the update channel and download, faked
$Script:Web = @{}
function Invoke-WebRequest {
    [CmdletBinding()]
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec)
    if (-not $Script:Web.ContainsKey($Uri)) { throw "404 (Not Found): $Uri" }
    if ($OutFile) { Copy-Item -LiteralPath $Script:Web[$Uri] -Destination $OutFile -Force; return }
    [pscustomobject]@{ Content = [IO.File]::ReadAllText($Script:Web[$Uri]) }
}
$next = Join-Path $Work 'next.ps1'
$long = 'INPUT :: typed fields no longer pick up earlier answers, and this highlight keeps going on purpose so that it has to wrap across several lines at any normal window width, which is exactly what the update screen has to handle neatly.'
$manifest = [ordered]@{
    version   = '99.0.0'
    scriptUrl = 'https://raw.test/inventorizer/v99.0.0/Inventorizer.ps1'
    sha256    = (Get-FileHash -LiteralPath $next -Algorithm SHA256).Hash
    changelog = @(
        [ordered]@{ version = '99.0.0'; date = '2099-01-02'; highlights = @($long, 'UPDATES :: a short one'); notes = @('a note that is long enough to wrap: it explains a small fix in some detail, the way the full changelog often does, and runs well past one line') },
        [ordered]@{ version = '98.0.0'; date = '2099-01-01'; highlights = @('THEME STUDIO :: third', 'NEW :: fourth', 'NEW :: fifth', 'NEW :: sixth'); notes = @() }
    )
}
$channel = Join-Path $Work 'version.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $channel -Encoding UTF8
$Script:Brand.UpdateUrl = 'https://raw.test/inventorizer/main/version.json'
$Script:Web[$Script:Brand.UpdateUrl] = $channel
$Script:Web[$manifest.scriptUrl] = $next

$upd = Test-ForUpdate
$r.offered = "$($upd.Latest)"
$r.highlights = @($upd.Highlights).Count
Trace ("offered v{0} with {1} highlights" -f $r.offered, $r.highlights)

# 4. the update itself. Relaunching is the last step: capture the screen there and
#    record the results, then let Inventorizer exit as it does after an update.
$stampFile = Join-Path $Work 'pressed-u.txt'
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [object[]]$ArgumentList)
    [IO.File]::WriteAllText((Join-Path $Work 'snap-final.txt'), [Console2]::Screen())
    $r.relaunch = $FilePath + ' ' + ($ArgumentList -join ' ')
    if (Test-Path -LiteralPath $stampFile) {
        $r.countdownMs = [int](([DateTime]::UtcNow.Ticks - [long](Get-Content -LiteralPath $stampFile -Raw)) / 10000)
    }
    Trace ("relaunch after {0} ms: {1}" -f $r.countdownMs, $r.relaunch)
    Save-Results
}
[Console2]::Run(@(
    'wait:1500', ('snap:' + (Join-Path $Work 'snap-update.txt')), 'type:c',
    'wait:1500', ('snap:' + (Join-Path $Work 'snap-changelog.txt')), 'type:x',
    'wait:1200', ('stamp:' + $stampFile), 'type:u',
    'wait:25000', 'type:x', 'wait:500', 'type:x'
), $log)
Show-UpdateScreen $upd
# Only reached if the update didn't relaunch.
$r.error = 'the update returned instead of relaunching'
Save-Results
