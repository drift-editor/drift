import ../src/utils/md_segments
import std/strutils

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

proc assertTrue(v: bool, msg: string = "") =
  if not v:
    echo "FAIL: ", msg
    quit(1)

# Empty document returns no segments.
let empty = markdownToSegments("")
assertEq(empty.len, 0, "empty doc")

# Plain paragraph.
let plain = markdownToSegments("Hello world")
assertEq(plain.len, 1, "plain segment count")
assertEq(plain[0].kind, mskText, "plain kind")
assertEq(plain[0].text, "Hello world", "plain text")

# Inline strong and emphasis.
let inlineStyles = markdownToSegments("**bold** and *italic*")
assertEq(inlineStyles.len, 3, "inline styles count")
assertEq(inlineStyles[0].kind, mskStrong, "strong kind")
assertEq(inlineStyles[0].text, "bold", "strong text")
assertEq(inlineStyles[1].kind, mskText, "between styles kind")
assertEq(inlineStyles[1].text, " and ", "between styles text")
assertEq(inlineStyles[2].kind, mskEm, "em kind")
assertEq(inlineStyles[2].text, "italic", "em text")

# Inline code.
let code = markdownToSegments("use `print()` here")
assertEq(code.len, 3, "code segment count")
assertEq(code[0].kind, mskText, "before code kind")
assertEq(code[0].text, "use ", "before code text")
assertEq(code[1].kind, mskCode, "code kind")
assertEq(code[1].text, "print()", "code text")
assertEq(code[2].kind, mskText, "after code kind")
assertEq(code[2].text, " here", "after code text")

# Heading.
let heading = markdownToSegments("## Section title")
assertTrue(heading.len >= 1, "heading segment count")
let hIdx = block:
  var idx = -1
  for i, s in heading:
    if s.kind == mskHeading:
      idx = i
      break
  idx
assertTrue(hIdx >= 0, "heading segment exists")
assertEq(heading[hIdx].level, 2, "heading level")
assertEq(heading[hIdx].text, "Section title", "heading text")

# Code block.
let codeBlock = markdownToSegments("```nim\nlet x = 1\n```")
assertTrue(codeBlock.len >= 1, "code block segment count")
for s in codeBlock:
  assertEq(s.kind, mskCodeBlock, "code block kind")
assertEq(codeBlock[0].text, "let x = 1", "code block first line")
assertEq(codeBlock[0].info, "nim", "code block info")

# Unordered list.
let ul = markdownToSegments("- first\n- second")
assertEq(ul.len, 2, "ul segment count")
assertEq(ul[0].kind, mskListItem, "ul item kind")
assertEq(ul[0].text, "- first", "ul first item")
assertEq(ul[1].text, "- second", "ul second item")

# Ordered list.
let ol = markdownToSegments("1. first\n2. second")
assertEq(ol.len, 2, "ol segment count")
assertEq(ol[0].text, "1. first", "ol first item")
assertEq(ol[1].text, "2. second", "ol second item")

# Blockquote.
let bq = markdownToSegments("> quoted text")
assertEq(bq.len, 1, "blockquote segment count")
assertEq(bq[0].kind, mskBlockquote, "blockquote kind")
assertEq(bq[0].text, "quoted text", "blockquote text")

# Horizontal rule.
let rule = markdownToSegments("---")
assertEq(rule.len, 1, "rule segment count")
assertEq(rule[0].kind, mskRule, "rule kind")

# Link.
let link = markdownToSegments("[Drift](https://drift-editor.dev)")
assertEq(link.len, 1, "link segment count")
assertEq(link[0].kind, mskLink, "link kind")
assertEq(link[0].text, "Drift", "link text")
assertEq(link[0].url, "https://drift-editor.dev", "link url")

# isProbablyMarkdown heuristic.
assertTrue(isProbablyMarkdown("# heading"), "detects heading")
assertTrue(isProbablyMarkdown("`code`"), "detects code")
assertTrue(isProbablyMarkdown("- item"), "detects list")
assertTrue(not isProbablyMarkdown("plain text"), "plain text not markdown")

# segmentsToPlainText fallback.
let segs = markdownToSegments("# Title\n\n`code`")
let fallback = segmentsToPlainText(segs)
assertTrue("Title" in fallback, "fallback contains heading")
assertTrue("code" in fallback, "fallback contains code")

echo "All md_segments tests passed!"
