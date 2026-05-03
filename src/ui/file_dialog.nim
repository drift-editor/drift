## Native file dialogs — no external tool calls

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
  # Thin GTK4 C bindings — no Nim wrapper dependency.
  # Uses GtkFileChooserNative with a local GMainLoop (gtk_dialog_run was removed in GTK4).

  const gtk4Cflags {.strdefine.} = staticExec("pkg-config --cflags gtk4").strip
  const gtk4Libs  {.strdefine.} = staticExec("pkg-config --libs gtk4").strip

  {.passC: gtk4Cflags.}
  {.passL: gtk4Libs.}

  {.emit: """
  #include <gtk/gtk.h>

  typedef struct {
    GtkFileChooserNative *dialog;
    gchar *result;
    gint response;
    GMainLoop *loop;
  } DriftDialogData;

  static void drift_on_dialog_response(GtkNativeDialog *dialog, gint response_id, DriftDialogData *data) {
    data->response = response_id;
    if (response_id == GTK_RESPONSE_ACCEPT) {
      GFile *file = gtk_file_chooser_get_file(GTK_FILE_CHOOSER(dialog));
      if (file) {
        data->result = g_file_get_path(file);
        g_object_unref(file);
      }
    }
    g_main_loop_quit(data->loop);
  }

  static gchar *drift_gtk4_file_dialog(gint kind, const gchar *title, const gchar *folder,
                                        const gchar **filter_names, const gchar **filter_patterns, gsize filter_count) {
    GtkFileChooserAction action;
    const gchar *accept_label;
    switch (kind) {
      case 1: action = GTK_FILE_CHOOSER_ACTION_SAVE;   accept_label = "Save";   break;
      case 2: action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER; accept_label = "Select"; break;
      default: action = GTK_FILE_CHOOSER_ACTION_OPEN;  accept_label = "Open";   break;
    }

    GtkFileChooserNative *dialog = gtk_file_chooser_native_new(title, NULL, action, accept_label, "Cancel");

    if (folder && folder[0]) {
      GFile *f = g_file_new_for_path(folder);
      gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog), f, NULL);
      g_object_unref(f);
    }

    if (filter_count > 0) {
      GtkFileFilter *all = gtk_file_filter_new();
      gtk_file_filter_set_name(all, "All");
      for (gsize i = 0; i < filter_count; i++) {
        GtkFileFilter *f = gtk_file_filter_new();
        gtk_file_filter_add_pattern(f, filter_patterns[i]);
        gtk_file_filter_set_name(f, filter_names[i]);
        gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), f);
        gtk_file_filter_add_pattern(all, filter_patterns[i]);
      }
      gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), all);
    }

    DriftDialogData data = {0};
    data.dialog = dialog;
    data.loop = g_main_loop_new(NULL, FALSE);

    g_signal_connect(dialog, "response", G_CALLBACK(drift_on_dialog_response), &data);
    gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
    g_main_loop_run(data.loop);

    g_main_loop_unref(data.loop);
    g_object_unref(dialog);

    return data.result; /* caller must g_free() */
  }
  """.}

  proc g_free(p: pointer) {.importc, nodecl, cdecl.}
  proc drift_gtk4_file_dialog(kind: int32; title, folder: cstring;
                              filterNames, filterPatterns: ptr cstring;
                              filterCount: csize_t): cstring
    {.importc, nodecl, cdecl.}

  proc show*(di: DialogInfo): Option[string] =
    var filterNames: seq[cstring]
    var filterPatterns: seq[cstring]
    for f in di.filters:
      filterNames.add(f.name.cstring)
      filterPatterns.add(f.ext.cstring)

    let kind = case di.kind:
      of dkSaveFile: 1.int32
      of dkSelectFolder: 2.int32
      else: 0.int32

    let cRes = drift_gtk4_file_dialog(
      kind,
      di.title.cstring,
      di.folder.cstring,
      (if filterNames.len > 0: filterNames[0].unsafeAddr else: nil),
      (if filterPatterns.len > 0: filterPatterns[0].unsafeAddr else: nil),
      filterNames.len.csize_t
    )

    if not cRes.isNil:
      var path = $cRes
      g_free(cRes)
      di.checkExtensionOnSave(path)
      return some(path)
    return none(string)

elif defined(windows):
  # Pure Nim struct — no importc, no windows.h include.
  # Layout matches OPENFILENAMEA on x86 and x64 Windows.
  type
    OPENFILENAMEA = object
      lStructSize: int32
      hwndOwner: uint
      hInstance: uint
      lpstrFilter: uint
      lpstrCustomFilter: uint
      nMaxCustFilter: int32
      nFilterIndex: int32
      lpstrFile: uint
      nMaxFile: int32
      lpstrFileTitle: uint
      nMaxFileTitle: int32
      lpstrInitialDir: uint
      lpstrTitle: uint
      Flags: int32
      nFileOffset: uint16
      nFileExtension: uint16
      lpstrDefExt: uint
      lCustData: uint
      lpfnHook: uint
      lpTemplateName: uint

  const
    OFN_HIDEREADONLY = 0x00000004
    OFN_PATHMUSTEXIST = 0x00000800
    OFN_FILEMUSTEXIST = 0x00001000
    OFN_OVERWRITEPROMPT = 0x00000002
    OFN_NOCHANGEDIR = 0x00000008
    MAX_PATH = 260

  proc GetOpenFileNameA(lpofn: ptr OPENFILENAMEA): int32 {.stdcall, dynlib: "comdlg32.dll", importc.}
  proc GetSaveFileNameA(lpofn: ptr OPENFILENAMEA): int32 {.stdcall, dynlib: "comdlg32.dll", importc.}

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
    if di.kind == dkSelectFolder:
      return none(string)

    var ofn = cast[ptr OPENFILENAMEA](alloc0(sizeof(OPENFILENAMEA)))
    ofn.lStructSize = sizeof(OPENFILENAMEA).int32
    ofn.Flags = OFN_HIDEREADONLY or OFN_PATHMUSTEXIST or OFN_NOCHANGEDIR

    var buffer = newString(MAX_PATH)
    ofn.lpstrFile = cast[uint](cast[pointer](buffer.cstring))
    ofn.nMaxFile = MAX_PATH.int32

    let filterStr = buildFilterString(di.filters)
    ofn.lpstrFilter = cast[uint](cast[pointer](filterStr.cstring))
    ofn.lpstrTitle = cast[uint](cast[pointer](di.title.cstring))
    ofn.lpstrInitialDir = if di.folder.len > 0:
      cast[uint](cast[pointer](di.folder.cstring)) else: 0'u

    var success: int32
    case di.kind:
    of dkOpenFile:
      ofn.Flags = ofn.Flags or OFN_FILEMUSTEXIST
      success = GetOpenFileNameA(ofn)
    of dkSaveFile:
      ofn.Flags = ofn.Flags or OFN_OVERWRITEPROMPT
      ofn.lpstrDefExt = if di.extension.len > 0:
        cast[uint](cast[pointer](di.extension.cstring)) else: 0'u
      success = GetSaveFileNameA(ofn)
    else:
      dealloc(ofn)
      return none(string)

    if success != 0:
      var cptr = cast[ptr UncheckedArray[char]](ofn.lpstrFile)
      var path = ""
      var i = 0
      while cptr[i] != '\0':
        path.add(cptr[i])
        inc i
      di.checkExtensionOnSave(path)
      dealloc(ofn)
      return some(path)
    dealloc(ofn)
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
