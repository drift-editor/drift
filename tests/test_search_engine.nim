import std/[os, strutils]
import ../src/utils/search_engine

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# --- Tool detection should not crash ---
let tool = detectSearchTool()
echo "Detected search tool: ", tool
assertEq(tool in {stRipgrep, stGrep, stFindstr, stFallback}, true, "tool is valid")

# --- Command builders should produce non-empty strings when an external tool is present ---
if tool != stFallback:
  let textCmd = buildSearchTextCmd("hello", "/tmp", true, false)
  assertEq(textCmd.len > 0, true, "search text command should not be empty")
  let findCmd = buildFindFilesCmd("*.nim", "/tmp")
  assertEq(findCmd.len > 0, true, "find files command should not be empty")

# --- Fallback text search ---
let root = "/tmp/se_test"
let textResult = fallbackSearchText("hello", root, true, false)
assertEq(textResult.contains("src/hello.nim"), true, "fallback should find hello.nim")
assertEq(textResult.contains("src/world.nim"), false, "fallback should not find world.nim")

# --- Fallback is case-insensitive when requested ---
let textResultCi = fallbackSearchText("HELLO", root, false, false)
assertEq(textResultCi.contains("src/hello.nim"), true, "fallback case-insensitive search should work")

# --- Fallback file search ---
let fileResult = fallbackFindFiles("*.nim", root)
assertEq(fileResult.contains("src/hello.nim"), true, "fallback should find *.nim files")
assertEq(fileResult.contains(".git"), false, "fallback should exclude .git dir")

# --- Glob pattern matching ---
assertEq(matchGlobPattern("src/hello.nim", "*.nim"), true, "glob match *.nim")
assertEq(matchGlobPattern("src/hello.txt", "*.nim"), false, "glob mismatch *.nim")
assertEq(matchGlobPattern("src/a.nim", "src/*.nim"), true, "glob match src/*.nim")
assertEq(matchGlobPattern("a.nim", "?.*"), true, "glob ?.* match")
assertEq(matchGlobPattern("x.nim", "?.*"), true, "glob ?.* match x")
assertEq(matchGlobPattern(".nim", "?.*"), false, "glob ?.* requires char before dot")

echo "All search engine tests passed!"
