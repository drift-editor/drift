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
    menu.addItem("new_file", "New File", proc() = callbacks.onNewFile(rootPath))
    menu.addItem("new_folder", "New Folder", proc() = callbacks.onNewFolder(rootPath))
    menu.addSeparator()
    menu.addItem("refresh", "Refresh", callbacks.onRefresh)
    menu.addItem("collapse_all", "Collapse All", callbacks.onCollapseAll)
    menu.addItem("paste", "Paste", proc() = callbacks.onPaste(rootPath))
  elif node.nodeType == fntDirectory:
    let folderPath = node.path
    menu.addItem("new_file", "New File", proc() = callbacks.onNewFile(folderPath))
    menu.addItem("new_folder", "New Folder", proc() = callbacks.onNewFolder(folderPath))
    menu.addSeparator()
    menu.addItem("reveal", "Reveal in Finder", proc() = callbacks.onReveal(folderPath))
    menu.addItem("copy_path", "Copy Path", proc() = callbacks.onCopyPath(folderPath))
    menu.addItem("copy_relative_path", "Copy Relative Path", proc() =
      callbacks.onCopyRelativePath(folderPath)
    )
    menu.addSeparator()
    menu.addItem("rename", "Rename", proc() = callbacks.onRenameFolder(folderPath))
    menu.addItem("delete", "Delete", proc() = callbacks.onDeleteFolder(folderPath))
  else:
    let filePath = node.path
    menu.addItem("open", "Open", proc() = callbacks.onOpenFile(filePath))
    menu.addSeparator()
    menu.addItem("reveal", "Reveal in Finder", proc() = callbacks.onReveal(filePath))
    menu.addItem("copy_path", "Copy Path", proc() = callbacks.onCopyPath(filePath))
    menu.addItem("copy_relative_path", "Copy Relative Path", proc() =
      callbacks.onCopyRelativePath(filePath)
    )
    menu.addSeparator()
    menu.addItem("rename", "Rename", proc() = callbacks.onRenameFile(filePath))
    menu.addItem("delete", "Delete", proc() = callbacks.onDeleteFile(filePath))
