#include <stdint.h>
#include <string.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#endif

MOONBIT_FFI_EXPORT moonbit_string_t moonsage_get_command_line_utf16(void) {
#ifdef _WIN32
  const WCHAR *command_line = GetCommandLineW();
  size_t length = wcslen(command_line);
  moonbit_string_t result = moonbit_make_string((int32_t)length, 0);
  memcpy(result, command_line, length * sizeof(WCHAR));
  return result;
#else
  return moonbit_make_string(0, 0);
#endif
}
