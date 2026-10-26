<# : batch
@echo off
title ARK Optimizer
set "SELF=%~f0"
set "ARKOPT_MODE=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:SELF))"
echo.
pause
exit /b
#>

# ======================================================================
#  ARK: Survival Evolved - Optimizer
#  Detects your hardware, picks a graphics profile, backs up and tweaks
#  Engine.ini, GameUserSettings.ini and Game.ini, and applies a few
#  Windows tweaks, optionally installs DXVK (official GitHub release).
#  Everything can be reverted with option 2.
#  Plain text script - open it in Notepad to see exactly what it does.
# ======================================================================

function Say($t, $c = 'Gray') { Write-Host $t -ForegroundColor $c }

# ---------- INI handling (changes only our keys, keeps everything else) ----------
function Get-FileEnc($path) {
    $b = [IO.File]::ReadAllBytes($path)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return 'Unicode' }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return 'UTF8' }
    return 'Default'
}

function Set-IniSection($path, $section, $values, $remove = @()) {
    $enc = 'Default'
    $list = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        $enc = Get-FileEnc $path
        foreach ($l in (Get-Content -LiteralPath $path)) { $list.Add([string]$l) }
    }
    $start = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        if ($list[$i].Trim() -ieq "[$section]") { $start = $i; break }
    }
    if ($start -lt 0) {
        if ($list.Count -gt 0 -and $list[$list.Count - 1].Trim() -ne '') { $list.Add('') }
        $list.Add("[$section]")
        $start = $list.Count - 1
    }
    $end = $list.Count
    for ($i = $start + 1; $i -lt $list.Count; $i++) {
        if ($list[$i].Trim().StartsWith('[')) { $end = $i; break }
    }
    while ($end - 1 -gt $start -and $list[$end - 1].Trim() -eq '') { $end-- }
    for ($i = $end - 1; $i -gt $start; $i--) {
        foreach ($r in $remove) {
            if ($list[$i] -match ('^\s*' + [regex]::Escape($r) + '\s*=')) { $list.RemoveAt($i); $end--; break }
        }
    }
    foreach ($k in $values.Keys) {
        $found = $false
        for ($i = $start + 1; $i -lt $end; $i++) {
            if ($list[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) {
                $list[$i] = "$k=$($values[$k])"; $found = $true
            }
        }
        if (-not $found) { $list.Insert($end, "$k=$($values[$k])"); $end++ }
    }
    Set-Content -LiteralPath $path -Value $list -Encoding $enc
}

# ---------- Find the game ----------
function Find-Ark {
    $libs = New-Object System.Collections.Generic.List[string]
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch {}
    if ($steam) {
        $steam = $steam -replace '/', '\'
        $libs.Add($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs.Add(($m.Groups[1].Value -replace '\\\\', '\'))
            }
        }
    }
    foreach ($d in [char[]](67..90)) {
        if (Test-Path "${d}:\") {
            $libs.Add("${d}:\SteamLibrary"); $libs.Add("${d}:\Steam"); $libs.Add("${d}:\Program Files (x86)\Steam"); $libs.Add("${d}:\Games\Steam")
        }
    }
    foreach ($l in $libs) {
        $p = Join-Path $l 'steamapps\common\ARK'
        if (Test-Path -LiteralPath (Join-Path $p 'ShooterGame')) { return $p }
    }
    return $null
}

# ---------- Hardware ----------
function Get-Hardware {
    $hw = @{}
    $vram = 0.0; $name = ''
    try {
        Get-ItemProperty 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -ErrorAction SilentlyContinue | ForEach-Object {
            $m = $_.'HardwareInformation.qwMemorySize'
            if ($m) {
                $gb = [math]::Round([double]$m / 1GB, 1)
                if ($gb -gt $vram) { $vram = $gb; $name = $_.DriverDesc }
            }
        }
    } catch {}
    if ($vram -eq 0) {
        $v = Get-CimInstance Win32_VideoController | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        $vram = [math]::Round([double]$v.AdapterRAM / 1GB, 1); $name = $v.Name
    }
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $hw.GpuName = $name
    $hw.Vram    = $vram
    $hw.Ram     = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $hw.CpuName = $cpu.Name.Trim()
    $hw.Cores   = [int]$cpu.NumberOfCores
    $hw.Integrated = (($name -match 'Intel') -and ($name -notmatch 'Arc')) -or ($name -match 'Vega \d+ Graphics|Radeon\(TM\) Graphics|^AMD Radeon Graphics$')
    return $hw
}

# ---------- Auto-balanced profile: CPU and GPU settings chosen separately ----------
# ARK is mostly CPU-bound. Settings that load the GPU follow GPU power, settings
# that load the CPU follow CPU power, so neither waits for the other.

# CPU class 0-3 from core count and generation
function Get-CpuTier($hw) {
    $n = $hw.CpuName; $c = $hw.Cores
    if ($c -lt 4) { return 0 }
    $gen = -1   # 0 = old, 1 = mid, 2 = new
    if ($n -match 'Ryzen\s+(Threadripper\s+)?\d\s+(PRO\s+)?(\d)\d{3}') {
        $g = [int]$Matches[3]
        $gen = if ($g -le 2) { 0 } elseif ($g -le 4) { 1 } else { 2 }
    } elseif ($n -match 'Core\(TM\)\s+i\d-(\d{4,5})') {
        $num = $Matches[1]
        # 5 digits (12400) or laptop 4 digits starting with 1 (1165G7) = two-digit generation
        $g = if ($num.Length -eq 5 -or $num.StartsWith('1')) { [int]$num.Substring(0, 2) } else { [int]$num.Substring(0, 1) }
        $gen = if ($g -le 7) { 0 } elseif ($g -le 11) { 1 } else { 2 }
    } elseif ($n -match 'Core.*Ultra|i\d-1[2-4]\d{3}') { $gen = 2 }
    elseif ($n -match 'FX|Athlon|Pentium|Celeron|Phenom|A\d+-\d{4}') { $gen = 0 }

    if ($gen -eq -1) { if ($c -ge 6) { return 2 } else { return 1 } }
    if ($gen -eq 0) { if ($c -ge 6) { return 1 } else { return 0 } }
    if ($gen -eq 1) { if ($c -ge 6) { return 2 } else { return 1 } }
    if ($c -ge 6) { return 3 } else { return 2 }
}

# GPU class 0-4 from VRAM, capped for older GPU families
function Get-GpuTier($hw) {
    if ($hw.Integrated) { return 0 }
    $v = $hw.Vram
    $t = if ($v -lt 2.5) { 0 } elseif ($v -lt 3.5) { 1 } elseif ($v -lt 5.5) { 2 } elseif ($v -lt 7.5) { 3 } else { 4 }
    if ($hw.GpuName -match 'RX 4\d0|RX 5[0-9]0\b|RX 590|GTX 9\d0|GTX 10[0-6]0|GTX 16\d0|R9 |R7 |HD \d{4}|GTX [4-7]\d0' -and $t -gt 3) { $t = 3 }
    if ($hw.Ram -lt 7) { $t = [math]::Min($t, 1) }
    return $t
}

$CpuNames = @('weak', 'older', 'mid-range', 'fast')
$GpuNames = @('weak / integrated', 'entry', 'mid-range', 'good', 'strong')

function New-AutoProfile($cpuT, $gpuT, $hw) {
    $g = $gpuT
    # textures depend on VRAM only - they cost memory, not speed
    $v = $hw.Vram
    $tex = if ($hw.Integrated -or $v -lt 2.5) { 0 } elseif ($v -lt 3.5) { 1 } elseif ($v -lt 5.5) { 2 } else { 3 }
    # CPU-heavy settings follow the CPU, but never above what the GPU can draw
    $c = [math]::Min($cpuT, $g)
    $cs = @(0, 1, 2, 3)[$c]
    # GPU-side quality: 0 Low, 1 Medium, 2 High, 3 Epic. The FPS limit keeps the
    # GPU from overworking, so spare GPU power goes into a nicer picture.
    $sg = [ordered]@{
        'sg.ResolutionQuality'       = @('70', '85', '100', '100', '100')[$g]
        'sg.ViewDistanceQuality'     = "$cs"
        'sg.AntiAliasingQuality'     = @('0', '0', '1', '2', '3')[$g]
        'sg.ShadowQuality'           = "$cs"
        'sg.PostProcessQuality'      = @('0', '0', '1', '2', '3')[$g]
        'sg.TextureQuality'          = "$tex"
        'sg.EffectsQuality'          = @('0', '0', '1', '2', '3')[$g]
        'sg.TrueSkyQuality'          = @('0.000000', '0.200000', '0.300000', '0.600000', '0.800000')[$g]
        'sg.GroundClutterQuality'    = "$cs"
        'sg.IBLQuality'              = @('0', '0', '1', '2', '3')[$g]
        'sg.HeightFieldShadowQuality'= "$cs"
    }
    # Pretty = keep ambient occlusion (depth) and water reflections on
    return @{ sg = $sg; LightShafts = @('0', '0', '1', '1', '1')[$g]; Aniso = @('2', '4', '8', '16', '16')[$g]; Pretty = ($g -ge 3) }
}

# Texture streaming pool in MB - more VRAM = sharper textures, less pop-in
function Get-PoolSize($hw) {
    if ($hw.Integrated -or $hw.Vram -lt 2.5) { return 600 }
    if ($hw.Vram -lt 3.5) { return 1000 }
    if ($hw.Vram -lt 5.5) { return 1800 }
    if ($hw.Vram -lt 7.5) { return 2500 }
    return 3500
}

# ---------- DXVK (DirectX 11 -> Vulkan, official release from GitHub) ----------
$DxvkMark = 'dxvk_by_ark_optimizer.txt'

function Install-Dxvk($ark, $hw) {
    $bin = Join-Path $ark 'ShooterGame\Binaries\Win64'
    if (-not (Test-Path -LiteralPath (Join-Path $bin 'ShooterGame.exe'))) {
        Say '  Game executable not found, DXVK skipped.' Yellow; return $null
    }
    # DXVK 2.x needs Vulkan 1.3 (newer GPUs). Older GPUs get 1.10.3 (Vulkan 1.1).
    $modern = $hw.GpuName -match 'RTX|GTX 1[0-9]|GTX 16|RX 5[0-9]{3}|RX 6[0-9]{3}|RX 7[0-9]{3}|RX 9[0-9]{3}|Arc'
    $ver = if ($modern) { '2.6.2' } else { '1.10.3' }
    # Already installed in the game folder -> nothing to do
    if ((Get-DxvkVersion $ark) -eq $ver -and (Test-Path -LiteralPath (Join-Path $bin 'd3d11.dll')) -and (Test-Path -LiteralPath (Join-Path $bin 'dxgi.dll'))) {
        Say "  DXVK $ver is already installed - nothing to download." Green
        return $ver
    }
    # Local cache: after the first download DXVK is never downloaded again
    $x64 = Join-Path $OptHome "dxvk-$ver"
    $cached = (Test-Path -LiteralPath (Join-Path $x64 'd3d11.dll')) -and (Test-Path -LiteralPath (Join-Path $x64 'dxgi.dll'))
    if ($cached) {
        Say "  Using DXVK $ver from the local cache - no download needed."
    } else {
        $url = "https://github.com/doitsujin/dxvk/releases/download/v$ver/dxvk-$ver.tar.gz"
        $tmp = Join-Path $env:TEMP "ark_optimizer_dxvk_$ver"
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $tgz = Join-Path $tmp 'dxvk.tar.gz'
        Say "  Downloading DXVK $ver from GitHub (only this once)..."
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $tgz -UseBasicParsing
        tar -xzf $tgz -C $tmp
        if ($LASTEXITCODE -ne 0) { throw 'Could not extract DXVK.' }
        New-Item -ItemType Directory -Path $x64 -Force | Out-Null
        foreach ($dll in 'd3d11.dll', 'dxgi.dll') {
            $src = Join-Path $tmp "dxvk-$ver\x64\$dll"
            if (-not (Test-Path -LiteralPath $src)) { throw "$dll missing in the DXVK package." }
            Copy-Item -LiteralPath $src -Destination $x64 -Force
        }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $already = Test-Path -LiteralPath (Join-Path $bin $DxvkMark)
    foreach ($dll in 'd3d11.dll', 'dxgi.dll') {
        $src = Join-Path $x64 $dll
        if (-not (Test-Path -LiteralPath $src)) { throw "$dll missing in the DXVK package." }
        $dst = Join-Path $bin $dll
        if ((Test-Path -LiteralPath $dst) -and -not $already) { Copy-Item -LiteralPath $dst -Destination "$dst.bak_optimizer" -Force }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
    Set-Content -LiteralPath (Join-Path $bin $DxvkMark) -Value "DXVK $ver installed by ARK Optimizer. Run the optimizer and choose 3 to remove it." -Encoding ASCII
    return $ver
}

# Version of DXVK installed by this program, or $null
function Get-DxvkVersion($ark) {
    $mark = Join-Path $ark "ShooterGame\Binaries\Win64\$DxvkMark"
    if (-not (Test-Path -LiteralPath $mark)) { return $null }
    $m = [regex]::Match((Get-Content -LiteralPath $mark -Raw), 'DXVK (\d+\.\d+(\.\d+)?)')
    if ($m.Success) { return $m.Groups[1].Value }
    return 'unknown'
}

function Remove-Dxvk($ark) {
    $bin = Join-Path $ark 'ShooterGame\Binaries\Win64'
    $mark = Join-Path $bin $DxvkMark
    if (-not (Test-Path -LiteralPath $mark)) { return $false }
    foreach ($dll in 'd3d11.dll', 'dxgi.dll') {
        $dst = Join-Path $bin $dll
        Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath "$dst.bak_optimizer") { Move-Item -LiteralPath "$dst.bak_optimizer" -Destination $dst -Force }
    }
    Remove-Item -LiteralPath (Join-Path $bin 'dxvk.conf') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $mark -Force
    return $true
}

# DXVK frame limiter: evenly paced frames (like RTSS), written next to the game
function Set-DxvkLimiter($ark, $fps) {
    $bin = Join-Path $ark 'ShooterGame\Binaries\Win64'
    if (-not (Test-Path -LiteralPath (Join-Path $bin $DxvkMark))) { return $false }
    $conf = Join-Path $bin 'dxvk.conf'
    if ($fps -gt 0) {
        Set-Content -LiteralPath $conf -Encoding ASCII -Value @(
            '# Written by ARK Optimizer - evenly paced frame limit',
            "dxgi.maxFrameRate = $fps"
        )
        return $true
    }
    Remove-Item -LiteralPath $conf -Force -ErrorAction SilentlyContinue
    return $false
}

# ---------- Standby memory cleaner (like ISLC / RAMMap "Empty Standby List") ----------
$PurgeScript = @'
try {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ArkMemPurge {
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct TokPriv { public int Count; public long Luid; public int Attr; }
    [DllImport("ntdll.dll")] static extern uint NtSetSystemInformation(int infoClass, ref int info, int length);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokPriv state, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    public static uint Purge() {
        IntPtr token;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return 1;
        TokPriv tp = new TokPriv(); tp.Count = 1; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out tp.Luid)) return 2;
        AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
        int cmd = 4;   // MemoryPurgeStandbyList
        return NtSetSystemInformation(80, ref cmd, 4);   // SystemMemoryListInformation
    }
}
"@
if ([ArkMemPurge]::Purge() -eq 0) { exit 0 } else { exit 1 }
} catch { exit 1 }
'@

function Clear-StandbyMemory {
    Say '  Clearing standby memory (Windows will ask for permission)...'
    if (Invoke-Elevated $PurgeScript) { Say '  Standby memory cleared - more free RAM for ARK.' Green }
    else { Say '  Memory was not cleared (permission declined). Starting anyway.' Yellow }
}

# ---------- Intro videos (moved here by clean-up, restored with option 2) ----------
$MoviesBak = '_disabled_by_ark_optimizer'

function Restore-Movies($ark) {
    $movies = Join-Path $ark 'ShooterGame\Content\Movies'
    $mBak = Join-Path $movies $MoviesBak
    if (-not (Test-Path -LiteralPath $mBak)) { return $false }
    Get-ChildItem -LiteralPath $mBak -File | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $movies -Force }
    Remove-Item -LiteralPath $mBak -Force -Recurse -ErrorAction SilentlyContinue
    return $true
}

# ---------- Faster loading: Windows Defender exclusion (needs admin) ----------
$DefMark = 'defender_exclusion_by_optimizer.txt'

function Q($s) { "'" + ($s -replace "'", "''") + "'" }

function Invoke-Elevated($script) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    try {
        $proc = Start-Process powershell -Verb RunAs -WindowStyle Hidden -Wait -PassThru `
            -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $b64
        return ($proc.ExitCode -eq 0)
    } catch { return $false }   # user said No in the Windows prompt
}

function Add-DefenderExclusion($ark, $cfg) {
    $mark = Join-Path $cfg $DefMark
    $s = "try { Add-MpPreference -ExclusionPath $(Q $ark) -ErrorAction Stop; " +
         "Set-Content -LiteralPath $(Q $mark) -Value $(Q $ark) -Encoding ASCII; exit 0 } catch { exit 1 }"
    return (Invoke-Elevated $s)
}

function Remove-DefenderExclusion($cfg) {
    $mark = Join-Path $cfg $DefMark
    if (-not (Test-Path -LiteralPath $mark)) { return $false }
    $path = (Get-Content -LiteralPath $mark -Raw).Trim()
    $s = "try { Remove-MpPreference -ExclusionPath $(Q $path) -ErrorAction Stop } catch {}; " +
         "Remove-Item -LiteralPath $(Q $mark) -Force; exit 0"
    return (Invoke-Elevated $s)
}

function Get-ModCount($ark) {
    $mods = Join-Path $ark 'ShooterGame\Content\Mods'
    if (-not (Test-Path -LiteralPath $mods)) { return 0 }
    return @(Get-ChildItem -LiteralPath $mods -Filter '*.mod' -File -ErrorAction SilentlyContinue |
             Where-Object { $_.BaseName -ne '111111111' }).Count
}

# ---------- Profiles ----------
$TierNames = @(
    'Very weak PC  - maximum performance, lower visuals',
    'Weak PC       - smoothness first',
    'Mid-range PC  - balanced',
    'Good PC       - nice visuals and smooth',
    'Best visuals  - as pretty as possible (GPU with 6+ GB VRAM)'
)

$Profiles = @(
    # 0 very weak
    @{ sg = [ordered]@{ 'sg.ResolutionQuality'='70'; 'sg.ViewDistanceQuality'='0'; 'sg.AntiAliasingQuality'='0'; 'sg.ShadowQuality'='0'; 'sg.PostProcessQuality'='0'; 'sg.TextureQuality'='0'; 'sg.EffectsQuality'='0'; 'sg.TrueSkyQuality'='0.000000'; 'sg.GroundClutterQuality'='0'; 'sg.IBLQuality'='0'; 'sg.HeightFieldShadowQuality'='0' }
       LightShafts='0'; Aniso='2' },
    # 1 weak
    @{ sg = [ordered]@{ 'sg.ResolutionQuality'='85'; 'sg.ViewDistanceQuality'='1'; 'sg.AntiAliasingQuality'='0'; 'sg.ShadowQuality'='0'; 'sg.PostProcessQuality'='0'; 'sg.TextureQuality'='1'; 'sg.EffectsQuality'='0'; 'sg.TrueSkyQuality'='0.200000'; 'sg.GroundClutterQuality'='0'; 'sg.IBLQuality'='0'; 'sg.HeightFieldShadowQuality'='0' }
       LightShafts='0'; Aniso='4' },
    # 2 mid-range
    @{ sg = [ordered]@{ 'sg.ResolutionQuality'='100'; 'sg.ViewDistanceQuality'='1'; 'sg.AntiAliasingQuality'='0'; 'sg.ShadowQuality'='1'; 'sg.PostProcessQuality'='1'; 'sg.TextureQuality'='1'; 'sg.EffectsQuality'='1'; 'sg.TrueSkyQuality'='0.300000'; 'sg.GroundClutterQuality'='1'; 'sg.IBLQuality'='1'; 'sg.HeightFieldShadowQuality'='1' }
       LightShafts='1'; Aniso='8' },
    # 3 good
    @{ sg = [ordered]@{ 'sg.ResolutionQuality'='100'; 'sg.ViewDistanceQuality'='2'; 'sg.AntiAliasingQuality'='1'; 'sg.ShadowQuality'='2'; 'sg.PostProcessQuality'='2'; 'sg.TextureQuality'='2'; 'sg.EffectsQuality'='2'; 'sg.TrueSkyQuality'='0.600000'; 'sg.GroundClutterQuality'='2'; 'sg.IBLQuality'='2'; 'sg.HeightFieldShadowQuality'='2' }
       LightShafts='1'; Aniso='16'; Pretty=$true },
    # 4 best visuals (Epic)
    @{ sg = [ordered]@{ 'sg.ResolutionQuality'='100'; 'sg.ViewDistanceQuality'='3'; 'sg.AntiAliasingQuality'='3'; 'sg.ShadowQuality'='3'; 'sg.PostProcessQuality'='3'; 'sg.TextureQuality'='3'; 'sg.EffectsQuality'='3'; 'sg.TrueSkyQuality'='0.800000'; 'sg.GroundClutterQuality'='3'; 'sg.IBLQuality'='3'; 'sg.HeightFieldShadowQuality'='3' }
       LightShafts='1'; Aniso='16'; Pretty=$true }
)

# ---------- Windows per-game flags for ShooterGame.exe (reverted with option 2) ----------
# 1) GPU preference "High performance" - laptops with two GPUs run ARK on the strong one
# 2) Fullscreen optimizations off - real exclusive fullscreen, less stutter for many players
$FlagsMark = 'winflags_by_optimizer.json'
$GpuPrefKey = 'Software\Microsoft\DirectX\UserGpuPreferences'
$LayersKey  = 'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$FsoFlag    = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'

function Set-GameFlags($ark, $cfg) {
    $exe = Join-Path $ark 'ShooterGame\Binaries\Win64\ShooterGame.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $mark = Join-Path $cfg $FlagsMark
    $k1 = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($GpuPrefKey)
    $k2 = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($LayersKey)
    try {
        $old1 = $k1.GetValue($exe); $old2 = $k2.GetValue($exe)
        if (-not (Test-Path -LiteralPath $mark)) {   # remember the ORIGINAL values only once
            $m = [ordered]@{ Exe = $exe; OldGpu = $old1; OldLayers = $old2 }
            Set-Content -LiteralPath $mark -Value (ConvertTo-Json $m) -Encoding UTF8
        }
        $k1.SetValue($exe, 'GpuPreference=2;')
        if ($old2 -and ([string]$old2) -match $FsoFlag) { }
        elseif ($old2) { $k2.SetValue($exe, ([string]$old2).TrimEnd() + " $FsoFlag") }
        else { $k2.SetValue($exe, "~ $FsoFlag") }
    } finally { $k1.Close(); $k2.Close() }
    return $true
}

function Remove-GameFlags($cfg) {
    $mark = Join-Path $cfg $FlagsMark
    if (-not (Test-Path -LiteralPath $mark)) { return $false }
    $m = Get-Content -LiteralPath $mark -Raw | ConvertFrom-Json
    $k1 = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($GpuPrefKey)
    $k2 = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($LayersKey)
    try {
        if ($m.OldGpu) { $k1.SetValue($m.Exe, [string]$m.OldGpu) } else { $k1.DeleteValue($m.Exe, $false) }
        if ($m.OldLayers) { $k2.SetValue($m.Exe, [string]$m.OldLayers) } else { $k2.DeleteValue($m.Exe, $false) }
    } finally { $k1.Close(); $k2.Close() }
    Remove-Item -LiteralPath $mark -Force
    return $true
}

# ---------- Loading checks ----------
# Installed size of ARK from the Steam manifest (instant, no folder scan)
function Get-ArkSizeGB($ark) {
    $manifest = Join-Path (Split-Path (Split-Path $ark -Parent) -Parent) 'appmanifest_346110.acf'
    if (Test-Path -LiteralPath $manifest) {
        $m = [regex]::Match((Get-Content -LiteralPath $manifest -Raw), '"SizeOnDisk"\s+"(\d+)"')
        if ($m.Success) { return [math]::Ceiling([double]$m.Groups[1].Value / 1GB) }
    }
    return 0
}

# SSD drives with their free space (GB)
function Get-SsdVolumes {
    $list = @()
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.MediaType -eq 'SSD' })) {
            foreach ($pt in @(Get-Partition -DiskNumber ([int]$pd.DeviceId) -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })) {
                $v = Get-Volume -DriveLetter $pt.DriveLetter -ErrorAction SilentlyContinue
                if ($v) { $list += @{ Letter = [string]$pt.DriveLetter; FreeGB = [math]::Floor($v.SizeRemaining / 1GB) } }
            }
        }
    } catch {}
    return $list
}

# Page file: disabled or very small = crashes and stutter in ARK
function Get-PageFileProblem($ramGB) {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.AutomaticManagedPagefile) { return $null }
        $use = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
        if ($use.Count -eq 0) { return 'disabled' }
        $total = ($use | Measure-Object AllocatedBaseSize -Sum).Sum   # MB
        if ($total -lt 8192 -and $ramGB -le 16) { return "only $([math]::Round($total / 1024, 1)) GB" }
    } catch {}
    return $null
}

# Programs using a lot of RAM (grouped by name, browsers have many processes)
function Get-MemoryHogs {
    $skip = '^(ShooterGame|steam|steamwebhelper|steamservice|explorer|dwm|System|Idle|Registry|Memory Compression|MsMpEng|svchost|csrss|lsass|wininit|winlogon|services|smss|fontdrvhost|powershell|pwsh|conhost|cmd|audiodg|SearchHost|StartMenuExperienceHost|ShellExperienceHost|TextInputHost|RuntimeBroker|ctfmon|sihost|taskhostw|SecurityHealthService|RadeonSoftware|AMDRSServ|NVIDIA.*|nvcontainer|NisSrv|spoolsv|WmiPrvSE|dllhost)$'
    return @(Get-Process | Where-Object { $_.ProcessName -notmatch $skip } |
        Group-Object ProcessName | ForEach-Object {
            @{ Name = $_.Name; GB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1GB, 1) }
        } | Where-Object { $_.GB -ge 0.4 } | Sort-Object { $_.GB } -Descending | Select-Object -First 5)
}

function Show-MemoryCheck {
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $hogs = Get-MemoryHogs
        if ($free -lt 6 -or $hogs.Count -gt 0) {
            $c = if ($free -lt 6) { 'Yellow' } else { 'Gray' }
            Say "  Free RAM: $free GB. ARK needs a lot of memory - for faster loading and less" $c
            Say '  stutter, close these programs before playing (save your work first):' $c
            foreach ($h in $hogs) { Say "     $($h.Name)  ($($h.GB) GB)" $c }
            if ($hogs.Count -eq 0) { Say '     (no single big program - close what you do not need)' $c }
            [void](Read-Host '  Press Enter to start ARK')
        } else {
            Say "  Free RAM: $free GB - good." Green
        }
    } catch {}
}

# ---------- Saved state (used by the self-repairing launcher and auto-tune) ----------
$OptHome   = Join-Path $env:LOCALAPPDATA 'ARK_Optimizer'
$StateFile = Join-Path $OptHome 'state.json'
$CI = [Globalization.CultureInfo]::InvariantCulture

function Add-Applied($list, $cfg, $file, $section, $values, $remove = @()) {
    Set-IniSection (Join-Path $cfg $file) $section $values $remove
    $v = [ordered]@{}; foreach ($k in $values.Keys) { $v[$k] = [string]$values[$k] }
    $list.Add(@{ File = $file; Section = $section; Values = $v; Remove = @($remove) })
}

function Save-State($state) {
    if (-not (Test-Path -LiteralPath $OptHome)) { New-Item -ItemType Directory -Path $OptHome | Out-Null }
    $o = [ordered]@{}
    $o['Version'] = 1; $o['ArkPath'] = [string]$state.ArkPath; $o['Cfg'] = [string]$state.Cfg
    $o['CleanMem'] = [bool]$state.CleanMem
    $o['Applied'] = $state.Applied.ToArray()
    Set-Content -LiteralPath $StateFile -Value (ConvertTo-Json $o -Depth 6) -Encoding UTF8
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try { $j = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { return $null }
    $st = @{ ArkPath = $j.ArkPath; Cfg = $j.Cfg; CleanMem = [bool]$j.CleanMem; Applied = New-Object System.Collections.Generic.List[object] }
    foreach ($e in @($j.Applied)) {
        $v = [ordered]@{}
        if ($e.Values) { foreach ($pp in $e.Values.PSObject.Properties) { $v[$pp.Name] = [string]$pp.Value } }
        $st.Applied.Add(@{ File = $e.File; Section = $e.Section; Values = $v; Remove = @(@($e.Remove) | Where-Object { $_ }) })
    }
    return $st
}

function Get-IniSectionValues($path, $section) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $h = @{}; $in = $false
    foreach ($l in (Get-Content -LiteralPath $path)) {
        $t = ([string]$l).Trim()
        if ($t.StartsWith('[')) { $in = ($t -ieq "[$section]"); continue }
        if ($in -and $t -match '^([^=;]+?)\s*=(.*)$') { $h[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $h
}

function Test-SameValue($a, $b) {
    if ($null -eq $a -or $null -eq $b) { return $false }
    $da = 0.0; $db = 0.0; $ns = [Globalization.NumberStyles]::Float
    if ([double]::TryParse([string]$a, $ns, $CI, [ref]$da) -and [double]::TryParse([string]$b, $ns, $CI, [ref]$db)) {
        return ([math]::Abs($da - $db) -lt 0.001)
    }
    return ([string]$a).Trim() -ieq ([string]$b).Trim()
}

function Get-SettingDiffs($state) {
    $diffs = New-Object System.Collections.Generic.List[object]
    foreach ($e in $state.Applied) {
        $cur = Get-IniSectionValues (Join-Path $state.Cfg $e.File) $e.Section
        foreach ($k in @($e.Values.Keys)) {
            $c = if ($cur) { $cur[$k] } else { $null }
            if (-not (Test-SameValue $c $e.Values[$k])) { $diffs.Add(@{ Entry = $e; Key = $k; Current = $c; IsRemove = $false }) }
        }
        foreach ($k in @($e.Remove)) {
            if ($cur -and $cur.ContainsKey($k)) { $diffs.Add(@{ Entry = $e; Key = $k; Current = $cur[$k]; IsRemove = $true }) }
        }
    }
    return ,$diffs
}

function Write-Applied($state) {
    foreach ($e in $state.Applied) { Set-IniSection (Join-Path $state.Cfg $e.File) $e.Section $e.Values $e.Remove }
}

function Use-CurrentValues($diffs) {
    foreach ($d in $diffs) {
        if ($d.IsRemove) { $d.Entry.Remove = @($d.Entry.Remove | Where-Object { $_ -ne $d.Key }) }
        elseif ($null -ne $d.Current) { $d.Entry.Values[$d.Key] = $d.Current }
    }
}

# ---------- Auto-tune: measure real CPU/GPU load while playing ----------
$GpuKeys = @('sg.AntiAliasingQuality', 'sg.PostProcessQuality', 'sg.EffectsQuality', 'sg.IBLQuality')
$CpuKeys = @('sg.ViewDistanceQuality', 'sg.ShadowQuality', 'sg.GroundClutterQuality', 'sg.HeightFieldShadowQuality')
$KeyNames = @{
    'sg.AntiAliasingQuality' = 'Anti-aliasing'; 'sg.PostProcessQuality' = 'General shading'
    'sg.EffectsQuality' = 'Effects'; 'sg.IBLQuality' = 'Lighting quality'
    'sg.ViewDistanceQuality' = 'View distance'; 'sg.ShadowQuality' = 'Shadows'
    'sg.GroundClutterQuality' = 'Grass'; 'sg.HeightFieldShadowQuality' = 'Terrain shadows'
    'sg.TrueSkyQuality' = 'Sky quality'; 'sg.ResolutionQuality' = 'Resolution'
}

function Measure-Session($gamePid) {
    $gpuOk = $true
    $samples = New-Object System.Collections.Generic.List[object]
    $start = Get-Date
    while (Get-Process -Id $gamePid -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 3
        if (((Get-Date) - $start).TotalSeconds -lt 120) { continue }   # skip loading
        $g = $null
        if ($gpuOk) {
            try {
                $eng = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop |
                       Where-Object { $_.Name -like "pid_$($gamePid)_*engtype_3D" }
                $g = [math]::Min(100, [double](($eng | Measure-Object UtilizationPercentage -Sum).Sum))
            } catch { $gpuOk = $false }
        }
        $cores = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_Total' }
        $cmax = [double](($cores | Measure-Object PercentProcessorTime -Maximum).Maximum)
        if ($null -ne $g -and $g -lt 5) { continue }   # menu, loading screen or minimized
        $samples.Add(@{ Gpu = $g; Cpu = $cmax })
    }
    if ($samples.Count -eq 0) { return @{ Count = 0 } }
    $gs = @($samples | Where-Object { $null -ne $_.Gpu } | ForEach-Object { $_.Gpu })
    return @{
        Count  = $samples.Count
        HasGpu = ($gs.Count -gt 0)
        GpuAvg = $(if ($gs.Count) { ($gs | Measure-Object -Average).Average } else { 0 })
        GpuMax = $(if ($gs.Count) { @($gs | Where-Object { $_ -ge 95 }).Count / $gs.Count } else { 0 })
        CpuAvg = (@($samples | ForEach-Object { $_.Cpu }) | Measure-Object -Average).Average
    }
}

# Returns proposed changes: list of @{ Key; From; To }
function Get-TuneProposal($sg, $stats, $stutter) {
    $ch = New-Object System.Collections.Generic.List[object]
    function Step($keys, $delta) {
        foreach ($k in $keys) {
            $from = [int]$sg[$k]; $to = [math]::Max(0, [math]::Min(3, $from + $delta))
            if ($to -ne $from) { $ch.Add(@{ Key = $k; From = "$from"; To = "$to" }) }
        }
    }
    $sky = [double]::Parse($sg['sg.TrueSkyQuality'], $CI)
    if ($stats.Verdict -eq 'gpu') {
        Step $GpuKeys -1
        if ($sky -gt 0.15) { $ch.Add(@{ Key = 'sg.TrueSkyQuality'; From = $sg['sg.TrueSkyQuality']; To = ($sky - 0.1).ToString('0.000000', $CI) }) }
        if ($ch.Count -eq 0) {
            $r = [int]$sg['sg.ResolutionQuality']
            if ($r -gt 70) { $ch.Add(@{ Key = 'sg.ResolutionQuality'; From = "$r"; To = "$([math]::Max(70, $r - 10))" }) }
        }
    } elseif ($stats.Verdict -eq 'spare') {
        $r = [int]$sg['sg.ResolutionQuality']
        if ($r -lt 100) { $ch.Add(@{ Key = 'sg.ResolutionQuality'; From = "$r"; To = "$([math]::Min(100, $r + 10))" }) }
        Step $GpuKeys 1
        if ($sky -lt 0.95) { $ch.Add(@{ Key = 'sg.TrueSkyQuality'; From = $sg['sg.TrueSkyQuality']; To = ([math]::Min(1.0, $sky + 0.1)).ToString('0.000000', $CI) }) }
        if ($stats.CpuAvg -lt 60) { Step $CpuKeys 1 }
        elseif ($stutter) { Step $CpuKeys -1 }
    } elseif ($stats.Verdict -eq 'cpu' -and $stutter) {
        Step $CpuKeys -1
    }
    return ,$ch
}

function Show-AutoTune($state, $stats) {
    Say ''
    Say '  ==============================================' Cyan
    Say '   AUTO-TUNE - results from your session' Cyan
    Say '  ==============================================' Cyan
    if ($stats.Count -lt 100) {
        Say '  The session was too short to analyse. Play at least 10 minutes' Yellow
        Say '  (loading and menus are not counted).' Yellow
        return
    }
    $min = [math]::Round($stats.Count * 3 / 60)
    Say "  Measured: about $min minutes of gameplay."
    if ($stats.HasGpu) { Say ("  Graphics card load : {0:0} % average, at the limit {1:0} % of the time" -f $stats.GpuAvg, ($stats.GpuMax * 100)) }
    Say ("  Busiest CPU core   : {0:0} % average" -f $stats.CpuAvg)
    Say ''

    $e = $state.Applied | Where-Object { $_.File -eq 'GameUserSettings.ini' -and $_.Section -eq 'ScalabilityGroups' } | Select-Object -First 1
    if (-not $e) { return }
    $sg = $e.Values

    if (-not $stats.HasGpu) { $stats.Verdict = $(if ($stats.CpuAvg -ge 85) { 'cpu' } else { 'ok' }) }
    elseif ($stats.GpuMax -ge 0.5) { $stats.Verdict = 'gpu' }
    elseif ($stats.GpuAvg -le 75) { $stats.Verdict = 'spare' }
    elseif ($stats.CpuAvg -ge 85) { $stats.Verdict = 'cpu' }
    else { $stats.Verdict = 'ok' }

    switch ($stats.Verdict) {
        'gpu'   { Say '  Result: the GRAPHICS CARD is at its limit. Lowering a few GPU settings' Yellow
                  Say '  will make the game smoother and the card cooler.' Yellow }
        'spare' { Say '  Result: the graphics card has SPARE POWER. The picture can be nicer' Green
                  Say '  without making the game slower.' Green }
        'cpu'   { Say '  Result: the PROCESSOR is the limit, the graphics card is fine.' Yellow }
        default { Say '  Result: CPU and GPU are WELL BALANCED. No changes needed.' Green; return }
    }

    $stutter = $false
    if ($stats.CpuAvg -ge 85 -and $stats.Verdict -ne 'gpu') {
        $x = Read-Host '  Did the game stutter or feel slow? (y = yes, Enter = no)'
        $stutter = $x -match '^(y|yes)$'
    }
    $ch = Get-TuneProposal $sg $stats $stutter
    if ($ch.Count -eq 0) {
        if ($stats.Verdict -eq 'spare') { Say '  Everything is already at maximum. Enjoy!' Green }
        else { Say '  No changes needed.' Green }
        return
    }
    $ql = @('Low', 'Medium', 'High', 'Epic')
    Say ''
    Say '  Suggested changes:'
    foreach ($c in $ch) {
        $name = $KeyNames[$c.Key]
        if ($c.Key -eq 'sg.TrueSkyQuality' -or $c.Key -eq 'sg.ResolutionQuality') {
            $f = [math]::Round([double]::Parse($c.From, $CI) * $(if ($c.Key -eq 'sg.TrueSkyQuality') { 100 } else { 1 }))
            $t = [math]::Round([double]::Parse($c.To, $CI) * $(if ($c.Key -eq 'sg.TrueSkyQuality') { 100 } else { 1 }))
            Say "   $name : $f % -> $t %"
        } else {
            Say "   $name : $($ql[[int]$c.From]) -> $($ql[[int]$c.To])"
        }
    }
    $x = Read-Host '  Apply these changes for the next game? (y = yes, Enter = no)'
    if ($x -match '^(y|yes)$') {
        foreach ($c in $ch) { $sg[$c.Key] = $c.To }
        Set-IniSection (Join-Path $state.Cfg $e.File) $e.Section $sg $e.Remove
        Save-State $state
        Say '  Applied. Play again with "Launch ARK" and it will check the result.' Green
    } else {
        Say '  Nothing changed.' Gray
    }
}

# ---------- Launcher mode (desktop shortcut "Launch ARK") ----------
function Start-Launcher {
    Say ''
    Say '  ==============================================' Cyan
    Say '        ARK Launcher (by ARK Optimizer)' Cyan
    Say '  ==============================================' Cyan
    $state = Read-State
    if (-not $state -or -not (Test-Path -LiteralPath $state.Cfg)) {
        Say '  No saved settings found. Run ARK_Optimizer.bat and choose 1 first.' Red
        return
    }
    if (Get-Process -Name 'ShooterGame' -ErrorAction SilentlyContinue) {
        Say '  ARK is already running.' Yellow
        return
    }

    # 1) Self-repair: check that ARK did not reset the optimized settings
    $diffs = Get-SettingDiffs $state
    if ($diffs.Count -eq 0) {
        Say '  Settings check: all optimized settings are in place.' Green
    } else {
        Say ''
        Say "  Settings check: $($diffs.Count) setting(s) differ from the optimized ones." Yellow
        Say '  This happens after a game update or crash, or if you changed them in the game menu.' Yellow
        Say '   1 = Restore the optimized settings  (recommended after an update or crash)'
        Say '   2 = Keep the current ones            (if you changed them on purpose)'
        $x = Read-Host '  Choice (Enter = 1)'
        if ($x -eq '2') { Use-CurrentValues $diffs; Say '  Keeping your settings.' Gray }
        else { Say '  Optimized settings restored.' Green }
        Write-Applied $state
        Save-State $state
    }

    # 2) Memory check (+ optional standby cleaner), then start the game
    Say ''
    Show-MemoryCheck
    if ($state.CleanMem) { Clear-StandbyMemory }
    Say '  Starting ARK through Steam...'
    Start-Process 'steam://rungameid/346110'
    $proc = $null
    for ($i = 0; $i -lt 180 -and -not $proc; $i++) {
        Start-Sleep -Seconds 2
        $proc = Get-Process -Name 'ShooterGame' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $proc) { Say '  ARK did not start within 6 minutes. Closing the launcher.' Yellow; return }
    Start-Sleep -Seconds 5
    foreach ($x in @(Get-Process -Name 'ShooterGame' -ErrorAction SilentlyContinue)) { try { $x.PriorityClass = 'High' } catch {} }
    Say '  ARK is running with high CPU priority.' Green

    # 3) Auto-tune measurement
    Say ''
    Say '  AUTO-TUNE is measuring CPU and GPU load while you play.' Cyan
    Say '  Keep this window open (you can minimize it). Results appear when you quit ARK.' Cyan
    $stats = Measure-Session $proc.Id
    Show-AutoTune $state $stats
}

# ---------- Main ----------
function Main {
    Say ''
    Say '  ==============================================' Cyan
    Say '        ARK: Survival Evolved - Optimizer' Cyan
    Say '  ==============================================' Cyan
    Say ''

    if (Get-Process -Name 'ShooterGame' -ErrorAction SilentlyContinue) {
        Say '  ARK is running. Close the game and run this program again.' Red
        return
    }

    $ark = Find-Ark
    if (-not $ark) {
        Say '  Could not find the game automatically.' Yellow
        $ark = (Read-Host '  Paste the path to your ARK folder (e.g. C:\Program Files (x86)\Steam\steamapps\common\ARK)').Trim('"', ' ')
        if (-not (Test-Path -LiteralPath (Join-Path $ark 'ShooterGame'))) { Say '  That folder does not contain ARK.' Red; return }
    }
    Say "  Game found: $ark" Green

    $cfg = Join-Path $ark 'ShooterGame\Saved\Config\WindowsNoEditor'
    if (-not (Test-Path -LiteralPath $cfg)) {
        Say ''
        Say '  The game has never been started, so the settings folder does not exist yet.' Yellow
        Say '  Start ARK, wait for the main menu, close it and run this program again.' Yellow
        return
    }

    Say ''
    Say '  What do you want to do?'
    Say '   1 = Optimize the game'
    Say '   2 = Restore original settings (from backup, also removes DXVK)'
    Say '   3 = Remove DXVK only'
    $choice = Read-Host '  Choice'

    if ($choice -eq '3') {
        if (Remove-Dxvk $ark) { Say '  DXVK removed. The game uses normal DirectX 11 again.' Green }
        else { Say '  DXVK was not installed by this program, nothing to remove.' Yellow }
        return
    }

    if ($choice -eq '2') {
        $bak = Get-ChildItem -LiteralPath $cfg -Directory -Filter 'Backup_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -Last 1
        if (-not $bak) { Say '  No backup found.' Red; return }
        foreach ($f in 'Engine.ini', 'GameUserSettings.ini', 'Game.ini') {
            $src = Join-Path $bak.FullName $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $cfg $f) -Force }
            elseif (Test-Path -LiteralPath (Join-Path $bak.FullName "$f.didnotexist")) {
                Remove-Item -LiteralPath (Join-Path $cfg $f) -Force -ErrorAction SilentlyContinue
            }
        }
        try { powercfg /setactive SCHEME_BALANCED | Out-Null } catch {}
        try {
            Set-ItemProperty -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 1 -Type DWord -ErrorAction Stop
        } catch {}
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Launch ARK.bat'
        Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
        $copy = Join-Path $OptHome 'ARK_Optimizer.bat'
        if ([IO.Path]::GetFullPath([string]$env:SELF) -ne [IO.Path]::GetFullPath($copy)) {
            Remove-Item -LiteralPath $OptHome -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Remove-Dxvk $ark) { Say '  DXVK removed.' Green }
        if (Restore-Movies $ark) { Say '  Intro videos restored.' Green }
        try { if (Remove-GameFlags $cfg) { Say '  Windows graphics options for ARK restored.' Green } } catch {}
        if (Test-Path -LiteralPath (Join-Path $cfg $DefMark)) {
            Say '  Removing the Windows Defender exclusion (Windows will ask for permission)...'
            if (Remove-DefenderExclusion $cfg) { Say '  Defender exclusion removed.' Green }
            else { Say '  Could not remove the Defender exclusion. Run option 2 again and click Yes.' Yellow }
        }
        Say "  Restored from $($bak.Name) (your original settings)." Green
        Say '  Power plan and Windows game recording were restored too.' Green
        return
    }
    if ($choice -ne '1') { Say '  Invalid choice.' Red; return }

    # --- Hardware and profile ---
    Say ''
    Say '  Detecting hardware...'
    $hw = Get-Hardware
    Say "   CPU : $($hw.CpuName) ($($hw.Cores) cores)"
    Say "   GPU : $($hw.GpuName) ($($hw.Vram) GB)"
    Say "   RAM : $($hw.Ram) GB"

    $cpuT = Get-CpuTier $hw
    $gpuT = Get-GpuTier $hw
    Say "   -> CPU class: $($CpuNames[$cpuT]),  GPU class: $($GpuNames[$gpuT])" Cyan
    Say ''
    Say '  Profiles:'
    Say '   A = AUTO-BALANCED  <-- recommended' Green
    Say '       GPU settings (textures, anti-aliasing, effects, sky, sharpness) match' Green
    Say '       your GPU, CPU settings (view distance, grass, shadows) match your CPU.' Green
    Say '       Best picture without one part waiting for the other.' Green
    for ($i = 0; $i -lt 5; $i++) { Say "   $i = $($TierNames[$i])" }
    $in = Read-Host '  Press Enter for AUTO-BALANCED, or type 0-4'
    $level = $gpuT
    if ($in -match '^[0-4]$') {
        $level = [int]$in
        $p = $Profiles[[int]$in]
        Say "  Using profile: $($TierNames[[int]$in])" Cyan
    } else {
        $p = New-AutoProfile $cpuT $gpuT $hw
        Say '  Using profile: AUTO-BALANCED' Cyan
    }
    $ql = @('Low', 'Medium', 'High', 'Epic')
    $s = $p.sg
    Say ("   Textures {0}, Anti-aliasing {1}, General shading {2}, Effects {3}," -f $ql[[int]$s['sg.TextureQuality']], $ql[[int]$s['sg.AntiAliasingQuality']], $ql[[int]$s['sg.PostProcessQuality']], $ql[[int]$s['sg.EffectsQuality']])
    Say ("   View distance {0}, Shadows {1}, Grass {2}, Sky {3} %, Resolution {4} %," -f $ql[[int]$s['sg.ViewDistanceQuality']], $ql[[int]$s['sg.ShadowQuality']], $ql[[int]$s['sg.GroundClutterQuality']], [int]([double]::Parse($s['sg.TrueSkyQuality'], [Globalization.CultureInfo]::InvariantCulture) * 100), $s['sg.ResolutionQuality'])
    Say ("   Ambient occlusion + water reflections: {0}" -f $(if ($p.Pretty) { 'ON' } else { 'off (saves performance)' }))

    # --- FPS limit (recommended value = what the CPU can hold steadily) ---
    $fpsRec = switch ($cpuT) { 0 { '3' } 3 { '2' } default { '1' } }
    $r = @{ '1' = ''; '2' = ''; '3' = '' }; $r[$fpsRec] = '  <-- recommended for your CPU'
    Say ''
    Say '  FPS limit - the biggest power saver. The GPU stops working once it has'
    Say '  enough frames, so it uses less electricity, runs cooler and quieter.'
    Say '  A limit your CPU can hold steadily also gives even, stutter-free frames.'
    Say "   1 = 45 FPS  (smooth, low power use)$($r['1'])"
    Say "   2 = 60 FPS  (smoother, more power)$($r['2'])"
    Say "   3 = 30 FPS  (lowest power use)$($r['3'])"
    Say '   4 = no limit (maximum power use)'
    $f = Read-Host "  Choice (Enter = $fpsRec)"
    if ($f -notmatch '^[1-4]$') { $f = $fpsRec }
    $fps = switch ($f) { '2' { 60 } '3' { 30 } '4' { 0 } default { 45 } }
    if ($fps -gt 0) { Say "  FPS limit: $fps" Cyan } else { Say '  No FPS limit' Cyan }

    # --- Upscale mode (like Magpie / FSR 1: lower render resolution + sharpening) ---
    $upRec = switch ($level) { 0 { '3' } 1 { '2' } default { '1' } }
    $r = @{ '1' = ''; '2' = ''; '3' = '' }; $r[$upRec] = '  <-- recommended for your PC'
    Say ''
    Say '  Upscale mode - works like Magpie / FSR: ARK draws a smaller picture (much less'
    Say '  work for the graphics card) and your GPU driver sharpens it, so it stays crisp.'
    Say "   1 = Off      (full resolution)$($r['1'])"
    Say "   2 = Quality  (85 % resolution + sharpening, hard to tell apart)$($r['2'])"
    Say "   3 = Speed    (75 % resolution + sharpening, most FPS)$($r['3'])"
    $u = Read-Host "  Choice (Enter = $upRec)"
    if ($u -notmatch '^[1-3]$') { $u = $upRec }
    $upscale = switch ($u) { '2' { 85 } '3' { 75 } default { 0 } }
    if ($upscale -gt 0) {
        $curRes = [int]$p.sg['sg.ResolutionQuality']
        $p.sg['sg.ResolutionQuality'] = "$([math]::Min($curRes, $upscale))"
        Say "  Upscale mode ON: render resolution $($p.sg['sg.ResolutionQuality']) %. Sharpening steps are shown at the end." Cyan
    } else { Say '  Upscale mode off.' Cyan }

    # --- Power plan ---
    Say ''
    Say '  Windows power plan:'
    Say '   1 = Balanced          (recommended - games run about the same, less electricity)'
    Say '   2 = High performance  (CPU always at full speed, more electricity)'
    $pw = Read-Host '  Choice (Enter = 1)'
    $highPower = $pw -eq '2'

    # --- Clean-up (optional) ---
    Say ''
    Say '  Clean-up - removes things ARK does not need to play:'
    Say '   - crash dumps and old log files (can take up GBs)'
    Say '   - intro videos at game start (moved to a backup folder, so the game'
    Say '     starts faster; restored with option 2)'
    Say '  Your saves, settings and game data are NOT touched.'
    $x = Read-Host '  Run clean-up? (y = yes, Enter = no)'
    $wantClean = $x -match '^(y|yes)$'

    # --- Wild creature count ---
    Say ''
    Say '  Number of wild creatures (single player / your own non-dedicated game).'
    Say '  This is the biggest CPU load. Fewer creatures = smoother game and'
    Say '  faster loading, visuals stay the same. Ignored on online servers.'
    $dRec = switch ($cpuT) { 0 { '2' } 3 { '3' } default { '1' } }
    $r = @{ '1' = ''; '2' = ''; '3' = '' }; $r[$dRec] = '  <-- recommended for your CPU'
    Say "   1 = 70 %   (still plenty of creatures)$($r['1'])"
    Say "   2 = 50 %   (smoothest)$($r['2'])"
    Say "   3 = 100 %  (original)$($r['3'])"
    $d = Read-Host "  Choice (Enter = $dRec)"
    if ($d -notmatch '^[1-3]$') { $d = $dRec }
    $dino = switch ($d) { '2' { '0.500000' } '3' { '1.000000' } default { '0.700000' } }
    Say "  Creature count: $([int]([double]::Parse($dino, [Globalization.CultureInfo]::InvariantCulture) * 100)) %" Cyan

    # --- DXVK (optional) ---
    Say ''
    $dxInstalled = Get-DxvkVersion $ark
    if ($dxInstalled) {
        Say "  DXVK $dxInstalled is already installed - kept, nothing to download." Green
        Say '  (To remove it, run this program and choose 3.)' Gray
        $wantDxvk = $false
    } else {
    Say '  DXVK (experimental) - translates DirectX 11 to Vulkan. In CPU-heavy games'
    Say '  like ARK it can raise FPS and reduce stutter, but results differ per PC.'
    Say '  Downloads the official DXVK release from GitHub once (needs internet), then'
    Say '  keeps a local copy, so it is never downloaded again.'
    Say '  SINGLE PLAYER ONLY - online servers with BattlEye may not allow it.'
    Say '  You can remove it any time with option 3.'
    if ($level -eq 0) {
        Say '  Not recommended for very weak / integrated graphics - the DirectX 10 mode' Yellow
        Say '  this program recommends for your PC helps more and does not work with DXVK.' Yellow
    }
    $x = Read-Host '  Install DXVK? (y = yes, Enter = no)'
    $wantDxvk = $x -match '^(y|yes)$'
    }
    if ($wantDxvk -or (Test-Path -LiteralPath (Join-Path $ark "ShooterGame\Binaries\Win64\$DxvkMark"))) {
        Say '  With DXVK the FPS limit is done by DXVK - frames come at even intervals' Gray
        Say '  (like the RTSS tool), so the game feels smoother at the same FPS.' Gray
    }

    # --- Standby memory cleaner (optional) ---
    $memRec = $hw.Ram -le 12
    Say ''
    Say '  Memory cleaner - before each start, "Launch ARK" can empty the Windows standby'
    Say '  memory (like the ISLC tool). More free RAM = less stutter while ARK loads the map.'
    Say '  Windows asks for permission every time.'
    if ($memRec) { Say "  Recommended for your PC ($($hw.Ram) GB RAM)." Green }
    else { Say "  With $($hw.Ram) GB RAM the benefit is small." Gray }
    $x = Read-Host '  Enable the memory cleaner? (y = yes, Enter = no)'
    $wantMem = $x -match '^(y|yes)$'

    # --- Faster loading (optional) ---
    $wantDef = $false
    if (-not (Test-Path -LiteralPath (Join-Path $cfg $DefMark))) {
        Say ''
        Say '  Faster map loading - Windows Defender scans every game file while ARK'
        Say '  reads tens of GB during loading. Excluding the ARK folder from scanning'
        Say '  can make loading noticeably faster. Only the ARK folder is excluded,'
        Say '  the rest of your PC stays protected. Windows will ask for permission.'
        Say '  (Only works if Windows Defender is your antivirus. Undo with option 2.)'
        $x = Read-Host '  Exclude the ARK folder from Defender scanning? (y = yes, Enter = no)'
        $wantDef = $x -match '^(y|yes)$'
    }

    # --- Backup (the first backup is your original settings and is kept) ---
    $bakDir = Join-Path $cfg ('Backup_' + (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    New-Item -ItemType Directory -Path $bakDir | Out-Null
    foreach ($f in 'Engine.ini', 'GameUserSettings.ini', 'Game.ini') {
        $src = Join-Path $cfg $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $bakDir }
        else { New-Item -ItemType File -Path (Join-Path $bakDir "$f.didnotexist") | Out-Null }
    }
    Say "  Backup saved to: $bakDir" Green

    # --- Engine.ini ---
    $engine = [ordered]@{
        'r.VolumetricFog'='0'
        'r.DefaultFeature.MotionBlur'='0'; 'r.MotionBlurQuality'='0'; 'r.DepthOfFieldQuality'='0'
        'r.SceneColorFringeQuality'='0'; 'r.LensFlareQuality'='0'; 'r.TranslucencyVolumeBlur'='0'
        'r.LightShafts'=$p.LightShafts; 'r.MaxAnisotropy'=$p.Aniso
        'r.OneFrameThreadLag'='1'; 'r.FinishCurrentFrame'='0'; 'r.VSync'='0'
        'r.Streaming.PoolSize'="$(Get-PoolSize $hw)"
    }
    $engRemove = @('r.ShadowQuality', 'r.BloomQuality', 'r.TonemapperQuality', 'r.ViewDistanceScale')
    if ($p.Pretty) {
        # keep ambient occlusion and reflections at game defaults (they make ARK look good)
        $engRemove += 'r.SSR.Quality', 'r.AmbientOcclusionLevels'
    } else {
        $engine['r.SSR.Quality'] = '0'; $engine['r.AmbientOcclusionLevels'] = '0'
    }
    if ($fps -gt 0) { $engine['t.MaxFPS'] = "$fps" } else { $engRemove += 't.MaxFPS' }
    $applied = New-Object System.Collections.Generic.List[object]
    Add-Applied $applied $cfg 'Engine.ini' 'SystemSettings' $engine $engRemove
    Say '  Engine.ini updated.' Green

    # --- GameUserSettings.ini ---
    Add-Applied $applied $cfg 'GameUserSettings.ini' 'ScalabilityGroups' $p.sg
    $opts = [ordered]@{
        'bUseVSync'='False'; 'bUseDFAO'='False'; 'bUseSSAO'=$(if ($p.Pretty) { 'True' } else { 'False' }); 'bDistanceFieldShadowing'='False'
        'bUseLowQualityLevelStreaming'='True'
        # true fullscreen - smoother than windowed
        'FullscreenMode'='0'; 'LastConfirmedFullscreenMode'='0'; 'PreferredFullscreenMode'='0'
    }
    $optRemove = @()
    if ($fps -gt 0) { $opts['FrameRateLimit'] = "$fps.000000" } else { $optRemove = @('FrameRateLimit') }
    Add-Applied $applied $cfg 'GameUserSettings.ini' '/Script/ShooterGame.ShooterGameUserSettings' $opts $optRemove
    Add-Applied $applied $cfg 'GameUserSettings.ini' 'ServerSettings' ([ordered]@{ 'DinoCountMultiplier' = $dino })
    Say '  GameUserSettings.ini updated.' Green

    # --- Game.ini: corpses disappear sooner = fewer objects on the map ---
    Add-Applied $applied $cfg 'Game.ini' '/script/shootergame.shootergamemode' ([ordered]@{ 'GlobalCorpseDecompositionTimeMultiplier' = '0.500000' })
    Say '  Game.ini updated.' Green

    # --- Save state + install a copy for the launcher ---
    try {
        Save-State @{ ArkPath = $ark; Cfg = $cfg; CleanMem = $wantMem; Applied = $applied }
        $copy = Join-Path $OptHome 'ARK_Optimizer.bat'
        if ($env:SELF -and ([IO.Path]::GetFullPath($env:SELF) -ne [IO.Path]::GetFullPath($copy))) {
            Copy-Item -LiteralPath $env:SELF -Destination $copy -Force
        }
        $launcherOk = Test-Path -LiteralPath $copy
    } catch { $launcherOk = $false; Say "  Could not save settings for the launcher: $($_.Exception.Message)" Yellow }

    # --- Windows ---
    try {
        $k = 'HKCU:\Software\Microsoft\GameBar'
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
        Set-ItemProperty -Path $k -Name 'AutoGameModeEnabled' -Value 1 -Type DWord
        Say '  Windows Game Mode enabled.' Green
    } catch { Say '  Could not enable Game Mode (not a problem).' Yellow }

    try {
        $k1 = 'HKCU:\System\GameConfigStore'
        $k2 = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
        foreach ($k in $k1, $k2) { if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null } }
        Set-ItemProperty -Path $k1 -Name 'GameDVR_Enabled' -Value 0 -Type DWord
        Set-ItemProperty -Path $k2 -Name 'AppCaptureEnabled' -Value 0 -Type DWord
        Say '  Background game recording (Xbox Game Bar) disabled.' Green
    } catch { Say '  Could not disable background recording (not a problem).' Yellow }

    try {
        if (Set-GameFlags $ark $cfg) {
            Say '  ARK set to use the high-performance graphics card (important on laptops).' Green
            Say '  Fullscreen optimizations disabled for ARK (real fullscreen, less stutter).' Green
        }
    } catch { Say '  Could not set the Windows graphics options for ARK (not a problem).' Yellow }

    # Desktop launcher: settings check + high CPU priority + auto-tune
    try {
        if (-not $launcherOk) { throw 'launcher files missing' }
        $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Launch ARK.bat'
        $launcher = @(
            '@echo off',
            'title ARK Launcher',
            'call "%LOCALAPPDATA%\ARK_Optimizer\ARK_Optimizer.bat" launch'
        )
        Set-Content -LiteralPath $lnk -Value $launcher -Encoding ASCII
        Say '  Desktop shortcut "Launch ARK" created (settings check, high priority, auto-tune).' Green
    } catch { Say '  Could not create the desktop shortcut (not a problem).' Yellow }

    if ($highPower) {
        powercfg /setactive SCHEME_MIN 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Say '  Power plan set to High performance.' Green }
        else { Say '  High performance power plan not available (not a problem).' Yellow }
    } else {
        powercfg /setactive SCHEME_BALANCED 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Say '  Power plan set to Balanced (lower power use).' Green }
    }

    # --- Clean-up ---
    if ($wantClean) {
        $freed = 0
        $saved = Join-Path $ark 'ShooterGame\Saved'
        foreach ($sub in 'Crashes', 'Logs') {
            $dir = Join-Path $saved $sub
            if (Test-Path -LiteralPath $dir) {
                Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                    $len = $_.Length
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $freed += $len } catch {}
                }
            }
        }
        $movies = Join-Path $ark 'ShooterGame\Content\Movies'
        $moved = 0
        if (Test-Path -LiteralPath $movies) {
            $mBak = Join-Path $movies $MoviesBak
            Get-ChildItem -LiteralPath $movies -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(mp4|bk2|wmv|avi|mov)$' } | ForEach-Object {
                    if (-not (Test-Path -LiteralPath $mBak)) { New-Item -ItemType Directory -Path $mBak | Out-Null }
                    try { Move-Item -LiteralPath $_.FullName -Destination $mBak -Force -ErrorAction Stop; $moved++ } catch {}
                }
        }
        Say "  Clean-up: $([math]::Round($freed / 1MB)) MB of crash dumps and logs removed." Green
        if ($moved -gt 0) { Say "  Clean-up: $moved intro video(s) disabled (backup in Movies\$MoviesBak)." Green }
    }

    # --- DXVK ---
    $dxvkVer = $null
    if ($wantDxvk) {
        try {
            $dxvkVer = Install-Dxvk $ark $hw
            if ($dxvkVer) { Say "  DXVK $dxvkVer installed." Green }
        } catch {
            Say "  DXVK could not be installed: $($_.Exception.Message)" Yellow
            Say '  Everything else was applied. Check your internet connection and try again.' Yellow
            Remove-Dxvk $ark | Out-Null
        }
    }
    # DXVK frame limiter (also when DXVK was installed by an earlier run)
    if (Test-Path -LiteralPath (Join-Path $ark "ShooterGame\Binaries\Win64\$DxvkMark")) {
        if ($fps -gt 0) {
            Set-DxvkLimiter $ark $fps | Out-Null
            # DXVK paces the frames; the in-game limit stays slightly higher as a backup
            $backup = $fps + 3
            foreach ($e in $applied) {
                if ($e.Values.Contains('t.MaxFPS')) { $e.Values['t.MaxFPS'] = "$backup" }
                if ($e.Values.Contains('FrameRateLimit')) { $e.Values['FrameRateLimit'] = "$backup.000000" }
            }
            Write-Applied @{ Cfg = $cfg; Applied = $applied }
            Save-State @{ ArkPath = $ark; Cfg = $cfg; CleanMem = $wantMem; Applied = $applied }
            Say "  Evenly paced DXVK frame limit: $fps FPS (smooth frame pacing like RTSS)." Green
        } else {
            Set-DxvkLimiter $ark 0 | Out-Null
        }
    }

    # --- Defender exclusion ---
    if ($wantDef) {
        Say '  Adding the Defender exclusion (click Yes in the Windows prompt)...'
        if (Add-DefenderExclusion $ark $cfg) { Say '  ARK folder excluded from Defender scanning.' Green }
        else { Say '  Defender exclusion not added (prompt declined or another antivirus is used).' Yellow }
    }

    # --- Disk ---
    $media = 'Unknown'
    try {
        $disk = Get-Partition -DriveLetter $ark.Substring(0, 1) -ErrorAction Stop | Get-Disk
        $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq "$($disk.Number)" } | Select-Object -First 1
        if ($pd) { $media = [string]$pd.MediaType }
    } catch {}

    # --- Summary ---
    Say ''
    Say '  ==============================================' Cyan
    Say '   DONE' Cyan
    Say '  ==============================================' Cyan
    Say ''
    $launch = '-USEALLAVAILABLECORES -novsync'
    if ($hw.Ram -lt 12) { $launch += ' -lowmemory' }
    # weak graphics: simpler sky renderer; very weak: DirectX 10 mode as well
    if ($level -le 1) { $launch += ' -nomansky' }
    $hasDxvk = $dxvkVer -or (Test-Path -LiteralPath (Join-Path $ark "ShooterGame\Binaries\Win64\$DxvkMark"))
    if ($level -eq 0 -and -not $hasDxvk) { $launch += ' -sm4 -d3d10' }
    Say '  In Steam (ARK > Properties > Launch Options) paste:'
    Say "     $launch" Yellow
    if ($level -le 1) {
        Say '   -nomansky   = simpler clouds and sky, big FPS gain on weak graphics' Gray
    }
    if ($launch -match '-d3d10') {
        Say '   -sm4 -d3d10 = DirectX 10 mode: slightly simpler lighting, but the' Gray
        Say '                 biggest FPS gain on very weak / integrated graphics' Gray
    }
    Say ''
    if ($dxvkVer) {
        Say '  DXVK notes:' Cyan
        Say '   - Play single player and start the game WITHOUT BattlEye' Cyan
        Say '     (pick that option in the Steam launch window, or add -NoBattlEye' Cyan
        Say '     to the launch options; remove it again before playing online).' Cyan
        Say '   - The first minutes may stutter while shaders are built. That is normal.' Cyan
        Say '   - If the game will not start or runs worse, run this program and choose 3.' Cyan
        Say ''
    }
    if ($media -eq 'HDD') {
        Say '  WARNING: The game is on a hard drive (HDD). Loading will be slow and the' Red
        Say '  game may stutter while moving around the map. Moving it to an SSD helps most' Red
        Say '  (Steam > ARK > Properties > Installed Files > Move install folder).' Red
        $need = Get-ArkSizeGB $ark
        $ssds = @(Get-SsdVolumes)
        if ($ssds.Count -gt 0) {
            $fit = @($ssds | Where-Object { $need -gt 0 -and $_.FreeGB -ge ($need + 15) } | Sort-Object { $_.FreeGB } -Descending)
            if ($fit.Count -gt 0) {
                Say "  GOOD NEWS: your SSD $($fit[0].Letter): has $($fit[0].FreeGB) GB free and ARK needs about $need GB." Green
                Say "  Move ARK there in Steam (Move install folder > choose drive $($fit[0].Letter):)." Green
                Say '  Loading will be several times faster.' Green
            } else {
                $best = $ssds | Sort-Object { $_.FreeGB } -Descending | Select-Object -First 1
                $sz = if ($need -gt 0) { "about $need GB" } else { 'a lot of space' }
                Say "  You have an SSD ($($best.Letter):, $($best.FreeGB) GB free), but ARK needs $sz." Yellow
                Say '  Free up space there, or remove unused maps (Steam > ARK > Properties > DLC)' Yellow
                Say '  to make ARK smaller, then move it to the SSD.' Yellow
            }
        }
        $sm = Get-Service -Name 'SysMain' -ErrorAction SilentlyContinue
        if ($sm -and ([string]$sm.StartType -eq 'Disabled' -or [string]$sm.Status -ne 'Running')) {
            Say ''
            Say '  The Windows service SysMain is off. On a hard drive it preloads often used' Yellow
            Say '  files into RAM and makes loading faster (it is on by default in Windows).' Yellow
            $x = Read-Host '  Turn SysMain back on? (y = yes, Enter = no)'
            if ($x -match '^(y|yes)$') {
                if (Invoke-Elevated "try { Set-Service -Name SysMain -StartupType Automatic -ErrorAction Stop; Start-Service -Name SysMain -ErrorAction Stop; exit 0 } catch { exit 1 }") {
                    Say '  SysMain is on.' Green
                } else { Say '  SysMain was not turned on.' Yellow }
            }
        }
        Say ''
        Say '  Until then, defragmenting the drive makes HDD loading faster.' Yellow
        Say '  It optimizes the WHOLE drive in its own window and can take SEVERAL HOURS' Yellow
        Say '  (best run overnight). You can keep using the PC, but do not play ARK meanwhile.' Yellow
        Say '  It is safe to stop at any time (Ctrl+C or close its window) - nothing is lost.' Yellow
        $x = Read-Host '  Defragment the drive now? (y = yes, Enter = no)'
        if ($x -match '^(y|yes)$') {
            try {
                Start-Process defrag.exe -Verb RunAs -ArgumentList "$($ark.Substring(0, 2)) /O /U /V"
                Say '  Defragmentation started in a new window.' Green
            } catch { Say '  Defragmentation not started.' Yellow }
        }
    } elseif ($media -eq 'SSD') {
        Say '  The game is on an SSD, loading will be fast.' Green
    }
    Say ''
    $pf = Get-PageFileProblem $hw.Ram
    if ($pf) {
        Say "  WARNING: the Windows page file is $pf. ARK uses a lot of memory and can" Red
        Say '  stutter or crash without it. Fix: Start > "Adjust the appearance and performance' Red
        Say '  of Windows" > Advanced > Virtual memory > Change > tick "Automatically manage".' Red
        Say ''
    }
    $mods = Get-ModCount $ark
    if ($mods -gt 0) {
        Say "  You have $mods mod(s) downloaded. Every mod makes map loading longer." Yellow
        Say '  Unsubscribe the mods you do not use (Steam Workshop > Subscribed items).' Yellow
        Say ''
    }
    if ($dino -ne '1.000000') {
        Say '  The new creature count applies to new games right away. For an existing save:' Yellow
        Say '  in game press Tab and type:  cheat DestroyWildDinos' Yellow
        Say '  Wild creatures disappear and respawn with the new count.' Yellow
        Say '  (Your tamed creatures are not affected.)' Yellow
        Say ''
    }
    Say '  More disk space: maps you do not play can be removed in Steam >' Gray
    Say '  ARK > Properties > DLC (uncheck them). You can download them again any time.' Gray
    Say ''
    Say '  Sharper picture for free: turn on image sharpening in your GPU software' Gray
    Say '  (AMD Adrenalin > Gaming > Graphics > Radeon Image Sharpening, or' Gray
    Say '  NVIDIA Control Panel > Manage 3D settings > Image Scaling / Sharpening).' Gray
    Say ''
    Say '  Even lower power use: in your GPU software (AMD Adrenalin > Performance >' Gray
    Say '  Tuning, or NVIDIA app) choose the preset "Undervolt GPU" / power saving.' Gray
    Say '  Same performance with less electricity on most cards.' Gray
    Say ''
    if ($upscale -gt 0) {
        Say '  UPSCALE MODE - turn on sharpening in your graphics driver (one time, 1 minute):' Cyan
        $gn = [string]$hw.GpuName
        if ($gn -match 'NVIDIA|GeForce|Quadro|RTX|GTX') {
            Say '   NVIDIA: right-click the desktop > NVIDIA Control Panel > Manage 3D settings >' Cyan
            Say '   Image Scaling: On, Sharpen about 50 %. (Or NVIDIA app > Graphics > Image Scaling.)' Cyan
        } elseif ($gn -match 'AMD|Radeon') {
            Say '   AMD: right-click the desktop > AMD Software > Gaming > Graphics >' Cyan
            Say '   Radeon Image Sharpening: On, Sharpness about 70 %.' Cyan
            Say '   (On some older Radeon cards it works in DirectX 11 only with DXVK installed.)' Cyan
        } elseif ($gn -match 'Intel') {
            Say '   Intel: open Intel Graphics Command Center / Intel Graphics Software and look for' Cyan
            Say '   "Sharpness" or "Image Sharpening" (not available on all Intel graphics).' Cyan
        } else {
            Say '   Open your graphics driver software and turn on "Image Sharpening".' Cyan
        }
        Say '   Without sharpening the picture is a bit softer, but still runs faster.' Gray
        Say ''
    }
    Say '  Even smoother: free external tools (frame limiter RTSS, upscalers for weak' Gray
    Say '  graphics) are explained in README.md, section "External tools".' Gray
    Say ''
    Say '  From now on start ARK with "Launch ARK" on your desktop. It will:' Cyan
    Say '   - check that ARK did not reset your settings (after updates or crashes)' Cyan
    Say '   - start the game with high CPU priority' Cyan
    Say '   - AUTO-TUNE: measure CPU and GPU load while you play and, after you quit,' Cyan
    Say '     suggest changes if the picture can be nicer or the game smoother' Cyan
    Say '  Close your browser and other programs before playing. Have fun!'
    Say '  To undo everything, run this program again and choose 2.'
}

try {
    if ($env:ARKOPT_MODE -eq 'launch') { Start-Launcher } else { Main }
} catch { Say "  Error: $($_.Exception.Message)" Red }
