## Document Module Tests

import ../../src/core/[types, document, errors]

proc runDocumentTests() =
  echo "Running Document Tests..."
  
  # Test 1: Create empty document
  var doc = newDocument()
  assert doc.lineCount == 1, "Empty document should have 1 line"
  assert doc.lines[0] == "", "Empty document line should be empty"
  echo "  ✓ Test 1: Create empty document"
  
  # Test 2: Create document with content
  doc = newDocument("Hello\nWorld")
  assert doc.lineCount == 2, "Document should have 2 lines"
  assert doc.lines[0] == "Hello", "First line should be 'Hello'"
  assert doc.lines[1] == "World", "Second line should be 'World'"
  echo "  ✓ Test 2: Create document with content"
  
  # Test 3: Insert text
  doc = newDocument("Hello World")
  let result = doc.insertText(CursorPos(line: 0, col: 6), "Beautiful ")
  assert result.isOk, "Insert should succeed"
  assert result.value == CursorPos(line: 0, col: 16), "Cursor should be at position 16"
  assert doc.lines[0] == "Hello Beautiful World", "Line should contain inserted text"
  echo "  ✓ Test 3: Insert text"
  
  # Test 4: Delete range
  doc = newDocument("Hello Beautiful World")
  let deleteResult = doc.deleteRange(
    CursorPos(line: 0, col: 5),
    CursorPos(line: 0, col: 15)
  )
  assert deleteResult.isOk, "Delete should succeed"
  assert deleteResult.value == " Beautiful", "Deleted text should be returned"
  assert doc.lines[0] == "Hello World", "Line should have deleted text removed"
  echo "  ✓ Test 4: Delete range"
  
  # Test 5: Multi-line insert
  doc = newDocument("Line 1")
  let multiResult = doc.insertText(CursorPos(line: 0, col: 6), "\nLine 2\nLine 3")
  assert multiResult.isOk, "Multi-line insert should succeed"
  assert doc.lineCount == 3, "Document should have 3 lines"
  assert doc.lines[0] == "Line 1", "First line unchanged"
  assert doc.lines[1] == "Line 2", "Second line added"
  assert doc.lines[2] == "Line 3", "Third line added"
  echo "  ✓ Test 5: Multi-line insert"
  
  # Test 6: Document statistics
  doc = newDocument("Hello World")
  assert doc.getCharacterCount() == 11, "Character count should be 11"
  assert doc.getWordCount() == 2, "Word count should be 2"
  echo "  ✓ Test 6: Document statistics"
  
  # Test 7: Line operations
  doc = newDocument("Line 1\nLine 2")
  let lineResult = doc.getLine(0)
  assert lineResult.isOk, "Get line should succeed"
  assert lineResult.value == "Line 1", "First line should be 'Line 1'"
  echo "  ✓ Test 7: Line operations"
  
  # Test 8: Invalid position
  doc = newDocument("Hello")
  let invalidResult = doc.insertText(CursorPos(line: 10, col: 0), "text")
  assert invalidResult.isErr, "Invalid position should return error"
  echo "  ✓ Test 8: Invalid position handling"
  
  # Test 9: Replace range
  doc = newDocument("Hello World")
  let replaceResult = doc.replaceRange(
    CursorPos(line: 0, col: 6),
    CursorPos(line: 0, col: 11),
    "Nim"
  )
  assert replaceResult.isOk, "Replace should succeed"
  assert doc.lines[0] == "Hello Nim", "Text should be replaced"
  echo "  ✓ Test 9: Replace range"
  
  echo ""
  echo "All Document Tests Passed! ✓"

when isMainModule:
  runDocumentTests()
