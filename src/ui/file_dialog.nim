## Native file dialogs — uses tinyfiledialogs

import std/[strutils, options]
import tinyfiledialogs

type
  DialogKind* = enum
    dkOpenFile
    dkSaveFile
    dkSelectFolder

  DialogFilter* = tuple[name: string, ext: string]

  DialogInfo* = object
    kind*: DialogKind
    title*: string
    filters*: seq[DialogFilter]
    folder*: string
    extension*: string

proc checkExtensionOnSave*(di: DialogInfo, res: var string) =
  if di.kind == dkSaveFile and di.extension.len > 0:
    let extPos = res.rfind('.')
    if extPos < 0 or extPos < res.len - di.extension.len - 1:
      res.add('.')
      res.add(di.extension)

proc show*(di: DialogInfo): Option[string] =
  case di.kind:
  of dkOpenFile:
    var patterns: seq[string]
    for f in di.filters:
      patterns.add(f.ext)
    let patternsArr = if patterns.len > 0: allocCStringArray(patterns) else: nil
    let cRes = tinyfd_openFileDialog(
      di.title.cstring,
      di.folder.cstring,
      patterns.len.cint,
      patternsArr,
      nil,
      0
    )
    if patternsArr != nil:
      deallocCStringArray(patternsArr)
    if cRes != nil:
      return some($cRes)
    return none(string)

  of dkSaveFile:
    var patterns: seq[string]
    for f in di.filters:
      patterns.add(f.ext)
    let patternsArr = if patterns.len > 0: allocCStringArray(patterns) else: nil
    let cRes = tinyfd_saveFileDialog(
      di.title.cstring,
      di.folder.cstring,
      patterns.len.cint,
      patternsArr,
      nil
    )
    if patternsArr != nil:
      deallocCStringArray(patternsArr)
    if cRes != nil:
      var path = $cRes
      di.checkExtensionOnSave(path)
      return some(path)
    return none(string)

  of dkSelectFolder:
    let cRes = tinyfd_selectFolderDialog(di.title.cstring, di.folder.cstring)
    if cRes != nil:
      return some($cRes)
    return none(string)

# Convenience functions
proc openFileDialog*(title: string = "Open File", folder: string = "",
                     filters: seq[DialogFilter] = @[]): Option[string] =
  var di = DialogInfo(
    kind: dkOpenFile,
    title: title,
    folder: folder,
    filters: filters
  )
  return di.show()

proc saveFileDialog*(title: string = "Save File", folder: string = "",
                     defaultName: string = "", extension: string = "",
                     filters: seq[DialogFilter] = @[]): Option[string] =
  var di = DialogInfo(
    kind: dkSaveFile,
    title: title,
    folder: folder,
    extension: extension,
    filters: filters
  )
  return di.show()

proc openFolderDialog*(title: string = "Select Folder", folder: string = ""): Option[string] =
  var di = DialogInfo(
    kind: dkSelectFolder,
    title: title,
    folder: folder
  )
  return di.show()
