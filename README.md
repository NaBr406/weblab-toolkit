# WebLab 仿真实验提交包分析工具

本项目原创代码和文档采用 [MIT License](LICENSE)。附带的第三方组件
`tools/USTCORi.SimExp.Instruments.Component.dll` 不在本项目 MIT 授权范围内，
其权利归原权利人所有。

针对 **科大奥锐 WebLab / USTCORi.SimExp** 虚拟仿真实验平台的提交协议分析工具集。
通过本地抓包还原客户端的提交包，把实验数据表填成标准答案后原样重放。

> 用于协议分析、安全研究与教学演示。使用者需自行确认使用场景是否合规，风险自负。

---

## 一、使用场景

### ✅ 适用

| 场景 | 说明 |
|---|---|
| **平台** | 科大奥锐 WebLab / USTCORi.SimExp 系列（高校大学物理虚拟仿真实验常见的那套） |
| **客户端形态** | WPF 版实验室（`USTCORi.SimExp.*.exe` + `SimExpConfig\ExamConfig.bin`）实测通过 |
| **提交方式** | 客户端通过 `POST {ServerIP}/ServiceAPI/UpdateRecord` 上报加密 XML 的部署 |
| **网络** | 明文 HTTP（`http://ip:port`），同网段可达 |
| **典型用途** | ① 批量核对各实验的判分项与权重；② 复现「提交包可篡改」这一设计缺陷；③ 实验课快速完成数值类判分项 |

### ❌ 不适用

| 场景 | 原因 |
|---|---|
| 非 USTCORi 系平台 | 协议完全不同 |
| HTTPS 且证书固定（HSTS） | 需要给代理装证书，工具本身不做 TLS 解密 |
| 提交包经过二次签名/服务端二次校验的版本 | `Key` 若覆盖了 `Content` 摘要就改不动 |
| 需要教师端人工审核定分的实验 | 工具只影响自动判分那部分 |

---

## 二、能力边界（务必先看）

平台把判分项分成两类，**本工具只对第一类有效**：

| 判分项类型 | 例子 | 能否用本工具拿分 | 原因 |
|---|---|---|---|
| **数值类** | 周期 5ms、倔强系数 0.944、单缝宽度 0.1219、砝码读数表 | ✅ 可以 | 数据在 XML 里，可解可改 |
| **状态/操作类** | 「连接成功」、「已经退磁」、光强 1–2mW 区间、CH1=50mV 档、「点击确认」 | ❌ 不行 | XML 里存的是**状态码**（double），含义由客户端私有映射决定，改文件填不出正确码 |
| **无 JudgeRule 的实验** | 透镜成像（TotalScore 全 0） | ⚠️ 部分 | 判分规则不在 XML 里，只能按「表格是否填满 + 平均值是否匹配」试 |

实测结论：

- 示波器、电桥、声速、驻波、刚体转动惯量、杨氏模量、长度密度、霍尔效应、单摆、液体表面张力 → 可做到 90~100；
- 单缝衍射、动态磁滞回线 → 卡在状态/操作类判分项（有 45 分左右拿不到），必须真的在软件里把连线、退磁、档位、光强调对；
- 实验报告类成绩（占总成绩 60%）→ 完全不在本工具范围内。

---

## 三、硬性前提

1. **必须先抓一次真实提交**。
   签名 `Key` 覆盖 `UserID + "," + LabID + FileName`，而 `FileName` 含**秒级时间戳**（`UserID+yyyyMMddHHmmss.xml`），无法离线构造。
   → 每个实验都必须「进一次 → 点结束实验」让它提交，才有可复用的 `Key`。

2. **不能杀进程**。必须点界面上的「结束实验」正常退出，否则客户端不上报。

3. **系统代理会被临时修改**。`proxy-on` 会把当前用户的 WinINET 代理指向 `127.0.0.1:8888`，`proxy-off` 还原（自动备份到 `proxy-state.json`）。异常退出后请手动执行一次 `proxy-off`，否则断网。

4. **仅 Windows**：需要 PowerShell 5.1+ 与 .NET Framework 4.x（Win10/11 自带）。

---

## 四、快速开始

```powershell
# 1. 开始抓包（只需一次）
.\1-开始抓包.bat

# 2. 进实验 → 点「结束实验」→ 等提示提交成功
#    每个实验都重复这一步

# 3. 刷分
.\2-一键刷分.bat
#    或命令行：.\tools\Invoke-LabPerfect.ps1 -Apply

# 4. 全部做完后还原代理
.\3-停止抓包.bat
```

批量与调参：

```powershell
cd tools

.\Invoke-LabPerfect.ps1 -Apply -All              # 处理日志里所有实验（自动去重）
.\Invoke-LabPerfect.ps1 -Report -Last 5          # 只看评分结构，判断上限在哪
.\Invoke-LabPerfect.ps1 -Apply -RealTime 1800    # 顺便把用时改成 30 分钟
.\Invoke-LabPerfect.ps1 -Apply -Fill @{ '峰峰值' = '1.234' }   # 给标准值为空的项指定真值
.\Invoke-LabPerfect.ps1 -Apply -NoSynthesize     # 两边都空的项不补造，保持原样
.\Invoke-LabPerfect.ps1 -Apply -Server http://10.0.0.5:8001    # 手动指定服务端
.\Invoke-LabPerfect.ps1 -All -KeepTemp           # 保留中间产物（perfect.xml）排查用
```

### 参数一览

| 参数 | 作用 |
|---|---|
| `-LogPath <path>` | 抓包日志，默认 `tools\capture\requests.log` |
| `-Apply` | 真正发包；不加 = DryRun，只打印报文大小 |
| `-All` | 处理日志里所有提交（默认只处理最新一条） |
| `-Last N` | 只处理最近 N 条 |
| `-RealTime <秒>` | 把 `//Title/User/Time/RealTime` 改成指定值 |
| `-Report` | 只打印评分结构（分值 × 行数 × 标准值有无），不提交 |
| `-Fill @{名称=值}` | 给标准值为空的判分项指定真值（按 `Name` 匹配） |
| `-NoSynthesize` | 两边都空的项不塞 `1`，保持空白 |
| `-Server <url>` | 手动指定服务端；不填则从抓包日志的请求行推断 |
| `-KeepTemp` | 保留临时目录（含解出的原包与 `perfect.xml`） |
| `-Quiet` | 不打印过程 |

---

## 五、工作原理

```
实验客户端 ──结束实验──▶ POST /ServiceAPI/UpdateRecord
                        UserID / LabID / LabName / RecordID / FileName / Content / Key
                                                                    │
                                                    Content = 加密 XML（固定口令）
                                                                    │
                        ┌───────────────────────────────────────────┘
                        ▼
        解密 → 把 RealResult 填成 StdResult → 重新加密 → 原样重放
                        │
                        ▼
        服务端校验（实测返回码）：
            1  = 成功
           -3  = RecordID 不存在
           -4  = Key / FileName / UserID 任一不匹配
```

关键点：**`Key` 只签 `UserID,LabID,FileName`，不包含 `Content`** —— 所以内容可以随便改，签名原样复用。这是整套方案成立的前提，也是这个平台的设计缺陷。

填充规则（`tools/Invoke-LabPerfect.ps1`）：

1. **表格型**（`StdResult`/`RealResult` 里含 `;`）：按行、按列逐格处理，**第 0 列（序号列）不动**；
   真标准值 → 抄进 `RealResult`；`RealResult` 已填 → 反填进 `StdResult`；两边都空 → 同时塞 `1`（`-NoSynthesize` 时跳过）。
   **行内括号有无与原样保持一致**（`(1,2,3)` 仍是 `(1,2,3)`，`1,2,3` 仍不加括号）。
2. **单值型**：真标准值 → 抄；已填 → 反填；都空且有 `JudgeRule` → 塞 `1`（或 `-Fill` 指定的值）。
3. 去重：同一 `RecordID + FileName` 的多份 `Content`，按**解密后「真标准值格子数」**选，打平才比长度；
   全部解不开时退回按长度选；最后按「最后一次出现」排序。

---

## 六、限制清单

| # | 限制 | 影响 |
|---|---|---|
| 1 | 每个实验必须真实提交一次才能拿到 `Key` | 无法「完全离线生成」 |
| 2 | 只能改数值类判分项 | 状态/操作类必须真做 |
| 3 | 依赖固定加密口令与 `Component.dll` | 平台一旦换口令或换组件即失效 |
| 4 | 只验证过明文 HTTP 部署 | HTTPS + 证书固定需额外处理 |
| 5 | `Real=Std` 依赖服务端使用记录内的 `StdResult` 判分 | 若某实验使用独立标准值则不生效 |
| 6 | 占位标准值（`NaN`/`0.000`）的判分项可能永远 0 分 | 这是平台自身的数据问题，非工具可解 |
| 7 | 需杀毒软件对 `HttpSpy.exe` 加信任 | 本地代理易被误报 |
| 8 | 只管实验成绩，不管实验报告 | 总成绩仍受报告分影响 |
| 9 | 脚本会临时改系统代理 | 异常退出记得手动还原 |
| 10 | 不同学校/版本部署的接口可能不同 | 本工具按实测的一套实现，未做兼容层 |

---

## 七、已知问题与环境适配

以下三条不是工具的实现缺陷，而是**宿主环境的坑**，工具里已经做了自动规避，列出来是为了你排查时不至于走弯路。

### 7.1 低完整性目录（Low Mandatory Level）里跑不起来

若仓库放在带 **Low Mandatory Level** 标签的目录（不少机器的非系统盘就是，可用
`icacls <文件>` 查看，输出里会有一行 `Mandatory Label\Low Mandatory Level`），
从这个目录启动的进程也是低完整性，于是：

- `%TEMP%`（Medium 完整性）下的目录**建不了** → 脚本原先直接死在第一行 `New-Item`；
- `Assembly.LoadFrom` 走内存映射，在低完整性 + 透明加密/DLP 过滤驱动下会报
  `FileLoadException: 不支持操作 (HRESULT: 0x80131515)`，或更隐蔽地在 JIT 阶段
  抛 `InvalidProgramException` 让进程直接以 `-532462766` 退出。

现版本的处理：

- 临时目录顺序改为 **脚本目录下的 `.tmp` → `%TEMP%`**，第一个能写就用（`.tmp` 已进 `.gitignore`）；
- `LabDecrypt` 默认 **读字节后 `Assembly.Load(byte[])` 纯内存加载**，全程不落盘、不走 memory-map；
  失败才退回「影子复制到可写目录 + `LoadFrom`」。

验证办法：`.\Invoke-LabPerfect.ps1 -All -KeepTemp` 跑通且打印出 `.tmp\lpf_xxx` 路径即正常。

### 7.2 `Component.dll` 偶发 JIT 崩溃

该 dll 是 .NET 2.x 的混淆程序集（类型名形如 `cwsQigtUY2cZbGk4AvO.*`），在 .NET 4 CLR 下
**偶发**抛出 `System.InvalidProgramException`，进程退出码 `-532462766`，控制台只留一句
「由于 Exception.ToString() 失败，因此无法打印异常字符串」。

现版本对每次 `dec`/`enc` 调用**自动重试 1 次**（先删残留输出再重试），重试恢复成功时会在
末尾打印「解密进程重试过 N 次」。若持续失败，看 Windows 事件查看器 → 应用程序日志里的
异常类型是最快的定位方式。

### 7.3 `Content` 的 URL 编码不统一

多数实验的 `Content` 直接是 base64；少数客户端会先做一次 URL 编码（base64 里的 `+ / =`
变成 `%2B %2F %3D`）。解析时两种都试，谁先解开用谁。

---

## 八、目录结构

```
weblab-toolkit-fix/
├─ 1-开始抓包.bat              启动代理 + 抓包
├─ 2-一键刷分.bat              处理最近一次提交
├─ 3-停止抓包.bat              停止抓包 + 还原代理
├─ 使用说明.md                 详细中文手册
├─ README.md                   本文件
├─ docs\
│  └─ 协议分析.md              提交协议/加密/签名/判分模型的技术笔记
└─ tools/
   ├─ proxy-on.ps1             备份代理 / 启动 HttpSpy / 切换代理
   ├─ proxy-off.ps1            停 HttpSpy / 还原代理
   ├─ Invoke-LabPerfect.ps1    核心：解包 → 填答案 → 重放
   ├─ HttpSpy.exe / .cs        本地抓包代理（HTTP 全量记录，HTTPS CONNECT 隧道）
   ├─ LabDecrypt.exe / .cs     实验数据包加解密（找不到 dll 时自动去 %TEMP%\lab\ 找）
   ├─ build.ps1                用系统 csc.exe 重新编译（无需 SDK）
   ├─ .tmp\                    运行时临时目录（自动创建，已 gitignore）
   └─ USTCORi.SimExp.Instruments.Component.dll
```

---

## 九、返回码 / 常见问题

| 现象 | 含义 | 处理 |
|---|---|---|
| 响应 `1` | 成功 | 刷新网页看成绩 |
| 响应 `-3` | `RecordID` 不存在或已被清理 | 重进一次该实验再刷 |
| 响应 `-4` | `Key`/`FileName`/`UserID` 不匹配 | 说明这次抓包对不上，重抓 |
| `找不到参数 SkipHttpErrorCheck` | 用了旧版脚本 | 更新到本仓库版本（已兼容 PS 5.1） |
| `禁止运行脚本` | 执行策略限制 | 用 `.bat` 入口，已带 `-ExecutionPolicy Bypass` |
| 抓不到包 | 实验进程在改代理前已联网 | 先开抓包，再启动实验 |
| `UnauthorizedAccessException ...Temp...` | 在低完整性目录里跑（见 7.1） | 更新到本版本，临时目录会自动落到 `.tmp` |
| `FileLoadException ... 0x80131515` | dll 从 memory-map 加载被拒（见 7.1） | 更新到本版本（已改纯内存加载） |
| 进程退出码 `-532462766`，无堆栈 | 混淆 dll 的 JIT 崩溃（见 7.2） | 重跑一次；持续失败看事件日志 |
| `没有可写的临时目录` | `.tmp` 与 `%TEMP%` 都不可写 | 把仓库挪到用户目录下再试 |

---

## 十、自行构建

只依赖 Windows 自带的 .NET Framework 编译器，无需 SDK：

```
cd tools
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

构建细节与坑：

- `build.ps1` 会自动在 `Framework64` / `Framework` 下找 `csc.exe`；
- **脚本与 `.cs` 源文件必须带 UTF-8 BOM**。不带 BOM 时，`powershell.exe` 5.1 会按系统
  ANSI 代码页（简体中文系统是 GBK/936）解析 `.ps1`，中文注释直接变成乱码并报语法错误；
  同理老 `csc.exe` 也需要 `/codepage:65001` 才能稳妥读中文——`build.ps1` 里已显式加上；
- 产物字节数应与仓库里的 exe 一致（`HttpSpy.exe` 10240、`LabDecrypt.exe` 9216），
  不一致时只可能是 PE 时间戳 / MVID 差异，功能等价；
- `Component.dll` 是可选依赖：仓库里带了就从同目录加载，没带则自动去 `%TEMP%\lab\<编号>\`
  找（启动过一次实验后就有）。不想在仓库里放第三方二进制，直接删掉这个 dll 即可，
  工具会提示你从客户端复制。

---

## 十一、更新记录

| 版本 | 内容 |
|---|---|
| v1.0 | 初始发布（协议分析 + 抓包代理 + 加解密 + 一键重放） |
| v1.1 | 修复标准答案为空的项无法填空；修复同一题多次下发时取错版本 |
| v1.2 | 去重改为按「真标准值格子数」选卷、按最后出现排序；新增 `-NoSynthesize` |
| v1.3 | 服务端地址改为从请求行推断（不再硬编码），新增 `-Server`；新增 `-KeepTemp`；临时目录适配低完整性环境（`.tmp`）；`LabDecrypt` 改纯内存加载；解密自动重试；表格行括号保持原样；`Content` 兼容 URL 编码；`build.ps1` 修编码与 `/codepage:65001` |

---

## 十二、致谢与声明

- 加解密组件 `USTCORi.SimExp.Instruments.Component.dll` 取自实验客户端，仅用于解析其自身格式。
- 本项目仅做协议分析与可复现性研究，不对任何使用后果负责。
