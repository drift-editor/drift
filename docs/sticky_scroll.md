# Sticky Scroll Coloring System

## Overview

The sticky scroll feature displays scope headers (proc, type, const, etc.) at the top of the editor when scrolled down into nested code. This document describes the coloring implementation.

## Why Custom Tokenization?

The main editor uses `SynEdit` from the uirelays package, which has a sophisticated `GeneralTokenizer` that handles full syntax highlighting with state tracking across lines. 

**Why not use SynEdit's tokenization directly?**

SynEdit stores tokenization in its internal `Cell` structure:
```nim
Cell = object
  c: char        # character
  s: TokenClass  # syntax highlighting token type
```

However, the `Cell` type and `getCell()` accessor are **not exported** from the uirelays package. We can only access characters via `ed[i]`, not the TokenClass. To use SynEdit's tokenization, we would need to either:
1. Modify uirelays to export `Cell` and `getCell` 
2. Add a new exported function like `getLineTokens()`

**Current approach:**

Creating a custom `tokenizeLine()` function provides:
- **Simplicity**: No need for multi-line state tracking
- **Independence**: Doesn't require SynEdit instance or buffer access  
- **Performance**: Lightweight tokenization for just the visible sticky lines
- **No external changes**: Works without modifying the uirelays package

The tradeoff is that we need to maintain keyword/builtin lists separately, but this is acceptable for the limited scope of sticky scroll headers.

## Files

- `src/editor/sticky_scroll.nim` - Tokenization and rendering
- `src/app/app.nim` - Integration in render loop

## Flow

```
app.nim render loop:
    1. check cacheId → update bufferTokens if changed (for main editor)
    2. computeStickyLines(bufferLines, firstLine) → seq[StickyLine]
    3. for each sticky line:
         tokenizeLine(sl.text) → seq[LineToken]
         drawHighlightedLine(font, x, y, text, tokens, theme, color)
```

## Data Types

```nim
type
  LineToken* = object
    start*: int       # position in line
    length*: int      # token length
    tokenType*: synTheme.TokenClass

  StickyLine* = object
    line*: int       # original line number in buffer
    text*: string    # stripped text content
```

## Functions

### tokenizeLine(text: string): seq[LineToken]

Tokenizes a single line into colored tokens.

Token types:
- `TokenClass.Comment` - `#` at start of line
- `TokenClass.CharLit` - backtick strings
- `TokenClass.StringLit` - double-quoted strings
- `TokenClass.DecNumber` - numbers
- `TokenClass.Keyword` - Nim keywords
- `TokenClass.Identifier` - other identifiers
- `TokenClass.Punctuation` - symbols

### tokenizeBuffer(lines: seq[string]): seq[seq[LineToken]]

Tokenizes entire buffer. Returns `seq[seq[LineToken]]` - one token sequence per line.

### tokenizedStickyLine(tokens: seq[seq[LineToken]], lineNum: int): seq[LineToken]

Looks up pre-computed tokens for a specific line number.

### drawHighlightedLine(font, x, y, text, tokens, theme, defaultColor)

Draws text with token colors. Handles:
- Gaps between tokens
- Trailing text after last token
- Tokens beyond text length (skipped)

## Integration in app.nim

```nim
# Update tokens BEFORE sticky scroll renders
let ed = app.buffers[idx].ed
let cid = ed.cacheId
if cid != app.lastColorScanCacheIds[idx] or app.bufferTokens[idx].len == 0:
  app.lastColorScanCacheIds[idx] = cid
  let full = ed.fullText()
  app.bufferLines[idx] = full.splitLinesKeep()
  app.bufferTokens[idx] = tokenizeBuffer(app.bufferLines[idx])
  ...

# Sticky scroll overlay
let sticky = computeStickyLines(app.bufferLines[idx], ed.firstLine, 5)
for i, sl in sticky:
  let stickyTokens = tokenizedStickyLine(app.bufferTokens[idx], sl.line)
  drawHighlightedLine(app.font, textX, y + 2, sl.text, stickyTokens, ed.theme, textColor)
```

## Known Issues

1. **Tokenization not triggered on fresh load**: `setText` increments `version`, not `cacheId`. FIX: check `bufferTokens.len == 0` as fallback.

2. **Wrong token lookup**: Was passing `sl.text` instead of `sl.line`. FIX: pass line number.

3. **Gap handling missing**: Original code didn't draw gaps between tokens. FIX: added gap/trailing handling.

4. **TokenClass.None undefined**: Theme doesn't define color for None. FIX: pass defaultColor parameter.

## Debugging

To add debug logging:

```nim
# In app.nim tokenization block:
stderr.writeLine("[app] tokenizing: cacheId=", $cid, " lines=", $app.bufferLines[idx].len)
```

## Testing

```bash
./drift test_file.nim
# Scroll down to see sticky headers
# Keywords (proc, type, var, const) should be colored
```

## Sticky Scroll Coloring Issues - FIXED ✓

**Status**: Fixed on 2026-04-21

### Issue 1: Text/Token Position Mismatch

**Problem**: Pre-computed tokens for original buffer lines were being used to highlight stripped text in sticky scroll.

**Solution**: Changed to tokenize the stripped text directly:
```nim
let stickyTokens = tokenizeLine(sl.text)  # Instead of tokenizedStickyLine(app.bufferTokens[idx], sl.line)
```

### Issue 2: Inconsistent Width Calculation

**Problem**: Gap text was using `measureText()` while token text was using `drawText()` return value, causing incorrect cursor positioning.

**Solution**: Use `drawText()` return value consistently:
```nim
let gapExt = drawText(font, cx, y, gapText, defaultColor, color(0, 0, 0, 0))
cx += gapExt.w
```

### Issue 3: TokenClass.None Being Drawn (CRITICAL BUG)

**Problem**: Whitespace tokens (spaces, tabs) were being created as `TokenClass.None` and drawn with theme colors, making them visible and causing them to overwrite subsequent tokens. This was the main reason only the first keyword appeared colored - the space after it was being drawn over the following text!

**Root Cause**: The tokenizer was creating tokens for whitespace, and `drawHighlightedLine` was drawing ALL tokens including whitespace.

**Solution**: Don't create tokens for whitespace at all - let them be gaps:
```nim
# In tokenizeLine - skip whitespace instead of tokenizing it
if c in {' ', '\t'}:
  inc i  # Just advance, don't create token
else:
  tc = synTheme.TokenClass.Punctuation
  result.add(LineToken(start: i, length: 1, tokenType: tc))
  inc i
```

This way, whitespace becomes gaps between tokens, which `drawHighlightedLine` handles correctly by drawing with the default color.

### Issue 4: Missing Builtin Type Recognition

**Problem**: Builtin types like `string`, `bool`, `int` were being tokenized as `Identifier` instead of `Builtin`.

**Solution**: Added `nimBuiltinTypes` constant and updated tokenization logic:
```nim
const nimBuiltinTypes = ["int", "int8", "int16", "int32", "int64",
  "uint", "uint8", "uint16", "uint32", "uint64",
  "float", "float32", "float64",
  "bool", "char", "string", "cstring",
  "pointer", "void", "auto", "any",
  "seq", "array", "set", "Table", "OrderedTable"]

tc = if word in nimKeywords: synTheme.TokenClass.Keyword
     elif word in nimBuiltinTypes: synTheme.TokenClass.Builtin
     else: synTheme.TokenClass.Identifier
```

### Summary

The main issue was that whitespace tokens were being drawn as visible characters, overwriting subsequent text. This made it appear as if only the first keyword was colored, when in reality all tokens after the first space were being covered up by the drawn whitespace.

### Testing

```bash
nim c src/app/app.nim
./drift test_file.nim
# Scroll down to see sticky headers
# Keywords (proc, type, var, const) show in purple
# Builtin types (string, bool, int) show in teal
# Identifiers show in default text color
# Punctuation shows in muted color
# Whitespace is invisible (as it should be)
```