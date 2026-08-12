# MoonSage Rabbita 前端

这是一个基于 `moonbit-community/rabbita` 的简洁 Web 前端。它使用 Rabbita 的 TEA 状态模型管理会话列表、消息流、输入草稿与斜杠菜单，当前以本地演示响应验证交互流程。

```powershell
moon build frontend --target js --release
node frontend/dev_server.mjs
```

浏览器打开 <http://127.0.0.1:8765/frontend/>。入口页面是 `index.html`，样式在 `styles.css`；后续接入真实 Agent 时，只需将 `Submit` 分支替换为 HTTP/WebSocket 命令。
