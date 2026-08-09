# MoonSage

MoonSage 是一个面向 [Mooncakes](https://mooncakes.io/)（MoonBit 包生态）的智能体工具。它结合了确定性的包搜索与可选的 LLM Agent，能够规划多步研究、查阅实时 manifest 与文档，并返回带有来源的推荐；还可以对远程包进行审计，甚至在确认后自动修复问题。

## 功能

- **search** — 无需 LLM，用关键词对 Mooncakes 全量元数据做确定性搜索与排序，输出带来源链接的推荐。
- **ask** — 基于 DeepSeek（或任意 OpenAI 兼容 API）的 Agent：流式输出（SSE），自动规划、搜索、查 manifest / module index / package docs，最后用中文给出带引用的结论。终端输出会将 Markdown 渲染为 ANSI 样式。
- **audit** — 远程审计：克隆指定包的 GitHub 源码，建立 `moon build` / `moon test` 基线，由专用 Agent 检查代码；`--fix` 模式下可自动修复并重跑测试验证，最后输出审计报告与 `git diff`。

## 环境要求

- [MoonBit 工具链](https://www.moonbitlang.com/download)（`moon` 命令）
- `git`（audit 功能需要）
- 一个 OpenAI 兼容的 API Key（仅 `ask` / `audit` 需要）

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
```

`audit` 流程：解析 manifest → `git clone --depth 1` 源码 → 定位项目根 → 专用 Agent（独立预算，默认 30 次工具调用）检查/修复 → 输出中文报告与 `git diff`。工具包括 `list_project_files` / `read_file` / `run_moon` / `git_diff`，`--fix` 时追加 `multi_edit` / `write_file` / `remove`（带路径穿越防护与三种确认模式）。已有文件优先使用局部 `multi_edit`，改动只发生在克隆的工作区内。

## 配置

配置读取自进程环境变量，未设置时回退到项目根目录的 `.env` 文件：

| 变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `MOONSAGE_API_KEY` | ask/audit 需要 | — | OpenAI 兼容 API Key |
| `MOONSAGE_BASE_URL` | 否 | `https://api.deepseek.com` | API 端点 |
| `MOONSAGE_MODEL` | 否 | `deepseek-chat` | 模型名 |

`.env` 已被 git 忽略，不要把 Key 提交到仓库。

## 项目结构

MoonSage 拆分为职责单一的多个子包，依赖单向无环：

```
moonsage/            领域层：数据模型、搜索、确定性搜索 Agent、响应压缩
moonsage/mooncakes   网络层：拉取 modules / manifest / docs
moonsage/llm         LLM 流式协议：SSE 解析 + stream_chat_completion
moonsage/tools       工具契约：ToolSchema / Tool / 注册表（零项目依赖）
moonsage/agent       通用 LLM Agent 运行时（循环、预算、纯文本兜底）
moonsage/audit       远程审计：审计工具、源码克隆、报告渲染
moonsage/md_ansi     Markdown → ANSI 终端渲染
moonsage/dotenv      .env 加载
moonsage/cmd/main    应用壳：CLI 分发
```

`ask` 与 `audit` 共用同一个 `@agent.Agent` 循环，各自只提供工具集、提示词与预算。

## 开发

```shell
moon check   # 静态检查
moon test    # 运行测试（66 个）
moon fmt     # 格式化
moon info    # 更新包接口
```
