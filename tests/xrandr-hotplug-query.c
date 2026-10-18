/* A removed output must return NULL without killing the calling process. */
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <stdio.h>
#include <string.h>

static int other_errors;
static int count_error(Display *display, XErrorEvent *event)
{
	(void)display;
	(void)event;
	other_errors++;
	return 0;
}

int main(int argc, char **argv)
{
	Display *display = XOpenDisplay(NULL);
	if (!display) return 2;
	XRRScreenResources *resources = XRRGetScreenResourcesCurrent(display, DefaultRootWindow(display));
	if (!resources || !resources->noutput) return 2;
	/* Keep the default fatal handler for the disappearing-monitor query. */
	XRROutputInfo *missing = XRRGetOutputInfo(display, resources, 0x7fffffff);
	if (missing) return 1;
	XRRCrtcInfo *missing_crtc = XRRGetCrtcInfo(display, resources, 0x7fffffff);
	if (missing_crtc) return 1;
	/* Recovery must not poison the connection or change valid queries. */
	XRROutputInfo *valid = XRRGetOutputInfo(display, resources, resources->outputs[0]);
	if (!valid || !valid->nameLen) return 1;
	XRRCrtcInfo *valid_crtc = XRRGetCrtcInfo(display, resources, valid->crtc);
	if (!valid_crtc || !valid_crtc->width) return 1;
	XRRFreeCrtcInfo(valid_crtc);
	XRRFreeOutputInfo(valid);
	/* Unrelated protocol errors must still reach the client's handler. */
	XSetErrorHandler(count_error);
	XDestroyWindow(display, 0x7fffffff);
	XSync(display, False);
	if (other_errors != 1) return 1;
	XRRFreeScreenResources(resources);
	XCloseDisplay(display);
	(void)argc;
	(void)argv;
	puts("PASS: stale output query survives, valid output works, unrelated error remains visible");
	return 0;
}
