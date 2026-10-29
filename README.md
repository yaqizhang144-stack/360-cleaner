# 360 残留清理工具

一个 Windows 下用来**体检并彻底清理 360 系列软件残留**的 PowerShell 脚本。

默认模式只读扫描、不动任何东西；确认有残留后再手动进入清理模式，清理前会建系统还原点、导出注册表备份，并要求输入 `YES` 才真正删除。

- 支持系统：Windows 10 / 11（Windows PowerShell 5.1，无需安装任何东西）
- 实测环境：Windows 10 19045 与 Windows 11 22621 虚拟机，真实安装 360 安全卫士后清理至 0 项

---

## 一、为什么要做这个

360 安全卫士走正常卸载流程后，通常还会留下这些东西：

| 残留类型 | 具体表现 |
|---|---|
| 进程 | `360tray`、`readertray` 等托盘进程仍在运行 |
| 服务 | `360SafeGuard`、改名后的 `SysCleanProService` 等，服务项删不掉 |
| 内核驱动 | `FileAbap64.sys`（过滤驱动）、`DsArk64.sys`（驱动文件被占用） |
| 注册表 | `HKLM\SOFTWARE\360Safe`、`HKLM\SOFTWARE\WOW6432Node\360Safe`、`HKCU\Software\LiveUpdate360` |
| 目录 | `C:\Program Files (x86)\360safe`、`%APPDATA%\Reader`、`%APPDATA%\SysCleanPro` |
| 快捷方式 | 桌面和开始菜单里名字不带 "360" 的子文件夹（`安全中心\安全卫士.lnk`） |
| 计划任务 | `\Readertray` 等 |
| 其它 | 防火墙规则、右键菜单项、浏览器插件（BHO）、图标覆盖（`360UDiskGuard64.dll`）、安全中心里仍显示 "360安全卫士" |

其中最难处理的三类：

1. **安全中心注册项**（`HKLM\SOFTWARE\Microsoft\Security Center\Provider\Av\{...}`）：该键 Owner 是 `LOCAL SERVICE`，ACL 里只有 `NT SERVICE\wscsvc` 有删除权限，管理员和 SYSTEM 都没有 —— 普通方式删不掉。
2. **`FileAbap64.sys` 过滤驱动**：`SYSTEM_START` 启动 + `FSFilter Activity Monitor` 加载组，运行中会把自己写回去。`sc delete` 返回 1072（已标记删除）重启也不生效，`PendingFileRenameOperations` 也不会被执行，因为 smss 处理之前驱动就已经加载并锁住了文件。
3. **改名的安装目录**：360AI办公装在 `%APPDATA%\Reader`，清理Pro 装在 `%APPDATA%\SysCleanPro`，目录名、进程名、服务名全都不含 "360"，按名字扫必然漏。

---

## 二、它在扫什么、怎么识别

脚本不是按固定路径硬删，而是**多路发现 + 多重校验**，匹配不到的一律不碰。

### 体检覆盖的 12 类对象

| # | 类别 | 扫描位置 |
|---|---|---|
| 1 | 运行中的进程 | `Win32_Process`，按可执行文件路径与签名判断 |
| 2 | 服务与驱动 | `HKLM\SYSTEM\CurrentControlSet\Services`，按名称 / ImagePath / 签名 |
| 3 | 驱动文件 | `System32\drivers\*.sys` |
| 4 | 系统目录文件 | `System32`、`SysWOW64` |
| 5 | 注册表主键 | `360Safe`、`360`、`Qihoo`、`LiveUpdate360` 等，含 `WOW6432Node` |
| 6 | 卸载项 | 三处 `Uninstall` 根键，按 DisplayName / Publisher / InstallLocation |
| 7 | 安装与数据目录 | 常见位置 + 各根目录下按名字扫 + 从服务 / 卸载项 / 进程 / 快捷方式反推 |
| 8 | 计划任务 | `Get-ScheduledTask`，按任务名与动作路径 |
| 9 | 开机自启动 | `Run` / `RunOnce`（HKLM + HKCU，含 WOW6432Node）、`App Paths` |
| 10 | 快捷方式 | 启动文件夹、桌面、开始菜单**递归**扫描，按名字**和解析出的目标**双重判断 |
| 11 | 防火墙规则 | `Get-NetFirewallRule` |
| 12 | 右键菜单 / BHO / 图标覆盖 / COM | `ContextMenuHandlers`、`PropertySheetHandlers`、`DragDropHandlers`、`Browser Helper Objects`、`ShellIconOverlayIdentifiers`、`ShellExecuteHooks`、`CLSID`、`Approved` |

另外单独报告 Defender / 安全中心残留：`Security Center\Provider\Av`、`Provider\Fw`、Defender 策略与排除项，并显示当前实时保护状态。

### 识别规则

- **名称前缀**：`360`、`QH`、`Qihoo`、`奇虎`、`ZhuDongFangYu`、`BAPIDRV`、`LiveUpdate360`
- **路径特征**：`\360*\`、`\Qihoo*\`、`360Safe`、`360sd`、`360Chrome`、`360se`、`360tray`、`QHActiveDefense` 等
- **品牌词**：显示名里必须带产品词（`360安全`、`360杀毒`、`360浏览`…）或 `奇虎` / `Qihoo`，**单纯的数字 360 不算**，避免误伤资源号一类的键
- **数字签名**：`VersionInfo.CompanyName` 匹配 `360|qihu|qihoo|奇虎`；版本信息为空时才做完整 Authenticode 校验（这一步慢，所以结果有缓存）

这是能认出 "Reader"、"SysCleanPro" 这种改名目录的原因 —— 它不看目录名，看里面 exe 的公司名和签名。

---

## 三、怎么用

### 第 1 步：体检（只读，绝对安全）

双击 **`1-Check.bat`**，或命令行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-360.ps1
```

它会逐类打印扫描结果，最后给结论：

```
结论: 共发现 12 处 360 相关项。可加 -Mode Clean 清理。
```

如果显示 `未发现 360 残留，无需清理`，就不用往下做了。

### 第 2 步：清理

1. **先断网**（拔网线或关 Wi-Fi），防止 360 联网把自己装回来
2. 关掉 360 的自我保护：主界面右上角菜单 → 设置 → 自我保护
3. 双击 **`2-Clean.bat`**，UAC 提示点"是"
4. 脚本会：建系统还原点 → 导出注册表备份 → **再跑一遍体检** → 等你输入 `YES`
5. 输入 `YES` 后逐项删除；输入其它内容则原样退出，不做任何改动

清理顺序是刻意排的：先结束进程，再删服务（否则服务会把进程拉起来）→ 驱动文件 → 注册表 → 卸载项 → 计划任务 → 防火墙 → 右键菜单/BHO → 自启动 → 快捷方式 → 安全中心 → 最后删目录。

### 第 3 步：复查

重启后**再跑一次 `1-Check.bat`**。这一步不能省：实测在安全模式清理后，注册表里仍会剩 `HKLM\SOFTWARE\WOW6432Node\360Safe`，正常模式再 Clean 一次才归零。

### 什么时候必须进安全模式

体检结果里出现 `FileAbap64.sys` 或 `FileAbap` 服务时，正常模式删不掉，必须：

1. 把整个工具文件夹拷到桌面（**安全模式没有网络**，拷不进去）
2. 设置 → 系统 → 恢复 → 高级启动 → 立即重启 → 疑难解答 → 高级选项 → 启动设置 → 重启 → 按 `4`/`F4`
3. 登录后（桌面四角显示"安全模式"）双击 `2-Clean.bat`，照常输 `YES`
4. 重启回正常模式，再跑 `1-Check.bat`

安全模式下"任务计划"服务不启动，脚本会提示"任务计划服务未运行"，属正常现象，计划任务留到第 4 步复查时补清。

> 注意：安全模式（minimal）**没有网络**。如果要在安全模式里重新拷贝工具，请选"安全模式（带网络）"。

---

## 四、安全设计

| 机制 | 说明 |
|---|---|
| 默认只读 | 不带 `-Mode Clean` 绝不写任何东西 |
| 减少误伤 | 名字必须以 `360`/`Qihoo`/`奇虎` 等开头；显示名必须带产品词；路径必须命中特征 |
| 不碰系统目录 | 删除前检查，`%SystemRoot%` 下的目录直接跳过 |
| 保护自身与关键根 | 备份目录、`C:\Windows`、`Program Files`、`%USERPROFILE%` 等根目录一律排除 |
| 还原点 | `Checkpoint-Computer`，描述 `Before-360-Cleanup` |
| 注册表备份 | 每个待删键 `reg.exe export` 到 `D:\360clean_backup`（无 D 盘则 `C:\`，再不行 `%TEMP%`），失败会提示 |
| 二次确认 | 必须手工输入 `YES`（已处理 `echo YES \|` 带来的尾随空格） |
| 删除失败不硬来 | 文件被占用时登记 `PendingFileRenameOperations`，并明确告知"重启时删除" |

还原点会受 Windows 自身限制：**1440 分钟内只允许建一个**。触发限制时脚本会提示"还原点没有新增"并继续，注册表备份仍会正常完成。此时请自行确认已有可用的还原点。

---

## 五、实测记录

以下都是 2026-10-28 ~ 10-29 在 VirtualBox 虚拟机里跑出来的结果，不是估算。

### 1. 真实安装 360 安全卫士

| 步骤 | 结果 |
|---|---|
| 在线安装 360 安全卫士后 `1-Check.bat` | 识别 **12 处**：运行中的 `360tray`、`C:\Program Files (x86)\360safe`、开始菜单 `360安全卫士` 子文件夹下 4 个快捷方式、桌面快捷方式、注册表等 |
| `2-Clean.bat` 输入 `YES` | 逐项删除，输出"清理完成" |
| 复查 `1-Check.bat` | **未发现 360 残留** |

这个在线安装版本没有装 `FileAbap64.sys` 过滤驱动，所以本轮不需要安全模式。

### 2. 360AI办公 / 清理Pro（按用户安装的一类）

| 步骤 | 结果 |
|---|---|
| 清理前体检 | **14 项**（`%APPDATA%\Reader`、`%APPDATA%\SysCleanPro`、`readertray` 进程、`\Readertray` 计划任务、6 个快捷方式等） |
| 清理后体检 | **0 项**；4 个目录、进程、计划任务、快捷方式全部删除 |

### 3. 驱动残留（安全模式）

| 步骤 | 结果 |
|---|---|
| 正常模式删 `FileAbap64.sys` | 失败 / 重启后复现 |
| 安全模式清理 | 服务状态为 STOPPED，可直接删除 |
| 重启回正常模式复查 | `sc query FileAbap` 报 1060（服务不存在）、无 `FileAbap64.sys`、安全中心 `Provider\Av\{F9612FBB...}` 键不存在、`bcdedit` 无 `safeboot` |

---

## 六、踩过的坑（改代码时注意）

1. **`TOKEN_PRIVILEGES` 必须 `[StructLayout(Pack=1)]`**。x64 下不加，LUID 会被对齐到偏移 8，`AdjustTokenPrivileges` 返回 `True` 但 `GetLastWin32Error()` 是 1300，特权其实没开 —— 这是"SYSTEM 也删不掉安全中心键"的真正原因。
2. **安全中心键要接管属主**：`SeTakeOwnershipPrivilege` → Owner 改为 Administrators → 加 FullControl → `reg delete`，即脚本里的 `Remove-RegKeyOwned`。
3. **`2-Clean.bat` 必须纯 ASCII**。UTF-8 + 中文注释 + `chcp 65001` 会让 cmd 解析错位，报 `'S-1-16-12288' 不是内部或外部命令`，提权流程跑到一半就断。
4. **管理员判定不要用 `net session`**：安全模式下 Server 服务未启动会误判为"非管理员"，导致无限提权弹窗。现在用 `fltmc` / `S-1-16-12288`。
5. **`Split-Path -LiteralPath $x -Parent` 在 PS 5.1 会报 AmbiguousParameterSet**，改用 `[IO.Path]::GetDirectoryName()`。
6. **`sc delete` 返回 1072 不等于失败**，是"已标记删除，重启后移除"，脚本按成功处理。
7. **逐进程 `Get-CimInstance -Filter "ProcessId=..."` 太慢**（体检 2 分钟、清理 7 分钟），改为一次查询建 pid→路径 表。
8. **函数名不要用 `Del`** 这种：会被 PowerShell 内置别名劫持，函数体根本不执行。
9. **`reg export` 只认 `HKLM\...`，不认 `HKLM:\...`**，所以有 `ConvertTo-RegPath`。
10. **安装目录反推要防呆**：从服务 ImagePath 反推时，`C:\Windows\SysWOW64` 这种系统目录绝不能当成 360 目录收进来。

---

## 七、文件说明

| 文件 | 作用 |
|---|---|
| `Clean-360.ps1` | 主脚本，`-Mode Audit`（默认）/ `-Mode Clean` |
| `1-Check.bat` | 只读体检入口 |
| `2-Clean.bat` | 清理入口，自动提权（UAC） |
| `使用说明.txt` | 面向普通用户的图文步骤说明，可单独发给别人 |
| `README.md` | 本文件，面向想了解实现细节的人 |

### 命令行参数

```powershell
# 只读体检（默认）
powershell -ExecutionPolicy Bypass -File .\Clean-360.ps1

# 清理（必须管理员）
powershell -ExecutionPolicy Bypass -File .\Clean-360.ps1 -Mode Clean

# 指定注册表备份目录
powershell -ExecutionPolicy Bypass -File .\Clean-360.ps1 -Mode Clean -BackupDir E:\bak

# 跳过 YES 确认（无人值守 / 批量，慎用）
powershell -ExecutionPolicy Bypass -File .\Clean-360.ps1 -Mode Clean -Force
```

### 还原

备份目录里的 `.reg` 双击即可导入还原。确认系统一切正常后可自行删除该目录。

---

## 八、已知限制

- **仅支持 Windows**，依赖 PowerShell 5.1 自带模块（`ScheduledTasks`、`NetSecurity`、`Defender`），不依赖第三方组件。
- **防火墙 / 部分注册表项读取需要管理员权限**，非管理员体检时这些类别可能显示"无"。
- **离线安装包 / 完整版**才会带 `FileAbap64.sys`，在线安装的小版本没有，所以不是每次都需要安全模式。
- **改名的组件靠签名识别**，如果某个版本既不带 360 公司名、又没有有效签名，可能扫不到；这种情况请把体检输出发出来再补规则。
- **安全模式（minimal）无网络**，工具必须提前拷好。
- 清理会删掉 360 的下载目录和浏览器数据（书签、密码等），需要保留请先自行备份。

---

## 九、免责声明

本工具用于清理**自己电脑上**已卸载 / 已安装的 360 软件残留，请在清理前确认：

- 已退出所有 360 程序并关闭自我保护；
- 已建过系统还原点或备份好重要数据；
- 备份目录 `360clean_backup` 在确认无问题前不要删。

按上述步骤执行造成的问题，作者不承担责任。脚本对匹配不到的项一律不碰，但仍建议首次使用先只跑体检、把输出看一遍。
