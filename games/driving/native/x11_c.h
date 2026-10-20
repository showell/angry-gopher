/* The C the X11 window uses, translated by build.zig's addTranslateC into
 * the module `c` (Zig 0.17 removed @cImport). */
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/Xrender.h>
#include <X11/Xatom.h>
#include <unistd.h>
#include <time.h>
