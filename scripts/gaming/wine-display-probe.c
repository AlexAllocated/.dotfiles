/* Read-only display and message-pump diagnostics in the actual Wine session. */
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <shellscalingapi.h>
#include <stdio.h>
#include <wchar.h>

static int failures;
static unsigned windows, monitors;

static BOOL CALLBACK monitor_info(HMONITOR monitor, HDC dc, LPRECT rect, LPARAM data)
{
	(void)dc;
	(void)data;
	MONITORINFOEXW info = {.cbSize = sizeof(info)};
	UINT effective_x = 0, effective_y = 0, raw_x = 0, raw_y = 0;
	BOOL found = GetMonitorInfoW(monitor, (MONITORINFO *)&info);
	HRESULT effective = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &effective_x, &effective_y);
	HRESULT raw = GetDpiForMonitor(monitor, MDT_RAW_DPI, &raw_x, &raw_y);
	if (!found || FAILED(effective) || FAILED(raw) ||
	    !effective_x || !raw_x) { failures++; return TRUE; }
	printf("monitor=%ls rect=%ld,%ld %ldx%ld primary=%u effective_dpi=%u raw_dpi=%u\n",
	       info.szDevice, info.rcMonitor.left, info.rcMonitor.top,
	       info.rcMonitor.right - info.rcMonitor.left, info.rcMonitor.bottom - info.rcMonitor.top,
	       !!(info.dwFlags & MONITORINFOF_PRIMARY), effective_x, raw_x);
	if (!info.szDevice[0] || !wcscmp(info.szDevice, L"WinDisc") ||
	    !EqualRect(rect, &info.rcMonitor)) {
		printf("unstable_monitor handle=%p enumerated=%ld,%ld %ldx%ld\n", (void *)monitor,
		       rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top);
		failures++;
	}
	monitors++;
	return TRUE;
}

static BOOL CALLBACK window_info(HWND window, LPARAM data)
{
	(void)data;
	wchar_t title[128];
	GetWindowTextW(window, title, 128);
	if (wcscmp(title, L"Battle.net") && wcscmp(title, L"World of Warcraft")) return TRUE;
	DWORD pid = 0;
	DWORD_PTR response;
	RECT client = {0};
	POINT corner = {0};
	GetWindowThreadProcessId(window, &pid);
	GetClientRect(window, &client);
	corner.x = client.right - 1;
	corner.y = client.bottom - 1;
	ClientToScreen(window, &corner);
	BOOL responsive = SendMessageTimeoutW(window, WM_NULL, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &response) != 0;
	printf("window=%ls pid=%lu visible=%u responsive=%u dpi=%u client=%ldx%ld bottom_right=%ld,%ld\n",
	       title, pid, IsWindowVisible(window), responsive, GetDpiForWindow(window),
	       client.right, client.bottom, corner.x, corner.y);
	if (!responsive) failures++;
	windows++;
	return TRUE;
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);
	SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
	/* Initialize desktop context before inspecting its display APIs. */
	GetDesktopWindow();
	if (!EnumDisplayMonitors(NULL, NULL, monitor_info, 0) || !EnumWindows(window_info, 0)) return 2;
	printf("display_probe monitors=%u application_windows=%u failures=%d\n", monitors, windows, failures);
	return failures || !monitors;
}
