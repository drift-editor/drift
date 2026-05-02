## Notification Component
## Toast notification manager for uirelays

import std/[times, strutils, math]
import uirelays
import uirelays/screen
import theme

const
  DefaultDurationMs = 3000
  FadeDurationMs = 300
  NotificationMinWidth = 200
  NotificationMaxWidth = 400
  NotificationPadding = 12
  NotificationMinHeight = 40
  Spacing = 8

type
  NotificationType* = enum
    ntSuccess
    ntError
    ntWarning
    ntInfo

  Notification* = ref object
    id*: string
    message*: string
    lines*: seq[string]
    notificationType*: NotificationType
    createdAt*: float64
    durationMs*: int
    alpha*: uint8
    targetY*: int
    currentY*: int
    bounds*: Rect
    dismissed*: bool

  NotificationManager* = ref object
    notifications*: seq[Notification]
    nextId*: int
    viewport*: Rect
    font*: Font
    lineHeight*: int
    charWidth*: int

# Helpers

proc getTypeColor(notificationType: NotificationType): Color =
  case notificationType
  of ntSuccess: currentTheme.getColor(tcSuccess)
  of ntError:   currentTheme.getColor(tcError)
  of ntWarning: currentTheme.getColor(tcWarning)
  of ntInfo:    currentTheme.getColor(tcInfo)

proc calculateWidth(message: string, charWidth: int): int =
  let width = message.len * charWidth + NotificationPadding * 2
  max(NotificationMinWidth, min(width, NotificationMaxWidth))

proc wrapText(message: string, charWidth: int, maxWidth: int): seq[string] =
  if message.len == 0:
    return @[""]
  let words = message.split(' ')
  var currentLine = ""
  for word in words:
    let testLine = if currentLine.len > 0: currentLine & " " & word else: word
    let tw = testLine.len * charWidth
    if tw <= maxWidth:
      currentLine = testLine
    else:
      if currentLine.len > 0:
        result.add(currentLine)
        currentLine = word
      else:
        # Single word too long, truncate
        var truncated = word
        while truncated.len > 0:
          let withEllipsis = if truncated.len < word.len: truncated & "..." else: truncated
          if withEllipsis.len * charWidth <= maxWidth:
            result.add(withEllipsis)
            break
          truncated.setLen(truncated.len - 1)
        if truncated.len == 0:
          result.add(word)
        currentLine = ""
  if currentLine.len > 0:
    result.add(currentLine)

proc calculateHeight(lineCount: int, lineHeight: int): int =
  max(NotificationMinHeight, lineCount * lineHeight + NotificationPadding * 2)

# Creation

proc newNotificationManager*(viewport: Rect, font: Font): NotificationManager =
  let sample = measureText(font, "Mg")
  NotificationManager(
    notifications: @[],
    nextId: 0,
    viewport: viewport,
    font: font,
    lineHeight: sample.h,
    charWidth: sample.w div 2
  )

proc add*(manager: NotificationManager,
          message: string,
          notificationType: NotificationType = ntInfo,
          durationMs: int = DefaultDurationMs): Notification =
  let width = calculateWidth(message, manager.charWidth)
  let maxTextWidth = width - NotificationPadding * 2 - 4  # 4 = accent bar
  let lines = wrapText(message, manager.charWidth, maxTextWidth)
  let height = calculateHeight(lines.len, manager.lineHeight)

  # Cap queue so stack doesn't overflow viewport
  while manager.notifications.len > 0:
    var totalH = 0
    for n in manager.notifications:
      totalH += n.bounds.h + Spacing
    if totalH + height + 20 <= manager.viewport.h:
      break
    manager.notifications.delete(0)

  let id = "notif_" & $manager.nextId
  manager.nextId += 1

  let x = manager.viewport.x + manager.viewport.w - width - 20

  let notification = Notification(
    id: id,
    message: message,
    lines: lines,
    notificationType: notificationType,
    createdAt: getTime().toUnixFloat(),
    durationMs: durationMs,
    alpha: 255,
    targetY: 0,
    currentY: -height,
    bounds: rect(x, 0, width, height),
    dismissed: false
  )

  manager.notifications.add(notification)

  var y = manager.viewport.y + 20
  for notif in manager.notifications:
    notif.targetY = y
    y += notif.bounds.h + Spacing

  notification

# Update

proc update*(manager: NotificationManager, deltaTimeMs: int) =
  let currentTime = getTime().toUnixFloat()
  let dt = deltaTimeMs.float32 / 1000.0  # seconds

  # 1. Remove expired notifications
  var i = 0
  while i < manager.notifications.len:
    let notif = manager.notifications[i]
    let elapsedMs = int((currentTime - notif.createdAt) * 1000.0)
    if notif.dismissed or elapsedMs >= notif.durationMs + FadeDurationMs:
      manager.notifications.delete(i)
    else:
      i += 1

  # 2. Recalculate targetY from fixed heights (not currentY) so targets are stable
  var y = manager.viewport.y + 20
  for notif in manager.notifications:
    notif.targetY = y
    notif.bounds.x = manager.viewport.x + manager.viewport.w - notif.bounds.w - 20
    y += notif.bounds.h + Spacing

  # 3. Animate each notification independently
  for notif in manager.notifications:
    let elapsedMs = int((currentTime - notif.createdAt) * 1000.0)

    # Fade out
    if elapsedMs >= notif.durationMs:
      let fadeProgress = clamp(
        (elapsedMs - notif.durationMs).float32 / FadeDurationMs.float32, 0.0, 1.0)
      notif.alpha = uint8(255.0 * (1.0 - fadeProgress))
    else:
      notif.alpha = 255

    # Smooth slide: exponential decay, frame-rate independent
    let diff = notif.targetY - notif.currentY
    if abs(diff) <= 1:
      notif.currentY = notif.targetY
    else:
      # ~90% of the way in 150ms: decay = 1 - e^(-dt/0.065)
      let decay = 1.0 - exp(-dt / 0.065)
      notif.currentY += int(diff.float32 * decay)
      # Ensure we always make at least 1px progress
      if notif.currentY != notif.targetY:
        if diff > 0: notif.currentY = max(notif.currentY, notif.currentY + 1)
        else:        notif.currentY = min(notif.currentY, notif.currentY - 1)

    notif.bounds.y = notif.currentY

proc dismiss*(notification: Notification) =
  notification.dismissed = true

proc dismissAll*(manager: NotificationManager) =
  for notif in manager.notifications:
    notif.dismissed = true

# Rendering

proc render*(notification: Notification, font: Font, lineHeight: int) =
  if notification.alpha <= 0:
    return

  let baseColor = getTypeColor(notification.notificationType)
  let surfaceBg = currentTheme.getColor(tcSurface)
  let bgColor = color(surfaceBg.r, surfaceBg.g, surfaceBg.b,
                      uint8(surfaceBg.a.int * notification.alpha.int div 255))
  let borderColor = color(baseColor.r, baseColor.g, baseColor.b,
                          uint8(baseColor.a.int * notification.alpha.int div 255 * 6 div 10))
  let accentColor = color(baseColor.r, baseColor.g, baseColor.b,
                          uint8(baseColor.a.int * notification.alpha.int div 255))
  let baseText = currentTheme.getColor(tcText)
  let textColor = color(baseText.r, baseText.g, baseText.b, notification.alpha)

  let b = notification.bounds

  # Main background
  fillRect(b, bgColor)

  # 1px outline
  fillRect(rect(b.x,     b.y,      b.w, 1), borderColor)
  fillRect(rect(b.x,     b.y + b.h - 1, b.w, 1), borderColor)
  fillRect(rect(b.x,     b.y,      1, b.h), borderColor)
  fillRect(rect(b.x + b.w - 1, b.y, 1, b.h), borderColor)

  # Left accent bar (type indicator)
  let accentWidth = 4
  fillRect(rect(b.x, b.y, accentWidth, b.h), accentColor)

  # Message text (wrapped lines)
  let textX = b.x + NotificationPadding + accentWidth
  var textY = b.y + NotificationPadding
  for line in notification.lines:
    discard drawText(font, textX, textY, line, textColor, bgColor)
    textY += lineHeight

proc render*(manager: NotificationManager) =
  for notif in manager.notifications:
    notif.render(manager.font, manager.lineHeight)

# Convenience Methods

proc success*(manager: NotificationManager, message: string, durationMs: int = DefaultDurationMs): Notification =
  manager.add(message, ntSuccess, durationMs)

proc error*(manager: NotificationManager, message: string, durationMs: int = DefaultDurationMs * 3 div 2): Notification =
  manager.add(message, ntError, durationMs)

proc warning*(manager: NotificationManager, message: string, durationMs: int = DefaultDurationMs): Notification =
  manager.add(message, ntWarning, durationMs)

proc info*(manager: NotificationManager, message: string, durationMs: int = DefaultDurationMs): Notification =
  manager.add(message, ntInfo, durationMs)

proc updateViewport*(manager: NotificationManager, viewport: Rect) =
  manager.viewport = viewport
  var y = manager.viewport.y + 20
  for notif in manager.notifications:
    notif.targetY = y
    notif.bounds.x = manager.viewport.x + manager.viewport.w - notif.bounds.w - 20
    y += notif.bounds.h + Spacing

# INTEGRATION_NOTES
# This module is a port of src_old_backup/ui/components/notification.nim to uirelays.
# Changes made:
#   - Uses uirelays/screen.Rect (x,y,w,h as int) instead of float32-based Rect.
#   - Uses uirelays/screen.Color (uint8 r,g,b,a).
#   - Rendering uses global fillRect and drawText (with Font + fg/bg colors).
#   - update() now takes deltaTimeMs as int instead of float32 seconds.
#   - Durations are stored as milliseconds (int) instead of float64 seconds.
#   - Removed drawRectOutline; borders are drawn manually with fillRect.
# To integrate into src/app/app.nim:
#   - Import src/ui/notification.
#   - Create the manager with: newNotificationManager(viewport, font)
#   - Call manager.update(16) each frame and manager.render() after drawing widgets.
