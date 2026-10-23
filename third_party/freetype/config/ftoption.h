/* Minimal TrueType/SFNT grayscale configuration for the vendored FreeType
 * subset. No gzip, bzip2, PNG, Brotli, HarfBuzz, SVG, cache, or system
 * streams. Derived from upstream defaults; upstream sources are unmodified.
 */
#ifndef PROBE_FTOPTION_H_
#define PROBE_FTOPTION_H_
#include <ft2build.h>
FT_BEGIN_HEADER
#define FT_CONFIG_OPTION_DISABLE_STREAM_SUPPORT
#define FT_CONFIG_OPTION_ERROR_STRINGS
#define FT_RENDER_POOL_SIZE 16384L
#define FT_MAX_MODULES 3
#define TT_CONFIG_OPTION_EMBEDDED_BITMAPS
#define TT_CONFIG_CMAP_FORMAT_4
#define TT_CONFIG_CMAP_FORMAT_12
#define TT_CONFIG_OPTION_BYTECODE_INTERPRETER
/* Shared internal declarations require these upstream limits even without a Type 1 driver. */
#define T1_MAX_DICT_DEPTH 5
#define T1_MAX_SUBRS_CALLS 16
#define T1_MAX_CHARSTRINGS_OPERANDS 256
FT_END_HEADER
#endif
