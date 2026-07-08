import std/strutils
import ../src/core/recent_files
import ../src/ui/welcome_screen

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# Initial list of recent files
let files = @[
  RecentFileEntry(path: "/home/user/project/main.nim"),
  RecentFileEntry(path: "/home/user/project/utils.nim"),
  RecentFileEntry(path: "/home/user/readme.md")
]

# Pinning an existing file moves it to the front and marks it pinned
let pinned = pinRecentFile(files, "/home/user/project/utils.nim")
assertEq(pinned.len, 3, "pin preserves count")
assertEq(pinned[0].path, "/home/user/project/utils.nim", "pinned moved to front")
assertEq(pinned[0].pinned, true, "pinned flag set")
assertEq(pinned[1].path, "/home/user/project/main.nim", "previous front follows")
assertEq(pinned[2].path, "/home/user/readme.md", "third item unchanged")

# isPinned reflects the flag
assertEq(isPinned(pinned, "/home/user/project/utils.nim"), true, "isPinned true")
assertEq(isPinned(pinned, "/home/user/project/main.nim"), false, "isPinned false")

# Unpinning removes the flag but keeps the entry in place
let unpinned = unpinRecentFile(pinned, "/home/user/project/utils.nim")
assertEq(unpinned[0].path, "/home/user/project/utils.nim", "unpin keeps position")
assertEq(unpinned[0].pinned, false, "unpin clears flag")
assertEq(unpinned[1].path, "/home/user/project/main.nim", "unpin neighbor unchanged")
assertEq(isPinned(unpinned, "/home/user/project/utils.nim"), false, "isPinned after unpin")

# Pinning an unknown path creates a new pinned entry at the front
let unknown = pinRecentFile(files, "/tmp/new.nim")
assertEq(unknown.len, 4, "pin unknown grows list")
assertEq(unknown[0].path, "/tmp/new.nim", "unknown pinned at front")
assertEq(unknown[0].pinned, true, "unknown entry pinned")

# Pinning respects MaxRecentFiles
var manyFiles: seq[RecentFileEntry] = @[]
for i in 0 ..< MaxRecentFiles + 5:
  manyFiles.add(RecentFileEntry(path: "/tmp/file" & $i & ".nim"))
let manyPinned = pinRecentFile(manyFiles, "/tmp/extra.nim")
assertEq(manyPinned.len, MaxRecentFiles, "pin caps list at MaxRecentFiles")
assertEq(manyPinned[0].path, "/tmp/extra.nim", "pinned extra at front")

echo "All recent_files tests passed!"

# Also verify welcome-screen ordering with pins
let ws = newWelcomeScreen()
let recent = @[
  (path: "/home/user/a.nim", isFolder: false),
  (path: "/home/user/b.nim", isFolder: false),
  (path: "/home/user/c.nim", isFolder: false)
]
ws.updateRecentFilesWithPins(recent, @["/home/user/b.nim"])

var recentSectionIdx = -1
for i, section in ws.sections:
  if section.title == "Recent":
    recentSectionIdx = i
    break
assertEq(recentSectionIdx >= 0, true, "Recent section exists")
let recentItems = ws.sections[recentSectionIdx].items
assertEq(recentItems.len, 3, "welcome recent item count")
assertEq(recentItems[0].data, "/home/user/b.nim", "pinned recent at top")
assertEq(recentItems[0].label.startsWith("\xF0\x9F\x93\x8C"), true, "pinned item has pin prefix")
assertEq(recentItems[1].data, "/home/user/a.nim", "unpinned recent follows")
assertEq(recentItems[2].data, "/home/user/c.nim", "unpinned recent order preserved")

echo "Welcome-screen pin ordering tests passed!"
