# DeepSeek Key Switcher

一个 Windows 托盘小工具：**多把 DeepSeek API key 一键切换**，一次点击把本机所有 AI 编码客户端切到同一把 key，并统一下发模型与推理档位。

纯 PowerShell + WinForms，零依赖、零安装、无后台服务。

```
左键单击托盘图标  →  立刻在 公司 key ↔ 个人 key 之间来回切
右键托盘图标     →  选择具体 key、开关自动重启、编辑密钥、开机自启
```

---

## 解决什么问题

手里有公司发的 key 和自己的 key，需要在多个 AI 编码工具之间频繁切换：

| 客户端 | key 存在哪 |
|---|---|
| **codex**（CLI + 桌面版） | `~/.codex/config.toml` 的 provider `http_headers`、`~/.codex/auth.json` |
| **DeepSeek Harness (dsh)** | `~/.dsh/.env` |
| **Reasonix** | `%APPDATA%\reasonix\.env`（两处变量） |
| **Hypercode**（opencode fork） | `~/.local/share/hypercode/auth.json` |

每个工具的配置格式都不一样（TOML / YAML / JSON / .env），手动改一遍要开四个文件、还可能漏改。这个工具把它们收进一个动作里。

---

## 功能

- **一键切换**：托盘左键单击 = 换另一把 key；右键菜单可选具体槽位
- **统一下发模型**：`model = deepseek-flash`（即 DeepSeek V4.1 Flash 1017）、`reasoning effort = max`（codex 侧映射为它自己的最高档 `xhigh`）
- **自动重启客户端**：切换后只重启「需要重启且当前正在运行」的客户端（见下方对照表）
- **切换前整份备份**：8 个目标文件备份到 `backups/<时间戳>/`，保留最近 30 次，随时可回滚
- **定点改写**：只替换目标字段的行，不重排文件、不破坏你手写的注释和其它配置
- **失败隔离**：8 个目标互相独立，某一项失败（比如没装某个客户端）只记日志，不影响其它项
- **单实例**：重复双击只会保留一个托盘，命名 Mutex 加锁
- **开机自启**：托盘菜单里一键开关

---

## 快速开始

### 1. 拿到文件

把整个目录放到任意位置（脚本用 `$PSScriptRoot` 定位，路径随意），例如：

```
C:\Tools\ds-key-switcher\
```

### 2. 填 key

```powershell
Copy-Item secrets.env.example secrets.env
notepad secrets.env
```

```ini
COMPANY=sk-你的公司key
PERSONAL=sk-你自己的key
```

> 两个槽的名字固定是 `company` / `personal`，可以只填一个。

### 3. 启动托盘

双击 `start-tray.vbs`（无窗口启动）。

Windows 11 默认把新托盘图标收进右下角 `^` 折叠区，可以拖到任务栏上常驻。

### 4. 切一次试试

左键单击托盘图标，气泡会告诉你切到了哪把 key（显示 key 尾号）。

---

## 给 AI Agent 的安装指令

把下面这段直接丢给你的 AI agent（Claude Code / Codex / Cursor / Reasonix 等）：

````text
帮我在本机安装并配置 DeepSeek Key Switcher（Windows 托盘工具，纯 PowerShell）。

仓库：https://github.com/baeut/ds-key-switcher

步骤：
1. 克隆到 C:\Tools\ds-key-switcher（或任意目录）
2. 复制 secrets.env.example 为 secrets.env
3. 问我公司 key 和自己的 key，写进 COMPANY= / PERSONAL=（只要 sk- 开头的串）
4. 运行一次演练确认 8 个写入点都能解析到：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\switch-core.ps1 -Profile personal -DryRun
5. 真实切到我指定的 key：
   powershell -NoProfile -ExecutionPolicy Bypass -File .\switch-core.ps1 -Profile personal -RestartClients
6. 双击 start-tray.vbs 启动托盘，确认进程存在（powershell -File tray.ps1）
7. 把结果（哪些客户端写成功、哪些跳过、哪些失败）报给我

注意：
- 不要提交 secrets.env（已在 .gitignore）
- 如果某个客户端没安装，对应写入点会记一条 FAIL 到 switch.log，这是预期的，不影响其它客户端
- 切换后需要重启的客户端，加 -RestartClients 会自动处理
````

### Agent 排障清单

| 现象 | 原因 / 处理 |
|---|---|
| `找不到 <路径>` | 该客户端没装或配置目录不存在，跳过即可，不影响其它项 |
| `secrets.env 里的 X= 还没填 key` | 模板没填，`COMPANY` / `PERSONAL` 至少填一个 |
| 托盘双击没反应 | 检查 `tray.ps1` 是否已在跑（单实例锁会静默退出）；看 `switch.log` |
| 切换了但客户端还在用旧 key | 该客户端需要重启；确认 `-RestartClients` 有没有加，或托盘里「切换后自动重启客户端」是否被关掉 |
| 弹出一个空白黑窗 | 旧版本的 bug（会独立重启 `codex.exe` 控制台程序），更新到当前版本 |

---

## 命令行用法

```powershell
# 只写配置，不重启任何客户端
powershell -NoProfile -ExecutionPolicy Bypass -File switch-core.ps1 -Profile company

# 写配置 + 重启需要重启的客户端
powershell -NoProfile -ExecutionPolicy Bypass -File switch-core.ps1 -Profile personal -RestartClients

# 演练：不碰真实配置，把结果写到 dryrun/ 供 diff
powershell -NoProfile -ExecutionPolicy Bypass -File switch-core.ps1 -Profile personal -DryRun
```

输出是一行 JSON 摘要（`profile` / `model` / `effort` / `keyTail` / `items[]` / `restarts[]`），方便 agent 解析。

也可以双击目录里的 `切到公司.bat` / `切到个人.bat`（等价于带 `-RestartClients` 的命令行）。

---

## 各客户端的生效方式

| 客户端 | 是否要重启 | 依据 |
|---|---|---|
| Reasonix | **不用**，立即生效 | 每次请求读 `.env` |
| codex CLI | **不用** | 每次启动读 `config.toml` |
| codex 桌面版 | 要重启**桌面版** | `app-server` 由桌面版通过 stdio 托管，配置只在启动时读 |
| DeepSeek Harness | 要重启 | `.env` 只在启动时 `loadEnv` 一次（`cordis.patch.yml` 的模型/档位有 watch 会热重载，但 key 不行） |
| Hypercode | 要重启 | `auth.json` 在启动时读取 |

`clients.ps1` 里的自动重启规则：

| 客户端 | 处理 |
|---|---|
| Reasonix | 跳过（热生效，重启只会白断会话） |
| codex CLI | 跳过（`codex.exe` 是控制台程序，独立拉起会弹一个永不消失的空白黑窗，还会和桌面版的 stdio 托管脱钩） |
| Codex 桌面版 | 重启：杀 `ChatGPT.exe` 主进程，按 AUMID 重新拉起（AUMID 用 `Get-StartApps` 动态查） |
| DeepSeek Harness | 重启 `DeepSeek Harness.exe` 主进程 |
| Hypercode | 重启 `HyperCode.exe` |

---

## 工作原理

一次切换 = 对 8 个文件做定点行替换：

| 目标 | 文件 | 改什么 |
|---|---|---|
| codex | `~/.codex/config.toml` | 顶层 `model`、`model_reasoning_effort`、`[model_providers.deepseek]` 的 `http_headers` |
| codex | `~/.codex/auth.json` | `OPENAI_API_KEY` |
| dsh | `~/.dsh/.env` | `DEEPSEEK_API_KEY` |
| dsh | `~/.dsh/profiles/desktop/cordis.patch.yml` | `agent-default-model` 块的 `provider` / `model` / `reasoningEffort` |
| Reasonix | `%APPDATA%\reasonix\.env` | `DEEPSEEK_API_KEY` 和所有 `REASONIX_CONNECTION_*_KEY` |
| Reasonix | `%APPDATA%\reasonix\config.toml` | `default_model`、`[agent]` 的 `planner_model` / `subagent_model` / `subagent_effort` |
| Hypercode | `~/.local/share/hypercode/auth.json` | `deepseek.key` |
| Hypercode | `~/.config/hypercode/hypercode.jsonc` | `agent.build.model` / `variant` |

设计上的几个取舍：

- **不用序列化器**：TOML/YAML/JSON 一律按行/定点替换。用 `ConvertTo-Json` 之类会重排整个文件，把用户的注释和排版全毁掉。
- **原子写**：先写 `.dstmp` 再 `Move-Item -Force`，避免写一半断电留下半个文件。
- **失败隔离**：每个目标包在独立 `try/catch` 里，结果收集进 JSON，托盘点一次就能看到全部明细。

---

## 自定义模型

模型和档位是 `switch-core.ps1` 顶部的常量：

```powershell
$ModelId        = 'deepseek-flash'          # = DeepSeek V4.1 Flash 1017
$EffortMax      = 'max'                     # 官方 reasoning 合法值：low / high / max
$EffortCodex    = 'xhigh'                   # codex 只认到 xhigh，没有 max
$ReasonixModel  = 'deepseek/deepseek-flash'
$HypercodeModel = 'deepseek/deepseek-flash'
```

要换成 `deepseek-v4-pro` 就改这几行。各客户端的模型 ID 格式不一样（codex/dsh 是裸 ID，Reasonix/Hypercode 是 `provider/model`），所以分开定义。

想加第三把 key：在 `secrets.env` 加一行 `THIRD=sk-...`，再把 `switch-core.ps1` 的 `ValidateSet('company','personal')` 和托盘菜单的 `@('company','personal')` 一起扩上。

---

## 安全说明

- 密钥只存在本地 `secrets.env`，已在 `.gitignore` 里排除
- 工具不做任何网络请求（除非你手动用 key 调 API 验证）
- `backups/` 里是历史配置快照，**包含明文 key**，同样被 `.gitignore` 排除
- 托盘气泡只显示 key 的后 4 位，不打印完整 key
- 本工具直接改写其它客户端的配置文件；出错时从 `backups/<时间戳>/` 拷回即可

---

## 文件结构

```
ds-key-switcher/
├─ start-tray.vbs        无窗口启动托盘
├─ tray.ps1              托盘本体（WinForms NotifyIcon）
├─ switch-core.ps1       核心：8 个写入点 + 备份 + 校验
├─ clients.ps1           客户端重启助手（进程识别 / 重启 / AUMID）
├─ secrets.env.example   密钥模板
├─ 切到公司.bat          双击切换（带自动重启）
├─ 切到个人.bat
├─ .gitignore
├─ README.md
├─ secrets.env           ← 你自己填，不入库
├─ state.json            ← 当前生效的槽位，不入库
├─ switch.log            ← 切换历史，不入库
└─ backups/<时间戳>/      ← 每次切换前的快照，不入库
```

---

## 边界

- 只支持 Windows（依赖 WinForms 托盘、`Get-StartApps`、Windows 进程模型）
- 只做 DeepSeek key 的切换；`~/.codex/config.toml` 里给 Claude Code 用的 `ANTHROPIC_AUTH_TOKEN` 不在托管范围
- 客户端升级后如果改了配置字段名，需要跟着更新 `switch-core.ps1` 里对应的替换规则

---

## License

MIT
