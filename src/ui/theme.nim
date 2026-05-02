## UI Theme Module
## Shared theming and styling for UI components (uirelays version)

import uirelays/screen

type
  ThemeColor* = enum
    tcBackground       ## Main background
    tcSurface          ## Elevated surfaces (dialogs, panels)
    tcSurfaceHover     ## Hover state for surfaces
    tcBorder           ## Borders and dividers
    tcText             ## Primary text
    tcTextSecondary    ## Secondary/muted text
    tcTextDisabled     ## Disabled text
    tcAccent           ## Primary accent (selection, focus)
    tcAccentHover      ## Accent hover state
    tcCursor           ## Editor cursor
    tcSelection        ## Editor selection
    tcLineNumber       ## Line numbers
    tcLineNumberActive ## Current line number
    tcGutter           ## Gutter background
    tcSuccess          ## Success messages
    tcWarning          ## Warning messages
    tcError            ## Error messages
    tcInfo             ## Info messages

  SyntaxColor* = enum
    synDefault
    synKeyword
    synControlFlow
    synString
    synComment
    synNumber
    synFunction
    synType
    synBuiltin
    synVariable
    synOperator
    synPunctuation
    synProcName
    synExportMark
    synMarkdownFence
    synMarkdownLanguage

  Theme* = object
    colors*: array[ThemeColor, Color]
    syntax*: array[SyntaxColor, Color]
    fontSize*: int
    fontSizeSmall*: int

const
  BorderRadius* = 4
  Spacing* = 8
  Padding* = 12

# Dark theme (default) -- Zed-inspired
proc darkTheme*(): Theme =
  Theme(
    colors: [
      tcBackground:       color(15,  17,  22,  255),
      tcSurface:          color(22,  24,  29,  255),
      tcSurfaceHover:     color(30,  33,  40,  255),
      tcBorder:           color(35,  38,  47,  255),
      tcText:             color(153, 161, 179, 255),
      tcTextSecondary:    color(101, 108, 125, 255),
      tcTextDisabled:     color(70,  75,  90,  255),
      tcAccent:           color(75,  146, 255, 255),
      tcAccentHover:      color(100, 165, 255, 255),
      tcCursor:           color(255, 255, 255, 255),
      tcSelection:        color(35,  40,  50,  200),
      tcLineNumber:       color(65,  70,  85,  255),
      tcLineNumberActive: color(130, 138, 155, 255),
      tcGutter:           color(18,  20,  25,  255),
      tcSuccess:          color(80,  180, 100, 255),
      tcWarning:          color(220, 160, 60,  255),
      tcError:            color(220, 90,  90,  255),
      tcInfo:             color(80,  150, 220, 255),
    ],
    syntax: [
      synDefault:     color(153, 161, 179, 255),
      synKeyword:     color(197, 141, 222, 255),
      synControlFlow: color(215, 120, 190, 255),
      synString:      color(165, 209, 109, 255),
      synComment:     color(92,  99,  112, 255),
      synNumber:      color(108, 182, 235, 255),
      synFunction:    color(212, 164, 106, 255),
      synType:        color(93,  175, 168, 255),
      synBuiltin:     color(93,  175, 168, 255),
      synVariable:    color(153, 161, 179, 255),
      synOperator:    color(139, 146, 168, 255),
      synPunctuation: color(139, 146, 168, 255),
      synProcName:    color(212, 164, 106, 255),
      synExportMark:  color(180, 130, 220, 255),
      synMarkdownFence:     color(128, 128, 128, 255),
      synMarkdownLanguage:  color(86,  156, 214, 255),
    ],
    fontSize: 14,
    fontSizeSmall: 12
  )

# Light theme
proc lightTheme*(): Theme =
  Theme(
    colors: [
      tcBackground:       color(250, 250, 250, 255),
      tcSurface:          color(255, 255, 255, 255),
      tcSurfaceHover:     color(240, 240, 240, 255),
      tcBorder:           color(200, 200, 200, 255),
      tcText:             color(30,  30,  30,  255),
      tcTextSecondary:    color(100, 100, 100, 255),
      tcTextDisabled:     color(150, 150, 150, 255),
      tcAccent:           color(0,   100, 200, 255),
      tcAccentHover:      color(0,   120, 230, 255),
      tcCursor:           color(0,   0,   0,   255),
      tcSelection:        color(180, 210, 255, 180),
      tcLineNumber:       color(150, 150, 150, 255),
      tcLineNumberActive: color(80,  80,  80,  255),
      tcGutter:           color(245, 245, 245, 255),
      tcSuccess:          color(40,  160, 60,  255),
      tcWarning:          color(230, 150, 30,  255),
      tcError:            color(220, 60,  60,  255),
      tcInfo:             color(60,  140, 220, 255),
    ],
    syntax: [
      synDefault:     color(30,  30,  30,  255),
      synKeyword:     color(180, 50,  120, 255),
      synControlFlow: color(180, 60,  150, 255),
      synString:      color(80,  140, 60,  255),
      synComment:     color(140, 140, 140, 255),
      synNumber:      color(60,  120, 180, 255),
      synFunction:    color(160, 100, 40,  255),
      synType:        color(60,  140, 120, 255),
      synBuiltin:     color(60,  140, 120, 255),
      synVariable:    color(30,  30,  30,  255),
      synOperator:    color(100, 100, 100, 255),
      synPunctuation: color(80,  80,  80,  255),
      synProcName:    color(160, 100, 40,  255),
      synExportMark:  color(140, 80,  160, 255),
      synMarkdownFence:     color(128, 128, 128, 255),
      synMarkdownLanguage:  color(60,  120, 180, 255),
    ],
    fontSize: 14,
    fontSizeSmall: 12
  )

# Global theme instance
var currentTheme* = darkTheme()

proc getColor*(theme: Theme, color: ThemeColor): Color =
  theme.colors[color]

proc getSyntaxColor*(theme: Theme, syntax: SyntaxColor): Color =
  theme.syntax[syntax]

proc setTheme*(theme: Theme) =
  currentTheme = theme

# SynEdit Theme

import widgets/theme as synTheme

proc driftSyneditTheme*(): synTheme.Theme =
  result.bg = currentTheme.getColor(tcBackground)
  result.selBg = currentTheme.getColor(tcSelection)
  result.bracketBg = currentTheme.getColor(tcSurfaceHover)
  result.cursorColor = currentTheme.getColor(tcCursor)
  result.lineNumColor = currentTheme.getColor(tcLineNumber)
  result.markerBg = color(55, 60, 45, 255)
  result.scrollBarColor = currentTheme.getColor(tcTextSecondary)
  result.scrollBarActiveColor = currentTheme.getColor(tcText)
  result.scrollTrackColor = currentTheme.getColor(tcSurface)
  for tc in synTheme.TokenClass:
    result.fg[tc] = currentTheme.getSyntaxColor(synDefault)
  result.fg[synTheme.TokenClass.Keyword] = currentTheme.getSyntaxColor(synKeyword)
  result.fg[synTheme.TokenClass.StringLit] = currentTheme.getSyntaxColor(synString)
  result.fg[synTheme.TokenClass.LongStringLit] = currentTheme.getSyntaxColor(synString)
  result.fg[synTheme.TokenClass.CharLit] = currentTheme.getSyntaxColor(synString)
  result.fg[synTheme.TokenClass.RawData] = currentTheme.getSyntaxColor(synString)
  result.fg[synTheme.TokenClass.Comment] = currentTheme.getSyntaxColor(synComment)
  result.fg[synTheme.TokenClass.LongComment] = currentTheme.getSyntaxColor(synComment)
  result.fg[synTheme.TokenClass.DecNumber] = currentTheme.getSyntaxColor(synNumber)
  result.fg[synTheme.TokenClass.BinNumber] = currentTheme.getSyntaxColor(synNumber)
  result.fg[synTheme.TokenClass.HexNumber] = currentTheme.getSyntaxColor(synNumber)
  result.fg[synTheme.TokenClass.OctNumber] = currentTheme.getSyntaxColor(synNumber)
  result.fg[synTheme.TokenClass.FloatNumber] = currentTheme.getSyntaxColor(synNumber)
  result.fg[synTheme.TokenClass.Identifier] = currentTheme.getSyntaxColor(synVariable)
  result.fg[synTheme.TokenClass.ControlFlow] = currentTheme.getSyntaxColor(synControlFlow)
  result.fg[synTheme.TokenClass.Function] = currentTheme.getSyntaxColor(synFunction)
  result.fg[synTheme.TokenClass.ProcName] = currentTheme.getSyntaxColor(synProcName)
  result.fg[synTheme.TokenClass.Type] = currentTheme.getSyntaxColor(synType)
  result.fg[synTheme.TokenClass.Builtin] = currentTheme.getSyntaxColor(synBuiltin)
  result.fg[synTheme.TokenClass.ExportMark] = currentTheme.getSyntaxColor(synExportMark)
  result.fg[synTheme.TokenClass.MarkdownFence] = currentTheme.getSyntaxColor(synMarkdownFence)
  result.fg[synTheme.TokenClass.MarkdownLanguage] = currentTheme.getSyntaxColor(synMarkdownLanguage)
  result.fg[synTheme.TokenClass.Operator] = currentTheme.getSyntaxColor(synOperator)
  result.fg[synTheme.TokenClass.Punctuation] = currentTheme.getSyntaxColor(synPunctuation)

# INTEGRATION_NOTES
# This module is a port of src_old_backup/ui/theme.nim to uirelays.
# Changes made:
#   - Color type changed from core/types.Color to uirelays/screen.Color (uint8 r,g,b,a).
#   - Removed float32-based sizing fields (borderRadius, spacing, padding).
#     Use the exported consts BorderRadius, Spacing, Padding instead.
#   - Removed dpiScale and scaledFontSize helpers; uirelays handles DPI via the driver.
# To integrate into src/app/app.nim:
#   - Import src/ui/theme.
#   - Replace any old Color references with uirelays/screen.Color.
#   - Replace theme.borderRadius / theme.spacing / theme.padding with the consts above.
