/* Repair Wine 11's stale display aliases after XRandR output IDs change.
 * Wine's write_source_to_registry() opens an existing alias through
 * NtCreateKey, then writes SymbolicLinkValue into its old target. Retarget
 * the alias itself using REG_OPTION_OPEN_LINK. Never delete source records.
 */
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#include <wctype.h>
#include <stdlib.h>

#define PATH_CAP 1024
static unsigned long xrandr_sources[64];
static int xrandr_count = -1;

static void normalize(wchar_t *path)
{
    wchar_t *out = path;
    for (const wchar_t *in = path; *in; in++)
        if (*in != L'\\' || out == path || out[-1] != L'\\') *out++ = *in;
    *out = 0;
}

static BOOL read_link(HKEY parent, const wchar_t *path, wchar_t *target)
{
    HKEY key;
    DWORD type = 0, size = (PATH_CAP - 1) * sizeof(wchar_t);
    if (RegOpenKeyExW(parent, path, REG_OPTION_OPEN_LINK, KEY_QUERY_VALUE, &key)) return FALSE;
    LONG error = RegQueryValueExW(key, L"SymbolicLinkValue", NULL, &type, (BYTE *)target, &size);
    RegCloseKey(key);
    if (error || type != REG_LINK || !size || size % sizeof(wchar_t)) return FALSE;
    target[size / sizeof(wchar_t)] = 0;
    normalize(target);
    return TRUE;
}

static BOOL hex_name(const wchar_t *name, size_t min, size_t max)
{
    size_t len = wcslen(name);
    if (len < min || len > max) return FALSE;
    for (size_t i = 0; i < len; i++) if (!iswxdigit(name[i])) return FALSE;
    return TRUE;
}

/* Read one source record, never follow arbitrary registry paths. */
static BOOL source_path(HKEY gpu, const wchar_t *prefix, const wchar_t *target, wchar_t *relative)
{
    size_t prefix_len = wcslen(prefix);
    if (_wcsnicmp(target, prefix, prefix_len) || !hex_name(target + prefix_len, 4, 8)) return FALSE;
    swprintf(relative, 64, L"Sources\\%ls", target + prefix_len);
    HKEY source;
    DWORD type = 0, flags = 0, size = sizeof(flags);
    if (RegOpenKeyExW(gpu, relative, 0, KEY_QUERY_VALUE, &source)) return FALSE;
    LONG error = RegQueryValueExW(source, L"StateFlags", NULL, &type, (BYTE *)&flags, &size);
    RegCloseKey(source);
    return !error && type == REG_DWORD && size == sizeof(flags);
}

static int repair_gpu(HKEY gpu, const wchar_t *native_gpu)
{
    struct repair { wchar_t alias[8], before[PATH_CAP], after[PATH_CAP], source[64]; } plan[64];
    wchar_t prefix[PATH_CAP], name[256], before[PATH_CAP], after[PATH_CAP], verified[PATH_CAP];
    wchar_t source[64], destination[64];
    unsigned count = 0;
    int changed = 0;
    if (swprintf(prefix, PATH_CAP, L"%ls\\Sources\\", native_gpu) < 0) return -1;
    normalize(prefix);
    if (xrandr_count > 0) {
        int present = 0;
        for (int i = 0; i < xrandr_count; i++) {
            swprintf(after, PATH_CAP, L"%ls%04lx", prefix, xrandr_sources[i]);
            if (source_path(gpu, prefix, after, destination)) present++;
        }
        if (present && present != xrandr_count) return 0; /* Wine is still publishing sources. */
        if (present) {
            for (int i = 0; i < xrandr_count; i++) {
                swprintf(name, 256, L"%04x", i);
                swprintf(after, PATH_CAP, L"%ls%04lx", prefix, xrandr_sources[i]);
                if (!read_link(gpu, name, before) || !source_path(gpu, prefix, before, source)) return 0;
                wcscpy(plan[count].alias, name);
                wcscpy(plan[count].before, before);
                wcscpy(plan[count].after, after);
                wcscpy(plan[count++].source, source);
            }
            goto apply;
        }
        /* Other GPUs and the private regression fixture retain the conservative
         * link-value repair. Never map output IDs into a GPU that lacks them. */
    }
    for (DWORD i = 0;; i++) {
        DWORD size = 256;
        LONG error = RegEnumKeyExW(gpu, i, name, &size, NULL, NULL, NULL, NULL);
        if (error == ERROR_NO_MORE_ITEMS) break;
        if (error) return -1;
        if (!hex_name(name, 4, 4) || !read_link(gpu, name, before)) continue;
        if (!source_path(gpu, prefix, before, source) || !read_link(gpu, source, after)) continue;
        if (!source_path(gpu, prefix, after, destination)) {
            fprintf(stderr, "Skipping unresolved Wine display alias %ls\n", name);
            continue;
        }
        if (count == 64) return -1;
        wcscpy(plan[count].alias, name);
        wcscpy(plan[count].before, before);
        wcscpy(plan[count].after, after);
        wcscpy(plan[count++].source, source);
    }
apply:
    /* Snapshot every alias first. If two monitors exchange indexes, their
     * source records contain A->B and B->A; these are two updates, not a
     * chain to follow. Clear the misplaced values only after all writes. */
    for (unsigned i = 0; i < count; i++) {
        if (!_wcsicmp(plan[i].before, plan[i].after)) continue;
        HKEY alias;
        if (RegOpenKeyExW(gpu, plan[i].alias, REG_OPTION_OPEN_LINK, KEY_SET_VALUE, &alias)) return -1;
        LONG error = RegSetValueExW(alias, L"SymbolicLinkValue", 0, REG_LINK,
                              (BYTE *)plan[i].after, (DWORD)(wcslen(plan[i].after) * sizeof(wchar_t)));
        if (error || !read_link(gpu, plan[i].alias, verified) || _wcsicmp(verified, plan[i].after)) {
            RegSetValueExW(alias, L"SymbolicLinkValue", 0, REG_LINK,
                           (BYTE *)plan[i].before, (DWORD)(wcslen(plan[i].before) * sizeof(wchar_t)));
            RegCloseKey(alias);
            return -1;
        }
        RegCloseKey(alias);
        changed++;
    }
    for (unsigned i = 0; i < count; i++) {
        HKEY key;
        if (RegOpenKeyExW(gpu, plan[i].source, REG_OPTION_OPEN_LINK, KEY_SET_VALUE, &key)) return -1;
        RegDeleteValueW(key, L"SymbolicLinkValue");
        RegCloseKey(key);
    }
    return changed;
}

static DWORD wait_for_display_change(DWORD count, const HANDLE *events, int *result)
{
    DWORD wait = MsgWaitForMultipleObjects(count, events, FALSE, INFINITE, QS_ALLINPUT);
    if (wait == WAIT_FAILED) {
        fprintf(stderr, "Wine display sync wait failed: %lu\n", GetLastError());
        *result = 1;
    }
    return wait;
}

#ifndef DISPLAY_SYNC_TEST
static const wchar_t video_path[] = L"System\\CurrentControlSet\\Control\\Video";
static const wchar_t native_config[] =
    L"\\Registry\\Machine\\System\\CurrentControlSet\\Hardware Profiles\\Current\\";
static void log_topology(void)
{
    static int before[6];
    static BOOL initialized;
    int now[6] = {GetSystemMetrics(SM_CMONITORS), GetSystemMetrics(SM_XVIRTUALSCREEN),
                  GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN),
                  GetSystemMetrics(SM_CYVIRTUALSCREEN), (int)GetDpiForSystem()};
    if (initialized && !memcmp(before, now, sizeof(now))) return;
    SYSTEMTIME time;
    GetSystemTime(&time);
    printf("[%04u-%02u-%02uT%02u:%02u:%02uZ] Wine display topology: monitors=%d origin=%d,%d size=%dx%d system_dpi=%d\n",
           time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
           now[0], now[1], now[2], now[3], now[4], now[5]);
    memcpy(before, now, sizeof(now));
    initialized = TRUE;
}
static int repair_displays(HKEY video)
{
    const char *path = getenv("WINE_XRANDR_PLAN");
    if (path) {
        FILE *file = fopen(path, "r");
        unsigned count;
        xrandr_count = -1;
        if (!file) return -1;
        if (fscanf(file, "%u", &count) != 1 || count > 64) { fclose(file); return -1; }
        for (unsigned i = 0; i < count; i++) {
            if (fscanf(file, "%lx", &xrandr_sources[i]) != 1 || !xrandr_sources[i] || xrandr_sources[i] > 0x1fffffff) {
                fclose(file);
                return -1;
            }
        }
        fclose(file);
        xrandr_count = (int)count;
    }
    /* Use Wine's own display initialization mutex, so records cannot be read
     * halfway through a hotplug update. Release it before notifying Wine. */
    HANDLE mutex = CreateMutexW(NULL, FALSE, L"display_device_init");
    if (!mutex) return -1;
    DWORD wait = WaitForSingleObject(mutex, 3000);
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
        CloseHandle(mutex);
        return -1;
    }
    int changed = 0;
    for (DWORD i = 0;; i++) {
        wchar_t name[256], native_gpu[PATH_CAP];
        DWORD size = 256;
        LONG error = RegEnumKeyExW(video, i, name, &size, NULL, NULL, NULL, NULL);
        if (error == ERROR_NO_MORE_ITEMS) break;
        if (error) { changed = -1; break; }
        HKEY gpu;
        if (RegOpenKeyExW(video, name, 0, KEY_READ, &gpu)) continue;
        swprintf(native_gpu, PATH_CAP, L"%ls%ls\\%ls", native_config, video_path, name);
        int result = repair_gpu(gpu, native_gpu);
        RegCloseKey(gpu);
        if (result < 0) { changed = -1; break; }
        changed += result;
    }
    ReleaseMutex(mutex);
    CloseHandle(mutex);
    return changed;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_CLOSE) { PostQuitMessage(0); return 0; }
    if (message == WM_QUERYENDSESSION) return TRUE;
    if (message == WM_ENDSESSION && wparam) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

int main(int argc, char **argv)
{
    BOOL watch = argc == 2 && !strcmp(argv[1], "--watch");
    if (argc != 1 && !watch) return 2;
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *(__cdecl *version)(void) =
        (void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "wine_get_version");
    /* NtUserCallNoParam's private operation numbers are version-specific. */
    if (!version || strcmp(version(), "11.0")) {
        fprintf(stderr, "Wine display sync requires the verified Wine 11.0 API\n");
        return 2;
    }
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    GetDesktopWindow();
    ULONG_PTR (WINAPI *refresh)(ULONG) =
        (void *)GetProcAddress(GetModuleHandleW(L"win32u.dll"), "NtUserCallNoParam");
    if (!refresh) return 2;
    HANDLE singleton = CreateMutexW(NULL, TRUE, L"DotfilesWineDisplaySync");
    if (!singleton) return 1;
    if (GetLastError() == ERROR_ALREADY_EXISTS) { CloseHandle(singleton); return 0; }
    HKEY video;
    if (RegOpenKeyExW(HKEY_CURRENT_CONFIG, video_path, 0, KEY_READ | KEY_NOTIFY, &video)) return 1;
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!event) return 1;
    WNDCLASSW cls = {.lpfnWndProc = window_proc, .hInstance = GetModuleHandleW(NULL),
                    .lpszClassName = L"DotfilesWineDisplaySync"};
    RegisterClassW(&cls);
    HWND window = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName, L"", WS_POPUP,
                                  0, 0, 0, 0, NULL, NULL, cls.hInstance, NULL);
    if (!window) return 1;
    HANDLE topology = INVALID_HANDLE_VALUE;
    const char *plan_path = getenv("WINE_XRANDR_PLAN");
    if (plan_path) {
        char directory[PATH_CAP];
        if (strlen(plan_path) >= sizeof(directory)) return 1;
        strcpy(directory, plan_path);
        char *separator = strrchr(directory, '\\');
        if (!separator) return 1;
        *separator = 0;
        topology = FindFirstChangeNotificationA(directory, FALSE, FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE);
        if (topology == INVALID_HANDLE_VALUE) return 1;
    }
    HANDLE shutdown = NULL;
    if (watch) {
        /* Like Proton's steam.exe, observe session shutdown without counting
         * as an application that keeps the prefix alive. The launcher waits
         * for Battle.net before starting us so we cannot race a cold start. */
        LONG (WINAPI *set_process_info)(HANDLE, ULONG, void *, ULONG) =
            (void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtSetInformationProcess");
        if (!set_process_info || set_process_info(GetCurrentProcess(), 1000,
                                                  &shutdown, sizeof(shutdown))) return 1;
    }
    printf("Wine display sync ready (runtime %s, process %lu)\n", version(), GetCurrentProcessId());
    int result = 0;
    BOOL topology_changed = plan_path != NULL;
    for (;;) {
        if (RegNotifyChangeKeyValue(video, TRUE, REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET,
                                     event, TRUE)) { result = 1; break; }
        int changed = repair_displays(video);
        if (changed < 0) {
            fprintf(stderr, "Wine display sync could not complete the repair\n");
            result = 1;
            break;
        }
        if (changed || topology_changed) {
            /* Wine 11.0's NtUserCallNoParam_DisplayModeChanged: rebuild the
             * shared monitor cache and notify the desktop/input machinery. */
            refresh(6);
            if (changed) printf("Repaired %d stale Wine display reference(s)\n", changed);
            topology_changed = FALSE;
        }
        log_topology();
        if (!watch) break;
        for (;;) {
            HANDLE events[3] = {event, shutdown, topology};
            DWORD count = topology == INVALID_HANDLE_VALUE ? 2 : 3;
            DWORD wait = wait_for_display_change(count, events, &result);
            if (wait == WAIT_OBJECT_0) { Sleep(200); break; }
            if (count == 3 && wait == WAIT_OBJECT_0 + 2) {
                if (!FindNextChangeNotification(topology)) { result = 1; goto done; }
                topology_changed = TRUE;
                Sleep(200);
                break;
            }
            if (wait != WAIT_OBJECT_0 + count) goto done;
            MSG msg;
            while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
                if (msg.message == WM_QUIT) goto done;
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
done:
    DestroyWindow(window);
    CloseHandle(event);
    if (shutdown) CloseHandle(shutdown);
    if (topology != INVALID_HANDLE_VALUE) FindCloseChangeNotification(topology);
    RegCloseKey(video);
    CloseHandle(singleton);
    return result;
}
#endif
