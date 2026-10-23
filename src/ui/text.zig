//! FreeType-backed glyph rasterization over a bounded caller-owned pool.
//! Rendered bitmaps are presentation-only: they never alias, transform, or
//! replace authoritative source bytes.

const std = @import("std");
const ft = @import("freetype_c");

pub const slot_count = 256;
pub const max_glyph_width = 32;
pub const max_glyph_rows = 32;
pub const pool_capacity = slot_count * max_glyph_width * max_glyph_rows;

const load_flags = ft.FT_LOAD_DEFAULT | ft.FT_LOAD_RENDER;

pub const Glyph = struct {
    codepoint: u21,
    width: u32,
    rows: u32,
    /// Distance from the cluster origin to the bitmap's left edge, in pixels.
    left: c_int,
    /// Distance from the baseline up to the bitmap's top edge, in pixels.
    top: c_int,
    /// Horizontal pen advance in whole pixels (26.6 truncated).
    advance: c_int,
    /// 8-bit coverage, `width * rows`, borrowed from the renderer pool.
    pixels: []u8,
};

/// Rasterizes glyphs from one in-memory font face at one fixed pixel size.
/// The pool is monotonically consumed: evicted slots are not reclaimed, so
/// callers cap the live charset well below `slot_count`.
pub const Renderer = struct {
    library: ft.FT_Library,
    face: ft.FT_Face,
    pool: []u8,
    pool_used: usize,
    pixel_size: u16,
    slots: [slot_count]?Glyph,
    next_eviction: usize,

    pub fn init(pool: []u8, font_bytes: []const u8, pixel_size: u16) InitError!Renderer {
        std.debug.assert(pool.len >= pool_capacity);
        std.debug.assert(font_bytes.len > 0);
        std.debug.assert(font_bytes.len <= std.math.maxInt(c_long));
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FreeTypeInitFailed;
        errdefer _ = ft.FT_Done_FreeType(library);
        var face: ft.FT_Face = null;
        if (ft.FT_New_Memory_Face(library, font_bytes.ptr, @intCast(font_bytes.len), 0, &face) != 0) return error.FontUnsupported;
        errdefer _ = ft.FT_Done_Face(face);
        if (face.*.face_flags == 0) return error.FontUnsupported;
        if (ft.FT_Set_Pixel_Sizes(face, 0, @intCast(pixel_size)) != 0) return error.PixelSizeUnsupported;
        return .{
            .library = library,
            .face = face,
            .pool = pool,
            .pool_used = 0,
            .pixel_size = pixel_size,
            .slots = @splat(null),
            .next_eviction = 0,
        };
    }

    pub fn deinit(self: *Renderer) void {
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
        self.* = undefined;
    }

    /// Returns the cached rasterization, refreshing via round-robin eviction.
    pub fn glyph(self: *Renderer, codepoint: u21) GlyphError!*const Glyph {
        for (self.slots, 0..) |maybe, index| {
            if (maybe) |cached| {
                if (cached.codepoint == codepoint) return &self.slots[index].?;
            }
        }
        return self.rasterize(codepoint);
    }

    fn rasterize(self: *Renderer, codepoint: u21) GlyphError!*const Glyph {
        if (ft.FT_Load_Char(self.face, @intCast(codepoint), load_flags) != 0) return error.GlyphLoadFailed;
        const slot: *ft.FT_GlyphSlotRec = self.face.*.glyph;
        const bitmap = slot.*.bitmap;
        if (bitmap.width > max_glyph_width or bitmap.rows > max_glyph_rows) return error.GlyphTooLarge;
        var pixels: []u8 = &.{};
        if (bitmap.width != 0 and bitmap.rows != 0) {
            if (bitmap.pixel_mode != @as(u8, @intCast(ft.FT_PIXEL_MODE_GRAY))) return error.GlyphModeUnsupported;
            if (bitmap.pitch <= 0 or bitmap.buffer == null) return error.GlyphModeUnsupported;
            const needed: usize = @as(usize, bitmap.width) * @as(usize, bitmap.rows);
            const start = self.pool_used;
            if (start + needed > self.pool.len) return error.GlyphPoolExhausted;
            pixels = self.pool[start..][0..needed];
            self.pool_used = start + needed;
            const stride: usize = @intCast(bitmap.pitch);
            for (0..bitmap.rows) |row| {
                const source = bitmap.buffer[row * stride ..][0..bitmap.width];
                @memcpy(pixels[row * bitmap.width ..][0..bitmap.width], source);
            }
        }
        const index = self.next_eviction;
        self.next_eviction = (index + 1) % slot_count;
        const metrics = slot.*.metrics;
        self.slots[index] = .{
            .codepoint = codepoint,
            .width = bitmap.width,
            .rows = bitmap.rows,
            .left = slot.*.bitmap_left,
            .top = slot.*.bitmap_top,
            .advance = @intCast(@divTrunc(metrics.horiAdvance, 64)),
            .pixels = pixels,
        };
        return &self.slots[index].?;
    }
};

pub const InitError = error{
    FreeTypeInitFailed,
    FontUnsupported,
    PixelSizeUnsupported,
    OutOfMemory,
};

pub const GlyphError = error{
    GlyphLoadFailed,
    GlyphTooLarge,
    GlyphModeUnsupported,
    GlyphPoolExhausted,
};
