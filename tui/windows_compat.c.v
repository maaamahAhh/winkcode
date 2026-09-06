module tui

// Compatibility flags for Windows -prod builds with GCC.
// Silences pointer type mismatches from wincon.h anonymous union parameters.
#flag windows -I @VMODROOT/tui
#flag windows -Wno-incompatible-pointer-types
#include "windows_compat.h"
