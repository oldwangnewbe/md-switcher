#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdbool.h>
#include <stdio.h>
#include <wchar.h>
#include "session.h"

static bool same_file(const wchar_t *a, const wchar_t *b)
{
    if (CompareStringOrdinal(a, -1, b, -1, TRUE) == CSTR_EQUAL) return true;
    HANDLE left = CreateFileW(a, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, 0, NULL);
    HANDLE right = CreateFileW(b, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                               NULL, OPEN_EXISTING, 0, NULL);
    BY_HANDLE_FILE_INFORMATION x, y;
    bool match = left != INVALID_HANDLE_VALUE && right != INVALID_HANDLE_VALUE &&
        GetFileInformationByHandle(left, &x) && GetFileInformationByHandle(right, &y) &&
        x.dwVolumeSerialNumber == y.dwVolumeSerialNumber &&
        (x.nFileIndexHigh || x.nFileIndexLow) &&
        x.nFileIndexHigh == y.nFileIndexHigh && x.nFileIndexLow == y.nFileIndexLow;
    if (left != INVALID_HANDLE_VALUE) CloseHandle(left);
    if (right != INVALID_HANDLE_VALUE) CloseHandle(right);
    return match;
}

static DWORD game_process(const wchar_t *expected)
{
    HANDLE list = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (list == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W row = { .dwSize = sizeof(row) };
    DWORD found = 0;
    if (Process32FirstW(list, &row)) {
        do {
            if (CompareStringOrdinal(row.szExeFile, -1, L"masterduel.exe", -1, TRUE) != CSTR_EQUAL) continue;
            HANDLE candidate = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, row.th32ProcessID);
            if (!candidate) continue;
            wchar_t path[2048];
            DWORD length = sizeof(path) / sizeof(*path);
            bool matches = QueryFullProcessImageNameW(candidate, 0, path, &length) && same_file(expected, path);
            CloseHandle(candidate);
            if (!matches) continue;
            if (found) { found = 0; break; }
            found = row.th32ProcessID;
        } while (Process32NextW(list, &row));
    }
    CloseHandle(list);
    return found;
}

static uintptr_t module_base(DWORD pid, const wchar_t *name, bool full_path)
{
    HANDLE list = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
    if (list == INVALID_HANDLE_VALUE) return 0;
    MODULEENTRY32W row = { .dwSize = sizeof(row) };
    uintptr_t found = 0;
    if (Module32FirstW(list, &row)) {
        do {
            bool match = full_path ? same_file(name, row.szExePath) :
                CompareStringOrdinal(name, -1, row.szModule, -1, TRUE) == CSTR_EQUAL;
            if (match) { found = (uintptr_t)row.modBaseAddr; break; }
        } while (Module32NextW(list, &row));
    }
    CloseHandle(list);
    return found;
}

static LPTHREAD_START_ROUTINE remote_load_library(DWORD pid)
{
    HMODULE kernel = GetModuleHandleW(L"kernel32.dll");
    FARPROC function = GetProcAddress(kernel, "LoadLibraryW");
    HMODULE local = NULL;
    wchar_t file[MAX_PATH];
    if (!function ||
        !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)function, &local) ||
        !GetModuleFileNameW(local, file, MAX_PATH)) return NULL;
    const wchar_t *name = wcsrchr(file, L'\\');
    uintptr_t remote = module_base(pid, name ? name + 1 : file, false);
    return remote ? (LPTHREAD_START_ROUTINE)(remote + (uintptr_t)function - (uintptr_t)local) : NULL;
}

static bool remote_call(HANDLE process, LPTHREAD_START_ROUTINE function, const void *argument,
                        SIZE_T size, DWORD timeout, DWORD *result)
{
    void *remote = VirtualAllocEx(process, NULL, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!remote) {
        printf("Remote allocation failed: %lu\n", (unsigned long)GetLastError());
        return false;
    }
    bool finished = false, release = true;
    if (WriteProcessMemory(process, remote, argument, size, NULL)) {
        HANDLE thread = CreateRemoteThread(process, NULL, 0, function, remote, 0, NULL);
        if (thread) {
            DWORD wait = WaitForSingleObject(thread, timeout);
            release = wait == WAIT_OBJECT_0;
            finished = release && GetExitCodeThread(thread, result);
            if (!finished) printf("Remote call wait: %lu, error: %lu\n", (unsigned long)wait, (unsigned long)GetLastError());
            CloseHandle(thread);
        } else printf("Remote thread failed: %lu\n", (unsigned long)GetLastError());
    } else printf("Remote write failed: %lu\n", (unsigned long)GetLastError());
    if (release) VirtualFreeEx(process, remote, 0, MEM_RELEASE);
    return finished;
}

static int apply(const wchar_t *expected, const wchar_t *dll, const wchar_t *selection, const wchar_t *log_path,
                 DWORD expected_pid)
{
    RoyalSession session = { .version = ROYAL_SESSION_VERSION };
    if (wcslen(log_path) >= ROYAL_LOG_PATH) return 10;
    wcscpy(session.log_path, log_path);
    FILE *file = _wfopen(selection, L"rb");
    if (!file) return 10;
    bool valid = fread(session.cards, 1, sizeof(session.cards), file) == sizeof(session.cards) && fgetc(file) == EOF;
    fclose(file);
    if (!valid) return 10;

    DWORD pid = game_process(expected);
    if (!pid || (expected_pid && pid != expected_pid)) return 11;
    LPTHREAD_START_ROUTINE load_library = remote_load_library(pid);
    if (!load_library) return 12;
    HANDLE process = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION |
        PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ, FALSE, pid);
    if (!process) return 12;
    int status = 13;
    DWORD result;
    uintptr_t remote = module_base(pid, dll, true);
    if (!remote && remote_call(process, load_library, dll, (wcslen(dll) + 1) * sizeof(wchar_t), 7000, &result)) {
        remote = module_base(pid, dll, true);
    }
    if (remote) {
        HMODULE local = LoadLibraryExW(dll, NULL, DONT_RESOLVE_DLL_REFERENCES);
        FARPROC start = local ? GetProcAddress(local, "StartRoyalFinish") : NULL;
        if (start) {
            LPTHREAD_START_ROUTINE initialize = (LPTHREAD_START_ROUTINE)(remote + (uintptr_t)start - (uintptr_t)local);
            status = remote_call(process, initialize, &session, sizeof(session), 30000, &result) ?
                (result == 0 ? 0 : 100 + (int)result) : 14;
        }
        if (local) FreeLibrary(local);
    }
    CloseHandle(process);
    return status;
}

int wmain(int argc, wchar_t **argv)
{
    if (argc == 2 && !wcscmp(argv[1], L"probe-display")) {
        DEVMODEW current = { .dmSize = sizeof(current) };
        if (!EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &current)) return 1;
        printf("MD_DISPLAY=%lu,%lu\n", (unsigned long)current.dmPelsWidth, (unsigned long)current.dmPelsHeight);
        return 0;
    }
    int status = 10;
    if (argc == 5) {
        status = apply(argv[1], argv[2], argv[3], argv[4], 0);
    } else if (argc == 6) {
        wchar_t *end;
        unsigned long pid = wcstoul(argv[5], &end, 10);
        if (pid && !*end) status = apply(argv[1], argv[2], argv[3], argv[4], (DWORD)pid);
    }
    printf("MD_ROYAL_RESULT=%d\n", status);
    return 0;
}
