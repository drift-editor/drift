--define:ChronosAsync
when defined(macosx):
  switch("passC", "-Wno-incompatible-function-pointer-types")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  when defined(linux):
    import std/strutils
    for line in readFile("nimble.paths").splitLines():
      if line.startsWith("--path:"):
        var p = line[7..^1]
        if p.startsWith("\"") and p.endsWith("\""):
          p = p[1..^2]
        p = p.replace("\\", "/")
        if len(p) >= 2 and p[1] == ':':
          p = "/mnt/" & ($p[0]).toLower() & "/" & p[3..^1]
        switch("path", p)
      elif line.startsWith("--"):
        switch(line[2..^1])
  else:
    include "nimble.paths"
# end Nimble config
