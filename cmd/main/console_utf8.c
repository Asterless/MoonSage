#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#endif

MOONBIT_FFI_EXPORT void moonsage_set_console_utf8(void) {
#ifdef _WIN32
  // Make the console interpret the program's UTF-8 output correctly.
  // When stdout is a real console, the MoonBit runtime uses WriteConsoleW
  // (UTF-16) and this call is a no-op; when output is forwarded through a
  // pipe (e.g. `moon run`), the runtime writes UTF-8 bytes, so the console
  // must be told to decode them as UTF-8 instead of the legacy ANSI codepage.
  SetConsoleOutputCP(CP_UTF8);
  // Also make typed input arrive as UTF-8: on a Chinese-locale console the
  // default input codepage is GBK (CP936), so Chinese input such as "你好"
  // arrives as GBK bytes that fail UTF-8 decoding in `read_until`.
  SetConsoleCP(CP_UTF8);
#endif
}
