## Clipboard ring helper tests

import ../src/app/app as appmod
import ../src/core/config

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

let cfg = defaultConfig()
var app = createApp(cfg)

# Empty ring
assertEq(app.clipboardHistory.len, 0, "history starts empty")
assertEq(app.clipboardHistoryIndex, 0, "index starts at 0")

# Push items
app.pushClipboardHistory("alpha")
app.pushClipboardHistory("beta")
app.pushClipboardHistory("gamma")
assertEq(app.clipboardHistory.len, 3, "history has 3 items")
assertEq(app.clipboardHistory[0], "gamma", "most recent at front")

# Duplicate moves to front, no growth
app.pushClipboardHistory("alpha")
assertEq(app.clipboardHistory.len, 3, "duplicate does not grow list")
assertEq(app.clipboardHistory[0], "alpha", "duplicate moved to front")

# Cap at configured size
for i in 0 ..< 20:
  app.pushClipboardHistory($i)
assertEq(app.clipboardHistory.len, cfg.clipboardHistorySize, "history capped to config size")
assertEq(app.clipboardHistory[0], "19", "newest remains at front after cap")

# Empty text is ignored
let prevLen = app.clipboardHistory.len
app.pushClipboardHistory("")
assertEq(app.clipboardHistory.len, prevLen, "empty text ignored")

# Zero-size config ignores pushes
var app2 = createApp(defaultConfig())
app2.config.clipboardHistorySize = 0
app2.pushClipboardHistory("x")
assertEq(app2.clipboardHistory.len, 0, "zero size config ignores push")

echo "clipboard ring tests passed"
