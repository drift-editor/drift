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
  proc drift_gtk4_file_dialog(kind: cint; title, folder: cstring;
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
      of dkSaveFile: 1.cint
      of dkSelectFolder: 2.cint
      else: 0.cint

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
  {.emit: """
  #include <windows.h>
  #include <string.h>
  #include <stdlib.h>

  static char *drift_win_file_dialog(int kind, const char *title,
                                      const char *folder, const char *filter,
                                      const char *defExt) {
    char buffer[MAX_PATH] = {0};
    OPENFILENAMEA ofn = {0};
    ofn.lStructSize = sizeof(ofn);
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = MAX_PATH;
    ofn.lpstrTitle = title;
    ofn.lpstrInitialDir = folder;
    ofn.lpstrFilter = filter;
    ofn.lpstrDefExt = defExt;
    ofn.Flags = OFN_HIDEREADONLY | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

    int ok;
    if (kind == 1) { /* save */
      ofn.Flags |= OFN_OVERWRITEPROMPT;
      ok = GetSaveFileNameA(&ofn);
    } else { /* open */
      ofn.Flags |= OFN_FILEMUSTEXIST;
      ok = GetOpenFileNameA(&ofn);
    }

    if (ok) {
      char *res = (char *)malloc(strlen(buffer) + 1);
      strcpy(res, buffer);
      return res;
    }
    return NULL;
  }
  """.}

  proc drift_win_file_dialog(kind: cint; title, folder, filter, defExt: cstring): cstring
    {.importc, nodecl, cdecl.}
  proc free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

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

    let filterStr = buildFilterString(di.filters)
    let cRes = drift_win_file_dialog(
      (if di.kind == dkSaveFile: 1 else: 0).cint,
      di.title.cstring,
      di.folder.cstring,
      filterStr.cstring,
      if di.extension.len > 0: di.extension.cstring else: nil
    )

    if not cRes.isNil:
      var path = $cRes
      free(cRes)
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
