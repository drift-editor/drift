import ../src/ui/ai_panel
import uirelays/input

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# --- newAIPanel defaults ---
var panel = newAIPanel()
assertEq(panel.messages.len, 0, "new panel has no messages")
assertEq(panel.inputText, "", "new panel input empty")
assertEq(panel.cursorPos, 0, "new panel cursor at 0")
assertEq(panel.isStreaming, false, "new panel not streaming")
assertEq(panel.placeholder, "Ask AI...", "default placeholder")

# --- sendCurrentMessage ---
var sentText = ""
panel.onSend = proc(text: string) =
  sentText = text

panel.inputText = "Hello, AI"
panel.cursorPos = panel.inputText.len
panel.sendCurrentMessage()
assertEq(panel.messages.len, 1, "one message after send")
assertEq(panel.messages[0].role, "user", "message role is user")
assertEq(panel.messages[0].content, "Hello, AI", "message content")
assertEq(panel.inputText, "", "input cleared")
assertEq(panel.cursorPos, 0, "cursor reset")
assertEq(sentText, "Hello, AI", "onSend callback received text")

# --- appendText / finalizeMessage ---
panel.appendText("Hello")
assertEq(panel.messages.len, 2, "assistant message created")
assertEq(panel.messages[^1].role, "assistant", "assistant role")
assertEq(panel.messages[^1].content, "Hello", "first chunk")
assertEq(panel.isStreaming, true, "streaming after append")

panel.appendText(" world")
assertEq(panel.messages[^1].content, "Hello world", "chunk appended")

panel.finalizeMessage()
assertEq(panel.isStreaming, false, "not streaming after finalize")

# --- clearChat ---
panel.clearChat()
assertEq(panel.messages.len, 0, "messages cleared")
assertEq(panel.inputText, "", "input cleared")
assertEq(panel.cursorPos, 0, "cursor reset")
assertEq(panel.isStreaming, false, "streaming cleared")

# --- placeholder customization ---
var panel2 = newAIPanel("Ask Kimi...")
assertEq(panel2.placeholder, "Ask Kimi...", "custom placeholder")

# --- copyLastAssistantMessage ---
var panel3 = newAIPanel()
panel3.messages.add(ChatMessage(role: "user", content: "question"))
panel3.messages.add(ChatMessage(role: "assistant", content: "answer"))
assertEq(panel3.copyLastAssistantMessage(), true, "copy found assistant")
assertEq(getClipboardText(), "answer", "clipboard has answer")
assertEq(panel3.copyMessageAt(0), true, "copy user message")
assertEq(getClipboardText(), "question", "clipboard has question")
assertEq(panel3.copyMessageAt(-1), false, "invalid index fails")
assertEq(panel3.copyLastAssistantMessage(), true, "still copies assistant")
assertEq(getClipboardText(), "answer", "clipboard has answer again")

# --- empty panel copy ---
var panel4 = newAIPanel()
assertEq(panel4.copyLastAssistantMessage(), false, "no assistant to copy")

# --- whitespace-only send is ignored ---
var panel5 = newAIPanel()
var called = false
panel5.onSend = proc(text: string) = called = true
panel5.inputText = "   \n  "
panel5.sendCurrentMessage()
assertEq(called, false, "whitespace-only input not sent")
assertEq(panel5.messages.len, 0, "no message added")

echo "All AI panel tests passed!"
