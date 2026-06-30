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

echo "All built-in AI tests passed!"