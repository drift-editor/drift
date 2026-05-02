## Security-Scoped Bookmarks for macOS App Sandbox
## Allows persistent access to user-selected files across app launches.
## Non-macOS platforms get no-op stubs so the same code compiles everywhere.

import std/[os, base64, options]

when defined(macosx):
  import darwin/objc/runtime
  import darwin/foundation/[nsurl, nsdata, nsstring, nserror]

type
  FileBookmark* = object
    path*: string
    bookmarkData*: string ## base64-encoded bookmark data

when defined(macosx):
  var gActiveResources: seq[NSURL] = @[]

  proc createBookmarkForFile*(filePath: string): Option[FileBookmark] =
    ## Create a security-scoped bookmark for a file.
    ## Returns None if bookmark creation fails.
    if not fileExists(filePath):
      return none(FileBookmark)

    let url = NSURL.fileURLWithPath(@filePath)
    if url.isNil:
      return none(FileBookmark)

    var error: NSError = nil
    let data = url.bookmarkDataWithOptions(
      NSURLBookmarkCreationWithSecurityScope,
      nil, nil, addr error
    )
    if data.isNil:
      return none(FileBookmark)

    let len = data.length
    var bytes = newSeq[byte](len)
    if len > 0:
      data.getBytes(addr bytes[0], len)

    some(FileBookmark(
      path: filePath,
      bookmarkData: encode(cast[string](bytes))
    ))

  proc validateBookmark*(bookmark: FileBookmark): bool =
    ## Resolve a bookmark and verify the file is still accessible.
    ## Starts and immediately stops accessing (for validation only).
    let decoded = decode(bookmark.bookmarkData)
    if decoded.len == 0:
      return false

    var bytes = newSeq[byte](decoded.len)
    if decoded.len > 0:
      copyMem(addr bytes[0], unsafeAddr decoded[0], decoded.len)
    let nsData = NSData.withBytes(bytes)
    if nsData.isNil:
      return false

    var isStale: BOOL = false
    var error: NSError = nil
    let url = NSURL.URLByResolvingBookmarkData(
      nsData,
      NSURLBookmarkResolutionWithSecurityScope,
      nil, addr isStale, addr error
    )
    if url.isNil:
      return false

    discard url.startAccessingSecurityScopedResource()
    url.stopAccessingSecurityScopedResource()
    result = fileExists(bookmark.path)

  proc startAccessingBookmark*(bookmark: FileBookmark): bool =
    ## Resolve a bookmark and start accessing the security-scoped resource.
    ## The resource stays accessible until stopAccessingAll() is called.
    let decoded = decode(bookmark.bookmarkData)
    if decoded.len == 0:
      return false

    var bytes = newSeq[byte](decoded.len)
    if decoded.len > 0:
      copyMem(addr bytes[0], unsafeAddr decoded[0], decoded.len)
    let nsData = NSData.withBytes(bytes)
    if nsData.isNil:
      return false

    var isStale: BOOL = false
    var error: NSError = nil
    let url = NSURL.URLByResolvingBookmarkData(
      nsData,
      NSURLBookmarkResolutionWithSecurityScope,
      nil, addr isStale, addr error
    )
    if url.isNil:
      return false
    if url.startAccessingSecurityScopedResource().bool != true:
      return false

    gActiveResources.add(url)
    result = fileExists(bookmark.path)

  proc stopAccessingAllSecurityScopedResources*() =
    ## Stop accessing all security-scoped resources.
    ## Call during app cleanup or when done with bookmarked files.
    for url in gActiveResources:
      if not url.isNil:
        url.stopAccessingSecurityScopedResource()
    gActiveResources.setLen(0)

else:
  ## No-op stubs for non-macOS platforms
  proc createBookmarkForFile*(filePath: string): Option[FileBookmark] =
    none(FileBookmark)

  proc validateBookmark*(bookmark: FileBookmark): bool =
    fileExists(bookmark.path)

  proc startAccessingBookmark*(bookmark: FileBookmark): bool =
    fileExists(bookmark.path)

  proc stopAccessingAllSecurityScopedResources*() =
    discard
