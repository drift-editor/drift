import std/[os, options]
import chronos
import ../src/services/lsp_thread

proc main() =
  stderr.writeLine("[main] creating thread")
  let thr = newLSPThread("nimlsp")
  stderr.writeLine("[main] thread created, polling...")
  var ready = false
  for i in 0..300:
    let respOpt = thr.getResponse()
    if respOpt.isSome:
      let resp = respOpt.get()
      stderr.writeLine("[main] got response: " & $resp.kind)
      if resp.kind == lmkReady:
        ready = true
        break
      elif resp.kind == lmkError:
        stderr.writeLine("[main] error: " & resp.str1)
        break
    sleep(100)
  if not ready:
    stderr.writeLine("[main] timed out waiting for ready")
  thr.shutdown()
  stderr.writeLine("[main] done")

main()
