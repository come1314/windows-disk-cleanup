# 排障手册

清理过程中最常遇到的问题，以及真实案例。

---

## 一、删了 40 GB，可用空间只多了 20 GB

**这是最常见、也最容易让人以为"清理失败"的现象。按下面顺序排查。**

### 1. Agent 的删除备份（最容易中招）

多数 AI 编程助手为了让删除"可撤销"，会在删除前把文件复制一份。这些副本通常存放在：

```
%USERPROFILE%\.<agent>\workspace\sessions\<会话ID>\modify_backup\
%LOCALAPPDATA%\<agent>\<...>\sessions\<会话ID>\modify_backup\
```

真实案例：删除 43.7 GB 缓存后，可用空间只增加 22.2 GB。逐层排查发现
`C:\Users\<用户>\.workbuddy\workspace\sessions\<id>\modify_backup\` 里有
**24,152 个文件、23.19 GB**，生成时间与删除动作精确对应。清掉这批备份后，
可用空间立刻从 83.6 GB 涨到 106.8 GB。

**检测**：

```powershell
.\cleanup.ps1 -Mode verify
```

它会把所有 `modify_backup` 目录加总报告。也可以手工查：

```powershell
Get-ChildItem "$env:USERPROFILE" -Directory -Filter 'modify_backup' -Recurse -Depth 6 -Force |
  ForEach-Object {
    $s = (Get-ChildItem $_.FullName -Recurse -Force -File | Measure-Object Length -Sum).Sum
    '{0,8:N2} GB  {1}' -f ($s/1GB), $_.FullName
  }
```

**处理**：向用户解释成因，单独征得同意后删除。这类副本对用户没有价值
（他们要删的东西本来就不想再看到）。

### 2. 回收站

删除进了回收站，空间并没有释放。检测：

```powershell
(Get-ChildItem 'C:\$Recycle.Bin' -Recurse -Force -File -ErrorAction SilentlyContinue |
  Measure-Object Length -Sum).Sum / 1GB
```

清空用 `Clear-RecycleBin -DriveLetter C -Force`，**必须单独确认**，因为
回收站里可能有用户还想恢复的东西。

### 3. 卷影副本 / 系统还原点

如果开了系统保护，被删除文件的旧数据块可能仍被快照引用。检测（需管理员）：

```powershell
vssadmin list shadowstorage
vssadmin list shadows
```

正常情况占用不大（通常是磁盘的 1~2%）。若确实很大，可选：

| 方案 | 命令 | 影响 |
|---|---|---|
| 删最旧的快照 | `vssadmin delete shadows /for=C: /oldest` | 失去对应时间点的还原能力 |
| 只调小上限 | 系统属性 → 系统保护 → 配置 | 保留最近还原点，更稳妥 |

**注意**：如果 `list shadows` 只显示一个刚创建的还原点、占用几个 GB，
那它**不是**空间消失的原因，别在这上面纠缠，回去查第 1 项。

### 4. 文件被进程占用，删除被跳过

运行中的程序会锁住自己的缓存文件。脚本会跳过并统计 `skipped` 数量。

处理顺序：
1. 报告哪个程序占用（`-Mode scan` 的 `LOCKED` 列会显示）；
2. 请用户保存工作后自行关闭；
3. 关闭后重跑一次；
4. **不要**为了删缓存去强杀用户的程序。

### 5. 读数本身不可靠

Windows 的可用空间读数有多条路径，可能不一致：

| 方式 | 特点 |
|---|---|
| `Get-PSDrive C`、`Get-Volume` | 有缓存，删完可能滞后几分钟 |
| `Get-CimInstance Win32_LogicalDisk` | 通常准确，偶尔滞后 |
| `fsutil volume diskfree C:` | **最准**，但需要管理员 |

真实案例：删除过程中 `Get-Volume` 报 39.8 GB，十分钟后同一命令报 70.4 GB，
而管理员下 `fsutil` 一直是准确的。**做结论时优先用 fsutil；非管理员时，
读数剧烈跳动就等几分钟再测，或明确告知用户"读数可能有延迟"。**

### 6. NTFS 延迟回收

大量小文件（几十万个）删除后，MFT 和日志的回收不是瞬时的。
删完立刻测可能偏小，重启后通常会回到正常值。

---

## 二、脚本一启动就退出（exit 2）

这几条是**有意设计的拒绝**，不是 bug。看到就照原文处理，不要绕开：

| 输出 | 原因 | 处理 |
|---|---|---|
| `This script needs PowerShell 5.1 or newer` | PowerShell 2.0/4.0 | 升级 PowerShell，或换一台机器 |
| `LanguageMode is ConstrainedLanguage` | 企业 AppLocker / WDAC 策略 | .NET 文件 API 被禁，脚本没法工作。让用户找管理员放行，或改用系统自带的「存储感知」 |
| `Could not resolve LOCALAPPDATA / USERPROFILE / SystemDrive` | 服务账户、SYSTEM、用户配置没加载 | 让用户用自己登录的账户开一个普通 PowerShell 窗口重跑 |

另外三种「像退出但不是」：

- **`-ExecutionPolicy` 拦截**：用文档里的完整命令 `powershell -NoProfile -ExecutionPolicy Bypass -File ...`
- **报告是乱码**：脚本沿用终端代码页。中文终端显示正常；要保证不乱码且 emoji 完整，
  用 `-OutFile report.md` 写文件再读，文件固定是 UTF-8
- **报告语言不对**：默认中文，英文用户加 `-Lang en`。`-Lang auto` 是猜的，
  Windows 在某些终端下会返回系统语言而不是用户语言，别依赖它

---

## 三、删不掉，提示"访问被拒绝"

| 原因 | 表现 | 处理 |
|---|---|---|
| 进程占用 | `IOException: 文件正由另一进程使用` | 关闭对应程序后重试 |
| 权限不足 | 系统目录 | 需要管理员；仍失败就放弃这一项 |
| 智能体自身目录保护 | `sandbox` 拒绝修改 `.workbuddy` 等自身状态目录 | 让用户自己删，或提供一条命令让他在终端执行 |
| 只读/系统属性 | 少数文件 | `attrib -r -s` 后重试，别滥用 |

实在删不掉就**如实报告并跳过**，不要用更激进的手段硬来。

---

## 四、删除大目录卡住很久

npm 缓存这类目录可能有 20 万个小文件，删除耗时 5~10 分钟。

- 放到后台执行，别让用户干等；
- 期间不要重复发起同一操作；
- 完成后汇报"删除 X 个条目、跳过 Y 个、剩余 Z MB"。

---

## 五、清理后应用变慢或异常

预期内的现象：

| 现象 | 原因 | 持续 |
|---|---|---|
| 浏览器首次打开网站稍慢 | HTTP 缓存重建 | 几分钟 |
| IDE 打开工程转圈 | 索引重建 | 几分钟到几十分钟 |
| 程序首次启动略慢 | Prefetch 被清 | 几次启动 |
| `npm install` 变慢 | 包缓存重建 | 一次 |

**不属于预期、需要立即告知用户的**：

- 程序登录状态丢失（通常是删了 `Cookies`、`Local Storage`、`Login Data` 等，不是 Cache）
- 聊天软件历史记录消失（删到了数据目录，不是缓存）
- 游戏/软件需要重新激活

如果发生，立刻停止后续操作，如实说明删了什么，并建议从回收站或备份恢复。

---

## 六、汇报模板

排查结束后，用这个结构讲清楚：

```
删除总量：41.6 GB
实际释放：22.2 GB
差额    ：19.4 GB
原因    ：Agent 删除备份占用了 23.19 GB（路径...）
处理    ：经你确认后已清除，现可用 106.8 GB
```

**不要把差额藏起来，也不要含糊地说"系统占用"。** 用户能接受"我查清楚了"，
不能接受"应该是缓存吧"。
