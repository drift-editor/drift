## Status Bar Component
## Bottom status bar showing editor information with left/right alignment

import uirelays/[coords, screen]
import theme, icons

const
  StatusBarHeight* = 26
  SectionPadding* = 16

type
  StatusBar* = ref object
    leftSections*: seq[string]
    rightSections*: seq[string]
    leftIcons*: seq[IconId]   ## parallel to leftSections; iiNone = no icon
    leftColors*: seq[Color]   ## parallel to leftSections; zero color = use default
    rightIcons*: seq[IconId]  ## parallel to rightSections
    rightColors*: seq[Color]  ## parallel to rightSections
    hoverRightIndex*: int     ## -1 = none
    activeRightIndex*: int    ## -1 = none
    lspIndex*: int            ## -1 = not present
    dapIndex*: int            ## -1 = not present
    aiIndex*: int             ## -1 = not present
    lineEndingIndex*: int     ## -1 = not present
    encodingIndex*: int       ## -1 = not present
    rightSectionBounds*: seq[Rect]  ## computed during render, parallel to rightSections

proc newStatusBar*(): StatusBar =
  StatusBar(leftSections: @[], rightSections: @[], leftIcons: @[], leftColors: @[],
            hoverRightIndex: -1, activeRightIndex: -1, lspIndex: -1, dapIndex: -1,
            aiIndex: -1, lineEndingIndex: -1, encodingIndex: -1)

proc render*(bar: StatusBar, font: Font, bounds: Rect) =
  fillRect(bounds, currentTheme.getColor(tcSurface))
  fillRect(rect(bounds.x, bounds.y, bounds.w, 1), currentTheme.getColor(tcBorder))

  let fm = font.getFontMetrics()
  let textY = bounds.y + (StatusBarHeight - fm.lineHeight) div 2
  let iconY = bounds.y + (StatusBarHeight - 16) div 2
  let hoverBg = currentTheme.getColor(tcSurfaceHover)
  let accentC = currentTheme.getColor(tcAccent)
  let textC = currentTheme.getColor(tcText)

  var x = bounds.x + SectionPadding
  for i, text in bar.leftSections:
    let icon = if i < bar.leftIcons.len: bar.leftIcons[i] else: iiNone
    if icon != iiNone:
      drawIcon(icon, x, iconY)
      x += 16 + 4
    let textColor = if i < bar.leftColors.len and bar.leftColors[i] != color(0, 0, 0, 0):
      bar.leftColors[i]
    else:
      textC
    let ext = font.drawText(x, textY, text, textColor, color(0, 0, 0, 0))
    x += ext.w + SectionPadding * 2
    if i < bar.leftSections.len - 1:
      fillRect(rect(x - SectionPadding, bounds.y + 4, 1, StatusBarHeight - 8), currentTheme.getColor(tcBorder))

  var rightWidth = 0
  var sectionWidths: seq[int]
  for i, text in bar.rightSections:
    let ext = font.measureText(text)
    var sectionW = ext.w + SectionPadding * 2
    let icon = if i < bar.rightIcons.len: bar.rightIcons[i] else: iiNone
    if icon != iiNone:
      sectionW += 16 + 4
    sectionWidths.add(sectionW)
    rightWidth += sectionW

  bar.rightSectionBounds = newSeq[Rect](bar.rightSections.len)
  x = bounds.x + bounds.w - rightWidth + SectionPadding
  for i, text in bar.rightSections:
    let sectionW = sectionWidths[i]
    let isHovered = i == bar.hoverRightIndex
    let isActive = i == bar.activeRightIndex

    # Hover / active background pill
    if isHovered or isActive:
      let pad = if isActive: 4 else: 2
      let pillAlpha = if isActive: 40 else: 25
      var pillColor = hoverBg
      if isActive:
        pillColor = color(accentC.r, accentC.g, accentC.b, uint8(pillAlpha))
      else:
        pillColor = color(hoverBg.r, hoverBg.g, hoverBg.b, uint8(pillAlpha))
      fillRect(rect(x + pad, bounds.y + pad, sectionW - pad * 2, StatusBarHeight - pad * 2), pillColor)

    let icon = if i < bar.rightIcons.len: bar.rightIcons[i] else: iiNone
    let iconX = x
    if icon != iiNone:
      drawIcon(icon, iconX, iconY)

    let textX = if icon != iiNone: x + 16 + 4 else: x
    let textColor = if isActive:
      accentC
    elif i < bar.rightColors.len and bar.rightColors[i] != color(0, 0, 0, 0):
      bar.rightColors[i]
    else:
      textC
    discard font.drawText(textX, textY, text, textColor, color(0, 0, 0, 0))
    bar.rightSectionBounds[i] = rect(x, bounds.y, sectionW, bounds.h)
    x += sectionW
    if i < bar.rightSections.len - 1:
      fillRect(rect(x - SectionPadding, bounds.y + 4, 1, StatusBarHeight - 8), currentTheme.getColor(tcBorder))
