--define:ChronosAsync
when defined(macosx):
  switch("passC", "-Wno-incompatible-function-pointer-types")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
