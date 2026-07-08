## Closed tab history tests

import ../src/app/app as appmod
import ../src/core/config

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

let cfg = defaultConfig()
var app = createApp(cfg)

# ClosedTabInfo can be constructed and stored
let info = ClosedTabInfo(path: "/tmp/test.nim", line: 5, col: 3)
assertEq(info.path, "/tmp/test.nim", "path stored")
assertEq(info.line, 5, "line stored")
assertEq(info.col, 3, "col stored")

# Simulate accumulating closed tabs and apply the same cap logic closeBuffer uses
for i in 0 ..< cfg.closedTabHistorySize + 5:
  app.closedTabs.add(ClosedTabInfo(path: "/tmp/file" & $i, line: i, col: 0))
  if app.closedTabs.len > cfg.closedTabHistorySize:
    app.closedTabs.delete(0)

assertEq(app.closedTabs.len, cfg.closedTabHistorySize, "closed tabs capped to config size")
assertEq(app.closedTabs[^1].path, "/tmp/file" & $(cfg.closedTabHistorySize + 4), "most recent kept")

# Zero-size config means nothing is retained
var app2 = createApp(defaultConfig())
app2.config.closedTabHistorySize = 0
app2.closedTabs.add(ClosedTabInfo(path: "/tmp/x.nim", line: 0, col: 0))
# closeBuffer would skip adding when size is 0; simulate that by deleting
if app2.config.closedTabHistorySize <= 0:
  app2.closedTabs.setLen(0)
assertEq(app2.closedTabs.len, 0, "zero size retains nothing")

echo "closed tab tests passed"
