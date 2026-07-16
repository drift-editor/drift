# Rendering Performance & Scroll Smoothness

## Overview

This document analyzes why editor scrolling can feel choppy and identifies
where the rendering cost comes from. The findings are ordered by impact, from
largest to smallest.

The important conclusion: the app's own render path (`src/app/app.nim`) is
mostly well-behaved. The dominant cost lives in the `uirelays` dependency's
text-drawing backend, which has **no glyph/texture caching**.

## 1. Root cause: no font/text caching (largest impact)

The SDL backend rasterizes and uploads text to the GPU **on every call, every
frame, with no cache**.

`uirelays/drivers/sdl2_driver.nim:89` (`sdlDrawTextShaded`):

```nim
let surf = renderUtf8Shaded(fp, text, toSdlColor(fg), toSdlColor(bg)) # CPU rasterize glyphs
let tex  = renderer.createTextureFromSurface(surf)                    # upload to GPU
renderer.copy(tex, addr src, addr dst)                                # draw
freeSurface(surf); destroy(tex)                                       # free both immediately
```

The SDL3 driver does the same (`uirelays/drivers/sdl3_driver.nim:121`).

The editor calls `drawText` once **per token run, per visible line, per frame**
(`widgets/synedit.nim:2094`, inside `drawTextLine`). On a full screen of roughly
50 visible lines with several colored tokens each, that is hundreds of
"rasterize surface + create texture + destroy texture" cycles every frame.
During a scroll (one frame per wheel notch) this is the primary source of jank.

**Fix:** add a text/glyph texture cache in the `uirelays` SDL driver, keyed by
`(font, text, fg, bg)`, and reuse the `SDL_Texture` instead of creating and
destroying it each frame. This is the single highest-value change. Note this
requires modifying the external `uirelays` package, not this repository.

## 2. Scrolling is discrete 3-line jumps (affects feel)

`widgets/synedit.nim:2498`:

```nim
of MouseWheelEvent:
  if focused:
    s.scrollLines(-e.y * 3)
```

Each wheel notch jumps a whole 3 lines. There is no pixel-level / sub-line
smooth scrolling and no inertia animation, so even with fast rendering the
motion looks stepped.

**Fix:** introduce a pixel-level scroll offset (SynEdit already tracks
`firstLineOffset`, which can drive sub-line rendering) or add scroll-position
animation/interpolation between frames.

## 3. Per-frame full redraw + blocking event loop (minor)

The main loop in `src/app/app.nim:694` (`run`) redraws everything each frame:
- full-screen background `fillRect` (`app.nim:710`)
- rebuilds the entire node tree via `buildNodeTree` (`app.nim:748`)
- renders every panel

`waitEvent(e, 500, ...)` (`app.nim:713`) blocks up to 500 ms when idle, so idle
CPU is fine. But during scroll one frame is produced per event; combined with
the uncached font cost above, the per-frame overhead becomes noticeable.

## What the app already does correctly

- Color scanning and line splitting are guarded by `cacheId`, so they only
  recompute when buffer contents change (`app.nim:1607`).
- Sticky-scroll line computation runs every frame (`app.nim:1627`) but operates
  on a small amount of data.
- SynEdit only draws visible lines via the `while dim.y + fontSize < endY` loop
  (`widgets/synedit.nim:2300`), so off-screen lines cost nothing.

## Recommended priority

1. **Add a text-texture cache to the uirelays SDL driver** — one change that
   removes most of the per-frame cost.
2. **Implement sub-line / pixel-level smooth scrolling** in SynEdit.
3. (Optional) Reduce per-frame full-screen redraw / node-tree rebuild in the app
   loop.
