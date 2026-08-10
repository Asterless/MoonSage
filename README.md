# MoonSage

MoonSage 是一个面向 [Mooncakes](https://mooncakes.io/)（MoonBit 包生态）的 MoonBit 原生智能体工具。它结合了确定性的包搜索与可选的 LLM Agent，能够规划多步研究、查阅实时 manifest 与文档、操作本地项目，并对远程包进行审计和验证修复。

## 功能

- **search** — 无需 LLM，用关键词对 Mooncakes 全量元数据做确定性搜索与排序，输出带来源链接的推荐。
- **ask** — 支持 OpenAI 兼容、Anthropic 与 Ollama 协议的单次 Agent 问答；可搜索包、读取实时 API 文档、并行委派独立研究，并以终端 Markdown 或 JSON Lines 输出结果。
- **chat** — 经典行输入交互会话，保留标准终端输入输出行为，并支持会话恢复与本地项目工具。
- **tui** — 独立的增强终端界面，提供内联编辑、斜杠命令菜单、状态信息与 Markdown ANSI 渲染。
- **frontend** — 基于 Rabbita 的简洁 Web 前端，提供会话导航、消息流、中文输入与命令菜单。
- **audit** — 远程审计：克隆指定包源码，建立 `moon build` / `moon test` 基线，由专用 Agent 检查代码；`--fix` 模式下可自动修复并重跑验证，最后输出报告、结构化证据与 `git diff`。

## 环境要求

- [MoonBit 工具链](https://www.moonbitlang.com/download)（`moon` 命令）
- `git`（audit 功能需要）
- 所选模型服务的 API Key（`chat` / `ask` / `audit` 需要；本地 Ollama 可按服务配置）
- `gh`（仅自动创建 GitHub PR 时需要）

## 快速开始

```powershell
# 1. 克隆并进入项目
git clone https://github.com/Asterless/MoonSage.git
cd MoonSage

# 2. 配置 API Key（复制示例并填写）
Copy-Item .env.example .env
# 编辑 .env，填入 MOONSAGE_API_KEY

# 3. 运行
moon run cmd/main -- search "json parser"          # 确定性搜索（无需 Key）
moon run cmd/main -- ask "帮我找一个 HTTP 客户端"   # LLM Agent
moon run cmd/main -- chat                           # 交互式本地 Agent
moon run cmd/main -- tui                            # 增强终端界面
moon build frontend --target js --release           # Rabbita Web 前端
```

## 命令

### search — 确定性包搜索

```shell
moon run cmd/main -- search <关键词>
```

`search` 读取 Mooncakes 全量模块元数据，按关键词打分排序，输出包名、版本、描述、许可证、评分与文档链接。不需要 LLM Key。

### ask — LLM Agent 问答

```powershell
moon run cmd/main -- ask "帮我找一个适合 native 后端的 HTTP 客户端"
```

Agent 工作流：翻译意图 → 搜索候选 → 查 manifest → 查 module index → 查 package docs → 汇总带引用的中文结论。输出通过 SSE 流式到达，并在终端渲染成 ANSI 样式（标题、粗体、行内代码、链接等）。

用于脚本和 CI 时，可启用 JSON Lines 输出。该模式的标准输出只包含一行一个 JSON 事件，不混入 ANSI、标题或 trace 文本：

```powershell
moon run cmd/main -- ask --stream-json "find an HTTP client"
```

事件类型包括 `thinking_delta`、`tool_started`、`tool_finished`、`retrying`、`final_started`、`final_delta` 与 `error`。工具事件包含回合号、调用 ID、名称、参数、状态和结果，便于调用方重建完整执行过程。

`ask` 还支持通过 `MOONSAGE_MCP` 接入一个显式的 stdio MCP 服务。发现的工具会以 `mcp_<server>_<tool>` 命名，并在每次发现或调用结束后终止服务进程：

```powershell
$env:MOONSAGE_MCP = '{"name":"files","command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","D:/work"]}'
moon run cmd/main -- ask "检查项目文件"
```

只应配置可信的 MCP 命令，因为服务进程继承 MoonSage 的本地权限。对于彼此独立的包研究，Agent 也可使用只读的 `delegate_task` 子代理，最多并发执行 3 个相邻委派，并按请求顺序返回结果。

### chat — 可恢复的交互会话

```powershell
moon run cmd/main -- chat
moon run cmd/main -- chat --session demo   # 创建或恢复指定会话
moon run cmd/main -- chat --continue       # 恢复最近会话
```

`chat` 提供项目文件搜索、读取、`moon` 命令、Git diff 和受确认保护的写入工具。使用 `/help` 查看命令，`/undo` 撤销最近一次文件编辑，`/exit` 或 `/quit` 离开会话。会话保存在 `.moonsage/sessions/`，长会话会在保留完整最近轮次的前提下自动压缩。`ask` 与 `chat` 都会读取启动目录下的 `AGENTS.md` 和 `CLAUDE.md`，按此顺序加入系统提示，每个文件最多读取 12,000 字节。

### tui — 增强终端界面

```powershell
moon run cmd/main -- tui
moon run cmd/main -- tui --session demo   # 创建或恢复指定会话
moon run cmd/main -- tui --continue       # 恢复最近会话
```

`tui` 与 `chat` 共用 Agent、工具与持久会话，但界面实现完全独立。`chat` 继续使用经典的逐行 stdin/stdout 交互；`tui` 提供中文内联输入、字符级编辑、输入 `/` 后的命令菜单、更多状态信息及 Markdown 终端渲染。

`frontend` 是浏览器端 Rabbita 界面，当前用本地演示响应验证交互；构建后可用 `py -3 -m http.server 8765` 提供静态页面。

### audit — 远程审计与自动修复

```powershell
# 只读审计（默认，不改代码）
moon run cmd/main -- audit moonbit-community/cmark

# 修复模式：写每个文件前逐条确认
moon run cmd/main -- audit moonbit-community/cmark --fix --confirm prompt

# 修复模式：最后统一展示 diff（默认）
moon run cmd/main -- audit moonbit-community/cmark --fix --confirm diff

# 修复模式：跳过确认直接改
moon run cmd/main -- audit moonbit-community/cmark --fix --yes

# 保留工作区便于查看 / 导出补丁
moon run cmd/main -- audit moonbit-community/cmark --fix --workspace ./audit-ws

# 修复、验证、推送分支并创建 PR
moon run cmd/main -- audit moonbit-community/cmark --fix --pr

# 清理之前遗留的临时审计工作区
moon run cmd/main -- audit --clean
```

`audit` 流程：解析 manifest → `git clone --depth 1` 源码 → 定位项目根 → 建立构建和测试基线 → 专用 Agent（独立预算，默认 30 次工具调用）检查/修复 → 输出中文报告、结构化工具证据与 `git diff`。工具包括 `list_project_files` / `read_file` / `run_moon` / `git_diff`，`--fix` 时追加 `multi_edit` / `write_file` / `remove`（带路径穿越防护与三种确认模式）。已有文件优先使用局部 `multi_edit`，改动只发生在克隆的工作区内；每次成功编辑后的验证结果会根据实际 `run_moon` 退出码记录，报告与证据冲突时会明确提示。

`--pr` 需要已登录的 GitHub CLI。MoonSage 会创建 `moonsage/fix-<repo>` 分支、提交并推送修复；没有上游写权限时先 fork，再向原仓库创建 PR。

## 配置

配置读取自进程环境变量，未设置时回退到项目根目录的 `.env` 文件：

| 变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `MOONSAGE_API_KEY` | chat/ask/audit 需要 | — | 所选 provider 的 API Key |
| `MOONSAGE_BASE_URL` | 否 | `https://api.deepseek.com` | API 端点 |
| `MOONSAGE_MODEL` | 否 | `deepseek-chat` | 模型名 |
| `MOONSAGE_PROVIDER` | 否 | `openai` | 协议：`openai`、`anthropic` 或 `ollama` |
| `MOONSAGE_MCP` | 否 | 空 | 单个 stdio MCP 服务的 JSON 配置，仅 `ask` 使用 |

`.env` 已被 git 忽略，不要把 Key 提交到仓库。
当前 CLI 要求 `MOONSAGE_API_KEY` 为非空字符串；连接无需认证的本地
Ollama 时可设置任意非空占位值。

## 项目结构

MoonSage 拆分为职责单一的多个子包，依赖单向无环：

```
moonsage/            领域层：数据模型、搜索、确定性搜索 Agent、响应压缩
moonsage/mooncakes   网络层：拉取 modules / manifest / docs
moonsage/llm         多 provider LLM 流式协议、SSE 解析、重试与增量去重
moonsage/tools       工具契约、注册表与 stdio MCP 客户端
moonsage/agent       通用 Agent 运行时：事件、预算、压缩、子代理、项目指令
moonsage/chat        经典行输入会话、持久化与共享 Agent 配置
moonsage/tui         独立增强终端界面与输入事件处理
moonsage/frontend    Rabbita Web 前端与静态页面
moonsage/local       本地项目只读工具与命令执行
moonsage/editing     受确认和语法检查保护的编辑、克隆与 PR 工具
moonsage/audit       远程审计：审计工具、源码克隆、报告渲染
moonsage/md_ansi     Markdown → ANSI 终端渲染
moonsage/dotenv      .env 加载
moonsage/cmd/main    应用壳：CLI 分发
```

`ask` 与 `audit` 共用同一个 `@agent.Agent` 循环，各自只提供工具集、提示词与预算。

## 开发

```shell
moon check   # 静态检查
moon info    # 更新包接口
moon fmt     # 格式化
moon test    # 运行测试
```
