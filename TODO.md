# MoonSage 改进 TODO(按优先级)

> 依据 2026-08-07 代码评审生成。每项完成后勾选,并记录修改文件与验证结果。

## P0 安全与正确性

- [x] **1. 修复 clone_repo 目标路径逃逸**
  - 文件: `editing/publish_tools.mbt`、`audit/audit_repo.mbt`
  - 内容: URL 的 `basename` / repo 组件可为 `..`,导致克隆目录逃出 workspace base;需要组件白名单校验 + 目标位于 base 下的验证,并补测试。
  - 完成: 新增 `valid_component` 白名单(`[A-Za-z0-9._-]`、1..100、拒绝 `.`/`..`)、`parse_github_url` 解析后校验、可测试的 `resolve_clone_target_name`,并在 `clone_repo_tool` 加 `target.has_prefix(base + "/")` 纵深防御;`audit/audit_repo.mbt` 同步加固 `parse_github_repo`(该路径克隆目标固定为 `workspace/repo`,无目录逃逸,仅让异常组件提前失败)。新增 `editing/publish_tools_wbtest.mbt` 5 个 + `audit/audit_wbtest.mbt` 1 个测试;`moon test` 116 通过;`.mbti` 无变化。
- [x] **2. run_moon 工具加超时**
  - 文件: `local/local.mbt`
  - 内容: `collect_output` 无超时,命令挂起会永久阻塞会话;加 `with_timeout` 并补测试。
- [x] **3. write_file 补 syncheck 校验**
  - 文件: `editing/write_tools.mbt`
  - 内容: 目前仅 `multi_edit` 有 `moonc syncheck` 门槛,`write_file` 直接落盘;补一致校验并补测试。
- [x] **4. LLM 流式请求加超时与重试**
  - 文件: `llm/llm_stream.mbt`
  - 内容: 非 2xx 响应体读取无超时;网络错误 / 429 / 5xx 无重试;加退避重试(收到内容前)并补测试。

## P1 体验与工程

- [x] **5. 编辑前 diff 预览 + /undo**
  - 文件: `editing/`、`chat/chat.mbt`
  - 内容: 确认写操作前展示 mini diff;会话内维护编辑历史,支持 `/undo` 回滚。
- [x] **6. 上下文压缩改进**
  - 文件: `agent/agent.mbt`
  - 内容: 压缩阈值改为 token 感知估算、按"轮"保留而非按"条"、摘要失败时回退策略。
- [x] **7. 解析并展示 reasoning_content**
  - 文件: `llm/llm_stream.mbt`、`agent/agent.mbt`、`chat/chat.mbt`
  - 内容: 支持 DeepSeek reasoner 的 `reasoning_content` 增量,走 `on_thinking`/`ThinkingDelta` 展示。
- [x] **8. 新增 grep/glob 工具 + list 上限**
  - 文件: `local/local.mbt`
  - 内容: 增加内容搜索与通配符列文件工具,`list_project_files` 加条目上限防止上下文爆炸。
- [x] **9. CI 加 Windows job + fmt/info 一致性检查**
  - 文件: `.github/workflows/ci.yml`
  - 内容: 项目有大量 Windows 专属代码但 CI 只在 ubuntu 跑;补 windows-latest,并加 `moon fmt --check`、`moon info` diff 检查。
- [x] **10. 抽取共享 util 包去重**
  - 文件: 新增 `util` 包;`local/`、`editing/`、`audit/` 的 `safe_path` / `json_string_arg` / `parse_int_or` / `basename` 收敛

## P2 架构与生态(长期)

- [ ] **11. provider 抽象层**: 支持 Anthropic 协议与 Ollama 本地模型,为多模型路由铺路
- [ ] **12. MCP 客户端**: 先 stdio 传输,接入工具注册表
- [ ] **13. headless / JSON 事件输出**: 基于 `EngineEvent` 提供 stream-json / HTTP 服务模式
- [ ] **14. 子代理并行**: 审计分析/修复阶段并行化,或引入 Task 工具
- [ ] **15. 技能/插件加载**: 项目级指令文件与可插拔工具集
