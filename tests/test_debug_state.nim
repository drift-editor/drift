import std/json
import ../src/core/debug_types

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# Line number conversions
assertEq(toDAPLine(0), 1, "toDAPLine(0)")
assertEq(toDAPLine(10), 11, "toDAPLine(10)")
assertEq(fromDAPLine(1), 0, "fromDAPLine(1)")
assertEq(fromDAPLine(11), 10, "fromDAPLine(11)")

# State helpers
assertEq(canStart(dssOff), true, "canStart off")
assertEq(canStart(dssError), true, "canStart error")
assertEq(canStart(dssTerminated), true, "canStart terminated")
assertEq(canStart(dssRunning), false, "canStart running")
assertEq(canStart(dssStopped), false, "canStart stopped")

assertEq(canContinue(dssStopped), true, "canContinue stopped")
assertEq(canContinue(dssRunning), false, "canContinue running")
assertEq(canContinue(dssOff), false, "canContinue off")

assertEq(canStep(dssStopped), true, "canStep stopped")
assertEq(canStep(dssRunning), false, "canStep running")

assertEq(isActive(dssStarting), true, "isActive starting")
assertEq(isActive(dssReady), true, "isActive ready")
assertEq(isActive(dssRunning), true, "isActive running")
assertEq(isActive(dssStopped), true, "isActive stopped")
assertEq(isActive(dssOff), false, "isActive off")

# Status strings
assertEq(statusString(dssOff), "Not started", "status off")
assertEq(statusString(dssRunning), "Running", "status running")
assertEq(statusString(dssStopped), "Stopped", "status stopped")

# Stack frame parsing
let stackJson = %*{
  "body": {
    "stackFrames": [
      {
        "id": 1,
        "name": "main",
        "source": {"path": "/tmp/main.nim"},
        "line": 5,
        "column": 3
      },
      {
        "id": 2,
        "name": "helper",
        "line": 10
      }
    ]
  }
}
let frames = parseStackFrames(stackJson)
assertEq(frames.len, 2, "frame count")
assertEq(frames[0].id, 1, "frame 0 id")
assertEq(frames[0].name, "main", "frame 0 name")
assertEq(frames[0].source, "/tmp/main.nim", "frame 0 source")
assertEq(frames[0].line, 4, "frame 0 line (0-based)")
assertEq(frames[0].column, 2, "frame 0 column (0-based)")
assertEq(frames[1].name, "helper", "frame 1 name")
assertEq(frames[1].source, "", "frame 1 source")
assertEq(frames[1].line, 9, "frame 1 line (0-based)")

# Nil / empty parsing
assertEq(parseStackFrames(nil).len, 0, "nil json")
assertEq(parseStackFrames(newJObject()).len, 0, "empty object")

echo "All debug state tests passed!"
