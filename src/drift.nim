## Drift Editor - Entry Point

import std/[os, strutils]
import app/app
import core/config

proc main() =
  var config = loadConfig()

  # Parse command line arguments
  var positionalArg = ""
  if paramCount() >= 1:
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      case arg
      of "--width", "-w":
        if i + 1 <= paramCount():
          try:
            config.windowWidth = parseInt(paramStr(i + 1))
          except ValueError:
            stderr.writeLine("Invalid width: " & paramStr(i + 1))
          i += 1
      of "--height", "-h":
        if i + 1 <= paramCount():
          try:
            config.windowHeight = parseInt(paramStr(i + 1))
          except ValueError:
            stderr.writeLine("Invalid height: " & paramStr(i + 1))
          i += 1
      of "--title", "-t":
        if i + 1 <= paramCount():
          config.windowTitle = paramStr(i + 1)
          i += 1
      of "--help", "-?":
        echo "Drift Editor"
        echo "Usage: drift [options] [file|dir]"
        echo ""
        echo "Options:"
        echo "  -w, --width   Window width (default: 1200)"
        echo "  -h, --height  Window height (default: 800)"
        echo "  -t, --title   Window title"
        echo "  -?, --help    Show this help"
        return
      else:
        if not arg.startsWith("-") and positionalArg.len == 0:
          positionalArg = arg
      i += 1

  let app = createApp(config)
  app.init()

  if positionalArg.len > 0:
    let path = positionalArg.absolutePath()
    if fileExists(path):
      discard app.openFile(path)
      let root = parentDir(path)
      if root.len > 0:
        app.openFolder(root)
        app.addRecentFolder(root)
      app.hideWelcome()
    elif dirExists(path):
      app.openFolder(path)
      app.addRecentFolder(path)
      app.hideWelcome()
    else:
      echo "Path does not exist: ", path

  app.run()
  app.cleanup()

when isMainModule:
  main()
