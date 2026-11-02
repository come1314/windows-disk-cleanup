---
name: windows-disk-cleanup
description: Safely reclaim disk space on Windows when the C drive is full or running low (triggered by 清理C盘, C盘满了, 磁盘空间不足, 清理缓存, 电脑变卡想清空间, free up space, disk cleanup, low disk space). Uses a whitelist-driven catalog, a hard denylist enforced in code, and requires explicit per-item user confirmation before every deletion. Produces a tiered report (safe / caution / never / user data), reconciles actually-freed space against the deleted amount, and diagnoses why a deletion freed less than expected.
agent_created: true
---

# Windows 磁盘清理

## 用途

帮用户安全地给 Windows 腾空间。核心不是"找出谁占地方"，而是**在删之前让用户清楚知道
每个东西是什么、删了会怎样，并且只在他明确同意后才动手**。

这个 skill 的价值在于五层保护（与 README 一致）：

1. **白名单**——只删目录清单里登记过的缓存位置，脚本会拒绝清单之外的任何路径
2. **黑名单**——系统关键目录和用户数据目录在代码层面硬拦，绕不过去
3. **子树校验**——黑名单会套用到目标的每一层子项。缓存目录里如果藏着 `.vhdx`
   （典型是 Docker 的 `AppData\Local\Docker\wsl`），整项拒绝；真删除时还会逐文件再验一遍
4. **试运行**——不加 `-Confirm` 只打印路径和体积，一个字节都不动
5. **审计**——每次操作追加写入 `cleanup-audit.jsonl`，供 `verify` 对账

**逐项确认**不是代码层，而是流程纪律：每一项都必须由用户看着体积、路径、后果来点头。

## 何时使用

- 用户说 C 盘满了、空间不够、电脑变卡、想清理垃圾
- 用户问"哪些文件可以删"、"这个文件夹能不能删"
- 用户做完清理后发现空间没变化，需要排查（见 `references/troubleshooting.md`）

不适用：用户明确要删某个具体文件——那是普通文件操作，不是清理任务。

## 适用范围与边界

- 支持 Win10/11、PowerShell 5.1 及以上（5.1 与 7.x 均可）、单用户与多用户机器
- **不需要管理员**。`Windows Temp`、`Prefetch`、`SoftwareDistribution\Download`、
  卷影副本需要提权，会失败并计入跳过，其余照常
- 脚本会自己处理这些机器差异，不用你操心：文档/桌面/下载被重定向或指向 OneDrive、
  中文用户名与中文路径、系统盘不是 C:、目录里的 junction、超过 260 字符的深路径、
  WMI 被禁用、装了 360 之类会锁文件的清理软件
- 启动前有硬性自检：PowerShell < 5.1、ConstrainedLanguage 模式、服务账户或缺
  环境变量时**直接退出并说明原因**，不会带病运行。看到 `exit 2` 就把原文转给用户
- **多用户**：其他账户的 Temp 和浏览器缓存会被列出，但需要管理员权限，
  且必须确认该账户当前没有人在用
- **清不到**（有意不做，不要尝试绕过）：`Program Files` 下的缓存
  （Steam `shadercache`、Adobe 媒体缓存）、WinSxS（走 `DISM`）、
  `Windows.edb` 搜索索引、Outlook `.ost`、OneDrive 占位文件
- 用户目录被移到非系统盘时仍可用，但收益会变小
- 装了第三方清理软件时，部分文件会被锁住跳过，属正常现象

## 报告语言

默认中文。**用户用英文跟你说话、或系统明显不是中文时，加 `-Lang en`**——
不要依赖 `-Lang auto`，Windows 的进程 UI 语言在某些终端里会返回系统语言而不是
用户语言，猜错就静默换了语言。宁可显式指定。

## 铁律

完整规则见 `references/safety-rules.md`，必须遵守。核心五条：

1. **白名单之外一律不删**——即使你觉得那明显是垃圾
2. **每次删除前逐项确认**——体积、完整路径、这是什么、删了会怎样，四项齐全
3. **用户数据永不自动删**——文档、桌面、下载、图片、视频只能建议移动
4. **系统关键目录不碰**——WinSxS、Installer、System32、Program Files、pagefile 等
5. **不做静默操作**——删了什么、跳过什么、释放多少，全部如实交代

另外三条最容易踩的：

- **回收站不等于释放空间**，同一块盘上的文件不会因为"进回收站"而腾出容量
- **删除前提醒用户保存工作**，缓存清理会让正在编辑的文档需要重新索引
- **别假设"目录叫 Cache 里面就都是缓存"**——Docker 的 `AppData\Local\Docker\wsl`
  看着像缓存，里面是两个 `.vhdx`。脚本会拒绝这类目标，不要绕过它，也不要在
  干净目录里手工加删除命令

## 工作流

### 第 1 步：自检（首次使用时）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/cleanup.ps1 -Mode selftest
```

必须看到 `SELFTEST OK`。如果失败，说明白名单/黑名单有问题，**不要继续**。

### 第 2 步：只读扫描

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/cleanup.ps1 -Mode scan -Deep
```

- 不写、不删，纯读取，可以放心跑
- 生成 `disk-scan.json`（机器可读清单）和控制台表格（人看的）
- `-Deep` 额外列出用户目录下 >500 MB 的文件，这些**只做展示，绝不自动删**

### 第 3 步：出报告，等用户选

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/cleanup.ps1 -Mode report
```

```powershell
# 存档一份，或调整最小展示体积（默认 10 MB）
... -Mode report -MinMB 50 -OutFile report.md
```

输出已经是**排好序的中文分级清单**（🟢 纯缓存 / 🟡 有代价 / ⚙️ 特殊操作 / 🔴 不建议动），
编号与扫描表一致，措辞来自 `scripts/i18n.zh.json`。

**直接把它发给用户**，不要自己重写表格——手写容易出现编号对不上、体积单位不一致的问题。

用户如果说"别动剪映""视频缓存别碰"之类，用 `-Exclude` 把这些从清单里摘掉：

```powershell
... -Mode report -Exclude "*JianyingPro*","*剪映*"
```

**必须等用户明确回复编号**。用户说"都行""你看着办"时，把清单再发一次让他挑。

> 找不到 `i18n.zh.json` 时报告会自动退回英文，不会报错。

### 第 4 步：试运行

**把用户选的编号直接传进去**，不用换算成 key。**先不加 `-Confirm` 跑一次**，拿到精确的删除清单：

```powershell
... -Mode clean -Keys 25,48
```

编号会经由 `disk-scan.json` 里记录的映射换算成路径，所以两次运行之间编号移位也不会删错。
key（8 位十六进制）同样可以用，写哪个都行。

输出会列出每一项的路径、文件数、体积。贴给用户做最后确认，并明确一句：
**"这一步删除不可恢复"**。

### 第 5 步：执行

```powershell
... -Mode clean -Keys 25,48 -Confirm
```

- 大目录（几十万小文件）可能要跑几分钟，放后台执行，别让用户干等
- 被占用的文件会自动跳过并统计，属于正常情况
- 输出里的 `protected=N` 是**有意保留**的受保护条目，不是失败
- 每条记录写入 `cleanup-audit.jsonl`

### 第 6 步：对账（必做，不能省）

```powershell
... -Mode verify
```

把"删除总量"和"实际释放"放在一起对比。差额超过 20% 就按
`references/troubleshooting.md` 排查。**最常见的原因是 Agent 自己的
`modify_backup` 删除备份**——真实案例里删了 43.7 GB 只释放 22.2 GB，
差额 23.19 GB 全在一个备份目录里。

最后给用户一句总结：

```
清理前 50.1 GB → 现在 106.8 GB，共腾出 56.7 GB
```

## 特殊动作

扫描结果里 `Tier=action` 的项**不能当普通删除处理**，脚本会拒绝，需单独操作：

| 项 | 正确做法 | 必须提醒 |
|---|---|---|
| 回收站 | `Clear-RecycleBin -DriveLetter ($env:SystemDrive.TrimEnd(':')) -Force` | 清空后无法恢复，可能有用户还想找回的东西 |
| hiberfil.sys | `powercfg /h off`（需管理员） | 失去休眠和快速启动，笔记本用户要谨慎 |
| pagefile.sys | 系统属性 → 高级 → 虚拟内存，**移到其他盘** | 不要删，只移动；需重启生效 |
| Docker 存储目录 | `docker system prune -a`，或 Docker Desktop 里调整磁盘镜像上限 | 目录里是 `docker_data.vhdx` / `ext4.vhdx`，删了等于删光所有镜像和容器，无法恢复 |

需要管理员的操作：把命令写成脚本让用户自己在管理员终端执行（见
`safety-rules.md` 第四节），不要尝试静默提权。

## 用户想删清单外的东西

比如"把下载文件夹里那个 4 GB 的压缩包删了"：

1. 告诉他完整路径
2. 说明这是什么、删了会怎样
3. 建议**先搬到其他盘**而不是删
4. 如果他坚持，让他自己在资源管理器里删，或明确说"确认删除"后再执行

不要因为"这是用户要求的"就绕开白名单去手写删除命令。

## 汇报要求

每次操作后必须说清：

- 删了哪些（名称 + 路径 + 体积）
- 跳过了哪些、为什么（被占用 / 权限不足 / **受保护未删**）
- 释放前后的可用空间，以及**删除量和释放量是否对得上**
- 差额的原因（查清楚了再说，不要含糊成"系统占用"）

输出里的 `protected=N` 表示"有意保留的受保护条目"，必须如实转述，
不能说成"删除失败"或"没权限"。

不允许出现"顺手清理了一下"这类不透明表述。

## 脚本参数

| 参数 | 说明 |
|---|---|
| `-Mode selftest` | 安全自检，验证黑白名单 + 中文词库 |
| `-Mode scan` | 只读扫描，输出 `disk-scan.json` |
| `-Mode scan -Deep` | 额外列出用户大文件（仅展示） |
| `-Mode report` | 输出分级清单（`-MinMB` 控制最小体积，`-OutFile` 存文件） |
| `-Mode clean -Keys 25,48` | 试运行，不删。编号或 key 都可以 |
| `-Mode clean -Keys 25,48 -Confirm` | 真正删除 |
| `-Mode clean -MinAgeMinutes 60` | 只删 60 分钟以前的内容，更保守 |
| `-Exclude "*剪映*"` | 从清单和删除里排除匹配项（名称或路径） |
| `-Lang en` / `-Lang zh` | 报告语言，默认中文。英文用户用 `en`；`auto` 靠系统语言猜，不稳 |
| `-Mode verify` | 对账 + 泄漏排查 |
| `-Mode admin-check` | 卷影副本/休眠/虚拟内存报告（需管理员） |

## 参考文件

| 文件 | 何时读 |
|---|---|
| `references/safety-rules.md` | 动手前必读，尤其"必须停下来问的场景" |
| `references/targets.md` | 向用户解释"这是什么"的素材，按需查询 |
| `references/troubleshooting.md` | 释放空间不符预期、删不掉、应用变慢时 |
