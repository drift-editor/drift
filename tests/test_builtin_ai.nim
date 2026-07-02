## Tests for built-in HTTP AI agent helpers (conversation history, request body).
import std/[json, strutils]
import ../src/services/builtin_ai
import ../src/core/config

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# --- makeChatRequestHistory: single turn (no history) ---
var cfg = defaultConfig()
cfg.aiModelPreset = "lightweight"
cfg.aiLightweightModelProvider = "deepseek"
cfg.aiLightweightModel = "deepseek-v4-flash"

let body1 = makeChatRequestHistory(cfg, "Hello", @[])
let j1 = parseJson(body1)
assertEq(j1["messages"].len, 1, "single turn has one message")
assertEq(j1["messages"][0]["role"].getStr(), "user", "first message role")
assertEq(j1["messages"][0]["content"].getStr(), "Hello", "first message content")
assertEq(j1["model"].getStr(), "deepseek-v4-flash", "model resolved")
assertEq(j1["stream"].getBool(), false, "stream false")

# --- makeChatRequestHistory: multi-turn with history ---
let history = @[
  (role: "user", content: "What is Nim?"),
  (role: "assistant", content: "Nim is a programming language.")
]
let body2 = makeChatRequestHistory(cfg, "Tell me more", history)
let j2 = parseJson(body2)
assertEq(j2["messages"].len, 3, "multi-turn has 3 messages")
assertEq(j2["messages"][0]["role"].getStr(), "user", "history[0] role")
assertEq(j2["messages"][0]["content"].getStr(), "What is Nim?", "history[0] content")
assertEq(j2["messages"][1]["role"].getStr(), "assistant", "history[1] role")
assertEq(j2["messages"][1]["content"].getStr(), "Nim is a programming language.", "history[1] content")
assertEq(j2["messages"][2]["role"].getStr(), "user", "new prompt role")
assertEq(j2["messages"][2]["content"].getStr(), "Tell me more", "new prompt content")

# --- makeChatRequest (backward compat) still single-turn ---
let body3 = makeChatRequest(cfg, "Solo")
let j3 = parseJson(body3)
assertEq(j3["messages"].len, 1, "makeChatRequest single turn")

# --- ChatTurn type alias and role constants ---
assertEq(ChatRoleUser, "user", "ChatRoleUser constant")
assertEq(ChatRoleAssistant, "assistant", "ChatRoleAssistant constant")

# --- allBuiltinModels honors aiEnabledModels ---
var cfgEnabled = defaultConfig()
cfgEnabled.aiEnabledModels = @["openai/gpt-5.5"]
let enabledModels = allBuiltinModels(cfgEnabled)
assertEq(enabledModels.len > 0, true, "at least one model enabled")
for m in enabledModels:
  assertEq(m.providerId, "openai", "only openai models should be enabled")
let allModels = allBuiltinModels()
assertEq(allModels.len > enabledModels.len, true, "allBuiltinModels should include more when unfiltered")

# --- isBuiltinModelEnabled ---
var cfgModels = defaultConfig()
assertEq(isBuiltinModelEnabled(cfgModels, "deepseek", "deepseek-v4-flash"), true, "empty list enables all")
cfgModels.aiEnabledModels = @["deepseek/deepseek-v4-pro"]
assertEq(isBuiltinModelEnabled(cfgModels, "deepseek", "deepseek-v4-pro"), true, "enabled model")
assertEq(isBuiltinModelEnabled(cfgModels, "deepseek", "deepseek-v4-flash"), false, "disabled model")

# --- doChatCompletionWithModel rejects disabled model ---
var cfgDisabled = defaultConfig()
cfgDisabled.aiEnabledModels = @["openai/gpt-5.5"]
let disabledResult = doChatCompletionWithModel(cfgDisabled, "hi", "deepseek", "deepseek-v4-flash")
assertEq(disabledResult.startsWith("Model disabled"), true, "doChatCompletionWithModel should reject disabled model")

# --- doChatCompletion rejects disabled model via resolveBuiltinModel ---
var cfgPreset = defaultConfig()
cfgPreset.aiModelPreset = "lightweight"
cfgPreset.aiLightweightModelProvider = "deepseek"
cfgPreset.aiLightweightModel = "deepseek-v4-flash"
cfgPreset.aiEnabledModels = @["deepseek/deepseek-v4-pro"]
let presetDisabled = doChatCompletion(cfgPreset, "hello")
assertEq(presetDisabled.startsWith("Model disabled"), true, "doChatCompletion should reject disabled preset model")

# --- Thinking-mode support detection (DeepSeek) ---
assertEq(providerSupportsThinking("deepseek"), true, "deepseek supports thinking")
assertEq(providerSupportsThinking("DeepSeek"), true, "provider check is case-insensitive")
assertEq(providerSupportsThinking("openai"), false, "openai has no thinking toggle")

# --- reasoningVariants: provider-specific effort options ---
assertEq(reasoningVariants("deepseek"), @["high", "max"], "deepseek variants")
assertEq(reasoningVariants("DeepSeek"), @["high", "max"], "variants are case-insensitive")
assertEq(reasoningVariants("openai").len, 0, "openai has no variants yet")

# Simple/history request builders never carry thinking (used by classifier/git paths).
let bodyNoThink = parseJson(makeChatRequestHistory(cfg, "Hi", @[]))
assertEq(bodyNoThink.hasKey("thinking"), false, "history request has no thinking field")

# --- applyThinking: always enables thinking + sets reasoning_effort for DeepSeek ---
var dsBody = %*{"model": "deepseek-v4-pro", "messages": []}
applyThinking(dsBody, "deepseek", "high")
assertEq(dsBody["thinking"]["type"].getStr(), "enabled", "thinking enabled for deepseek")
assertEq(dsBody["reasoning_effort"].getStr(), "high", "reasoning_effort=high injected")

var dsBodyMax = %*{"model": "deepseek-v4-pro", "messages": []}
applyThinking(dsBodyMax, "deepseek", "max")
assertEq(dsBodyMax["reasoning_effort"].getStr(), "max", "reasoning_effort=max injected")

# Unknown effort is ignored (thinking still enabled, no reasoning_effort key).
var dsBodyBad = %*{"model": "deepseek-v4-pro", "messages": []}
applyThinking(dsBodyBad, "deepseek", "bogus")
assertEq(dsBodyBad["thinking"]["type"].getStr(), "enabled", "thinking enabled even with bad effort")
assertEq(dsBodyBad.hasKey("reasoning_effort"), false, "invalid effort not written")

# Non-DeepSeek provider: applyThinking is a no-op (toggle is provider-scoped).
var oaBody = %*{"model": "gpt-5.5", "messages": []}
applyThinking(oaBody, "openai", "high")
assertEq(oaBody.hasKey("thinking"), false, "no thinking field for openai")
assertEq(oaBody.hasKey("reasoning_effort"), false, "no reasoning_effort for openai")

# --- config: reasoning effort default + persistence ---
assertEq(defaultConfig().aiReasoningEffort, "high", "default reasoning effort is high")

# --- assistantTurnJson echoes reasoning_content back on tool-call turns ---
let turnWithTool = assistantTurnJson(AgenticResult(
  content: "",
  reasoning: "let me think",
  toolCalls: @[AIToolCall(id: "c1", name: "read_file", arguments: %*{"path": "a.nim"})]))
assertEq(turnWithTool.hasKey("reasoning_content"), true, "tool turn carries reasoning_content")
assertEq(turnWithTool["reasoning_content"].getStr(), "let me think", "reasoning_content value")

# A plain assistant turn with no reasoning has no reasoning_content field.
let turnPlain = assistantTurnJson(AgenticResult(content: "done"))
assertEq(turnPlain.hasKey("reasoning_content"), false, "plain turn omits reasoning_content")

echo "All built-in AI tests passed!"