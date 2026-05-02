import std/[strutils, math, tables]
import uirelays

type
  ColorParseError* = object of CatchableError

const colorNames = [
  ("aliceblue", "F0F8FF"),
  ("antiquewhite", "FAEBD7"),
  ("aqua", "00FFFF"),
  ("aquamarine", "7FFFD4"),
  ("azure", "F0FFFF"),
  ("beige", "F5F5DC"),
  ("bisque", "FFE4C4"),
  ("black", "000000"),
  ("blanchedalmond", "FFEBCD"),
  ("blue", "0000FF"),
  ("blueviolet", "8A2BE2"),
  ("brown", "A52A2A"),
  ("burlywood", "DEB887"),
  ("cadetblue", "5F9EA0"),
  ("chartreuse", "7FFF00"),
  ("chocolate", "D2691E"),
  ("coral", "FF7F50"),
  ("cornflowerblue", "6495ED"),
  ("cornsilk", "FFF8DC"),
  ("crimson", "DC143C"),
  ("cyan", "00FFFF"),
  ("darkblue", "00008B"),
  ("darkcyan", "008B8B"),
  ("darkgoldenrod", "B8860B"),
  ("darkgray", "A9A9A9"),
  ("darkgrey", "A9A9A9"),
  ("darkgreen", "006400"),
  ("darkkhaki", "BDB76B"),
  ("darkmagenta", "8B008B"),
  ("darkolivegreen", "556B2F"),
  ("darkorange", "FF8C00"),
  ("darkorchid", "9932CC"),
  ("darkred", "8B0000"),
  ("darksalmon", "E9967A"),
  ("darkseagreen", "8FBC8F"),
  ("darkslateblue", "483D8B"),
  ("darkslategray", "2F4F4F"),
  ("darkslategrey", "2F4F4F"),
  ("darkturquoise", "00CED1"),
  ("darkviolet", "9400D3"),
  ("deeppink", "FF1493"),
  ("deepskyblue", "00BFFF"),
  ("dimgray", "696969"),
  ("dimgrey", "696969"),
  ("dodgerblue", "1E90FF"),
  ("firebrick", "B22222"),
  ("floralwhite", "FFFAF0"),
  ("forestgreen", "228B22"),
  ("fuchsia", "FF00FF"),
  ("gainsboro", "DCDCDC"),
  ("ghostwhite", "F8F8FF"),
  ("gold", "FFD700"),
  ("goldenrod", "DAA520"),
  ("gray", "808080"),
  ("grey", "808080"),
  ("green", "008000"),
  ("greenyellow", "ADFF2F"),
  ("honeydew", "F0FFF0"),
  ("hotpink", "FF69B4"),
  ("indianred", "CD5C5C"),
  ("indigo", "4B0082"),
  ("ivory", "FFFFF0"),
  ("khaki", "F0E68C"),
  ("lavender", "E6E6FA"),
  ("lavenderblush", "FFF0F5"),
  ("lawngreen", "7CFC00"),
  ("lemonchiffon", "FFFACD"),
  ("lightblue", "ADD8E6"),
  ("lightcoral", "F08080"),
  ("lightcyan", "E0FFFF"),
  ("lightgoldenrodyellow", "FAFAD2"),
  ("lightgray", "D3D3D3"),
  ("lightgrey", "D3D3D3"),
  ("lightgreen", "90EE90"),
  ("lightpink", "FFB6C1"),
  ("lightsalmon", "FFA07A"),
  ("lightseagreen", "20B2AA"),
  ("lightskyblue", "87CEFA"),
  ("lightslategray", "778899"),
  ("lightslategrey", "778899"),
  ("lightsteelblue", "B0C4DE"),
  ("lightyellow", "FFFFE0"),
  ("lime", "00FF00"),
  ("limegreen", "32CD32"),
  ("linen", "FAF0E6"),
  ("magenta", "FF00FF"),
  ("maroon", "800000"),
  ("mediumaquamarine", "66CDAA"),
  ("mediumblue", "0000CD"),
  ("mediumorchid", "BA55D3"),
  ("mediumpurple", "9370DB"),
  ("mediumseagreen", "3CB371"),
  ("mediumslateblue", "7B68EE"),
  ("mediumspringgreen", "00FA9A"),
  ("mediumturquoise", "48D1CC"),
  ("mediumvioletred", "C71585"),
  ("midnightblue", "191970"),
  ("mintcream", "F5FFFA"),
  ("mistyrose", "FFE4E1"),
  ("moccasin", "FFE4B5"),
  ("navajowhite", "FFDEAD"),
  ("navy", "000080"),
  ("oldlace", "FDF5E6"),
  ("olive", "808000"),
  ("olivedrab", "6B8E23"),
  ("orange", "FFA500"),
  ("orangered", "FF4500"),
  ("orchid", "DA70D6"),
  ("palegoldenrod", "EEE8AA"),
  ("palegreen", "98FB98"),
  ("paleturquoise", "AFEEEE"),
  ("palevioletred", "DB7093"),
  ("papayawhip", "FFEFD5"),
  ("peachpuff", "FFDAB9"),
  ("peru", "CD853F"),
  ("pink", "FFC0CB"),
  ("plum", "DDA0DD"),
  ("powderblue", "B0E0E6"),
  ("purple", "800080"),
  ("rebeccapurple", "663399"),
  ("red", "FF0000"),
  ("rosybrown", "BC8F8F"),
  ("royalblue", "4169E1"),
  ("saddlebrown", "8B4513"),
  ("salmon", "FA8072"),
  ("sandybrown", "F4A460"),
  ("seagreen", "2E8B57"),
  ("seashell", "FFF5EE"),
  ("sienna", "A0522D"),
  ("silver", "C0C0C0"),
  ("skyblue", "87CEEB"),
  ("slateblue", "6A5ACD"),
  ("slategray", "708090"),
  ("slategrey", "708090"),
  ("snow", "FFFAFA"),
  ("springgreen", "00FF7F"),
  ("steelblue", "4682B4"),
  ("tan", "D2B48C"),
  ("teal", "008080"),
  ("thistle", "D8BFD8"),
  ("tomato", "FF6347"),
  ("turquoise", "40E0D0"),
  ("violet", "EE82EE"),
  ("wheat", "F5DEB3"),
  ("white", "FFFFFF"),
  ("whitesmoke", "F5F5F5"),
  ("yellow", "FFFF00"),
  ("yellowgreen", "9ACD32"),
].toTable

proc parseHex*(hex: string): Color =
  assert hex.len == 6
  let r = parseHexInt(hex[0..1]).uint8
  let g = parseHexInt(hex[2..3]).uint8
  let b = parseHexInt(hex[4..5]).uint8
  color(r, g, b, 255)

proc parseHtmlHex*(hex: string): Color =
  if hex[0] != '#':
    raise newException(ColorParseError, "Expected '#'")
  parseHex(hex[1..^1])

proc parseHtmlHexTiny*(hex: string): Color =
  if hex[0] != '#':
    raise newException(ColorParseError, "Expected '#'")
  if hex.len != 4:
    raise newException(ColorParseError, "Expected 4 chars for tiny hex")
  let r = parseHexInt($hex[1] & $hex[1]).uint8
  let g = parseHexInt($hex[2] & $hex[2]).uint8
  let b = parseHexInt($hex[3] & $hex[3]).uint8
  color(r, g, b, 255)

proc parseHtmlRgb*(text: string): Color =
  if not text.startsWith("rgb(") or text[^1] != ')':
    raise newException(ColorParseError, "Expected 'rgb(...)'")
  let inner = text[4..^2].replace(" ", "")
  let arr = inner.split(',')
  if arr.len != 3:
    raise newException(ColorParseError, "Expected 3 numbers in rgb()")
  let r = clamp(parseFloat(arr[0]).int, 0, 255).uint8
  let g = clamp(parseFloat(arr[1]).int, 0, 255).uint8
  let b = clamp(parseFloat(arr[2]).int, 0, 255).uint8
  color(r, g, b, 255)

proc parseHtmlRgba*(text: string): Color =
  if not text.startsWith("rgba(") or text[^1] != ')':
    raise newException(ColorParseError, "Expected 'rgba(...)'")
  let inner = text[5..^2].replace(" ", "")
  let arr = inner.split(',')
  if arr.len != 4:
    raise newException(ColorParseError, "Expected 4 numbers in rgba()")
  let r = clamp(parseFloat(arr[0]).int, 0, 255).uint8
  let g = clamp(parseFloat(arr[1]).int, 0, 255).uint8
  let b = clamp(parseFloat(arr[2]).int, 0, 255).uint8
  let a = uint8(clamp(round(parseFloat(arr[3]) * 255.0), 0.0, 255.0))
  color(r, g, b, a)

proc parseHsl*(text: string): Color =
  if not text.startsWith("hsl(") or text[^1] != ')':
    raise newException(ColorParseError, "Expected 'hsl(...)'")
  let inner = text[4..^2].replace(" ", "")
  let arr = inner.split(',')
  if arr.len != 3:
    raise newException(ColorParseError, "Expected 3 numbers in hsl()")
  let h = parseFloat(arr[0])
  let s = parseFloat(arr[1].replace("%", "")) / 100.0
  let l = parseFloat(arr[2].replace("%", "")) / 100.0
  let c = (1.0 - abs(2.0 * l - 1.0)) * s
  let x = c * (1.0 - abs((h / 60.0) mod 2.0 - 1.0))
  let m = l - c / 2.0
  var r1, g1, b1: float64
  if h < 60.0:       (r1, g1, b1) = (c, x, 0.0)
  elif h < 120.0:    (r1, g1, b1) = (x, c, 0.0)
  elif h < 180.0:    (r1, g1, b1) = (0.0, c, x)
  elif h < 240.0:    (r1, g1, b1) = (0.0, x, c)
  elif h < 300.0:    (r1, g1, b1) = (x, 0.0, c)
  else:              (r1, g1, b1) = (c, 0.0, x)
  let r = uint8(clamp((r1 + m) * 255.0, 0.0, 255.0))
  let g = uint8(clamp((g1 + m) * 255.0, 0.0, 255.0))
  let b = uint8(clamp((b1 + m) * 255.0, 0.0, 255.0))
  color(r, g, b, 255)

proc parseHsla*(text: string): Color =
  if not text.startsWith("hsla(") or text[^1] != ')':
    raise newException(ColorParseError, "Expected 'hsla(...)'")
  let inner = text[5..^2].replace(" ", "")
  let arr = inner.split(',')
  if arr.len != 4:
    raise newException(ColorParseError, "Expected 4 numbers in hsla()")
  let h = parseFloat(arr[0])
  let s = parseFloat(arr[1].replace("%", "")) / 100.0
  let l = parseFloat(arr[2].replace("%", "")) / 100.0
  let a = clamp(parseFloat(arr[3]), 0.0, 1.0)
  let c = (1.0 - abs(2.0 * l - 1.0)) * s
  let x = c * (1.0 - abs((h / 60.0) mod 2.0 - 1.0))
  let m = l - c / 2.0
  var r1, g1, b1: float64
  if h < 60.0:       (r1, g1, b1) = (c, x, 0.0)
  elif h < 120.0:    (r1, g1, b1) = (x, c, 0.0)
  elif h < 180.0:    (r1, g1, b1) = (0.0, c, x)
  elif h < 240.0:    (r1, g1, b1) = (0.0, x, c)
  elif h < 300.0:    (r1, g1, b1) = (x, 0.0, c)
  else:              (r1, g1, b1) = (c, 0.0, x)
  let r = uint8(clamp((r1 + m) * 255.0, 0.0, 255.0))
  let g = uint8(clamp((g1 + m) * 255.0, 0.0, 255.0))
  let b = uint8(clamp((b1 + m) * 255.0, 0.0, 255.0))
  let au = uint8(clamp(round(a * 255.0), 0.0, 255.0))
  color(r, g, b, au)

proc parseHtmlName*(text: string): Color =
  let lowerName = text.toLowerAscii()
  if lowerName in colorNames:
    parseHex(colorNames[lowerName])
  else:
    raise newException(ColorParseError, "Not a valid color name: " & text)

proc parseColor*(text: string): Color =
  let s = text.strip()
  if s.startsWith('#'):
    if s.len == 4:
      return parseHtmlHexTiny(s)
    elif s.len == 7:
      return parseHtmlHex(s)
    elif s.len == 9:
      let r = parseHexInt(s[1..2]).uint8
      let g = parseHexInt(s[3..4]).uint8
      let b = parseHexInt(s[5..6]).uint8
      let a = parseHexInt(s[7..8]).uint8
      color(r, g, b, a)
    else:
      raise newException(ColorParseError, "HTML color invalid: " & text)
  elif s.len > 4 and s.startsWith("rgba"):
    return parseHtmlRgba(s)
  elif s.len > 3 and s.startsWith("rgb"):
    return parseHtmlRgb(s)
  elif s.len > 4 and s.startsWith("hsla"):
    return parseHsla(s)
  elif s.len > 3 and s.startsWith("hsl"):
    return parseHsl(s)
  else:
    return parseHtmlName(s)
