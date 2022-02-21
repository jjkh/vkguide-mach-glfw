// TODO: currently each font independently inits FreeType
ft_handle: c.FT_Library,
ft_face: c.FT_Face,

const Font = @This();

const std = @import("std");
const log = std.log.scoped(.font);

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub fn create(font_file: []const u8) !Font {
    var ft_handle: c.FT_Library = undefined;
    {
        const status = c.FT_Init_FreeType(&ft_handle);
        if (status > 0) {
            log.err("freetype init failed with code {}", .{status});
            return error.FreeTypeInitFailed;
        }
    }
    errdefer _ = c.FT_Done_FreeType(ft_handle);

    var ft_face: c.FT_Face = undefined;
    {
        const status = c.FT_New_Memory_Face(ft_handle, font_file, font_file.len, 0, &ft_face);
        if (status > 0) {
            log.err("font load failed with code {}", .{status});
            return error.FontLoadFailed;
        }
    }

    return Font{ .ft_handle = ft_handle, .ft_face = ft_face };
}

pub fn free(self: *Font) void {
    _ = c.FT_Done_Face(self.ft_face);
    _ = c.FT_Done_FreeType(self.ft_handle);
}

pub const Glyph = struct {
    glyph_slot: c.FT_GlyphSlot,
};

// TODO: this isn't robust - what about extended grapheme clusters?
pub fn getGlyph(self: Font, codepoint: u21, px_height: usize) Glyph {
    _ = c.FT_Set_Pixel_Sizes(self.ft_face, 0, px_height);

    const status = c.FT_Load_Char(self.ft_face, codepoint, c.FT_LOAD_RENDER);
    if (status > 0) {
        log.err("'{0u}' ({0}) load failed with code {1}", .{ codepoint, status });
        return error.FreeTypeInitFailed;
    }
}
