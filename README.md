# windows-disk-cleanup

> 一个给 Windows 清理磁盘空间的 WorkBuddy / AI Agent skill，核心特征是**删之前必须你点头，且只能删登记过的东西**。
>
> A whitelist-driven, confirmation-first disk cleanup skill for Windows. It refuses to delete anything outside a curated catalog, and every deletion needs per-item human approval.

[![selftest](https://github.com/come1314/windows-disk-cleanup/actions/workflows/selftest.yml/badge.svg)](https://github.com/come1314/windows-disk-cleanup/actions/workflows/selftest.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## English quick start

Requires Windows 10/11 and PowerShell 5.1+ (already installed on every modern Windows).
No admin needed. The script is pure ASCII and works on non-English systems.

```powershell
# 1. safety self-check - must print SELFTEST OK
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode selftest

# 2. read-only scan (writes disk-scan.json, deletes nothing)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode scan

# 3. report - add -Lang en for English, -OutFile to save it
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode report -Lang en

# 4. dry run with the numbers you picked from the report (nothing is deleted)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode clean -Keys 25,48

# 5. only after you approve the dry-run output
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode clean -Keys 25,48 -Confirm

# 6. reconcile: deleted vs actually freed
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode verify
```

What it will never do: touch Documents/Desktop/Downloads/Pictures/Videos, system folders,
`.vhdx`/`.vmdk` disk images (including ones hidden inside a cache folder), or delete anything
without an explicit `-Confirm`. The docs below are in Chinese; the tool itself is not.

---

## 为什么会有这个东西

起因是一次真实的翻车：帮用户清 C 盘，删掉了 43.7 GB 缓存，可用空间却只多了 22.2 GB。

排查后发现真凶不在系统里，而在**删除动作本身**——AI 编程助手为了"可撤销"，会在删除前把文件
复制一份到 `sessions\<id>\modify_backup\`。那次留下了 **24,152 个文件、23.19 GB**，
刚好等于消失的那部分空间。

市面上讲"怎么清 C 盘"的内容很多，但几乎没人讲**清完之后怎么对账**，也没人把
"哪些绝对不能删"写成代码。这个项目想同时解决这两件事：

1. 不让 AI 凭感觉判断"这个目录是不是缓存"
2. 清完之后能说清楚"为什么释放的数字对不上"

## 安全设计

五层，任意一层独立生效：

| 层 | 机制 | 作用 |
|---|---|---|
| 1 | **白名单** | `clean` 模式只认目录清单里的条目。计划文件只提供"编号 → key"的映射，**路径一律从运行时重新计算的目录表取**——伪造或过期的计划文件也选不到清单外的东西 |
| 2 | **黑名单** | `Test-DeniedPath()` 在代码里硬拦 WinSxS、System32、Installer、Program Files、用户文档、pagefile、`.vhdx` 等，无论谁来要求都拒绝 |
| 3 | **子树校验** | `Get-DeniedDescendant()` 把黑名单套用到目标的每一层子项。白名单目录里如果藏着 `.vhdx`（Docker 的 `AppData\Local\Docker\wsl` 就是典型），**整项拒绝**，不会递归删下去；真删除时再用 `Test-DeletableChild()` 逐文件过一遍，两道都拦不住才轮到 unlink |
| 4 | **试运行** | 不加 `-Confirm` 只打印将要删除的路径和体积，一个字节都不动 |
| 5 | **审计** | 每次操作追加写入 `cleanup-audit.jsonl` |

第 3 层是补上的一刀：黑名单原本只检查「要删的那个目录」，可递归删除会一路删进子目录，
子目录里的 `.vhdx` 根本不会再被问一次。Docker 的 WSL 存储目录看起来完全像个缓存目录，
却装着 `docker_data.vhdx` 和 `ext4.vhdx`——删了就是删掉所有镜像和容器。现在它被降级为
「特殊操作」，脚本直接拒绝，清理 Docker 空间请用 `docker system prune -a`。

另外 `-Mode selftest` 会跑 **83 项断言**，验证黑名单确实拒绝坏路径、白名单确实放行好路径、过宽的规则不会误伤深层缓存目录、
所有目录条目都在安全根目录内、嵌套的 `.vhdx` 会被子树校验拦下、编号与 key 都能解析到同一项，
以及**真实的删除路径**（在 `%TEMP%` 的临时树上跑，确认缓存被删、vhdx 保留、junction 不穿透）。
**改完代码先跑自检，再跑真机。**

## 安装

### 作为 WorkBuddy skill

```bash
# 用户级（所有项目可用）
git clone https://github.com/come1314/windows-disk-cleanup.git ~/.workbuddy/skills/windows-disk-cleanup

# 或者项目级
git clone https://github.com/come1314/windows-disk-cleanup.git <你的项目>/.workbuddy/skills/windows-disk-cleanup
```

之后直接说「C 盘满了帮我清理」就会触发。

### 不装 skill，只当普通脚本用

```powershell
# 1. 安全自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode selftest

# 2. 只读扫描（不删任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode scan -Deep

# 3. 按报告里的编号试运行（不删任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode clean -Keys 25,48

# 4. 确认后执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode clean -Keys 25,48 -Confirm

# 5. 对账
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\cleanup.ps1 -Mode verify
```

`-Keys` 两种写法都行：报告里的**编号**（`25,48`），或扫描输出里的 **key**（`a258b99a`）。
编号会经 `disk-scan.json` 里记录的映射换算成路径，所以两次运行之间编号移位也不会删错东西。

## 目录结构

```
windows-disk-cleanup/
├─ SKILL.md                    # Agent 读的工作流与铁律
├─ scripts/
│  ├─ cleanup.ps1              # 全部逻辑：scan / clean / report / verify / selftest
│  └─ i18n.zh.json             # 中文文案词库，改措辞不用碰代码
├─ references/
│  ├─ safety-rules.md          # 动手前必读
│  ├─ targets.md               # 每个缓存位置"这是什么"
│  └─ troubleshooting.md       # 释放空间不符预期时怎么查
├─ sample-report.md            # 报告长什么样（已匿名化）
└─ .github/workflows/selftest.yml
```

运行时产物（`disk-scan.json`、`cleanup-audit.jsonl`、`report*.md`）都在 `.gitignore` 里——
它们记录的是**这一台机器**的路径和体积，不该进仓库。

## 命令一览

| 命令 | 是否改动磁盘 | 说明 |
|---|---|---|
| `-Mode selftest` | 否 | 83 项安全断言 + 中文词库覆盖率 |
| `-Mode scan` | 否 | 生成 `disk-scan.json` + 控制台清单 |
| `-Mode scan -Deep` | 否 | 额外列出用户目录 >500 MB 的文件（仅展示） |
| `-Mode report` | 否 | 输出中文分级清单，可直接发给用户 |
| `-Mode clean -Keys 25,48` | 否 | 试运行（编号或 key 都可以） |
| `-Mode clean -Keys 25,48 -Confirm` | **是** | 执行删除 |
| `-Mode clean -MinAgeMinutes 60` | **是** | 只删 60 分钟以前的内容，更保守 |
| `-Mode verify` | 否 | 对账 + 泄漏排查 |
| `-Mode admin-check` | 否 | 卷影副本 / 休眠 / 虚拟内存报告（需管理员） |

通用参数：`-Exclude "*剪映*"` 把匹配的项从清单和删除中排除，`-MinMB 50` 控制报告最小展示体积，
`-Lang en` 输出英文报告（默认中文，`auto` 为按系统语言猜测，不建议依赖），`-TopFiles 15` 控制 `-Deep` 列出的文件条数。

退出码：`0` 正常完成（包括"没有可删的项"这种空结果），`1` 自检断言失败，`2` 运行前提不满足（PowerShell 版本、语言模式、账户类型）。
可以直接接在 CI 或计划任务里。

## 报告长什么样

`-Mode report` 直接产出，不用自己排版。完整示例见 [`sample-report.md`](sample-report.md)
（应用名与体积做了匿名化处理，不是任何真实机器的扫描结果）：

```markdown
## 磁盘清理清单

> 扫描时间 2026-11-02 14:53 | 当前可用空间 **71.80 GB**

### 🟢 第一档：纯缓存，删了没感觉（9 项，合计 4.02 GB）

| # | 这是什么 | 体积 |
|---|---|---|
| 25 | **Edge Default 网页离线缓存** —— 网页应用（Service Worker）的离线资源缓存 | 1.42 GB |
| 4 | **npx 临时包** —— npx 临时安装的包 | 1.16 GB |

### 🟡 第二档：能删，但有代价（11 项，合计 15.64 GB）

| # | 这是什么 | 体积 | 删了会怎样 |
|---|---|---|---|
| 36 | **旧版 Windows** —— 升级前留下的旧系统，用于回滚 | 7.12 GB | 失去回滚到旧版本的能力 |
| 35 | **完整内存转储** —— 某次蓝屏时保存的完整内存镜像 | 2.50 GB | 无法再分析那次蓝屏 |
```

文案全部来自 `scripts/i18n.zh.json`，改词库就能改说法，不用碰代码。

## 覆盖范围

**🟢 纯缓存**：用户/系统临时文件、npm、pnpm、Yarn、pip、go build、conda、NuGet、Gradle、
Maven、Chrome/Edge/Firefox 各级缓存、崩溃转储、WinINet、音乐软件在线缓存

**🟡 有代价**：Windows 更新包、传递优化、系统日志、蓝屏转储、Prefetch、Windows.old、
C++/JetBrains 索引、各类 Electron 应用缓存

**⚙️ 特殊操作**：回收站、休眠文件、虚拟内存、Docker 存储目录——只给正确做法，脚本拒绝当普通删除处理

**🔴 永不触碰**：WinSxS、Windows Installer、System32、Program Files、ProgramData、
System Volume Information、pagefile、hiberfil、`.vhdx`/`.vhd`（**含任意层级子目录里的**）、
所有用户文档目录

**📦 只报告不删**：用户目录下的大文件（安装包、ISO、录屏、素材包）——建议移动到其他盘

## 明确不做的事

- 不删用户文档、下载、桌面、图片、视频里的任何东西
- 不替代 `DISM /Online /Cleanup-Image` 处理 WinSxS（那才是官方正确做法）
- 不自动清空回收站（会单独确认）
- 不静默提权，需要管理员时给出手动执行的命令
- 不碰虚拟机的磁盘镜像（`.vhdx`/`.vhd`/`.vmdk`，包括藏在缓存类目录里的）
- 不删 `AppData\Local\Docker\wsl`——那里是镜像和容器本身，清理请用 `docker system prune -a`

## 兼容性

### 运行前提（不满足会直接报错退出，不会半路失败）

| 前提 | 说明 |
|---|---|
| Windows 10 / 11 | Server 未测试 |
| PowerShell 5.1 及以上 | 5.1 和 7.x 都支持；装 Win10/11 就有，无需额外安装 |
| **FullLanguage** 模式 | 企业的 ConstrainedLanguage 会禁掉脚本依赖的 .NET 文件 API，检测到就直接退出并说明原因 |
| 普通登录用户会话 | 服务账户 / SYSTEM / 没有正常加载的用户配置会被识别并拒绝 |
| 能读取 `LOCALAPPDATA`、`USERPROFILE`、`SystemDrive` | 环境变量缺失时会向 Known Folder API 兜底，仍拿不到才退出 |

不需要管理员。只有 `Windows Temp`、`Prefetch`、`SoftwareDistribution\Download`、
卷影副本这几项需要提权，它们会失败并被跳过统计，其余照常工作。

### 报告语言

默认中文。给英文用户或英文系统用 `-Lang en`：

```powershell
... -Mode report -Lang en
```

`-Lang auto` 是按系统 UI 语言猜的，**不建议依赖**：Windows 的进程 UI 语言在某些终端
设置下会返回系统语言而不是用户语言（实测会把中文用户判成 en-US）。猜错的代价是
静默输出另一种语言，不如显式指定。

### 能用的场景

| 场景 | 支持 |
|---|---|
| Windows 10 / 11 家庭版、专业版 | ✅ |
| 单用户、单系统盘（C:） | ✅ 最佳路径 |
| 多用户同一台机器 | ✅ 其他账户的 Temp / 浏览器缓存会列出（需管理员，标为"谨慎"） |
| 中文用户名、中文路径 | ✅ 脚本本身是纯 ASCII（自检会断言），中文只在 JSON 词库里 |
| 系统盘不是 C: | ✅ 全部从 `$env:SystemDrive` 取 |
| 文档/桌面/下载被重定向到 D:、或指向 OneDrive | ✅ 用 Known Folder API 取实际路径来拦，不靠文件夹名 |
| 非中文 Windows | ✅ 加 `-Lang en` 出英文报告；说明文档仍是中文 |
| 没有装 Node/Python 等开发环境 | ✅ 对应项不存在就自动跳过 |
| 控制台是 GBK 还是 UTF-8 | ✅ 沿用终端自己的代码页；要中文报告带 emoji 完整无损就用 `-OutFile` |
| 目录里带 junction / 符号链接 | ✅ 不穿透链接，不会陷进 `AppData\Local\Application Data` 那种自指链接 |
| 路径超过 260 字符（npm / pnpm 缓存常见） | ✅ 走 `\\?\` 长路径 API |
| WMI / CIM 被禁用 | ✅ 可用空间改用 `DriveInfo` 读取 |

### 会打折或不适用的场景

| 场景 | 情况 |
|---|---|
| 用户目录被移到 D: 等非系统盘 | 能跑，但"清 C 盘"的收益变少——缓存跟着用户目录走了 |
| 域账户 / 漫游配置文件 | 部分可用，缓存目录仍会被列出，但 Profile 结构可能不同 |
| Windows Server | 未测试 |
| 装了第三方清理软件（360、腾讯管家等） | 可能锁住文件，删不掉的部分会被跳过并统计 |
| 用 `SUBST` / 网络盘映射的用户目录 | 不建议使用 |
| 系统开了 BitLocker + 大量快照 | 释放量可能小于删除量（见 troubleshooting） |
| 32 位 PowerShell 跑在 64 位系统 | 能跑，但 `System32` 会重定向到 `SysWOW64`；本工具不碰这两个目录，影响仅限显示 |

### 已验证的环境

作者机器实测：Windows 11 + Windows PowerShell 5.1 + zh-CN + 非管理员 + 存在自指 junction
的配置下，`selftest` 83 项断言全过，`scan` / `report` / `dry-run` / `verify` 全流程跑通。

CI（GitHub Actions `windows-latest`）跑三个 job：`powershell`（5.1）与 `pwsh`（7）各跑一遍
自检、只读扫描、中英文报告渲染、空删除试运行和对账，外加一个 `PSScriptAnalyzer` 的
error 级静态检查。**其他 Windows 版本/语言/权限组合尚未逐一实测**，
遇到问题请开 issue 并附 `selftest` 输出。

### 明确清不到的地方

这些是**有意不做**，不是遗漏：

- **`C:\Program Files` 下的缓存**——Steam 的 `steamapps\shadercache`、Adobe 的媒体缓存都在这里，
  按黑名单规则无法触碰。需要用户自己处理。
- **WinSxS**——正确做法是 `DISM /Online /Cleanup-Image /StartComponentCleanup`，
  按钮式删除只会把系统弄坏。本工具只提供说明，不代为执行。
- **Windows.edb 搜索索引**——需要 `控制面板 → 索引选项 → 高级 → 重建`，不能直接删文件。
- **Outlook `.ost` 文件**——删了要重新同步整个邮箱，风险大于收益。
- **OneDrive 占位文件**——占的是"名义大小"不是真实磁盘占用，清它没意义。
- **回收站、休眠、虚拟内存**——只给方法，必须用户单独确认（脚本会拒绝当普通项处理）
- **Docker 的 WSL 存储目录**——`AppData\Local\Docker\wsl` 装的是 `ext4.vhdx`，
  即镜像和容器本身。清它等于删数据，正确做法是 `docker system prune -a`；
  脚本只展示体积，拒绝删除。

## 后续可优化的方向

已经想到但还没做的，欢迎 PR：

1. **单文件 exe** —— 用 `ps2exe` 打包，让完全不懂命令行的用户双击运行
2. **`-Drive` 参数** —— 支持清理 D:/E: 等非系统盘上的项目缓存
3. **断点续删** —— 超大目录删除中断后可续跑，而不是从头再来
4. **更多国产软件精确路径** —— 迅雷、百度网盘、微信开发者工具目前靠通用规则命中，
   路径不稳定，需要逐版本验证
5. **更多语言** —— 英文用脚本内置文案（`-Lang en`），其他语种加一份 `i18n.<lang>.json` 即可，
   条目名本身是英文的，只需要补标签和说明

## 免责声明

本工具执行的是**不可恢复的删除**。虽然做了五层保护，但磁盘清理本身有风险：
误删缓存可能导致程序需重建索引、重新下载依赖、丢失未保存的临时状态。

**请务必先跑 `-Mode selftest` 和 `-Mode scan`，并在试运行输出上确认无误后再加 `-Confirm`。**
因使用本工具造成的数据丢失，作者不承担责任。

## License

MIT © 2026 Jiandan Song，见 [LICENSE](LICENSE)。
