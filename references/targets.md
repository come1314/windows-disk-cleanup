# 清理目标分类说明

面向用户的解释素材。向用户展示清单时，用这里的描述，不要只丢路径。

---

## 🟢 绿色：纯缓存，删除无功能损失

| 目标 | 路径 | 是什么 | 删除后果 |
|---|---|---|---|
| 用户临时文件 | `%LOCALAPPDATA%\Temp` | 程序安装/运行时的临时落盘文件 | 无。个别正在运行的程序会重建，被占用的文件自动跳过 |
| 系统临时文件 | `C:\Windows\Temp` | 系统级临时文件 | 无。需管理员权限 |
| npm 缓存 | `%LOCALAPPDATA%\npm-cache\_cacache` | Node 装包时的下载副本 | 下次 `npm install` 重新下载 |
| pnpm / Yarn 缓存 | `%LOCALAPPDATA%\pnpm-store`、`Yarn\Cache` | 同上，不同包管理器 | 下次装包重新下载 |
| pip 缓存 | `%LOCALAPPDATA%\pip\cache` | Python 包下载副本 | 下次 `pip install` 重新下载 |
| go build 缓存 | `%LOCALAPPDATA%\go-build` | Go 编译中间产物 | 下次编译重新生成，首编变慢 |
| conda 包缓存 | `~\.conda\pkgs` 等 | conda 安装包压缩包 | 下次装包重新下载 |
| 浏览器缓存 | Chrome/Edge `User Data\<配置>\Cache` 等 | 网页资源缓存 | 首次访问网站略慢，不影响登录状态和书签 |
| Firefox 缓存 | `Profiles\*\cache2` | 同上 | 同上 |
| 崩溃转储 | `%LOCALAPPDATA%\CrashDumps` | 程序崩溃时的内存快照 | 无。除非要分析历史崩溃 |
| WinINet 缓存 | `%LOCALAPPDATA%\Microsoft\Windows\INetCache` | 老旧网络缓存 | 无 |
| 音乐缓存 | `Tencent\QQMusic\QQMusicCache`、`NetEase\CloudMusic\Cache` | **在线播放**的音频缓存 | 重听要重新缓冲。**注意：不是用户下载的音乐库** |

---

## 🟡 黄色：可以删，但有明确代价

| 目标 | 路径 | 是什么 | 代价 |
|---|---|---|---|
| 更新下载包 | `C:\Windows\SoftwareDistribution\Download` | 已下载的 Windows 更新 | 该更新需重新下载；先停 `wuauserv` |
| 传递优化缓存 | `...\DeliveryOptimization` | 更新/商店的 P2P 分享缓存 | 无，自动重建 |
| Windows 日志 | `C:\Windows\Logs` | CBS/DISM 安装日志 | 系统更新出问题时少了排查依据 |
| 蓝屏转储 | `C:\Windows\Minidump`、`MEMORY.DMP` | 蓝屏时的内存快照 | 无法再分析历史蓝屏原因 |
| 预读取 | `C:\Windows\Prefetch` | 加速程序启动的预读数据 | 前几次启动略慢（影响很小） |
| Windows.old | `C:\Windows.old` | 上一版本 Windows（用于回滚） | 失去回滚到旧版本的能力。**建议用系统「存储感知」清，它会同时清理回滚记录** |
| C++ 索引库 | `%LOCALAPPDATA%\Microsoft\vscode-cpptools` | VS Code 的 C/C++ 代码索引 | 重新打开工程要重新索引，大工程数分钟 |
| JetBrains 索引 | `%LOCALAPPDATA%\JetBrains\<版本>\caches、index` | IntelliJ/PyCharm 索引缓存 | 重新打开工程要重建索引。**只删这两项，不要删整个版本目录**（配置和插件在里面） |
| NuGet 包 | `~\.nuget\packages` | .NET 依赖包缓存 | 下次 `restore` 重新下载，可能几个 GB |
| Gradle 缓存 | `~\.gradle\caches` | Java 依赖缓存 | 下次构建重新下载 |
| Maven 仓库 | `~\.m2\repository` | 同上 | 下次构建重新下载 |
| Docker 数据 | `%LOCALAPPDATA%\Docker\wsl` | **不是缓存**：`docker_data.vhdx` / `ext4.vhdx`，即镜像、容器、数据卷本身 | **不能删**，删了等于删光所有镜像和容器。要腾空间用 `docker system prune -a`，或调整 Docker Desktop 的镜像上限。脚本已把它列为特殊动作并拒绝删除 |
| 通用应用缓存 | `%LOCALAPPDATA%\<应用>\Cache`、`cef_cache`、`Code Cache` | 各 Electron 应用的缓存 | 一般无影响；但个别应用把重要数据放在名叫 Cache 的目录里，所以要逐个确认 |
| Agent 备份 | `...\sessions\*\modify_backup` | AI 编程助手删除文件前的副本 | 无（详见 troubleshooting.md） |

---

## 🔴 红色：永远不要删

| 路径 | 为什么不能删 |
|---|---|
| `C:\Windows\WinSxS` | 组件存储，用硬链接和系统文件互指。手动删会让系统无法更新、无法修复，甚至无法启动。正确做法是 `DISM /Online /Cleanup-Image /StartComponentCleanup` |
| `C:\Windows\Installer` | MSI 安装缓存。删了以后软件**无法卸载、无法修复、无法升级**，且体积不会因此变小 |
| `C:\Windows\System32` / `SysWOW64` | 系统核心 |
| `C:\Program Files` / `Program Files (x86)` | 已安装软件本体 |
| `C:\ProgramData\Package Cache` | Visual Studio / VC++ 运行库的安装缓存，删了相关软件无法修复 |
| `C:\System Volume Information` | 卷影副本和还原点的存放地，只能通过 `vssadmin` 管理 |
| `C:\$Recycle.Bin` 本身 | 目录本身不能删，要清空请用 `Clear-RecycleBin` |
| `C:\pagefile.sys` | 虚拟内存。删了会导致程序崩溃、系统不稳定。空间不够就**移**到别的盘 |
| `C:\hiberfil.sys` | 休眠文件。不能直接删文件，要关休眠得用 `powercfg /h off` |
| `*.vhdx` / `*.vhd` | WSL2、Docker、虚拟机的磁盘镜像，删了等于删整台虚拟机的数据 |
| WSL 发行版目录 | 是完整的 Linux 文件系统 |

---

## 📦 用户数据：只建议移动，不建议删除

扫描时把大于 500 MB 的用户文件单独列出来，用 `-Mode scan -Deep`。

典型可优化项（都是"装完就忘"的东西，但决定权在用户）：

| 类型 | 例子 | 建议 |
|---|---|---|
| 安装包 | `pycharm-*.exe`、`idea*.exe`、`*setup*.exe` | 装完就没用，可删可搬 |
| 光盘镜像 | `*.iso` | 尤其常见重复下载（文件名带 `(1)`、`(2)`、`(4)`） |
| 旧版软件包 | `sqlmanagementstudio_x86.exe` | 同上 |
| 素材压缩包 | `*资料*.rar`、`*.zip` | 解压后原件通常可删 |
| 录屏/视频 | `屏幕录制 *.mp4` | 体积大，**建议搬到其他盘**而不是删 |

同一文件下载多次的（`xxx.zip` 和 `xxx (1).zip` 内容相同）是最好说服用户清理的一类，
但要**让他自己确认哪个留哪个删**，不要替他判断。
