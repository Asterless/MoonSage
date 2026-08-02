# MoonSage

MoonSage is a MoonBit-native tool-calling agent for discovering packages in the
[Mooncakes](https://mooncakes.io/) registry. It combines deterministic package
search with an optional DeepSeek-powered agent that can plan multi-step
research, inspect live manifests, and return cited recommendations.

## Run

```shell
moon run cmd/main -- search "json parser"
```

`search` does not require an LLM key. To use the agent, configure an API key in
the current shell and run `ask`:

```powershell
$env:MOONSAGE_API_KEY="your-key"
moon run cmd/main -- ask "帮我找一个适合 native 后端的 HTTP 客户端"
```

Optional configuration:

```powershell
$env:MOONSAGE_BASE_URL="https://api.deepseek.com"
$env:MOONSAGE_MODEL="deepseek-chat"
```

MoonSage reads credentials from the process environment. Do not commit API
keys to source files or `.env` files.

## Agent loop

The `ask` command runs an observable tool loop with a maximum of six model
rounds, twelve total tool calls, and four package-document reads:

1. Translate the user's intent into package research steps.
2. Call `search_modules` with concise technical keywords.
3. Call `get_module_manifest` for relevant candidates.
4. Call `get_module_index` to discover packages and public symbols.
5. Call `get_package_docs` for API signatures and docstrings.
6. Feed tool observations back to the model.
7. Return an answer in the user's language with Mooncakes documentation URLs.

Mooncakes requests use `moonbitlang/async/http`. The `ask` command streams
chat completions directly from any OpenAI-compatible API (e.g. DeepSeek) over
SSE (`text/event-stream`): it reads the response body incrementally, parses
each `data:` delta, and assembles text and tool calls as they arrive. No
third-party LLM SDK is required, and runtime execution does not depend on curl
or another external program.

## Development

```shell
moon check
moon test
moon info
moon fmt
```
