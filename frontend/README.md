# MoonSage Rabbita 前端

这是一个基于 `moonbit-community/rabbita` 的 Web 前端。它使用 Rabbita 的 TEA 状态模型管理会话列表、消息流、输入草稿与斜杠菜单，并通过同源 `/api/agent` 端点连接 MoonSage Agent。

```powershell
moon build frontend --target js --release
moon build cmd/main --target native --release
$env:MOONSAGE_API_KEY = "your-api-key"
node frontend/dev_server.mjs
```

浏览器打开 <http://127.0.0.1:8765/frontend/>。`MOONSAGE_BASE_URL`、`MOONSAGE_MODEL` 和 `MOONSAGE_PROVIDER` 沿用 CLI 配置，API Key 只保留在服务端。开发服务器优先复用 `_build/native/release` 中的 Agent，以避免每次请求重新启动 MoonBit 构建流程；找不到时回退到 `moon run cmd/main -- ask --stream-json`。状态和回答以 NDJSON 实时传给浏览器，部署时也可将 `MOONSAGE_AGENT_BIN` 指向预构建的 MoonSage 可执行文件。

## Agent 可观测性

协议 v2 将 Agent 生命周期完整透传到浏览器：`tool_started` / `tool_finished`（工具卡片：名称、轮次、参数与结果，可展开）、`thinking`（思考过程折叠面板）、`retry`（重试次数与原因）、`warning`（黄色提示条）、`meta`（上下文截断提示）。回答按 100ms 节流刷新，底部自动吸底（用户上翻时暂停跟随）。生成中可随时点击「停止」：浏览器中断请求，服务端终止 Agent 进程树，已生成的部分回答会被保留。

## 会话与工作区

会话持久化在本机浏览器的 localStorage（每个会话保留最近 60 条消息），刷新页面不丢失；新会话以首条消息自动命名。右上角的 `</>` 按钮打开本地工作区，可浏览和编辑文本文件、查看工作区或暂存区 Diff，并逐文件暂存、取消暂存和提交。服务端将仓库根目录作为工作区，拒绝路径穿越、符号链接、二进制文件、非 UTF-8 文件和超过 1 MB 的文件；`.git`、`.moonsage`、`.mooncakes`、`_build`、`node_modules`、`target` 与 `.env` 不会出现在文件浏览器中，也不能通过文件接口访问。保存文件时按原行尾风格（LF/CRLF）写回，不会产生整文件换行符噪音。

## 安全

服务端仅监听 127.0.0.1，并校验 Host/Origin（防 DNS rebinding）；所有写端点要求 `application/json`；静态文件只暴露 `frontend/` 与 `_build/js/`，`.env`、`.git` 等一律 403；响应统一携带 `nosniff` / `X-Frame-Options` / `Referrer-Policy` 安全头；页面带有 CSP meta。

## 测试

```powershell
moon test -p frontend --target js   # 前端白盒测试
node --test frontend/dev_server.test.mjs   # 服务端集成测试
```
