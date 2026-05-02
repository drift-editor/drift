## File System Watcher - Optimized polling version

import std/[os, times, tables]

type
  FileWatcher* = object
    watchDirs*: seq[string]
    fileTimes*: Table[string, Time]

  FileEvent* = object
    path*: string
    kind*: FileEventKind

  FileEventKind* = enum
    feCreated
    feModified
    feDeleted

proc newFileWatcher*(): FileWatcher =
  FileWatcher(watchDirs: @[], fileTimes: initTable[string, Time]())

proc addDir*(fw: var FileWatcher; dir: string) =
  if dir.dirExists and dir notin fw.watchDirs:
    fw.watchDirs.add(dir)
    for kind, fp in walkDir(dir):
      if fp.fileExists:
        fw.fileTimes[fp] = fp.getLastModificationTime()

proc pollEvents*(fw: var FileWatcher; maxEvents = 50): seq[FileEvent] =
  result = @[]
  for dir in fw.watchDirs:
    if not dir.dirExists: continue
    for kind, fp in walkDir(dir):
      if fp.fileExists:
        let newMt = fp.getLastModificationTime()
        if fp notin fw.fileTimes:
          fw.fileTimes[fp] = newMt
          result.add(FileEvent(path: fp, kind: feCreated))
          if result.len >= maxEvents: return
        else:
          let oldMt = fw.fileTimes[fp]
          if newMt != oldMt:
            fw.fileTimes[fp] = newMt
            result.add(FileEvent(path: fp, kind: feModified))
            if result.len >= maxEvents: return
      elif fp in fw.fileTimes:
        fw.fileTimes.del(fp)
        result.add(FileEvent(path: fp, kind: feDeleted))
        if result.len >= maxEvents: return