import ../src/editor/color_parser
import ../src/editor/color_highlight

proc assertEq[T](a, b: T, msg: string = "") =
  if a != b:
    echo "FAIL: ", msg, " expected ", b, " got ", a
    quit(1)

# Test hex parsing
let c1 = parseColor("#FF0000")
assertEq(c1.r, 255'u8, "#FF0000 r")
assertEq(c1.g, 0'u8, "#FF0000 g")
assertEq(c1.b, 0'u8, "#FF0000 b")

let c2 = parseColor("#0F0")
assertEq(c2.r, 0'u8, "#0F0 r")
assertEq(c2.g, 255'u8, "#0F0 g")
assertEq(c2.b, 0'u8, "#0F0 b")

let c3 = parseColor("#FF00FF80")
assertEq(c3.r, 255'u8, "#FF00FF80 r")
assertEq(c3.g, 0'u8, "#FF00FF80 g")
assertEq(c3.b, 255'u8, "#FF00FF80 b")
assertEq(c3.a, 128'u8, "#FF00FF80 a")

# Test rgb/rgba
let c4 = parseColor("rgb(255, 128, 0)")
assertEq(c4.r, 255'u8, "rgb r")
assertEq(c4.g, 128'u8, "rgb g")
assertEq(c4.b, 0'u8, "rgb b")

let c5 = parseColor("rgba(0, 255, 255, 0.5)")
assertEq(c5.r, 0'u8, "rgba r")
assertEq(c5.g, 255'u8, "rgba g")
assertEq(c5.b, 255'u8, "rgba b")
assertEq(c5.a, 128'u8, "rgba a")

# Test hsl
let c6 = parseColor("hsl(0, 100%, 50%)")
assertEq(c6.r, 255'u8, "hsl red r")
assertEq(c6.g, 0'u8, "hsl red g")
assertEq(c6.b, 0'u8, "hsl red b")

let c7 = parseColor("hsl(120, 100%, 50%)")
assertEq(c7.r, 0'u8, "hsl green r")
assertEq(c7.g, 255'u8, "hsl green g")
assertEq(c7.b, 0'u8, "hsl green b")

let c8 = parseColor("hsl(240, 100%, 50%)")
assertEq(c8.r, 0'u8, "hsl blue r")
assertEq(c8.g, 0'u8, "hsl blue g")
assertEq(c8.b, 255'u8, "hsl blue b")

# Test named colors
let c9 = parseColor("red")
assertEq(c9.r, 255'u8, "red r")
let c10 = parseColor("aliceblue")
assertEq(c10.r, 240'u8, "aliceblue r")

# Test scanner
let testText = "#FF0000 rgb(0,255,0) hsl(240,100%,50%) red"
let markers = scanColorHighlights(testText)
assertEq(markers.len, 4, "marker count")
assertEq(markers[0].a, 0, "marker 0 start")
assertEq(markers[0].b, 6, "marker 0 end")
assertEq(markers[1].a, 8, "marker 1 start")
assertEq(markers[1].b, 19, "marker 1 end")
assertEq(markers[2].a, 21, "marker 2 start")
assertEq(markers[2].b, 37, "marker 2 end")
assertEq(markers[3].a, 39, "marker 3 start")
assertEq(markers[3].b, 41, "marker 3 end")

echo "All tests passed!"
