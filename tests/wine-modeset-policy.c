/* Run in a disposable Wine prefix under Xwayland, with EmulateModeset set
 * before starting the process. This tests runtime behavior, not a registry
 * string: an emulated mode changes Wine's resolution while a native mode
 * must continue to match the compositor. Always restore the original mode.
 */
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <shellscalingapi.h>
#include <stdio.h>
#include <string.h>

static unsigned monitors;
static BOOL dpi_valid = TRUE;

static BOOL CALLBACK check_monitor(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data)
{
	(void)dc;
	(void)rect;
	(void)data;
	UINT x = 0, y = 0;
	HRESULT result = GetDpiForMonitor(monitor, MDT_RAW_DPI, &x, &y);
	printf("monitor raw DPI: result=%lx x=%u y=%u\n", (unsigned long)result, x, y);
	if (FAILED(result) || !x || !y) dpi_valid = FALSE;
	monitors++;
	return TRUE;
}

int main(int argc, char **argv)
{
	BOOL emulated = argc == 2 && !strcmp(argv[1], "--expect-emulated");
	if (argc != 2 || (!emulated && strcmp(argv[1], "--expect-native"))) return 2;
	setvbuf(stdout, NULL, _IONBF, 0);
	DEVMODEW initial = {.dmSize = sizeof(DEVMODEW)};
	if (!EnumDisplaySettingsExW(NULL, ENUM_CURRENT_SETTINGS, &initial, 0)) return 2;
	DWORD width = initial.dmPelsWidth == 1920 ? 800 : 1920;
	DWORD height = width == 800 ? 600 : 1080;
	DEVMODEW target = {.dmSize = sizeof(DEVMODEW)};
	BOOL supported = FALSE;
	for (DWORD i = 0; EnumDisplaySettingsExW(NULL, i, &target, 0); i++) {
		if (target.dmPelsWidth == width && target.dmPelsHeight == height) {
			supported = TRUE;
			break;
		}
	}
	if (!supported) return 2;
	target.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
	LONG result = ChangeDisplaySettingsExW(NULL, &target, NULL, 0, NULL);
	DEVMODEW actual = {.dmSize = sizeof(DEVMODEW)};
	BOOL queried = EnumDisplaySettingsExW(NULL, ENUM_CURRENT_SETTINGS, &actual, 0);
	BOOL enumerated = EnumDisplayMonitors(NULL, NULL, check_monitor, 0);
	LONG restored = ChangeDisplaySettingsExW(NULL, &initial, NULL, 0, NULL);
	printf("initial=%lux%lu requested=%lux%lu observed=%lux%lu change=%ld restore=%ld\n",
	       initial.dmPelsWidth, initial.dmPelsHeight, width, height,
	       actual.dmPelsWidth, actual.dmPelsHeight, result, restored);
	DWORD expected_width = emulated ? width : initial.dmPelsWidth;
	DWORD expected_height = emulated ? height : initial.dmPelsHeight;
	if (result != DISP_CHANGE_SUCCESSFUL || restored != DISP_CHANGE_SUCCESSFUL ||
	    !queried || !enumerated || !monitors || !dpi_valid ||
	    actual.dmPelsWidth != expected_width || actual.dmPelsHeight != expected_height) return 1;
	puts("PASS: modeset policy and monitor DPI");
	return 0;
}
