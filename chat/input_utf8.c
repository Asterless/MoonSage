#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "moonbit.h"

#ifdef _WIN32
#include <windows.h>
#endif

// Convert bytes encoded in the system ANSI codepage (GBK/CP936 on Chinese
// Windows) to UTF-8. The MoonBit side only calls this after UTF-8 decoding
// fails, so the input is expected to be a legacy codepage sequence.
MOONBIT_FFI_EXPORT moonbit_bytes_t moonsage_gbk_to_utf8(
  moonbit_bytes_t input,
  int32_t offset,
  int32_t len
) {
#ifdef _WIN32
  if (len <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  const char *data = (const char *)input + offset;
  int wide_len = MultiByteToWideChar(
    CP_ACP,
    0,
    data,
    len,
    NULL,
    0
  );
  if (wide_len <= 0) {
    // Conversion failed (unmappable bytes): return the input unchanged.
    moonbit_bytes_t fallback = moonbit_make_bytes(len, 0);
    memcpy(fallback, data, (size_t)len);
    return fallback;
  }
  wchar_t *wide = (wchar_t *)malloc((size_t)wide_len * sizeof(wchar_t));
  if (wide == NULL) {
    moonbit_bytes_t fallback = moonbit_make_bytes(len, 0);
    memcpy(fallback, data, (size_t)len);
    return fallback;
  }
  MultiByteToWideChar(CP_ACP, 0, data, len, wide, wide_len);
  int utf8_len = WideCharToMultiByte(
    CP_UTF8,
    0,
    wide,
    wide_len,
    NULL,
    0,
    NULL,
    NULL
  );
  moonbit_bytes_t result = moonbit_make_bytes(utf8_len, 0);
  WideCharToMultiByte(
    CP_UTF8,
    0,
    wide,
    wide_len,
    (char *)result,
    utf8_len,
    NULL,
    NULL
  );
  free(wide);
  return result;
#else
  moonbit_bytes_t result = moonbit_make_bytes(len, 0);
  memcpy(result, (const char *)input + offset, (size_t)len);
  return result;
#endif
}
