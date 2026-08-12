# MoonSage Rabbita 前端

这是一个基于 `moonbit-community/rabbita` 的 Web 前端。它使用 Rabbita 的 TEA 状态模型管理会话列表、消息流、输入草稿与斜杠菜单，并通过同源 `/api/agent` 端点连接 MoonSage Agent。

```powershell
moon build frontend --target js --release
$env:MOONSAGE_API_KEY = "your-api-key"
node frontend/dev_server.mjs
```

浏览器打开 <http://127.0.0.1:8765/frontend/>。`MOONSAGE_BASE_URL`、`MOONSAGE_MODEL` 和 `MOONSAGE_PROVIDER` 沿用 CLI 配置，API Key 只保留在服务端。开发服务器默认通过 `moon run cmd/main -- ask --stream-json` 调用 Agent；部署时可将 `MOONSAGE_AGENT_BIN` 指向预构建的 MoonSage 可执行文件。
