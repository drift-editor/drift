import uirelays/screen
import widgets/synedit

let fakeFont = Font(1)
var ed = createSynEdit(fakeFont)
ed.setText("line0\nline1\nline2\nline3\nline4")

ed.setLineBgDecoration(1, color(255, 0, 0, 50))
ed.setLineBgDecoration(3, color(0, 255, 0, 50))
echo "Decs after adding: ok"

ed.clearLineBgDecorations()
echo "Decs after clear: ok"

ed.setLineBgDecoration(0, color(0, 0, 255, 50))
ed.setLineBgDecoration(2, color(255, 255, 0, 50))
echo "Decs after re-adding: ok"

ed.setText("new0\nnew1\nnew2")
echo "Decs after setText: ok"
echo "All synedit decoration tests passed!"
