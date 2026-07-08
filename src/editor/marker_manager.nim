import uirelays
import widgets/synedit

type
  MarkerSource* = enum
    msDiagnostic
    msColorHighlight
    msBreakpoint
    msBracketMatch

  BufferMarkers* = object
    sources*: array[MarkerSource, seq[tuple[a, b: int, color: Color]]]

proc initBufferMarkers*(): BufferMarkers =
  result = BufferMarkers()

proc setMarkers*(bm: var BufferMarkers, source: MarkerSource,
                 markers: seq[tuple[a, b: int, color: Color]]) =
  bm.sources[source] = markers

proc applyMarkers*(ed: var SynEdit, bm: BufferMarkers) =
  ed.clearMarkers()
  for src in MarkerSource:
    for m in bm.sources[src]:
      ed.addMarker(m.a, m.b, m.color)
