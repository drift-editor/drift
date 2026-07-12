## File tree data model — pure types and tree traversal, no UI, no filesystem I/O.

import std/[os, sets]

type
  FileNodeType* = enum
    fntFile
    fntDirectory

  FileNode* = ref object
    path*: string
    name*: string
    nodeType*: FileNodeType
    isExpanded*: bool
    children*: seq[FileNode]
    parent*: FileNode
    isLoaded*: bool

proc newFileNode*(path: string, parent: FileNode = nil): FileNode =
  let nodeType = if dirExists(path): fntDirectory else: fntFile
  FileNode(
    path: path,
    name: extractFilename(path),
    nodeType: nodeType,
    isExpanded: false,
    children: @[],
    parent: parent,
    isLoaded: false
  )

proc countVisibleNodes*(node: FileNode): int =
  result = 1
  if node.isExpanded:
    for child in node.children:
      result += countVisibleNodes(child)

proc getVisibleNodeAtIndex*(node: FileNode, targetIdx: int, varIdx: var int): FileNode =
  if varIdx == targetIdx:
    return node
  varIdx += 1
  if node.isExpanded:
    for child in node.children:
      let found = getVisibleNodeAtIndex(child, targetIdx, varIdx)
      if found != nil:
        return found
  nil

proc getNodeIndex*(node: FileNode, target: FileNode, varIdx: var int): int =
  if node == target:
    return varIdx
  result = -1
  varIdx += 1
  if node.isExpanded:
    for child in node.children:
      let idx = getNodeIndex(child, target, varIdx)
      if idx >= 0:
        return idx

proc findNodeByPath*(node: FileNode, path: string): FileNode =
  if node.path == path:
    return node
  if node.isExpanded:
    for child in node.children:
      let found = findNodeByPath(child, path)
      if found != nil:
        return found
  nil

proc collapse*(node: FileNode) =
  node.isExpanded = false
