import std/[os, options]
import chronos
import ../src/services/lsp_thread

proc main() =
  stderr.writeLine("[main] creating thread with minlsp")
  let thr = newLSPThread("minlsp")
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
  else:
    thr.requestHover("/Users/bung/nim-works/drift/src/app/app.nim", 0, 0)
    for i in 0..100:
      let respOpt = thr.getResponse()
      if respOpt.isSome:
        let resp = respOpt.get()
        if resp.kind == lmkHover:
          if resp.hoverText.isSome:
            stderr.writeLine("[main] hover: " & resp.hoverText.get()[0..<min(100, resp.hoverText.get().len)])
          else:
            stderr.writeLine("[main] hover: none")
          break
      sleep(100)
  thr.shutdown()
  stderr.writeLine("[main] done")

main()
