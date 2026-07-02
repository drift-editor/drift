## Auto-close brackets and quotes for the Drift editor.
##
## Intercept TextInputEvent and KeyBackspace before passing to SynEdit so that:
##   - Typing an opener inserts the closer and leaves cursor between them
##   - Typing a closer when already sitting on one skips over it
##   - Backspace on an empty pair deletes both characters

import widgets/synedit

# Pair table: opener -> closer
const openers* = {'(', '[', '{', '"', '\'', '`'}
const closers* = {')', ']', '}', '"', '\'', '`'}

func pairClose*(c: char): char =
  case c
  of '(': ')'
  of '[': ']'
  of '{': '}'
  of '"': '"'
  of '\'': '\''
  of '`': '`'
  else: '\0'

func pairOpen*(c: char): char =
  case c
  of ')': '('
  of ']': '['
  of '}': '{'
  of '"': '"'
  of '\'': '\''
  of '`': '`'
  else: '\0'

func isOpener*(c: char): bool = c in openers
func isCloser*(c: char): bool = c in closers

proc charAfterCursor*(ed: SynEdit): char =
  ## Character immediately after the cursor, or '\0' if at end.
  let pos = ed.cursor
  if pos < ed.len: ed[pos] else: '\0'

proc charBeforeCursor*(ed: SynEdit): char =
  ## Character immediately before the cursor, or '\0' if at start.
  let pos = ed.cursor
  if pos > 0: ed[pos - 1] else: '\0'

proc shouldAutoClose*(ed: SynEdit, ch: char): bool =
  ## True when typing opener `ch` should also insert the closer.
  ## Fires when the character after cursor is whitespace, a closer, or end-of-buffer.
  if not isOpener(ch): return false
  let next = charAfterCursor(ed)
  result = next == '\0' or next == '\n' or next in closers or next == ' ' or next == '\t'

proc shouldSkipOver*(ed: SynEdit, ch: char): bool =
  ## True when the cursor already sits on `ch` and `ch` is a closer —
  ## just advance instead of inserting another one.
  if not isCloser(ch): return false
  charAfterCursor(ed) == ch

proc shouldDeletePair*(ed: SynEdit): bool =
  ## True when Backspace is pressed and cursor is between a matching pair.
  let before = charBeforeCursor(ed)
  let after  = charAfterCursor(ed)
  if before == '\0' or after == '\0': return false
  isOpener(before) and pairClose(before) == after
