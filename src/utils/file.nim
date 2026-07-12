import std/[os, strutils]

proc isImageFile*(path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii()
  ext in [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"]

proc isBinaryFile*(path: string): bool =
  if not fileExists(path):
    return false
  try:
    let f = open(path, fmRead)
    defer: f.close()
    var buf: array[8192, char]
    let read = f.readChars(toOpenArray(buf, 0, buf.len - 1))
    for i in 0 ..< read:
      if buf[i] == '\0':
        return true
    # Limitation: only the first 8KB is scanned; null bytes beyond this
    # point in very large files are not detected.
    false
  except IOError:
    false

proc detectLineEnding*(text: string): string =
  if text.contains("\c\L"): "CRLF"
  else: "LF"

proc languageIdFor*(path: string): string =
  if path.len == 0:
    return "nim"
  let ext = path.splitFile.ext.toLowerAscii()
  case ext
  of ".nim", ".nims": "nim"
  of ".py": "python"
  of ".js", ".jsx": "javascript"
  of ".ts", ".tsx": "typescript"
  of ".c", ".h": "c"
  of ".cpp", ".cc", ".cxx", ".hpp": "cpp"
  of ".cs": "csharp"
  of ".java": "java"
  of ".rs": "rust"
  of ".html", ".htm": "html"
  of ".xml": "xml"
  of ".md", ".markdown": "markdown"
  else: ""

proc pathStartsWith*(path, prefix: string): bool =
  let normPath = path.replace('\\', '/')
  let normPrefix = prefix.replace('\\', '/')
  normPath.startsWith(normPrefix & "/")
