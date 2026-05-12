#include <stdio.h>
#include "../include/open_file.h"
#include <windows.h>
#include <commdlg.h>

extern const char* open_file(const char* filter, size_t length, size_t* o_length) {
    if (!o_length) return NULL;
    *o_length = 0;
    static char file[MAX_PATH] = {0};
    OPENFILENAMEW ofn = {0};
    WCHAR fileBuf[MAX_PATH] = L"";
    WCHAR wc_filter[MAX_PATH] = L"Text Files\0*.txt\0All Files\0*.*\0\0";
    MultiByteToWideChar(CP_ACP, 0, filter,  (int)length, wc_filter, MAX_PATH);

    ofn.lStructSize = sizeof(ofn);
    ofn.hwndOwner = NULL;
    ofn.lpstrFilter = wc_filter;
    ofn.lpstrFile = fileBuf;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;

    if (GetOpenFileNameW(&ofn)) {

        int used;
        char ch = '%';
        WideCharToMultiByte(CP_ACP, 0, fileBuf, MAX_PATH, file, sizeof(file), &ch, &used);

        *o_length = (size_t)strlen(file);
        return file;
    }

    return NULL;
}
