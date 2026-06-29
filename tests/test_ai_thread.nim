import std/[os, times, options, strutils]
import ../src/services/ai_thread
import ../src/core/config

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# --- isPathInsideWorkspace ---
let root = getTempDir() / "drift_ai_workspace_test"
removeDir(root)
createDir(root)
let nested = root / "sub" / "dir"
createDir(nested)
let fileInside = root / "file.txt"
writeFile(fileInside, "inside")

assertEq(isPathInsideWorkspace(fileInside, root), true, "file inside workspace")
assertEq(isPathInsideWorkspace(nested, root), true, "dir inside workspace")
assertEq(isPathInsideWorkspace(root / "../outside", root), false, "path outside workspace")
assertEq(isPathInsideWorkspace(root & "-evil", root), false, "prefix attack outside workspace")

# Relative paths
setCurrentDir(root)
assertEq(isPathInsideWorkspace("file.txt", root), true, "relative file inside")
assertEq(isPathInsideWorkspace("../outside", root), false, "relative outside")

# Trailing slashes
assertEq(isPathInsideWorkspace(fileInside, root & "/"), true, "root with trailing slash")

# --- buildAICommand ---
# We cannot call the private buildAICommand directly, but we can verify newAIThread
# accepts a config and the unsupported-provider path produces an error response.
var cfg = defaultConfig()
cfg.aiAgent = "unsupported_provider"
cfg.aiModel = "gpt-4"
var thread = newAIThread(cfg)
var foundError = false
var deadline = epochTime() + 2.0
while epochTime() < deadline:
  let resp = thread.getResponse()
  if resp.isSome:
    if resp.get().kind == amkError:
      foundError = true
      assert "Unsupported AI provider" in resp.get().error, "expected unsupported provider error"
      break
    else:
      echo "Unexpected response: ", resp.get().kind
  sleep(10)
assertEq(foundError, true, "unsupported provider reported as error")
thread.shutdown()

# Kimi provider starts without immediate error (we won't wait for ready; just verify construction)
cfg.aiAgent = "kimi"
var thread2 = newAIThread(cfg)
thread2.shutdown()

echo "All AI thread tests passed!"
