# 😉winkcode

A coding agent CLI. Built-in tools (read, write, edit, grep, glob, list_dir, exec, web_search, web_fetch, subagent), MCP, skills, session management, and context compaction. Windows only.

Basic functionality only. Still under development; not suitable for production use.

## Building

```bash
v .
```
or
```bash
v -prod .
```

## Usage

Configure custom providers and models in `~/.winkcode/config.json`:

```jsonc
{
  "defaultModel": "custom-model",
  "providers": {
    "example-provider": {
      "api": "openai", // or "anthropic"
      "baseUrl": "https://api.example.com/v1"
    }
  },
  "models": {
    "custom-model": {
      "provider": "example-provider",
      "maxTokens": 8192,
      "contextWindow": 128000,
      "reasoning": true
    }
  }
}
```

API keys in `~/.winkcode/auth.json`:

```json
{
  "example-provider": "sk-..."
}
```

`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and optional `EXA_API_KEY` environment variables are also supported.

Resume previous session:

```bash
winkcode -c
```

---

<img width="979" height="512" alt="image" src="https://github.com/user-attachments/assets/9f3721d5-3b16-4f1a-80c5-7f50cae0e6b4" />
