#include <windows.h>
#include <string.h>
#include <stdlib.h>

char *drift_win_file_dialog(int kind, const char *title,
                            const char *folder, const char *filter,
                            const char *defExt) {
  char buffer[MAX_PATH] = {0};
  OPENFILENAMEA ofn = {0};
  ofn.lStructSize = sizeof(ofn);
  ofn.lpstrFile = buffer;
  ofn.nMaxFile = MAX_PATH;
  ofn.lpstrTitle = title;
  ofn.lpstrInitialDir = folder;
  ofn.lpstrFilter = filter;
  ofn.lpstrDefExt = defExt;
  ofn.Flags = OFN_HIDEREADONLY | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

  int ok;
  if (kind == 1) {
    ofn.Flags |= OFN_OVERWRITEPROMPT;
    ok = GetSaveFileNameA(&ofn);
  } else {
    ofn.Flags |= OFN_FILEMUSTEXIST;
    ok = GetOpenFileNameA(&ofn);
  }

  if (ok) {
    char *res = (char *)malloc(strlen(buffer) + 1);
    strcpy(res, buffer);
    return res;
  }
  return NULL;
}
