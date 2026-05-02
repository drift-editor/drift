import std/[os, options]
import chronos
import ../src/services/lsp_thread

proc main() =
  stderr.writeLine("[main] creating thread with bad exe")
  let thr = newLSPThread("nonexistent_lsp_xxx")
  stderr.writeLine("[main] thread created, polling...")
  for i in 0..50:
    let respOpt = thr.getResponse()
    if respOpt.isSome:
      let resp = respOpt.get()
      stderr.writeLine("[main] got response: " & $resp.kind & " " & resp.str1)
      break
    sleep(100)
  thr.shutdown()
  stderr.writeLine("[main] done")

main()
