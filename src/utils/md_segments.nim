## Minimal Markdown segment renderer for the AI chat panel.
## Uses nim-markdown to parse content into an AST, then flattens the AST
## into styled segments that can be rendered with uirelays primitives.

import std/strutils
import markdown as mdlib except markdown

export mdlib.Token, mdlib.Document, mdlib.Paragraph, mdlib.Heading,
       mdlib.CodeBlock, mdlib.Blockquote, mdlib.Ul, mdlib.Ol,
       mdlib.Li, mdlib.Text, mdlib.CodeSpan, mdlib.Em, mdlib.Strong,
       mdlib.Link, mdlib.AutoLink, mdlib.SoftBreak, mdlib.HardBreak,
       mdlib.ThematicBreak, mdlib.MarkdownError

type
  MdSegmentKind* = enum
    mskText        ## Plain text (may be inside other inline styles)
    mskStrong      ## Bold text (rendered with accent color, no real bold font)
    mskEm          ## Italic text (rendered muted, no real italic font)
    mskCode        ## Inline code
    mskCodeBlock   ## Fenced or indented code block
    mskHeading     ## Heading line (prefix with # markers)
    mskBlockquote  ## Quote line (left bar + muted)
    mskListItem    ## List item (prefix with bullet/number)
    mskLink        ## Hyperlink (text + url)
    mskBreak       ## Explicit line break
    mskRule        ## Thematic break / horizontal rule

  MdSegment* = object
    kind*: MdSegmentKind
    text*: string
    url*: string          ## For links
    info*: string         ## For code blocks (language)
    level*: int           ## Heading level or list nesting
    index*: int           ## Ordered list number

proc stripInlineMarkers(s: string): string =
  ## Remove backslash escapes from display text.
  result = s.multiReplace([("\\*", "*"), ("\\_", "_"), ("\\`", "`"), ("\\[", "["), ("\\]", "]")])

proc flattenLinkText(token: Token, parts: var seq[string])

proc flattenInlines(token: Token, segments: var seq[MdSegment], baseKind: MdSegmentKind = mskText) =
  ## Walk inline tokens and emit plain text segments with inline-style hints.
  var node = token.children.head
  while node != nil:
    let child = node.value
    if child of Text:
      let t = Text(child)
      let txt = stripInlineMarkers(t.doc)
      if txt.len > 0:
        segments.add(MdSegment(kind: baseKind, text: txt))
    elif child of CodeSpan:
      segments.add(MdSegment(kind: mskCode, text: stripInlineMarkers(child.doc)))
    elif child of Em:
      flattenInlines(child, segments, mskEm)
    elif child of Strong:
      flattenInlines(child, segments, mskStrong)
    elif child of Link:
      var textParts: seq[string]
      flattenLinkText(child, textParts)
      let linkText = textParts.join("")
      if linkText.len > 0:
        segments.add(MdSegment(kind: mskLink, text: linkText, url: Link(child).url))
    elif child of AutoLink:
      let a = AutoLink(child)
      segments.add(MdSegment(kind: mskLink, text: a.text, url: a.url))
    elif child of SoftBreak:
      segments.add(MdSegment(kind: mskText, text: " "))
    elif child of HardBreak:
      segments.add(MdSegment(kind: mskBreak))
    elif child of Escape:
      let txt = stripInlineMarkers(child.doc)
      if txt.len > 0:
        segments.add(MdSegment(kind: baseKind, text: txt))
    else:
      # Fallback: render the raw doc text.
      if child.doc.len > 0:
        segments.add(MdSegment(kind: baseKind, text: stripInlineMarkers(child.doc)))
    node = node.next

proc flattenLinkText(token: Token, parts: var seq[string]) =
  ## Recursively collect visible text from a Link's children.
  var node = token.children.head
  while node != nil:
    let child = node.value
    if child of Text:
      parts.add(stripInlineMarkers(Text(child).doc))
    elif child of CodeSpan:
      parts.add(stripInlineMarkers(child.doc))
    elif child of Em or child of Strong or child of Link:
      flattenLinkText(child, parts)
    elif child of AutoLink:
      parts.add(AutoLink(child).text)
    elif child.doc.len > 0:
      parts.add(stripInlineMarkers(child.doc))
    node = node.next

proc markdownToSegments*(doc: string): seq[MdSegment] =
  ## Parse a markdown document and flatten it into renderable segments.
  if doc.len == 0:
    return @[]
  var root = Document()
  try:
    discard mdlib.markdown(doc, root = root)
  except MarkdownError:
    # If parsing fails, return the raw text as a single segment.
    return @[MdSegment(kind: mskText, text: doc)]

  var segments: seq[MdSegment]

  proc walkBlock(token: Token; depth: int; listNumber: var int) =
    var node = token.children.head
    while node != nil:
      let child = node.value
      if child of Paragraph:
        flattenInlines(child, segments)
        segments.add(MdSegment(kind: mskBreak))
      elif child of Heading:
        var headText = ""
        var tmp: seq[MdSegment]
        flattenInlines(child, tmp)
        for s in tmp:
          if s.kind in {mskText, mskStrong, mskEm, mskCode, mskLink}:
            headText.add(s.text)
        segments.add(MdSegment(kind: mskHeading, text: headText, level: Heading(child).level))
        segments.add(MdSegment(kind: mskBreak))
      elif child of CodeBlock:
        let info = CodeBlock(child).info
        let lines = child.doc.splitLines()
        for line in lines:
          segments.add(MdSegment(kind: mskCodeBlock, text: line, info: info))
        if lines.len > 0:
          segments.add(MdSegment(kind: mskBreak))
      elif child of Blockquote:
        # Blockquotes can contain nested blocks; prefix every emitted line.
        let startIdx = segments.len
        walkBlock(child, depth + 1, listNumber)
        for i in startIdx ..< segments.len:
          if segments[i].kind == mskBreak:
            continue
          # Convert any segment in the quote to a blockquote segment.
          segments[i].kind = mskBlockquote
          segments[i].level = depth
      elif child of Ul:
        walkBlock(child, depth, listNumber)
      elif child of Ol:
        let saved = listNumber
        listNumber = Ol(child).start
        walkBlock(child, depth, listNumber)
        listNumber = saved
      elif child of Li:
        let marker = if child of Li and Li(child).marker == ".":
                       $listNumber & "."
                     else:
                       "-"
        inc listNumber
        # Collect the item's inline/block content.
        let startIdx = segments.len
        walkBlock(child, depth + 1, listNumber)
        # Insert list-item marker at the beginning of the first text-bearing segment,
        # or as a new segment if none exists.
        var inserted = false
        for i in startIdx ..< segments.len:
          if segments[i].kind in {mskText, mskStrong, mskEm, mskCode, mskHeading, mskBlockquote}:
            segments[i].kind = mskListItem
            segments[i].text = marker & " " & segments[i].text
            segments[i].level = depth
            inserted = true
            break
        if not inserted and startIdx < segments.len:
          segments[startIdx].kind = mskListItem
          segments[startIdx].level = depth
          segments[startIdx].text = marker & " " & segments[startIdx].text
        # Trim the trailing paragraph break so list items sit tightly together.
        if segments.len > startIdx and segments[^1].kind == mskBreak:
          segments.setLen(segments.len - 1)
      elif child of ThematicBreak:
        segments.add(MdSegment(kind: mskRule))
        segments.add(MdSegment(kind: mskBreak))
      elif child of Text:
        # Loose text at block level.
        let txt = stripInlineMarkers(Text(child).doc)
        if txt.len > 0:
          segments.add(MdSegment(kind: mskText, text: txt))
      else:
        # Unknown block: try to render raw doc.
        if child.doc.len > 0:
          segments.add(MdSegment(kind: mskText, text: stripInlineMarkers(child.doc)))
      node = node.next

  var listNumber = 1
  walkBlock(root, 0, listNumber)

  # Trim trailing breaks.
  while segments.len > 0 and segments[^1].kind == mskBreak:
    segments.setLen(segments.len - 1)

  result = segments

proc segmentsToPlainText*(segments: seq[MdSegment]): string =
  ## Fallback plain-text representation for copy-to-clipboard.
  for i, s in segments:
    case s.kind
    of mskLink:
      result.add(s.text & " (" & s.url & ")")
    of mskBreak:
      result.add("\n")
    of mskRule:
      result.add("---\n")
    of mskHeading:
      result.add(repeat("#", s.level) & " " & s.text & "\n")
    of mskListItem:
      result.add(repeat("  ", s.level) & s.text & "\n")
    of mskBlockquote:
      result.add(repeat("  ", s.level) & "> " & s.text & "\n")
    of mskCodeBlock:
      result.add(s.text & "\n")
    else:
      result.add(s.text)
  result = result.strip(leading = false, chars = {'\n'})

proc isProbablyMarkdown*(s: string): bool =
  ## Heuristic to decide whether a message should be parsed as markdown.
  ## Avoids running the parser on every short/plain response.
  if s.len == 0: return false
  let markers = [
    "```", "#", "##", "###", "**", "__", "*", "_", "`", "[>",
    "- ", "* ", "1. ", "2. ", "3. ", "| ", "---", "***", "___"
  ]
  for m in markers:
    if s.contains(m):
      return true
  return false
