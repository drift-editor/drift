## Built-in HTTP AI agent helpers
## Talks to OpenAI-compatible chat completions endpoints for model providers.
## The caller (ai_thread.nim) runs this in its own worker thread.

import std/[httpclient, json, strutils, uri]
import ../core/config

type BuiltinModelProvider* = object
  id*: string
  label*: string
  baseUrl*: string
  models*: seq[string]

const BuiltinModelProviders* = [
  BuiltinModelProvider(
    id: "openai",
    label: "OpenAI",
    baseUrl: "https://api.openai.com/v1",
    models: @["gpt-4o", "gpt-4o-mini", "o1", "o3-mini"]
  ),
  BuiltinModelProvider(
    id: "deepseek",
    label: "DeepSeek",
    baseUrl: "https://api.deepseek.com",
    models: @["deepseek-v4-flash", "deepseek-v4-pro"]
  ),
  BuiltinModelProvider(
    id: "moonshot",
    label: "Moonshot",
    baseUrl: "https://api.moonshot.cn/v1",
    models: @["kimi-for-coding"]
  ),
  BuiltinModelProvider(
    id: "groq",
    label: "Groq",
    baseUrl: "https://api.groq.com/openai/v1",
    models: @["llama-3.3-70b-versatile", "mixtral-8x7b-32768", "gemma2-9b-it"]
  ),
  BuiltinModelProvider(
    id: "openrouter",
    label: "OpenRouter",
    baseUrl: "https://openrouter.ai/api/v1",
    models: @["openai/gpt-4o", "anthropic/claude-3.5-sonnet", "deepseek/deepseek-chat"]
  ),
]

proc defaultBaseUrl*(providerId: string): string =
  let p = providerId.toLowerAscii()
  for mp in BuiltinModelProviders:
    if mp.id == p:
      return mp.baseUrl
  return ""

proc providerLabel*(providerId: string): string =
  let p = providerId.toLowerAscii()
  for mp in BuiltinModelProviders:
    if mp.id == p:
      return mp.label
  return p.capitalizeAscii()

proc isHttpAgent*(agentId: string): bool =
  ## Only the built-in agent speaks HTTP directly; everything else uses ACP.
  agentId.toLowerAscii() == "builtin"

proc allBuiltinModels*(): seq[tuple[providerId, model, label: string]] =
  ## Flat list of every built-in model with a display label.
  for mp in BuiltinModelProviders:
    for m in mp.models:
      result.add((mp.id, m, mp.label & " — " & m))

proc makeChatRequest*(config: AppConfig, prompt: string): string =
  ## Build OpenAI-compatible /chat/completions request body.
  let (_, model) = effectiveBuiltinModel(config)
  let messages = %*[{"role": "user", "content": prompt}]
  let body = %*{
    "model": model,
    "messages": messages,
    "stream": false
  }
  return $body

proc doChatCompletion*(config: AppConfig, prompt: string): string =
  ## Synchronous HTTP call to the configured endpoint.
  ## Returns the assistant message content, or an error string starting with
  ## "HTTP error", "Request failed", or "Unexpected response".
  let (providerId, _) = effectiveBuiltinModel(config)
  var baseUrl = config.aiBaseUrl
  if baseUrl.len == 0:
    baseUrl = defaultBaseUrl(providerId)
  if baseUrl.len == 0:
    baseUrl = "https://api.openai.com/v1"
  let url = baseUrl & "/chat/completions"
  let client = newHttpClient(userAgent = "drift/1.0")
  client.headers = newHttpHeaders({
    "Content-Type": "application/json"
  })
  if config.aiApiKey.len > 0:
    client.headers["Authorization"] = "Bearer " & config.aiApiKey
  let body = makeChatRequest(config, prompt)
  try:
    let resp = client.request(url, httpMethod = HttpPost, body = body)
    if resp.code.int div 100 != 2:
      return "HTTP error " & $resp.code & ": " & resp.body
    let j = parseJson(resp.body)
    if j.hasKey("choices") and j["choices"].kind == JArray and j["choices"].len > 0:
      let choice = j["choices"][0]
      if choice.hasKey("message") and choice["message"].hasKey("content"):
        return choice["message"]["content"].getStr()
    return "Unexpected response: " & resp.body
  except CatchableError as e:
    return "Request failed: " & e.msg
  finally:
    client.close()
