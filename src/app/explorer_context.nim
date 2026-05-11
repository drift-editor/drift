## File Explorer Context Menu Builder
## Extracted from app.nim to keep it manageable.

import uirelays
import uirelays/screen
import ../ui/[file_explorer, context_menu]

type
  ExplorerMenuCallbacks* = object
    onNewFile*: proc(dir: string)
    onNewFolder*: proc(dir: string)
    onRefresh*: proc()
    onCollapseAll*: proc()
    onPaste*: proc(dir: string)
    onReveal*: proc(path: string)
    onCopyPath*: proc(path: string)
    onCopyRelativePath*: proc(path: string)
    onRenameFile*: proc(path: string)
    onRenameFolder*: proc(path: string)
    onDeleteFile*: proc(path: string)
    onDeleteFolder*: proc(path: string)
    onOpenFile*: proc(path: string)

proc buildExplorerContextMenu*(
  menu: ContextMenu,
  node: FileNode,
  rootPath: string,
  width, height: int,
  font: Font,
  callbacks: ExplorerMenuCallbacks
) =
  menu.clear()
  if node == nil:
    menu.addItem("new_file", "New File", proc() = (if callbacks.onNewFile != nil: callbacks.onNewFile(rootPath)))
    menu.addItem("new_folder", "New Folder", proc() = (if callbacks.onNewFolder != nil: callbacks.onNewFolder(rootPath)))
    menu.addSeparator()
    menu.addItem("refresh", "Refresh", callbacks.onRefresh)
    menu.addItem("collapse_all", "Collapse All", callbacks.onCollapseAll)
    menu.addItem("paste", "Paste", proc() = (if callbacks.onPaste != nil: callbacks.onPaste(rootPath)))
  elif node.nodeType == fntDirectory:
    let folderPath = node.path
    menu.addItem("new_file", "New File", proc() = (if callbacks.onNewFile != nil: callbacks.onNewFile(folderPath)))
    menu.addItem("new_folder", "New Folder", proc() = (if callbacks.onNewFolder != nil: callbacks.onNewFolder(folderPath)))
    menu.addSeparator()
    menu.addItem("reveal", "Reveal in Finder", proc() = (if callbacks.onReveal != nil: callbacks.onReveal(folderPath)))
    menu.addItem("copy_path", "Copy Path", proc() = (if callbacks.onCopyPath != nil: callbacks.onCopyPath(folderPath)))
    menu.addItem("copy_relative_path", "Copy Relative Path", proc() =
      if callbacks.onCopyRelativePath != nil: callbacks.onCopyRelativePath(folderPath)
    )
    menu.addSeparator()
    menu.addItem("rename", "Rename", proc() = (if callbacks.onRenameFolder != nil: callbacks.onRenameFolder(folderPath)))
    menu.addItem("delete", "Delete", proc() = (if callbacks.onDeleteFolder != nil: callbacks.onDeleteFolder(folderPath)))
  else:
    let filePath = node.path
    menu.addItem("open", "Open", proc() = (if callbacks.onOpenFile != nil: callbacks.onOpenFile(filePath)))
    menu.addSeparator()
    menu.addItem("reveal", "Reveal in Finder", proc() = (if callbacks.onReveal != nil: callbacks.onReveal(filePath)))
    menu.addItem("copy_path", "Copy Path", proc() = (if callbacks.onCopyPath != nil: callbacks.onCopyPath(filePath)))
    menu.addItem("copy_relative_path", "Copy Relative Path", proc() =
      if callbacks.onCopyRelativePath != nil: callbacks.onCopyRelativePath(filePath)
    )
    menu.addSeparator()
    menu.addItem("rename", "Rename", proc() = (if callbacks.onRenameFile != nil: callbacks.onRenameFile(filePath)))
    menu.addItem("delete", "Delete", proc() = (if callbacks.onDeleteFile != nil: callbacks.onDeleteFile(filePath)))
