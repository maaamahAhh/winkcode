#pragma once
#include <windows.h>

// Forward declaration of union uChar at file scope.
// KEY_EVENT_RECORD in wincon.h defines uChar as an anonymous union.
// In -prod mode, V generates keepalive helpers referencing union uChar.
// Without a file-scope declaration, GCC treats the prototype parameter
// as prototype-scoped, causing a conflicting types error.
union uChar;
