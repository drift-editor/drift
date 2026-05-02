## Native file dialogs - no external tool calls

import std/[strutils, options]

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

when defined(macosx) and not defined(ios):
  import darwin/objc/runtime
  import darwin/foundation

  {.passL: "-framework Foundation".}
  {.passL: "-framework AppKit".}
  when defined(cpp):
    {.passC: "-ObjC++".}

  type
    NSSavePanel {.importobjc: "NSSavePanel*", header: "<AppKit/AppKit.h>", incompleteStruct.} = object
    NSOpenPanel {.importobjc: "NSOpenPanel*", header: "<AppKit/AppKit.h>", incompleteStruct.} = object

  proc newOpenPanel: NSOpenPanel {.importobjc: "NSOpenPanel openPanel", nodecl.}
  proc newSavePanel: NSSavePanel {.importobjc: "NSSavePanel savePanel", nodecl.}

  proc showOpen(di: DialogInfo): string =
    var dialog = newOpenPanel()
    let ctitle: cstring = di.title.cstring
    let kind = di.kind
    let path: cstring = (if di.folder.len == 0: "" else: di.folder).cstring
    var cres: cstring

    var filters = newMutableArray[NSString]()
    for f in di.filters:
      filters.add(toNSString(f.ext.replace("*.", "")))

    {.emit: """
      if (`kind` == `dkSelectFolder`){
        [`dialog` setCanChooseDirectories:YES];
        [`dialog` setCanChooseFiles:NO];
      }
      else {
        [`dialog` setCanChooseDirectories:NO];
        [`dialog` setCanChooseFiles:YES];
      }

      if ([`filters` count] > 0)
        [`dialog` setAllowedFileTypes: (NSArray<NSString *> *)`filters`];

      `dialog`.title = [NSString stringWithUTF8String: `ctitle`];
      [`dialog` setDirectoryURL:[NSURL fileURLWithPath: [NSString stringWithUTF8String: `path`]]];
      if ([`dialog` runModal] == NSOKButton && `dialog`.URLs.count > 0)
        `cres` = (char *)[`dialog`.URLs objectAtIndex: 0].path.UTF8String;
      // Restore app focus after modal dialog closes
      dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *win = [NSApp mainWindow];
        if (!win) win = [[NSApp windows] firstObject];
        if (win) {
          [win makeKeyAndOrderFront:nil];
          [[win contentView] becomeFirstResponder];
        }
        [NSApp activateIgnoringOtherApps:YES];
      });
    """.}

    if not cres.isNil:
      result = $cres

  proc showSave(di: DialogInfo): string =
    var dialog = newSavePanel()
    let ctitle: cstring = di.title.cstring
    let path: cstring = (if di.folder.len == 0: "" else: di.folder).cstring
    var cres: cstring

    var filters = newMutableArray[NSString]()
    for f in di.filters:
      filters.add(toNSString(f.ext.replace("*.", "")))

    {.emit: """
      if ([`filters` count] > 0)
        [`dialog` setAllowedFileTypes: (NSArray<NSString *> *)`filters`];

      `dialog`.canCreateDirectories = true;
      `dialog`.title = [NSString stringWithUTF8String: `ctitle`];
      [`dialog` setDirectoryURL:[NSURL fileURLWithPath: [NSString stringWithUTF8String: `path`]]];
      if ([`dialog` runModal] == NSOKButton)
        `cres` = (char *)`dialog`.URL.path.UTF8String;
      // Restore app focus after modal dialog closes
      dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *win = [NSApp mainWindow];
        if (!win) win = [[NSApp windows] firstObject];
        if (win) {
          [win makeKeyAndOrderFront:nil];
          [[win contentView] becomeFirstResponder];
        }
        [NSApp activateIgnoringOtherApps:YES];
      });
    """.}

    if not cres.isNil:
      result = $cres

  proc show*(di: DialogInfo): Option[string] =
    var res: string
    if di.kind == dkOpenFile or di.kind == dkSelectFolder:
      res = di.showOpen()
    else:
      res = di.showSave()

    if res.len > 0:
      di.checkExtensionOnSave(res)
      return some(res)
    return none(string)

elif defined(linux) and not defined(android) and not defined(emscripten):
  import oldgtk3/[gtk, glib]

  proc initCheckWithArgv*(): bool {.inline.} =
    var
      cmdLine{.importc.}: cstringArray
      cmdCount{.importc.}: cint
    gtk.initCheck(cmdCount, cmdLine).bool

  proc show*(di: DialogInfo): Option[string] =
    discard initCheckWithArgv()

    var action: FileChooserAction
    var buttons = newSeq[tuple[title: string, rType: ResponseType]](2)
    buttons[0] = (title: "Cancel", rType: ResponseType.CANCEL)
    buttons[1] = (title: "Open", rType: ResponseType.ACCEPT)

    case di.kind:
    of dkOpenFile:
      action = FileChooserAction.OPEN
    of dkSaveFile:
      action = FileChooserAction.SAVE
      buttons[1].title = "Save"
    of dkSelectFolder:
      action = FileChooserAction.SELECT_FOLDER
      buttons[1].title = "Select"

    var dialog = newFileChooserDialog(di.title.cstring, nil, action, nil)
    for button in buttons:
      discard dialog.add_button(button.title, button.rType.cint)

    if di.folder.len > 0:
      discard cast[FileChooser](dialog).setCurrentFolder(di.folder.cstring)

    if di.filters.len > 0:
      var filters = newSeq[FileFilter]()
      let all = newFileFilter()
      all.setName("All")
      filters.add(all)
      for fi in di.filters:
        let pfi = newFileFilter()
        pfi.addPattern(fi.ext.cstring)
        all.addPattern(fi.ext.cstring)
        pfi.setName(fi.name.cstring)
        filters.add(pfi)

      for fi in filters:
        cast[FileChooser](dialog).addFilter(fi)

    let res = dialog.run()
    if cast[ResponseType](res) in [ResponseType.ACCEPT, ResponseType.YES, ResponseType.APPLY]:
      let fileChooser = cast[FileChooser](pointer(dialog))
      result = some($fileChooser.getFilename())
      var path = result.get()
      di.checkExtensionOnSave(path)
      result = some(path)
    else:
      result = none(string)

    dialog.destroy()

    while events_pending():
      discard main_iteration()

elif defined(windows):
  import std/[winlean, sequtils]

  type
    OPENFILENAMEA {.importc: "OPENFILENAMEA", header: "<windows.h>".} = object
      lStructSize: DWORD
      hwndOwner: HWND
      hInstance: HINSTANCE
      lpstrFilter: cstring
      lpstrCustomFilter: cstring
      nMaxCustFilter: DWORD
      nFilterIndex: DWORD
      lpstrFile: cstring
      nMaxFile: DWORD
      lpstrFileTitle: cstring
      nMaxFileTitle: DWORD
      lpstrInitialDir: cstring
      lpstrTitle: cstring
      Flags: DWORD
      nFileOffset: WORD
      nFileExtension: WORD
      lpstrDefExt: cstring
      lCustData: LPARAM
      lpfnHook: pointer
      lpTemplateName: cstring

  const
    OFN_HIDEREADONLY = 0x00000004
    OFN_PATHMUSTEXIST = 0x00000800
    OFN_FILEMUSTEXIST = 0x00001000
    OFN_OVERWRITEPROMPT = 0x00000002
    OFN_NOCHANGEDIR = 0x00000008
    MAX_PATH = 260

  proc GetOpenFileNameA(lpofn: var OPENFILENAMEA): BOOL {.importc, stdcall, dynlib: "comdlg32.dll".}
  proc GetSaveFileNameA(lpofn: var OPENFILENAMEA): BOOL {.importc, stdcall, dynlib: "comdlg32.dll".}

  proc buildFilterString(filters: seq[DialogFilter]): string =
    if filters.len == 0:
      return "All Files\0*.*\0\0"
    result = ""
    for f in filters:
      result.add(f.name)
      result.add('\0')
      result.add(f.ext)
      result.add('\0')
    result.add("\0")

  proc show*(di: DialogInfo): Option[string] =
    var ofn: OPENFILENAMEA
    ofn.lStructSize = sizeof(OPENFILENAMEA).DWORD
    ofn.Flags = OFN_HIDEREADONLY or OFN_PATHMUSTEXIST or OFN_NOCHANGEDIR

    var buffer = newString(MAX_PATH)
    ofn.lpstrFile = buffer.cstring
    ofn.nMaxFile = MAX_PATH.DWORD

    let filterStr = buildFilterString(di.filters)
    ofn.lpstrFilter = filterStr.cstring
    ofn.lpstrTitle = di.title.cstring
    ofn.lpstrInitialDir = if di.folder.len > 0: di.folder.cstring else: nil

    var success: BOOL
    case di.kind:
    of dkOpenFile:
      ofn.Flags = ofn.Flags or OFN_FILEMUSTEXIST
      success = GetOpenFileNameA(ofn)
    of dkSaveFile:
      ofn.Flags = ofn.Flags or OFN_OVERWRITEPROMPT
      ofn.lpstrDefExt = if di.extension.len > 0: di.extension.cstring else: nil
      success = GetSaveFileNameA(ofn)
    else:
      return none(string)

    if success.bool:
      var path = $ofn.lpstrFile
      let nullPos = path.find('\0')
      if nullPos >= 0:
        path = path[0..<nullPos]
      di.checkExtensionOnSave(path)
      return some(path)
    return none(string)

else:
  proc show*(di: DialogInfo): Option[string] =
    {.error: "Unsupported platform for file dialog".}

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
