import std/os
import chronos
import ../src/services/dap_client

proc main() {.async.} =
  let adapterPath = getCurrentDir() / "tests" / "fake_dap_adapter.py"
  if not fileExists(adapterPath):
    stderr.writeLine("FAIL: fake adapter not found: " & adapterPath)
    quit(1)

  stderr.writeLine("[test] starting fake adapter: " & adapterPath)
  let client = await startDAP(adapterPath)
  if not client.isReady:
    stderr.writeLine("FAIL: client not ready: " & client.errorMsg())
    quit(1)

  client.ensureReadLoop()

  # The DAP spec says the adapter sends an `initialized` event after the
  # `initialize` response. The client must wait for this event before
  # sending setup requests such as `setBreakpoints` or `launch`.
  let initOk = await client.waitForInitialized(5.seconds)
  if not initOk:
    stderr.writeLine("FAIL: initialized event not received")
    quit(1)

  # Once initialized, setup requests should be accepted.
  try:
    discard await client.requestSetBreakpoints("/tmp/main.nim", @[1, 2, 3])
  except CatchableError as e:
    stderr.writeLine("FAIL: setBreakpoints failed: " & e.msg)
    quit(1)

  try:
    await client.requestLaunch("/tmp/main", cwd = "/tmp", stopOnEntry = false)
  except CatchableError as e:
    stderr.writeLine("FAIL: launch failed: " & e.msg)
    quit(1)

  if not client.isRunning:
    stderr.writeLine("FAIL: client should be running after launch")
    quit(1)

  await client.stopDAP()
  stderr.writeLine("All DAP lifecycle tests passed!")

waitFor main()
