# =============================================================
#  Clean-360.ps1  --  360 残留体检 / 彻底清理
#
#  只读体检（默认，不改任何东西）：
#     powershell -ExecutionPolicy Bypass -File .\Clean-360.ps1
#
#  真正清理（必须"以管理员身份运行"PowerShell）：
#     powershell -ExecutionPolicy Bypass -File .\Clean-360.ps1 -Mode Clean
#
#  设计原则：先体检、后动手；删之前先备份注册表、先建还原点。
#            匹配不到 360 的项一律不碰。
# =============================================================
[CmdletBinding()]
param(
    [ValidateSet('Audit','Clean')]
    [string]$Mode = 'Audit',
    [string]$BackupDir = '',
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 备份目录：挑一个真正可写的位置（D 盘可能是光驱）
if ([string]::IsNullOrWhiteSpace($BackupDir)) {
    $cands = @()
    if (Test-Path 'D:\') { $cands += 'D:\360clean_backup' }
    $cands += (Join-Path $env:SystemDrive '360clean_backup')
    $cands += (Join-Path $env:TEMP '360clean_backup')
    foreach ($c in $cands) {
        try {
            New-Item -ItemType Directory -Force -Path $c -ErrorAction Stop | Out-Null
            $probe = Join-Path $c '.write_test'
            Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
            $BackupDir = $c
            break
        } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($BackupDir)) { $BackupDir = Join-Path $env:TEMP '360clean_backup' }
}

# ---------- 匹配规则 ----------
# 名字用前缀匹配，宁可少删也不要误伤系统组件
$NamePatterns = @(
    '^360',
    '^QH',
    '^Qihoo',
    '^奇虎',
    '^ZhuDongFangYu',
    '^BAPIDRV',
    '^LiveUpdate360'
)

# 路径/命令行里出现这些才算 360 的东西
$PathPattern = '(?i)(\\360[^\\]*\\|\\360$|\\Qihoo[^\\]*\\|\\Qihoo$|\\奇虎[^\\]*\\' +
               '|360Safe|360sd|360Chrome|360se|360tray|360doctor|360leakfixer|' +
               'ZhuDongFangYu|QHActiveDefense|QHNetFilter|QHDrv|BAPIDRV)'

# 显示名/产品名里算 360 的写法（纯粹的数字 360 会误伤资源号，必须带产品词）
$BrandRe = '(?i)^\s*360|360(安全|杀毒|浏览|极速|压缩|驱动|软件|云盘|手机|企业|游戏|影视|壁纸|桌面|文件)|奇虎|Qihoo'

$RegKeys = @(
    'HKLM:\SOFTWARE\360Safe',
    'HKLM:\SOFTWARE\WOW6432Node\360Safe',
    'HKLM:\SOFTWARE\360',
    'HKLM:\SOFTWARE\WOW6432Node\360',
    'HKLM:\SOFTWARE\Qihoo',
    'HKLM:\SOFTWARE\WOW6432Node\Qihoo',
    'HKCU:\Software\360Safe',
    'HKCU:\Software\360',
    'HKCU:\Software\Qihoo'
)

# 动态扫描这些根键，凡是子键名以 360/Qihoo/奇虎 开头的一律算
$RegScanRoots = @(
    'HKLM:\SOFTWARE',
    'HKLM:\SOFTWARE\WOW6432Node',
    'HKCU:\Software'
)

$KnownDirs = @(
    "$env:ProgramFiles\360",
    "${env:ProgramFiles(x86)}\360",
    "$env:ProgramData\360safe",
    'C:\ProgramData\360safe',
    "$env:APPDATA\360safe",
    "$env:LOCALAPPDATA\360Safe",
    "$env:LOCALAPPDATA\360Chrome",
    "$env:LOCALAPPDATA\360Browser",
    "$env:LOCALAPPDATA\360sd",
    "$env:LOCALAPPDATA\Qihoo",
    "$env:APPDATA\360se6",
    "$env:APPDATA\360Chrome",
    "$env:LOCALAPPDATA\360Downloads",
    "$env:USERPROFILE\360Downloads",
    'C:\360Downloads',
    'C:\360Safe',
    'C:\360se6'
)

$DirScanRoots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    $env:ProgramData,
    $env:LOCALAPPDATA,
    $env:APPDATA,
    "$env:USERPROFILE\AppData\LocalLow",
    $env:USERPROFILE,
    "$env:SystemDrive\"
)

$UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
)

$RunKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)

$AppPathsRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths'
)

# 右键菜单 / 属性页 / 拖放处理程序
$ShellExtRoots = @(
    'HKLM:\SOFTWARE\Classes\*\shellex\ContextMenuHandlers',
    'HKLM:\SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers',
    'HKLM:\SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers',
    'HKLM:\SOFTWARE\Classes\Directory\shellex\DragDropHandlers',
    'HKLM:\SOFTWARE\Classes\Folder\shellex\ContextMenuHandlers',
    'HKLM:\SOFTWARE\Classes\AllFilesystemObjects\shellex\ContextMenuHandlers',
    'HKLM:\SOFTWARE\Classes\Drive\shellex\ContextMenuHandlers',
    'HKLM:\SOFTWARE\Classes\*\shellex\PropertySheetHandlers',
    'HKLM:\SOFTWARE\Classes\Directory\shellex\PropertySheetHandlers'
)

$BhoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Browser Helper Objects'
$OverlayRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
$HookRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellExecuteHooks',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\ShellExecuteHooks'
)
$ClsidRoots = @(
    'HKLM\SOFTWARE\Classes\CLSID',
    'HKLM\SOFTWARE\Classes\WOW6432Node\CLSID'
)
$ApprovedRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved'

$DefenderPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender'
$DefenderExcl = @(
    'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Paths',
    'HKLM:\SOFTWARE\Microsoft\Windows Defender\Exclusions\Processes',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Paths',
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Processes'
)
$SecurityCenterRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Security Center\Provider\Av',
    'HKLM:\SOFTWARE\Microsoft\Security Center\Provider\Fw'
)

# ---------- 辅助函数 ----------
function Test-Hit([string]$Name) {
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    foreach ($p in $NamePatterns) { if ($Name -match $p) { return $true } }
    return $false
}

function Test-360Path([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    return ($Path -match $PathPattern)
}

# 文件名看不出来时按签名判断（360 会把组件改名成 readertray / DsArk 之类）
function Test-360Exe([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if (Test-360Path $Path) { return $true }
    try {
        $co = [string](Get-Item -LiteralPath $Path -Force -ErrorAction Stop).VersionInfo.CompanyName
        return ($co -match '(?i)360|qihu|qihoo|奇虎|三六零')
    } catch { return $false }
}

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function ConvertTo-RegPath([string]$Path) {
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM'
    $p = $p -replace '^HKEY_CURRENT_USER', 'HKCU'
    $p = $p -replace '^HKEY_CLASSES_ROOT', 'HKCR'
    # reg.exe 只认 HKLM\...，不认 HKLM:\...
    $p = $p -replace '^(HKLM|HKCU|HKCR|HKU|HKCC):\\', '$1\'
    return $p
}

function Get-DefaultValue([string]$Path) {
    # 同样走 .NET，注册表提供程序在深层路径上每次调用都要 1 秒以上
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $p = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
    $hive = $null
    if ($p -match '^HKEY_LOCAL_MACHINE\\?(.*)$' -or $p -match '^HKLM:\\?(.*)$') {
        $hive = [Microsoft.Win32.Registry]::LocalMachine
    } elseif ($p -match '^HKEY_CURRENT_USER\\?(.*)$' -or $p -match '^HKCU:\\?(.*)$') {
        $hive = [Microsoft.Win32.Registry]::CurrentUser
    } else {
        return $null
    }
    $sub = $matches[1]
    if ([string]::IsNullOrEmpty($sub)) { return $null }
    try {
        $k = $hive.OpenSubKey($sub)
        if (-not $k) { return $null }
        $v = $k.GetValue('')
        $k.Close()
        return $v
    } catch { return $null }
}

function Get-ClsidServer([string]$Clsid) {
    if ([string]::IsNullOrEmpty($Clsid)) { return '' }
    # 用 .NET 直接读注册表：Test-Path/Get-ItemProperty 在 CLSID 这种路径上每条要 1~2 秒
    $root = [Microsoft.Win32.Registry]::LocalMachine
    foreach ($sub in @(
        "SOFTWARE\Classes\CLSID\$Clsid\InprocServer32",
        "SOFTWARE\Classes\WOW6432Node\CLSID\$Clsid\InprocServer32",
        "SOFTWARE\Classes\CLSID\$Clsid\LocalServer32",
        "SOFTWARE\Classes\WOW6432Node\CLSID\$Clsid\LocalServer32"
    )) {
        $k = $root.OpenSubKey($sub)
        if ($k) {
            $v = $k.GetValue('')
            $k.Close()
            if ($v) { return ([string]$v).Trim('"') }
        }
    }
    $cu = [Microsoft.Win32.Registry]::CurrentUser
    $k2 = $cu.OpenSubKey("Software\Classes\CLSID\$Clsid\InprocServer32")
    if ($k2) {
        $v = $k2.GetValue('')
        $k2.Close()
        if ($v) { return ([string]$v).Trim('"') }
    }
    return ''
}

# 从服务的 ImagePath 反推 360 的安装根目录
function ConvertTo-DirFromImage([string]$ImagePath) {
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    $p = $ImagePath.Trim() -replace '^\\\?\?\\', ''
    if ($p -match '^"([^"]+)"') { $p = $matches[1] } else { $p = ($p -split '\s+')[0] }
    $p = $p -replace '(?i)^\\SystemRoot\\', "$env:SystemRoot\"
    $p = $p -replace '(?i)^System32\\', "$env:SystemRoot\System32\"
    if ($p -notmatch '^[A-Za-z]:\\') { return $null }
    $dir = Split-Path -Parent $p
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    return $dir
}

# 往上找最外层的 360 目录，比如 ...\360\360Safe\safemon -> ...\360
function Get-360Ancestor([string]$Dir) {
    try { $cur = Get-Item -LiteralPath $Dir -ErrorAction Stop } catch { return $null }
    $best = $null
    while ($cur -and $cur.Parent) {
        if (Test-Hit $cur.Name) { $best = $cur.FullName }
        $cur = $cur.Parent
    }
    return $best
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-BootState {
    (Get-CimInstance Win32_ComputerSystem).BootupState
}

# ---------- 数字签名识别 ----------
# 360 会把组件改成不带 360 字样的名字（如 SysCleanProService），只能靠文件属性和签名认
$script:SigCache = @{}
function Test-360Binary([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($script:SigCache.ContainsKey($Path)) { return $script:SigCache[$Path] }
    $r = $false
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $Path -ErrorAction Stop
            $co = [string]$item.VersionInfo.CompanyName
            if ($co -match '(?i)360|qihu|qihoo|奇虎') {
                $r = $true
            } elseif ([string]::IsNullOrWhiteSpace($co)) {
                # 没有版本信息才做完整签名校验（很慢）
                $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
                if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match '(?i)qihoo|qihu|奇虎') { $r = $true }
            }
        }
    } catch { }
    $script:SigCache[$Path] = $r
    return $r
}

# 从服务的 ImagePath 取出 exe 完整路径
function ConvertTo-ExePath([string]$ImagePath) {
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    $p = $ImagePath.Trim() -replace '^\\\?\?\\', ''
    if ($p -match '^"([^"]+)"') { $p = $matches[1] } else { $p = ($p -split '\s+')[0] }
    $p = $p -replace '(?i)^\\SystemRoot\\', "$env:SystemRoot\"
    $p = $p -replace '(?i)^System32\\', "$env:SystemRoot\System32\"
    $p = $p -replace '(?i)^system32\\', "$env:SystemRoot\System32\"
    if ($p -match '^[A-Za-z]:\\') { return $p }
    return $null
}

# =============================================================
#  发现
# =============================================================
function Get-360Services {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        $img = [string]$p.ImagePath
        $exe = ConvertTo-ExePath $img
        $hit = (Test-Hit $k.PSChildName) -or (Test-360Path $img) -or
               ([string]$p.DisplayName -match $BrandRe) -or (Test-360Binary $exe)
        if (-not $hit) { continue }
        $type = switch ($p.Type) {
            1       { '内核驱动' }
            2       { '文件系统驱动' }
            16      { '服务(独立进程)' }
            32      { '服务(共享进程)' }
            default { "Type=$($p.Type)" }
        }
        $imgClean = $img -replace '^\\\?\?\\', ''
        $out.Add([pscustomobject]@{
            名称   = $k.PSChildName
            类型   = $type
            路径   = $imgClean
            显示名 = [string]$p.DisplayName
            Exe    = $exe
        })
    }
    return $out
}

function Get-360DriverFiles {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($f in Get-ChildItem "$env:SystemRoot\System32\drivers" -Filter '*.sys' -ErrorAction SilentlyContinue) {
        if (Test-Hit $f.BaseName) { $out.Add($f.FullName) }
    }
    return $out
}

function Get-360RegKeys {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $RegKeys) { if (Test-Path -LiteralPath $k) { [void]$set.Add($k) } }

    foreach ($root in $RegScanRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $drive = if ($root -like 'HKCU:*') { 'HKCU:' } else { 'HKLM:' }
        $sub = $root.Substring($root.IndexOf(':') + 1)
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            if ($k.PSChildName -match '^(360|Qihoo|奇虎|LiveUpdate360)') {
                [void]$set.Add("$drive$sub\$($k.PSChildName)")
            }
        }
    }

    foreach ($root in $AppPathsRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            if (Test-Hit $k.PSChildName) { [void]$set.Add((ConvertTo-RegPath $k.PSPath)) }
        }
    }
    return @($set)
}

function Get-360UninstallKeys {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($root in $UninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $disp = [string]$props.DisplayName
            $loc = [string]$props.InstallLocation
            if (($k.PSChildName -match '^(360|Qihoo|奇虎|LiveUpdate360)') -or
                ($disp -match $BrandRe) -or
                (Test-360Path $loc)) {
                $out.Add([pscustomobject]@{
                    名称 = if ($disp) { $disp } else { $k.PSChildName }
                    键   = $k.PSPath
                    目录 = $loc
                })
            }
        }
    }
    return $out
}

function Get-360Dirs {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $KnownDirs) {
        if ($p -and (Test-Path -LiteralPath $p)) {
            try { [void]$set.Add((Get-Item -LiteralPath $p -Force -ErrorAction Stop).FullName) } catch { }
        }
    }
    # 在各常见根目录下按名字找
    foreach ($r in $DirScanRoots) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue) {
            if ($d.Name -match '^(360|Qihoo|奇虎|LiveUpdate360)') { [void]$set.Add($d.FullName) }
        }
    }
    # 从服务 ImagePath 反推真实安装位置
    foreach ($s in Get-360Services) {
        $dir = ConvertTo-DirFromImage $s.路径
        if (-not $dir) { continue }
        $anc = Get-360Ancestor $dir
        # 只有目录名本身带 360 才收；否则会导出 C:\Windows\SysWOW64 这种系统目录
        if ($anc) { [void]$set.Add($anc) }
    }
    # 从卸载项的 InstallLocation 反推
    foreach ($u in Get-360UninstallKeys) {
        $loc = ([string]$u.目录).Trim().Trim('"')
        if ($loc -and (Test-Path -LiteralPath $loc)) {
            $anc = Get-360Ancestor $loc
            if ($anc) { [void]$set.Add($anc) }
        }
    }
    # 从 360 进程 / 快捷方式目标反推安装目录：
    # 按用户安装的程序（如 360AI办公 装在 %APPDATA%\Reader）名字不带 360，只能靠签名认
    $exes = New-Object System.Collections.Generic.List[string]
    foreach ($p in Get-360Processes) {
        $path = ''
        try { $path = [string]$p.Path } catch { }
        if ($path) { $exes.Add($path) }
    }
    foreach ($l in Get-360Shortcuts) {
        if ($l.目标) { $exes.Add([string]$l.目标) }
    }
    foreach ($exe in $exes) {
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        if (-not (Test-360Exe $exe)) { continue }
        $dir = [System.IO.Path]::GetDirectoryName($exe)
        if (-not $dir) { continue }
        if ($dir -like "$env:SystemRoot\*") { continue }
        $di = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if ($di) { [void]$set.Add($di.FullName) }
    }
    # 用户目录下按签名找：360 会把安装目录改名成 Reader / SysCleanPro 这类普通名字
    foreach ($r in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        foreach ($d in Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue) {
            if ($d.Name -match '^(Microsoft|Packages|Temp|Programs|Adobe|Google|Mozilla|\.)') { continue }
            foreach ($f in Get-ChildItem -LiteralPath $d.FullName -Filter *.exe -File -ErrorAction SilentlyContinue) {
                if (Test-360Exe $f.FullName) { [void]$set.Add($d.FullName); break }
            }
        }
    }
    # 去掉被其它候选包含的子目录
    $final = New-Object System.Collections.Generic.List[string]
    foreach ($p in ($set | Sort-Object Length)) {
        $dup = $false
        foreach ($q in $final) {
            if ($p.StartsWith($q.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $dup = $true; break }
        }
        if (-not $dup) { $final.Add($p) }
    }
    # 自己的备份目录不能被当成 360 残留删掉；系统目录和盘根一律不删
    $bdir = $BackupDir.TrimEnd('\')
    $guarded = @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
                 $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA) |
               Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    return @($final | Where-Object {
        $p = $_.TrimEnd('\')
        $bad = $false
        if ($p.Equals($bdir, [StringComparison]::OrdinalIgnoreCase)) { $bad = $true }
        if ($p.StartsWith($bdir + '\', [StringComparison]::OrdinalIgnoreCase)) { $bad = $true }
        foreach ($g in $guarded) {
            if ($p.Equals($g, [StringComparison]::OrdinalIgnoreCase)) { $bad = $true }
            if ($g.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { $bad = $true }
        }
        -not $bad
    })
}

function Get-360Tasks {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $hit = (Test-Hit $t.TaskName) -or (Test-360Path ([string]$t.TaskPath))
        if (-not $hit) {
            # 任务名可能完全不像 360（如 \Readertray），要看它实际执行哪个程序
            foreach ($a in $t.Actions) {
                $exe = [string]$a.Execute
                if (-not $exe) { continue }
                $exe = $exe.Trim().Trim('"')
                if ($exe -notmatch '^[A-Za-z]:\\') {
                    $c = Join-Path $env:SystemRoot $exe
                    if (Test-Path -LiteralPath $c) { $exe = $c }
                }
                if ((Test-360Path $exe) -or (Test-360Binary $exe)) { $hit = $true; break }
            }
        }
        if ($hit) { $out.Add([pscustomobject]@{ TaskName = $t.TaskName; TaskPath = $t.TaskPath }) }
    }
    return $out
}

function Get-360RunValues {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($rk in $RunKeys) {
        $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ((Test-Hit $p.Name) -or (Test-360Path ([string]$p.Value))) {
                $out.Add([pscustomobject]@{ 键 = $rk; 名称 = $p.Name; 命令 = [string]$p.Value })
            }
        }
    }
    return $out
}

function Get-360Startup {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($s in Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue) {
        if ((Test-Hit $s.Name) -or (Test-360Path ([string]$s.Command))) {
            $out.Add([pscustomobject]@{ 名称 = $s.Name; 位置 = $s.Location; 命令 = $s.Command })
        }
    }
    return $out
}

function Get-360Shortcuts {
    $out = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $ws = $null
    try { $ws = New-Object -ComObject WScript.Shell } catch { }

    # 开始菜单要递归：360 常把自己放在「安全卫士」「Reader」这类子文件夹里，
    # 快捷方式名也可能不带 360（如 安全卫士.lnk），只能看目标程序
    $dirs = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop"
    )
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue) {
            if ($f.PSIsContainer) { continue }
            if ($f.Extension -notin '.lnk','.url') { continue }
            $target = ''
            if ($ws -and $f.Extension -eq '.lnk') {
                try { $target = [string]$ws.CreateShortcut($f.FullName).TargetPath } catch { }
            }
            if ((Test-Hit $f.BaseName) -or (Test-360Exe $target)) {
                if ($seen.Add($f.FullName)) {
                    $out.Add([pscustomobject]@{ 名称 = $f.Name; 位置 = $f.DirectoryName; 目标 = $target; 文件 = $f.FullName })
                }
            }
        }
    }
    if ($ws) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ws) } catch { } }
    return $out
}

function Get-360FirewallRules {
    $out = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    # 按规则名 / 显示名匹配（Group 里常有 @FirewallAPI.dll,-36001 这类资源号，不能用 360 直接匹配）
    foreach ($r in Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        if (($r.DisplayName -match $BrandRe) -or
            ($r.Name -match '(?i)^(360|Qihoo|ZhuDongFangYu)') -or
            ($r.Name -match '(?i)360safe|360sd|360se|360chrome|360tray')) {
            if ($seen.Add($r.Name)) {
                $out.Add([pscustomobject]@{ 名称 = $r.Name; 显示名 = $r.DisplayName; 方向 = $r.Direction })
            }
        }
    }

    # 按程序路径匹配，抓名字不像但程序指向 360 的规则
    foreach ($f in Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue) {
        $prog = [string]$f.Program
        if (-not (Test-360Path $prog)) { continue }
        foreach ($r in Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $f -ErrorAction SilentlyContinue) {
            if ($seen.Add($r.Name)) {
                $out.Add([pscustomobject]@{ 名称 = $r.Name; 显示名 = $r.DisplayName; 方向 = $r.Direction })
            }
        }
    }
    return $out
}

# 扫出所有指向 360 目录的 COM 组件注册（explorer 就是靠这些加载 360 的 DLL）
$script:ClsidCache = $null
# 从已知的 shell 扩展注册点解析出 360 的 CLSID（不做全盘扫描，太慢）
function Get-360Clsids {
    if ($null -ne $script:ClsidCache) { return $script:ClsidCache }
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $ShellExtRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $g = [string](Get-DefaultValue $k.PSPath)
            if ($g -match '^\{[0-9A-Fa-f\-]+\}$' -and (Test-360Path (Get-ClsidServer $g))) { [void]$set.Add($g) }
        }
    }
    if (Test-Path -LiteralPath $OverlayRoot) {
        foreach ($k in Get-ChildItem -LiteralPath $OverlayRoot -ErrorAction SilentlyContinue) {
            $g = [string](Get-DefaultValue $k.PSPath)
            if ($g -match '^\{[0-9A-Fa-f\-]+\}$' -and (Test-360Path (Get-ClsidServer $g))) { [void]$set.Add($g) }
        }
    }
    foreach ($hr in $HookRoots) {
        if (-not (Test-Path -LiteralPath $hr)) { continue }
        foreach ($p in (Get-ItemProperty -LiteralPath $hr -ErrorAction SilentlyContinue).PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if ($p.Name -match '^\{[0-9A-Fa-f\-]+\}$' -and (Test-360Path (Get-ClsidServer $p.Name))) { [void]$set.Add($p.Name) }
        }
    }
    if (Test-Path -LiteralPath $BhoRoot) {
        foreach ($k in Get-ChildItem -LiteralPath $BhoRoot -ErrorAction SilentlyContinue) {
            if ($k.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$' -and (Test-360Path (Get-ClsidServer $k.PSChildName))) { [void]$set.Add($k.PSChildName) }
        }
    }
    $script:ClsidCache = @($set)
    return $script:ClsidCache
}

function Get-360ShellExt {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($root in $ShellExtRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $clsid = [string](Get-DefaultValue $k.PSPath)
            $srv = Get-ClsidServer $clsid
            if ((Test-Hit $k.PSChildName) -or (Test-360Path $srv) -or (Test-Hit $clsid)) {
                $out.Add([pscustomobject]@{
                    类型 = '右键菜单/属性页'
                    名称 = $k.PSChildName
                    键   = (ConvertTo-RegPath $k.PSPath)
                    服务 = $srv
                })
            }
        }
    }
    if (Test-Path -LiteralPath $BhoRoot) {
        foreach ($k in Get-ChildItem -LiteralPath $BhoRoot -ErrorAction SilentlyContinue) {
            $srv = Get-ClsidServer $k.PSChildName
            if (Test-360Path $srv) {
                $out.Add([pscustomobject]@{
                    类型 = '浏览器插件(BHO)'
                    名称 = $k.PSChildName
                    键   = (ConvertTo-RegPath $k.PSPath)
                    服务 = $srv
                })
            }
        }
    }
    if (Test-Path -LiteralPath $ApprovedRoot) {
        $props = Get-ItemProperty -LiteralPath $ApprovedRoot -ErrorAction SilentlyContinue
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            if (([string]$p.Value) -match $BrandRe) {
                $srv = Get-ClsidServer $p.Name
                $out.Add([pscustomobject]@{
                    类型 = '已批准的扩展项'
                    名称 = $p.Name
                    键   = $ApprovedRoot
                    服务 = if ($srv) { $srv } else { [string]$p.Value }
                })
            }
        }
    }
    # 资源管理器图标覆盖（360 的 U 盘卫士就挂在这里，explorer 会因此常驻加载它的 DLL）
    $clsids = @{}
    foreach ($g in (Get-360Clsids)) { $clsids[$g] = $true }

    if (Test-Path -LiteralPath $OverlayRoot) {
        foreach ($k in Get-ChildItem -LiteralPath $OverlayRoot -ErrorAction SilentlyContinue) {
            $v = [string](Get-DefaultValue $k.PSPath)
            $srv = Get-ClsidServer $v
            if ((Test-Hit $k.PSChildName) -or $clsids.ContainsKey($v) -or (Test-360Path $srv)) {
                $out.Add([pscustomobject]@{ 类型 = '图标覆盖'; 名称 = $k.PSChildName; 键 = (ConvertTo-RegPath $k.PSPath); 服务 = $srv })
            }
        }
    }

    foreach ($hr in $HookRoots) {
        if (-not (Test-Path -LiteralPath $hr)) { continue }
        $props = Get-ItemProperty -LiteralPath $hr -ErrorAction SilentlyContinue
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $srv = Get-ClsidServer $p.Name
            if ($clsids.ContainsKey($p.Name) -or (Test-360Path $srv) -or (Test-Hit $p.Name)) {
                $out.Add([pscustomobject]@{ 类型 = '挂钩值'; 名称 = $p.Name; 键 = (ConvertTo-RegPath $hr); 服务 = $srv })
            }
        }
    }

    foreach ($g in $clsids.Keys) {
        $out.Add([pscustomobject]@{ 类型 = 'COM 组件'; 名称 = $g; 键 = "HKLM:\SOFTWARE\Classes\CLSID\$g"; 服务 = (Get-ClsidServer $g) })
    }

    return $out
}

function Get-360DefenderLeftover {
    $out = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $DefenderPolicy) {
        $p = Get-ItemProperty -LiteralPath $DefenderPolicy -ErrorAction SilentlyContinue
        foreach ($n in @('DisableAntiSpyware','DisableAntiVirus')) {
            if ($null -ne $p.$n) {
                $out.Add([pscustomobject]@{ 类型 = 'Defender 策略'; 键 = $DefenderPolicy; 名称 = $n; 值 = $p.$n })
            }
        }
        $rt = "$DefenderPolicy\Real-Time Protection"
        if (Test-Path -LiteralPath $rt) {
            $r = Get-ItemProperty -LiteralPath $rt -ErrorAction SilentlyContinue
            foreach ($prop in $r.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                if ($prop.Name -match '^Disable' -and $prop.Value -ne 0) {
                    $out.Add([pscustomobject]@{ 类型 = 'Defender 实时保护策略'; 键 = $rt; 名称 = $prop.Name; 值 = $prop.Value })
                }
            }
        }
    }
    foreach ($ex in $DefenderExcl) {
        if (-not (Test-Path -LiteralPath $ex)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $ex -ErrorAction SilentlyContinue) {
            if (Test-360Path $k.PSChildName) {
                $out.Add([pscustomobject]@{ 类型 = 'Defender 排除项'; 键 = (ConvertTo-RegPath $k.PSPath); 名称 = $k.PSChildName; 值 = '' })
            }
        }
    }
    foreach ($root in $SecurityCenterRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $disp = [string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).DISPLAYNAME
            if ($disp -match $BrandRe) {
                $out.Add([pscustomobject]@{ 类型 = '安全中心注册'; 键 = (ConvertTo-RegPath $k.PSPath); 名称 = $disp; 值 = '' })
            }
        }
    }
    return $out
}

function Get-360Processes {
    # 一次 WMI 查询拿全进程路径；逐进程查询在慢机器上要几十秒
    $exeMap = @{}
    try {
        foreach ($w in Get-CimInstance Win32_Process -ErrorAction Stop) {
            if ($w.ExecutablePath) { $exeMap[[int]$w.ProcessId] = [string]$w.ExecutablePath }
        }
    } catch { }

    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        $hit = Test-Hit $p.ProcessName
        if (-not $hit) {
            $path = ''
            try { $path = [string]$p.Path } catch { }
            if (-not $path -and $exeMap.ContainsKey([int]$p.Id)) { $path = $exeMap[[int]$p.Id] }
            if ($path) { $hit = Test-360Exe $path }
        }
        if ($hit) { $p }
    }
}

# System32 / SysWOW64 / drivers 下属于 360 的文件（含改名的组件）
function Get-360SystemFiles {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($d in @("$env:SystemRoot\System32", "$env:SystemRoot\SysWOW64", "$env:SystemRoot\System32\drivers")) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($f in Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue) {
            if ($f.Name -match '^(360|QH|BAPIDRV|ZhuDongFangYu)') { $out.Add($f.FullName); continue }
            $co = ''
            try { $co = $f.VersionInfo.CompanyName } catch { }
            if ($co -match '(?i)360|qihu|qihoo|奇虎') { $out.Add($f.FullName) }
        }
    }
    return $out
}

# =============================================================
#  体检
# =============================================================
function Invoke-Audit {
    $total = 0

    Write-Head '运行中的 360 进程'
    $proc = @(Get-360Processes)
    if ($proc.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else {
        $proc | Format-Table ProcessName, Id -AutoSize | Out-String | Write-Host
        $total += $proc.Count
    }

    Write-Head '服务与驱动 (HKLM\SYSTEM\CurrentControlSet\Services)'
    $svc = @(Get-360Services)
    if ($svc.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $svc | Format-Table 名称, 显示名, 类型, 路径 -AutoSize | Out-String | Write-Host; $total += $svc.Count }

    Write-Head '驱动文件 (System32\drivers\*.sys)'
    $drv = @(Get-360DriverFiles)
    if ($drv.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $drv | ForEach-Object { Write-Host "  $_" }; $total += $drv.Count }

    Write-Head '系统目录里的 360 文件 (System32 / SysWOW64)'
    $sysf = @(Get-360SystemFiles)
    if ($sysf.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $sysf | ForEach-Object { Write-Host "  $_" }; $total += $sysf.Count }

    Write-Head '注册表主键'
    $reg = @(Get-360RegKeys)
    if ($reg.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $reg | ForEach-Object { Write-Host "  $_" }; $total += $reg.Count }

    Write-Head '卸载项 (程序和功能)'
    $uninst = @(Get-360UninstallKeys)
    if ($uninst.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $uninst | ForEach-Object { Write-Host "  $($_.名称)"; if ($_.目录) { Write-Host "    目录: $($_.目录)" -ForegroundColor DarkGray } }; $total += $uninst.Count }

    Write-Head '安装目录 / 数据目录'
    $dir = @(Get-360Dirs)
    if ($dir.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else {
        $dir | ForEach-Object {
            $size = (Get-ChildItem -LiteralPath $_ -Recurse -Force -ErrorAction SilentlyContinue |
                     Where-Object { -not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                     Measure-Object Length -Sum).Sum
            Write-Host ("  {0}  ({1:N1} MB)" -f $_, ($size / 1MB))
        }
        $total += $dir.Count
    }

    Write-Head '计划任务'
    if ((Get-Service Schedule -ErrorAction SilentlyContinue).Status -ne 'Running') {
        Write-Host '  (任务计划服务未运行：安全模式下查不到，请回正常模式再查一次)' -ForegroundColor Yellow
    } else {
        $task = @(Get-360Tasks)
        if ($task.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
        else { $task | Format-Table TaskName, TaskPath -AutoSize | Out-String | Write-Host; $total += $task.Count }
    }

    Write-Head '开机自启动项'
    $run = @(Get-360RunValues)
    if ($run.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $run | Format-Table 名称, 命令 -AutoSize | Out-String | Write-Host; $total += $run.Count }

    Write-Head '启动文件夹 / 桌面快捷方式'
    $lnk = @(Get-360Shortcuts)
    if ($lnk.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $lnk | ForEach-Object { Write-Host "  $($_.位置)\$($_.名称)"; if ($_.目标) { Write-Host "    -> $($_.目标)" -ForegroundColor DarkGray } }; $total += $lnk.Count }

    Write-Head '防火墙规则'
    $fw = @(Get-360FirewallRules)
    if ($fw.Count -eq 0) { Write-Host '  (无，或需要管理员权限才能读取)' -ForegroundColor DarkGray }
    else { $fw | Format-Table 显示名, 方向 -AutoSize | Out-String | Write-Host; $total += $fw.Count }

    Write-Head '右键菜单 / 浏览器插件 / 图标覆盖 / COM 组件'
    $ext = @(Get-360ShellExt)
    if ($ext.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $ext | Format-Table 类型, 名称, 服务 -AutoSize | Out-String | Write-Host; $total += $ext.Count }

    Write-Head 'Defender / 安全中心残留'
    $def = @(Get-360DefenderLeftover)
    if ($def.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    else { $def | Format-Table 类型, 名称, 值 -AutoSize | Out-String | Write-Host; $total += $def.Count }

    Write-Head 'Windows Defender 当前状态'
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Write-Host ("  实时保护: {0}   防病毒服务: {1}" -f `
            $(if ($mp.RealTimeProtectionEnabled) { '已开启' } else { '已关闭' }), `
            $(if ($mp.AMServiceEnabled) { '正常' } else { '已停用' }))
    } catch {
        Write-Host '  读取失败（Defender 可能已被第三方杀软接管）' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host "启动方式: $(Get-BootState)" -ForegroundColor DarkGray
    if ($total -eq 0) {
        Write-Host '结论: 未发现 360 残留，无需清理。' -ForegroundColor Green
    } else {
        Write-Host "结论: 共发现 $total 处 360 相关项。可加 -Mode Clean 清理。" -ForegroundColor Yellow
    }
}

# =============================================================
#  删除辅助
# =============================================================
function Remove-PathForce([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $true } catch { }
    # 360 会给目录加限制性 ACL，先夺取所有权再删
    & takeown.exe /f "$Path" /r /d y 2>$null | Out-Null
    & icacls.exe "$Path" /grant "*S-1-5-32-544:(OI)(CI)F" /t /c /q 2>$null | Out-Null
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $true } catch { }
    # 隐藏/只读属性、以及 Remove-Item 处理不了的路径，走系统自带 rd
    & attrib.exe -r -s -h "$Path" /s /d 2>$null | Out-Null
    & cmd.exe /c rd /s /q "`"$Path`"" 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    # 仍失败：多半是 360 的 shell 扩展被 explorer 加载着，重启 explorer 再删
    $holders = @(Get-LoadingProcess $Path)
    if ($holders.Count -gt 0) {
        $hadExplorer = $false
        foreach ($p in $holders) {
            if ($p.ProcessName -eq 'explorer') { $hadExplorer = $true }
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        }
        Start-Sleep -Seconds 2
        & cmd.exe /c rd /s /q "`"$Path`"" 2>$null | Out-Null
        if ($hadExplorer) {
            try { Start-Process explorer.exe -ErrorAction SilentlyContinue } catch { }
        }
    }
    return (-not (Test-Path -LiteralPath $Path))
}

# 哪些进程加载了这个目录里的 DLL
function Get-LoadingProcess([string]$Dir) {
    $out = New-Object System.Collections.Generic.List[object]
    $prefix = $Dir.TrimEnd('\') + '\'
    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        try {
            foreach ($m in $p.Modules) {
                if ($m.FileName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $out.Add($p); break }
            }
        } catch { }
    }
    return $out
}

function Enable-Privilege([string]$Name) {
    if (-not ('Clean360.Priv' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Clean360 {
  public class Priv {
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr p, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TP newst, int len, IntPtr prev, IntPtr rl);
    // LUID 在原生结构里紧跟在 DWORD 之后；不 Pack=1 的话 x64 会把它对齐到偏移 8，调整特权必然失败(1300)
    [StructLayout(LayoutKind.Sequential, Pack=1)]
    struct TP { public int Count; public int LuidLow; public int LuidHigh; public int Attr; }
    public static bool Enable(string name) {
        IntPtr tok;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out tok)) return false;
        long luid;
        if (!LookupPrivilegeValue(null, name, out luid)) return false;
        TP tp = new TP(); tp.Count = 1; tp.LuidLow = (int)(luid & 0xFFFFFFFF); tp.LuidHigh = (int)(luid >> 32); tp.Attr = 2;
        if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
        return Marshal.GetLastWin32Error() == 0;
    }
  }
}
'@ -ErrorAction SilentlyContinue
    }
    if ('Clean360.Priv' -as [type]) { return [Clean360.Priv]::Enable($Name) }
    return $false
}

# 被驱动占用的文件删不掉时，登记到 PendingFileRenameOperations，重启时由内核删除
function Add-PendingFileDelete([string]$Path) {
    try {
        $sm  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $cur = @((Get-ItemProperty -LiteralPath $sm -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations)
        $entry = '\??\' + $Path
        if ($cur -contains $entry) { return $true }
        $new = @($cur | Where-Object { $_ -ne $null -and $_ -ne '' })
        $new += @($entry, '')
        Set-ItemProperty -LiteralPath $sm -Name PendingFileRenameOperations -Value ([string[]]$new) -Type MultiString -ErrorAction Stop
        return $true
    } catch { return $false }
}

# 安全中心的 Provider 键只有 NT SERVICE\wscsvc 有 Delete 权限，管理员连 WRITE_OWNER 都没有，
# 必须先启用 SeTakeOwnershipPrivilege 接管属主、给自己加完全控制，然后才能删。
function Remove-RegKeyOwned([string]$Key) {
    if (Remove-RegKeyForce $Key) { return $true }
    if (-not (Enable-Privilege 'SeTakeOwnershipPrivilege')) { return $false }
    $sub = (ConvertTo-RegPath $Key) -replace '^HKLM\\', ''
    try {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if (-not $k) { return $false }
        $acl = $k.GetAccessControl()
        $acl.SetOwner([System.Security.Principal.NTAccount]'BUILTIN\Administrators')
        $k.SetAccessControl($acl)
        $k.Close()

        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($sub,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if (-not $k) { return $false }
        $acl = $k.GetAccessControl()
        $acl.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit', 'None', 'Allow')))
        $k.SetAccessControl($acl)
        $k.Close()
    } catch { return $false }
    return (Remove-RegKeyForce $Key)
}

function Remove-RegKeyForce([string]$Key) {
    $hk = (ConvertTo-RegPath $Key)
    & reg.exe delete $hk /f 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    try { Remove-Item -LiteralPath $Key -Recurse -Force -ErrorAction Stop; return $true } catch { return $false }
}

# =============================================================
#  清理
# =============================================================
function Invoke-Clean {
    if (-not (Test-Admin)) {
        Write-Host '错误: 清理必须以管理员身份运行。' -ForegroundColor Red
        Write-Host '右键 PowerShell -> 以管理员身份运行，再执行本脚本。' -ForegroundColor Red
        return
    }

    Invoke-Audit

    $svc     = @(Get-360Services)
    $drv     = @(Get-360DriverFiles)
    $sysf    = @(Get-360SystemFiles)
    $reg     = @(Get-360RegKeys)
    $uninst  = @(Get-360UninstallKeys)
    $dir     = @(Get-360Dirs)
    $tasks   = @(Get-360Tasks)
    $run     = @(Get-360RunValues)
    $lnk     = @(Get-360Shortcuts)
    $fw      = @(Get-360FirewallRules)
    $ext     = @(Get-360ShellExt)
    $def     = @(Get-360DefenderLeftover)
    $proc    = @(Get-360Processes)

    if (($svc.Count + $drv.Count + $sysf.Count + $reg.Count + $uninst.Count + $dir.Count + $tasks.Count +
         $run.Count + $lnk.Count + $fw.Count + $ext.Count + $def.Count) -eq 0) {
        Write-Host ''
        Write-Host '没有任何可清理的对象，退出。' -ForegroundColor Green
        return
    }

    # --- 安全提示 ---
    if ($svc | Where-Object { $_.类型 -like '*驱动*' }) {
        if ((Get-BootState) -notmatch 'Fail-safe|安全模式') {
            Write-Host ''
            Write-Host '注意: 检测到内核驱动，建议在安全模式下清理，否则文件可能被占用。' -ForegroundColor Yellow
            Write-Host '进入方式: 设置->系统->恢复->高级启动->疑难解答->高级选项->启动设置->重启->按4' -ForegroundColor Yellow
        }
    }

    if (-not $Force) {
        Write-Host ''
        $ans = Read-Host '将永久删除以上条目。确认请输入 YES'
        if ($ans.Trim().ToUpper() -ne 'YES') { Write-Host '已取消，未做任何改动。' -ForegroundColor Green; return }
    }

    # --- 还原点 ---
    Write-Head '创建系统还原点'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
        Checkpoint-Computer -Description 'Before-360-Cleanup' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        $after = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
        if ($after -gt $before) {
            Write-Host '  已创建还原点 Before-360-Cleanup' -ForegroundColor Green
        } else {
            Write-Host '  还原点没有新增（系统限制 24 小时内只能建一个），请自行确认已有还原点。' -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  创建失败: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  可继续，但请自行确认已手动建过还原点。' -ForegroundColor Yellow
    }

    # --- 备份注册表 ---
    New-Item -ItemType Directory -Force -Path $BackupDir -ErrorAction SilentlyContinue | Out-Null
    $backupKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $reg) { [void]$backupKeys.Add((ConvertTo-RegPath $k)) }
    foreach ($u in $uninst) { [void]$backupKeys.Add((ConvertTo-RegPath $u.键)) }
    foreach ($r in $RunKeys) { [void]$backupKeys.Add((ConvertTo-RegPath $r)) }
    foreach ($e in $ext) { [void]$backupKeys.Add((ConvertTo-RegPath $e.键)) }
    foreach ($d in $def) { [void]$backupKeys.Add((ConvertTo-RegPath $d.键)) }

    $ok = 0; $fail = 0
    foreach ($k in $backupKeys) {
        $short = $k -replace '[\\/:*?"<>|]', '_'
        $file  = Join-Path $BackupDir "$short.reg"
        & reg.exe export $k $file /y 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok++ } else { $fail++ }
    }
    Write-Host "  注册表已备份到 $BackupDir（成功 $ok 项，失败 $fail 项）" -ForegroundColor Green
    if ($fail -gt 0) {
        Write-Host '  有项目备份失败，建议先手动用 regedit 导出这些键，再继续清理。' -ForegroundColor Yellow
    }

    # --- 1. 结束 360 进程 ---
    Write-Head '结束 360 进程'
    $killed = 0
    foreach ($p in @(Get-360Processes)) {
        try {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Write-Host "  已结束 $($p.ProcessName) (PID $($p.Id))" -ForegroundColor Green
            $killed++
        } catch {
            Write-Host "  结束失败 $($p.ProcessName)（PID $($p.Id)）" -ForegroundColor Yellow
        }
    }
    if ($killed -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }

    # 服务进程（如改名后的 SysCleanProService）名字不带 360，按服务 exe 的名字结束
    foreach ($s in $svc) {
        if (-not $s.Exe) { continue }
        $base = [IO.Path]::GetFileNameWithoutExtension($s.Exe)
        foreach ($p in @(Get-Process -Name $base -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                Write-Host "  已结束 $base (PID $($p.Id))" -ForegroundColor Green
            } catch {
                Write-Host "  结束失败 $base (PID $($p.Id))" -ForegroundColor Yellow
            }
        }
    }

    # --- 2. 服务与驱动 ---
    Write-Head '删除服务与驱动'
    $svcOk = 0
    foreach ($s in $svc) {
        & sc.exe stop $s.名称 2>$null | Out-Null
        & sc.exe delete $s.名称 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  已删除 $($s.名称)" -ForegroundColor Green
            $svcOk++
            continue
        }
        # 1072 = 服务已被标记删除，重启后才会真正移除
        if ($LASTEXITCODE -eq 1072) {
            Write-Host "  已标记删除 $($s.名称)（重启后移除）" -ForegroundColor Green
            $svcOk++
            continue
        }
        # sc 删不掉（孤儿键报 1060、服务 ACL 拒绝报 5），直接删服务注册表键
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.名称)"
        if ((Test-Path -LiteralPath $key) -and (Remove-RegKeyForce $key)) {
            Write-Host "  已删除 $($s.名称)（sc 失败，已直接删注册表键）" -ForegroundColor Green
            $svcOk++
        } else {
            Write-Host "  删除失败 $($s.名称)" -ForegroundColor Yellow
        }
    }
    if ($svc.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }

    # --- 3. 驱动文件本体 ---
    Write-Head '删除驱动文件'
    if ($drv.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($f in $drv) {
        $leaf  = Split-Path $f -Leaf
        if (Remove-PathForce $f) { Write-Host "  已删除 $f" -ForegroundColor Green; continue }
        if (Add-PendingFileDelete $f) {
            Write-Host "  已登记重启时删除 $leaf（正被驱动占用）" -ForegroundColor Yellow
        } else {
            Write-Host "  删除失败 $f（文件被占用，重启或安全模式再试）" -ForegroundColor Yellow
        }
    }

    # --- 3b. System32 / SysWOW64 里的 360 文件（含改名组件）---
    Write-Head '删除系统目录里的 360 文件'
    if ($sysf.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($f in $sysf) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        if (Remove-PathForce $f) { Write-Host "  已删除 $f" -ForegroundColor Green }
        elseif (Add-PendingFileDelete $f) { Write-Host "  已登记重启时删除 $f" -ForegroundColor Yellow }
        else { Write-Host "  删除失败 $f（被占用，重启后再试）" -ForegroundColor Yellow }
    }

    # --- 4. 注册表主键 ---
    Write-Head '删除注册表主键'
    if ($reg.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($k in $reg) {
        if (Remove-RegKeyForce $k) { Write-Host "  已删除 $k" -ForegroundColor Green }
        else { Write-Host "  删除失败 $k" -ForegroundColor Yellow }
    }

    # --- 5. 卸载项 ---
    Write-Head '删除卸载项'
    if ($uninst.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($u in $uninst) {
        if (Remove-RegKeyForce $u.键) { Write-Host "  已删除 $($u.名称)" -ForegroundColor Green }
        else { Write-Host "  删除失败 $($u.名称)" -ForegroundColor Yellow }
    }

    # --- 6. 计划任务 ---
    Write-Head '删除计划任务'
    if ($tasks.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($t in $tasks) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
            Write-Host "  已删除 $($t.TaskPath)$($t.TaskName)" -ForegroundColor Green
        } catch {
            Write-Host "  删除失败 $($t.TaskName)" -ForegroundColor Yellow
        }
    }

    # --- 7. 防火墙规则 ---
    Write-Head '删除防火墙规则'
    if ($fw.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($r in $fw) {
        try {
            Remove-NetFirewallRule -Name $r.名称 -ErrorAction Stop
            Write-Host "  已删除 $($r.显示名)" -ForegroundColor Green
        } catch {
            Write-Host "  删除失败 $($r.显示名)" -ForegroundColor Yellow
        }
    }

    # --- 8. 右键菜单 / BHO / 扩展注册 ---
    Write-Head '删除右键菜单 / 浏览器插件'
    if ($ext.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($e in $ext) {
        if ($e.类型 -eq '已批准的扩展项' -or $e.类型 -eq '挂钩值') {
            $kpath = $e.键 -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\'
            try {
                Remove-ItemProperty -LiteralPath $kpath -Name $e.名称 -ErrorAction Stop
                Write-Host "  已删除 $($e.类型): $($e.名称)" -ForegroundColor Green
            } catch {
                Write-Host "  删除失败 $($e.名称)" -ForegroundColor Yellow
            }
            continue
        }
        if (Remove-RegKeyForce $e.键) { Write-Host "  已删除 $($e.类型): $($e.名称)" -ForegroundColor Green }
        else { Write-Host "  删除失败 $($e.名称)" -ForegroundColor Yellow }
        # 顺手清掉死掉的 CLSID
        if ($e.名称 -match '^\{[0-9A-Fa-f\-]+\}$') {
            foreach ($c in @("HKLM:\SOFTWARE\Classes\CLSID\$($e.名称)",
                             "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$($e.名称)")) {
                if (Test-Path -LiteralPath $c) { [void](Remove-RegKeyForce $c) }
            }
        }
    }

    # --- 9. 开机自启动项 ---
    Write-Head '删除开机自启动项'
    if ($run.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($rv in $run) {
        try {
            Remove-ItemProperty -LiteralPath $rv.键 -Name $rv.名称 -ErrorAction Stop
            Write-Host "  已删除 $($rv.名称)  ($($rv.键))" -ForegroundColor Green
        } catch {
            Write-Host "  删除失败 $($rv.名称)（在 regedit 里手动删）" -ForegroundColor Yellow
        }
    }

    # --- 10. 启动文件夹 / 快捷方式 ---
    Write-Head '删除启动文件夹 / 快捷方式'
    if ($lnk.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($l in $lnk) {
        $full = Join-Path $l.位置 $l.名称
        if (Remove-PathForce $full) { Write-Host "  已删除 $full" -ForegroundColor Green }
        else { Write-Host "  删除失败 $full" -ForegroundColor Yellow }
    }

    # --- 11. Defender / 安全中心残留 ---
    Write-Head '恢复 Defender / 清理安全中心注册'
    if ($def.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($d in $def) {
        if ($d.类型 -eq 'Defender 策略' -or $d.类型 -eq 'Defender 实时保护策略') {
            try {
                Remove-ItemProperty -LiteralPath $d.键 -Name $d.名称 -ErrorAction Stop
                Write-Host "  已删除策略 $($d.名称)" -ForegroundColor Green
            } catch {
                Write-Host "  删除失败 $($d.名称)" -ForegroundColor Yellow
            }
        } else {
            $ok = if ($d.类型 -eq '安全中心注册') { Remove-RegKeyOwned $d.键 } else { Remove-RegKeyForce $d.键 }
            if ($ok) { Write-Host "  已删除 $($d.类型): $($d.名称)" -ForegroundColor Green }
            elseif ($d.类型 -eq '安全中心注册') {
                Write-Host "  未能删除 $($d.名称)（该键只有 wscsvc 有删除权；接管属主失败时可在安全模式下再试）" -ForegroundColor Yellow
            }
            else { Write-Host "  删除失败 $($d.类型): $($d.名称)" -ForegroundColor Yellow }
        }
    }

    # --- 12. 目录 ---
    Write-Head '删除目录'
    if ($dir.Count -eq 0) { Write-Host '  (无)' -ForegroundColor DarkGray }
    foreach ($d in $dir) {
        if ($d.TrimEnd('\') -match ('^' + [regex]::Escape($env:SystemRoot) + '\\')) {
            Write-Host "  跳过系统目录 $d" -ForegroundColor Yellow
            continue
        }
        if (Remove-PathForce $d) { Write-Host "  已删除 $d" -ForegroundColor Green }
        else { Write-Host "  删除失败 $d（文件被占用，重启或安全模式再试）" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host '清理完成。请重启后再跑一次体检确认。' -ForegroundColor Green
}

# =============================================================
switch ($Mode) {
    'Audit' { Invoke-Audit }
    'Clean' { Invoke-Clean }
}
