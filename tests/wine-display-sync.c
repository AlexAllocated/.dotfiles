#define DISPLAY_SYNC_TEST
#include "../scripts/gaming/wine-display-sync.c"

static unsigned assertions;
#define CHECK(expr) do { assertions++; if (!(expr)) { \
    fprintf(stderr, "Failed line %d: %s\n", __LINE__, #expr); return 1; } } while (0)

static void set_target(HKEY key, const wchar_t *target)
{
    RegSetValueExW(key, L"SymbolicLinkValue", 0, REG_LINK,
                   (const BYTE *)target, (DWORD)(wcslen(target) * sizeof(wchar_t)));
}

static DWORD flags(HKEY parent, const wchar_t *name)
{
    HKEY key;
    DWORD value = 0, size = sizeof(value);
    if (RegOpenKeyExW(parent, name, 0, KEY_READ, &key)) return 0;
    RegQueryValueExW(key, L"StateFlags", NULL, NULL, (BYTE *)&value, &size);
    RegCloseKey(key);
    return value;
}

int main(int argc, char **argv)
{
    BOOL watch = argc == 2 && !strcmp(argv[1], "--watch-test");
    if (!watch) {
        HANDLE invalid = NULL;
        int result = 0;
        CHECK(wait_for_display_change(1, &invalid, &result) == WAIT_FAILED);
        CHECK(result == 1); /* An API failure must reach bounded recovery. */
    }
    HKEY root = watch ? HKEY_CURRENT_CONFIG : HKEY_CURRENT_USER;
    wchar_t path[256], native[PATH_CAP], a[PATH_CAP], b[PATH_CAP], invalid[PATH_CAP], actual[PATH_CAP];
    HKEY gpu, old, current, alias, second;
    second = NULL;
    swprintf(path, 256, L"%ls\\DotfilesDisplaySyncTest-%lu-%llu",
             watch ? L"System\\CurrentControlSet\\Control\\Video" : L"Software",
             GetCurrentProcessId(), GetTickCount64());
    CHECK(!RegCreateKeyExW(root, path, 0, NULL, REG_OPTION_VOLATILE, KEY_ALL_ACCESS, NULL, &gpu, NULL));
    struct { ULONG length; WCHAR name[PATH_CAP]; } info;
    ULONG size;
    LONG (WINAPI *query)(HANDLE, ULONG, void *, ULONG, ULONG *) =
        (void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryKey");
    CHECK(query && !query(gpu, 3, &info, sizeof(info), &size));
    info.name[info.length / sizeof(wchar_t)] = 0;
    wcscpy(native, info.name);
    if (watch) swprintf(native, PATH_CAP,
        L"\\Registry\\Machine\\System\\CurrentControlSet\\Hardware Profiles\\Current\\%ls", path);
    swprintf(a, PATH_CAP, L"%ls\\Sources\\0010", native);
    swprintf(b, PATH_CAP, L"%ls\\Sources\\0020", native);
    CHECK(!RegCreateKeyExW(gpu, L"Sources\\0010", 0, NULL, REG_OPTION_VOLATILE, KEY_ALL_ACCESS, NULL, &old, NULL));
    CHECK(!RegCreateKeyExW(gpu, L"Sources\\0020", 0, NULL, REG_OPTION_VOLATILE, KEY_ALL_ACCESS, NULL, &current, NULL));
    DWORD value = 1;
    RegSetValueExW(old, L"StateFlags", 0, REG_DWORD, (BYTE *)&value, sizeof(value));
    value = 5;
    RegSetValueExW(current, L"StateFlags", 0, REG_DWORD, (BYTE *)&value, sizeof(value));
    CHECK(!RegCreateKeyExW(gpu, L"0000", 0, NULL, REG_OPTION_VOLATILE | REG_OPTION_CREATE_LINK,
                            KEY_ALL_ACCESS, NULL, &alias, NULL));
    set_target(alias, a);
    CHECK(repair_gpu(gpu, native) == 0);
    CHECK(flags(gpu, L"0000") == 1);

    /* Real Wine registry semantics: a REG_LINK value on a regular source
     * record does not turn it into a symbolic link. */
    set_target(old, b);
    CHECK(flags(gpu, L"0000") == 1);
    if (watch) {
        for (unsigned i = 0; i < 100 && flags(gpu, L"0000") != 5; i++) Sleep(100);
        CHECK(flags(gpu, L"0000") == 5);
        CHECK(flags(gpu, L"Sources\\0010") == 1);
        goto cleanup;
    }
    CHECK(repair_gpu(gpu, native) == 1);
    CHECK(flags(gpu, L"0000") == 5);
    CHECK(flags(gpu, L"Sources\\0010") == 1);
    CHECK(!read_link(gpu, L"Sources\\0010", actual));
    CHECK(repair_gpu(gpu, native) == 0);

    set_target(current, b);
    CHECK(repair_gpu(gpu, native) == 0);
    CHECK(!read_link(gpu, L"Sources\\0020", actual));

    /* Swapping monitor indexes must repair both aliases from one snapshot,
     * then remove misplaced values so the next notification cannot undo it. */
    CHECK(!RegCreateKeyExW(gpu, L"0001", 0, NULL, REG_OPTION_VOLATILE | REG_OPTION_CREATE_LINK,
                            KEY_ALL_ACCESS, NULL, &second, NULL));
    set_target(second, a);
    set_target(current, a);
    set_target(old, b);
    CHECK(repair_gpu(gpu, native) == 2);
    CHECK(flags(gpu, L"0000") == 1 && flags(gpu, L"0001") == 5);
    CHECK(repair_gpu(gpu, native) == 0);

    swprintf(invalid, PATH_CAP, L"%ls\\Elsewhere\\0020", native);
    set_target(old, invalid);
    CHECK(repair_gpu(gpu, native) == 0);
    CHECK(flags(gpu, L"0000") == 1);
    swprintf(invalid, PATH_CAP, L"%ls\\Sources\\9999", native);
    set_target(old, invalid);
    CHECK(repair_gpu(gpu, native) == 0);
    CHECK(flags(gpu, L"0000") == 1);
    RegDeleteValueW(old, L"SymbolicLinkValue");

    /* Lost link values cannot recover aliases that collapsed to one source.
     * Authoritative XRandR IDs must restore distinct bindings even then. */
    set_target(alias, b);
    set_target(second, b);
    xrandr_sources[0] = 0x20;
    xrandr_sources[1] = 0x10;
    xrandr_count = 2;
    CHECK(repair_gpu(gpu, native) == 1);
    CHECK(flags(gpu, L"0000") == 5 && flags(gpu, L"0001") == 1);
    CHECK(read_link(gpu, L"0000", actual) && !_wcsicmp(actual, b));
    CHECK(read_link(gpu, L"0001", actual) && !_wcsicmp(actual, a));
    CHECK(repair_gpu(gpu, native) == 0);
    xrandr_sources[1] = 0x9999;
    CHECK(repair_gpu(gpu, native) == 0); /* Wait for a complete native source set. */
    CHECK(flags(gpu, L"0001") == 1);
    xrandr_count = -1;

cleanup:;
    LONG (WINAPI *delete_key)(HANDLE) =
        (void *)GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtDeleteKey");
    CHECK(delete_key && !delete_key(alias) && (!second || !delete_key(second)));
    RegCloseKey(alias);
    RegCloseKey(second);
    RegCloseKey(old);
    RegCloseKey(current);
    RegCloseKey(gpu);
    CHECK(!RegDeleteTreeW(root, path));
    CHECK(RegOpenKeyExW(root, path, 0, KEY_READ, &gpu) == ERROR_FILE_NOT_FOUND);
    printf("PASS: %u %s assertions\n", assertions, watch ? "live watcher" : "registry repair");
    return 0;
}
