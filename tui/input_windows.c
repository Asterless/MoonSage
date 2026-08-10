#include <string.h>
#include <stdint.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>

static HANDLE moonsage_input_handle = INVALID_HANDLE_VALUE;
static DWORD moonsage_original_input_mode = 0;
static int moonsage_input_active = 0;

static moonbit_string_t moonsage_utf16_string(const WCHAR *value, int32_t length) {
  moonbit_string_t result = moonbit_make_string(length, 0);
  if (length > 0) {
    memcpy(result, value, (size_t)length * sizeof(WCHAR));
  }
  return result;
}

static moonbit_string_t moonsage_ascii_string(const char *value) {
  int32_t length = (int32_t)strlen(value);
  moonbit_string_t result = moonbit_make_string(length, 0);
  for (int32_t i = 0; i < length; i++) {
    result[i] = (uint16_t)(unsigned char)value[i];
  }
  return result;
}
#endif

MOONBIT_FFI_EXPORT int32_t moonsage_tui_input_start(void) {
#ifdef _WIN32
  if (moonsage_input_active) {
    return 0;
  }
  moonsage_input_handle = GetStdHandle(STD_INPUT_HANDLE);
  if (moonsage_input_handle == INVALID_HANDLE_VALUE ||
      !GetConsoleMode(moonsage_input_handle, &moonsage_original_input_mode)) {
    return -1;
  }
  DWORD mode = moonsage_original_input_mode;
  mode |= ENABLE_EXTENDED_FLAGS | ENABLE_WINDOW_INPUT;
  mode &= ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT |
            ENABLE_VIRTUAL_TERMINAL_INPUT);
  if (!SetConsoleMode(moonsage_input_handle, mode)) {
    return -1;
  }
  moonsage_input_active = 1;
  return 0;
#else
  return -1;
#endif
}

MOONBIT_FFI_EXPORT void moonsage_tui_input_stop(void) {
#ifdef _WIN32
  if (moonsage_input_active && moonsage_input_handle != INVALID_HANDLE_VALUE) {
    SetConsoleMode(moonsage_input_handle, moonsage_original_input_mode);
  }
  moonsage_input_active = 0;
  moonsage_input_handle = INVALID_HANDLE_VALUE;
#endif
}

MOONBIT_FFI_EXPORT moonbit_string_t moonsage_tui_read_event(void) {
#ifdef _WIN32
  INPUT_RECORD record;
  DWORD read = 0;
  for (;;) {
    if (!ReadConsoleInputW(moonsage_input_handle, &record, 1, &read) || read == 0) {
      return moonbit_make_string(0, 0);
    }
    if (record.EventType == WINDOW_BUFFER_SIZE_EVENT) {
      return moonbit_make_string(0, 0);
    }
    if (record.EventType != KEY_EVENT || !record.Event.KeyEvent.bKeyDown) {
      continue;
    }
    KEY_EVENT_RECORD key = record.Event.KeyEvent;
    WCHAR c = key.uChar.UnicodeChar;
    if (c == 8) {
      WCHAR backspace = 127;
      return moonsage_utf16_string(&backspace, 1);
    }
    if (c != 0) {
      return moonsage_utf16_string(&c, 1);
    }
    switch (key.wVirtualKeyCode) {
      case VK_LEFT: return moonsage_ascii_string("\x1b[D");
      case VK_RIGHT: return moonsage_ascii_string("\x1b[C");
      case VK_UP: return moonsage_ascii_string("\x1b[A");
      case VK_DOWN: return moonsage_ascii_string("\x1b[B");
      case VK_HOME: return moonsage_ascii_string("\x1b[H");
      case VK_END: return moonsage_ascii_string("\x1b[F");
      case VK_DELETE: return moonsage_ascii_string("\x1b[3~");
      case VK_PRIOR: return moonsage_ascii_string("\x1b[5~");
      case VK_NEXT: return moonsage_ascii_string("\x1b[6~");
      case VK_ESCAPE: return moonsage_ascii_string("\x1b");
      default: break;
    }
  }
#else
  return moonbit_make_string(0, 0);
#endif
}
