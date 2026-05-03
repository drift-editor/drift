## Icon system using VS Code Codicons (SVG -> pixie -> PNG -> uirelays Image)

import std/[os, tables, strutils]
import pixie except drawImage
import pixie/fileformats/svg
import uirelays

type
  IconId* = enum
    iiNone
    iiFile
    iiFolder
    iiFolderOpened
    iiSearch
    iiGear
    iiFileMedia
    iiFileCode
    iiCheck
    iiGitBranch
    iiArrowUp
    iiArrowDown
    iiWarning
    iiNewFile
    iiFolderLibrary
    iiListSelection
    iiHistory
    iiEdit
    iiExplorer
    iiClose
    iiChevronUp
    iiChevronDown
    iiChevronRight
    iiCaseSensitive
    iiAdd
    iiRemove
    iiDiscard
    iiRefresh
    iiGitCommit
    iiError
    iiSparkle
    iiPlay
    iiPlayGreen
    iiBug

var iconImages: Table[IconId, uirelays.screen.Image]
const IconSize = 16
var iconScale: int = 1

proc backendSupportsRasterImages*(): bool {.inline.} =
  screen.drawRelays.loadImage != nil and screen.drawRelays.drawImage != nil

proc setIconScale*(scale: int) =
  iconScale = max(1, scale)

proc iconFileName(id: IconId): string =
  case id
  of iiFile: "file.svg"
  of iiFolder: "folder.svg"
  of iiFolderOpened: "folder-opened.svg"
  of iiSearch: "search.svg"
  of iiGear: "gear.svg"
  of iiFileMedia: "file-media.svg"
  of iiFileCode: "file-code.svg"
  of iiCheck: "check.svg"
  of iiGitBranch: "git-branch.svg"
  of iiArrowUp: "arrow-up.svg"
  of iiArrowDown: "arrow-down.svg"
  of iiWarning: "warning.svg"
  of iiNewFile: "new-file.svg"
  of iiFolderLibrary: "folder-library.svg"
  of iiListSelection: "list-selection.svg"
  of iiHistory: "history.svg"
  of iiEdit: "edit.svg"
  of iiExplorer: "explorer.svg"
  of iiClose: "close.svg"
  of iiChevronUp: "chevron-up.svg"
  of iiChevronDown: "chevron-down.svg"
  of iiChevronRight: "chevron-right.svg"
  of iiCaseSensitive: "case-sensitive.svg"
  of iiAdd: "add.svg"
  of iiRemove: "remove.svg"
  of iiDiscard: "discard.svg"
  of iiRefresh: "refresh.svg"
  of iiGitCommit: "git-commit.svg"
  of iiError: "error.svg"
  of iiSparkle: "sparkle.svg"
  of iiPlay: "play.svg"
  of iiPlayGreen: "play-green.svg"
  of iiBug: "bug.svg"
  of iiNone: ""

proc loadIcons*() =
  if not backendSupportsRasterImages():
    echo "[icons] display backend has no raster image support; icons disabled"
    return
  let baseDir = currentSourcePath().parentDir / ".." / ".." / "resources" / "icons" / "codicons"
  let tmpDir = getTempDir() / "drift_icons"
  createDir(tmpDir)

  for id in IconId.low..IconId.high:
    if id == iiNone: continue
    var svgPath = baseDir / iconFileName(id)
    if not fileExists(svgPath):
      svgPath = baseDir.parentDir / iconFileName(id)
    if not fileExists(svgPath):
      echo "[icons] missing: ", svgPath
      continue
    try:
      var svgData = readFile(svgPath)
      svgData = svgData.replace("fill=\"currentColor\"", "fill=\"#DCDCDC\"")
      let scaledSize = IconSize * iconScale
      let svg = parseSvg(svgData, scaledSize, scaledSize)
      let img = newImage(svg)
      let pngPath = tmpDir / ($id & ".png")
      img.writeFile(pngPath)
      let handle = screen.loadImage(pngPath)
      if handle.int != 0:
        iconImages[id] = handle
      else:
        echo "[icons] failed to load: ", pngPath
    except CatchableError as e:
      echo "[icons] error loading ", svgPath, ": ", e.msg

proc drawIcon*(id: IconId; x, y: int) =
  if not backendSupportsRasterImages(): return
  if id == iiNone or id notin iconImages: return
  let img = iconImages[id]
  let srcSize = IconSize * iconScale
  uirelays.screen.drawImage(img, rect(0, 0, srcSize, srcSize), rect(x, y, IconSize, IconSize))

proc drawIconCentered*(id: IconId; bounds: uirelays.Rect) =
  if not backendSupportsRasterImages(): return
  if id == iiNone or id notin iconImages: return
  let img = iconImages[id]
  let x = bounds.x + (bounds.w - IconSize) div 2
  let y = bounds.y + (bounds.h - IconSize) div 2
  let srcSize = IconSize * iconScale
  uirelays.screen.drawImage(img, rect(0, 0, srcSize, srcSize), rect(x, y, IconSize, IconSize))

proc hasIcon*(id: IconId): bool =
  id in iconImages
