/* Translation shim: exposes the full public FreeType API to Zig's
 * translateC. ft2build.h alone only dispatches header macros. */
#include <ft2build.h>
#include FT_FREETYPE_H
