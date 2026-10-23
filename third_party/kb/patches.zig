//! Build-time patch engine for the vendored kb_text_shape.h header.
//!
//! The vendored header stays byte-identical to the pinned upstream commit so
//! future updates are a plain re-vendor. Patches are exact-context
//! replacements applied in order at build time; see README.md for the update
//! and patch-removal procedure. The end goal is zero patches.

const std = @import("std");

pub const upstream_repository: []const u8 = "https://github.com/JimmyLefevre/kb";
pub const upstream_commit: []const u8 = "7d811ad80215eef6363d60057b0ea140215278a1";
pub const upstream_version: []const u8 = "kb_text_shape 2.28g";
pub const upstream_sha256: []const u8 = "51a93aad590375148f35cb32e24f44ee0afcb6eb4c993749ef31143f78979a5e";
pub const patched_sha256: []const u8 = "72d961c99b0ef71e526e427f6dd6af794a930a15bc6454358cbefadc31a5acb8";

/// The pristine upstream bytes, embedded at compile time so every consumer
/// (verification executable, status tool, tests) rebuilds whenever the
/// vendored header changes.
pub const vendored_header = @embedFile("kb_text_shape.h");

pub const Error = error{
    PatchContextMissing,
    PatchContextAmbiguous,
    PatchedHashMismatch,
    OutOfMemory,
};

pub const Patch = struct {
    id: []const u8,
    summary: []const u8,
    old: []const u8,
    new: []const u8,
};

pub const Failure = struct {
    kind: Error = error.PatchContextMissing,
    patch_index: ?usize = null,
    occurrences: usize = 0,
};

pub const patches = [_]Patch{
    .{
        .id = "P0-provenance-banner",
        .summary = "Mark the locally patched copy per zlib license condition 2.",
        .old =
        \\/*  kb_text_shape - v2.28g - text segmentation and shaping
        ,
        .new =
        \\/* Locally patched for warkocz; not upstream bytes.
        \\   Changes: allocation failure propagation and GB11 grapheme state.
        \\   See third_party/kb/README.md; original license retained below. */
        \\/*  kb_text_shape - v2.28g - text segmentation and shaping
        ,
    },
    .{
        .id = "P1-arena-push-block-sentinel",
        .summary = "Refused arena allocation must not insert the sentinel as a block.",
        .old =
        \\        Result = (kbts__arena_block *)&Arena->BlockSentinel;
        \\        Arena->Error = 1;
        \\      }
        ,
        .new =
        \\        Result = (kbts__arena_block *)&Arena->BlockSentinel;
        \\        Arena->Error = 1;
        \\        return Result; /* warkocz patch: never write through the sentinel. */
        \\      }
        ,
    },
    .{
        .id = "P2-create-shape-context-null",
        .summary = "CreateShapeContext2 must return null instead of dereferencing a refused allocation.",
        .old =
        \\  Result->SelfAllocator = Allocator;
        \\  Result->SelfAllocatorData = AllocatorData;
        \\  return Result;
        ,
        .new =
        \\  if(Result)
        \\  {
        \\    Result->SelfAllocator = Allocator; /* warkocz patch. */
        \\    Result->SelfAllocatorData = AllocatorData;
        \\  }
        \\  return Result;
        ,
    },
    .{
        .id = "P3-font-push-oom-classification",
        .summary = "Map PlaceBlob out-of-memory to the context error in ShapePushFontFromMemory2.",
        .old =
        \\          Error = kbts_PlaceBlob(Result, &State, Scratch, Output);
        \\        }
        \\
        \\        if(!Error)
        ,
        .new =
        \\          Error = kbts_PlaceBlob(Result, &State, Scratch, Output);
        \\        }
        \\        if(Error == KBTS_LOAD_FONT_ERROR_OUT_OF_MEMORY)
        \\        {
        \\          Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY; /* warkocz patch. */
        \\        }
        \\
        \\        if(!Error)
        ,
    },
    .{
        .id = "P4-shape-config-null-cache",
        .summary = "A failed shape config creation must not cache or return a null config.",
        .old =
        \\    Result = kbts_CreateShapeConfig2(FontInfo->Font, Script, Language, FontInfo->VariationVector, kbts__ArenaAllocator, &Context->ConfigArena, 0);
        \\
        \\    KBTS_ASSERT
        ,
        .new =
        \\    Result = kbts_CreateShapeConfig2(FontInfo->Font, Script, Language, FontInfo->VariationVector, kbts__ArenaAllocator, &Context->ConfigArena, 0);
        \\    if(!Result)
        \\    {
        \\      Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY; /* warkocz patch. */
        \\      return 0;
        \\    }
        \\
        \\    KBTS_ASSERT
        ,
    },
    .{
        .id = "P5-glyph-config-null-cache",
        .summary = "A failed glyph config creation must not cache or return a null config.",
        .old =
        \\      Result = kbts_CreateGlyphConfig(ShapeConfig, FeatureOverrides, FeatureOverrideCount, kbts__ArenaAllocator, &Context->ConfigArena);
        \\
        \\      KBTS_ASSERT
        ,
        .new =
        \\      Result = kbts_CreateGlyphConfig(ShapeConfig, FeatureOverrides, FeatureOverrideCount, kbts__ArenaAllocator, &Context->ConfigArena);
        \\      if(!Result)
        \\      {
        \\        Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY; /* warkocz patch. */
        \\        return 0;
        \\      }
        \\
        \\      KBTS_ASSERT
        ,
    },
    .{
        .id = "P6-shaperun-init-branch-checks",
        .summary = "Check config, glyph config, and glyph push in the run-initialization branch.",
        .old =
        \\            ShapeConfig = kbts__FindOrCreateShapeConfig(Context, RunFontInfo, RunScript, Language);
        \\
        \\            kbts_glyph_config *GlyphConfig = kbts__FindOrCreateGlyphConfig(Context, ShapeConfig, InputCodepoint->FeatureOverrides, InputCodepoint->FeatureOverrideCount);
        \\            kbts_PushGlyph(&Context->GlyphStorage, RunFontInfo->Font, InputCodepoint->Codepoint, GlyphConfig, InputCodepointIndex);
        ,
        .new =
        \\            ShapeConfig = kbts__FindOrCreateShapeConfig(Context, RunFontInfo, RunScript, Language);
        \\            if(!ShapeConfig) return 0; /* warkocz patch. */
        \\
        \\            kbts_glyph_config *GlyphConfig = kbts__FindOrCreateGlyphConfig(Context, ShapeConfig, InputCodepoint->FeatureOverrides, InputCodepoint->FeatureOverrideCount);
        \\            if(Context->Error) return 0; /* warkocz patch: null is valid without overrides. */
        \\            if(!kbts_PushGlyph(&Context->GlyphStorage, RunFontInfo->Font, InputCodepoint->Codepoint, GlyphConfig, InputCodepointIndex))
        \\            {
        \\              Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
        \\              return 0;
        \\            }
        ,
    },
    .{
        .id = "P7-shaperun-else-branch-checks",
        .summary = "Check config, glyph config, and glyph push in the run-continuation branch.",
        .old =
        \\            ShapeConfig = kbts__FindOrCreateShapeConfig(Context, RunFontInfo, RunScript, Language);
        \\          }
        \\
        \\          kbts_glyph_config *GlyphConfig = kbts__FindOrCreateGlyphConfig(Context, ShapeConfig, InputCodepoint->FeatureOverrides, InputCodepoint->FeatureOverrideCount);
        \\          kbts_PushGlyph(&Context->GlyphStorage, RunFontInfo->Font, InputCodepoint->Codepoint, GlyphConfig, InputCodepointIndex);
        ,
        .new =
        \\            ShapeConfig = kbts__FindOrCreateShapeConfig(Context, RunFontInfo, RunScript, Language);
        \\            if(!ShapeConfig) return 0; /* warkocz patch. */
        \\          }
        \\
        \\          kbts_glyph_config *GlyphConfig = kbts__FindOrCreateGlyphConfig(Context, ShapeConfig, InputCodepoint->FeatureOverrides, InputCodepoint->FeatureOverrideCount);
        \\          if(Context->Error) return 0; /* warkocz patch. */
        \\          if(!kbts_PushGlyph(&Context->GlyphStorage, RunFontInfo->Font, InputCodepoint->Codepoint, GlyphConfig, InputCodepointIndex))
        \\          {
        \\            Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
        \\            return 0;
        \\          }
        ,
    },
    .{
        .id = "P8-shaperun-scratchpad-memory",
        .summary = "Refused scratchpad arena memory must stop the run before placement.",
        .old =
        \\        kbts_shape_scratchpad *Scratchpad = kbts_PlaceShapeScratchpad(ShapeConfig, kbts__PushSize(&Context->ScratchArena, ScratchpadSize, 8), kbts__ArenaAllocator, &Context->ScratchArena);
        ,
        .new =
        \\        void *ScratchMemory = kbts__PushSize(&Context->ScratchArena, ScratchpadSize, 8); /* warkocz patch. */
        \\        if(!ScratchMemory)
        \\        {
        \\          Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY;
        \\          return 0;
        \\        }
        \\        kbts_shape_scratchpad *Scratchpad = kbts_PlaceShapeScratchpad(ShapeConfig, ScratchMemory, kbts__ArenaAllocator, &Context->ScratchArena);
        ,
    },
    .{
        .id = "P9-shaperun-no-partial-publish",
        .summary = "A failed scratchpad must not publish a partially shaped run.",
        .old =
        \\          Context->Error = Scratchpad->Error;
        \\        }
        \\      }
        ,
        .new =
        \\          Context->Error = Scratchpad->Error;
        \\          return 0; /* warkocz patch: never publish a partially shaped run. */
        \\        }
        \\      }
        ,
    },
    .{
        .id = "P10-create-scratchpad-null",
        .summary = "CreateShapeScratchpad must survive a refused allocation.",
        .old =
        \\  kbts_un Size = kbts_SizeOfShapeScratchpad(Config);
        \\  kbts_shape_scratchpad *Result = kbts_PlaceShapeScratchpad(Config, kbts__AllocatorAllocate(Allocator, AllocatorData, Size), Allocator, AllocatorData);
        \\  Result->SelfAllocated = 1;
        \\  return Result;
        ,
        .new =
        \\  kbts_un Size = kbts_SizeOfShapeScratchpad(Config);
        \\  void *Memory = kbts__AllocatorAllocate(Allocator, AllocatorData, Size); /* warkocz patch. */
        \\  if(!Memory)
        \\  {
        \\    return 0;
        \\  }
        \\  kbts_shape_scratchpad *Result = kbts_PlaceShapeScratchpad(Config, Memory, Allocator, AllocatorData);
        \\  if(Result)
        \\  {
        \\    Result->SelfAllocated = 1;
        \\  }
        \\  return Result;
        ,
    },
    .{
        .id = "P11-context-font-variation-vector",
        .summary = "A refused variation vector must raise the context error.",
        .old =
        \\  ContextFont->Info.VariationVector = kbts__PushArray(&Context->FontArena, float, AxisCount);
        \\}
        ,
        .new =
        \\  ContextFont->Info.VariationVector = kbts__PushArray(&Context->FontArena, float, AxisCount);
        \\  if(AxisCount && !ContextFont->Info.VariationVector)
        \\  {
        \\    Context->Error = KBTS_SHAPE_ERROR_OUT_OF_MEMORY; /* warkocz patch. */
        \\  }
        \\}
        ,
    },
    .{
        .id = "P12-push-font-variations-guard",
        .summary = "Skip variation writes after a context-font initialization failure.",
        .old =
        \\      kbts__InitializeContextFont(Context, ContextFont, Font);
        \\
        \\      kbts__ShapeSetFontVariations(Context, ContextFontHandle, Variations, VariationCount, KBTS__SHAPE_SET_FONT_VARIATIONS_FLAG_SET_TO_DEFAULT_IF_NOT_EXPLICITLY_SET);
        ,
        .new =
        \\      kbts__InitializeContextFont(Context, ContextFont, Font);
        \\
        \\      if(!Context->Error) /* warkocz patch. */
        \\      {
        \\        kbts__ShapeSetFontVariations(Context, ContextFontHandle, Variations, VariationCount, KBTS__SHAPE_SET_FONT_VARIATIONS_FLAG_SET_TO_DEFAULT_IF_NOT_EXPLICITLY_SET);
        \\      }
        ,
    },
    .{
        .id = "P13-push-font-file-variations-guard",
        .summary = "Skip variation writes after a file-font initialization failure.",
        .old =
        \\      if(!Result->Error)
        \\      {
        \\        kbts__InitializeContextFont(Context, ContextFont, Result);
        \\
        \\        kbts__ShapeSetFontVariations(Context, ContextFontHandle, Variations, VariationCount, KBTS__SHAPE_SET_FONT_VARIATIONS_FLAG_SET_TO_DEFAULT_IF_NOT_EXPLICITLY_SET);
        \\      }
        \\      else
        ,
        .new =
        \\      if(!Result->Error)
        \\      {
        \\        kbts__InitializeContextFont(Context, ContextFont, Result);
        \\
        \\        if(!Context->Error) /* warkocz patch. */
        \\        {
        \\          kbts__ShapeSetFontVariations(Context, ContextFontHandle, Variations, VariationCount, KBTS__SHAPE_SET_FONT_VARIATIONS_FLAG_SET_TO_DEFAULT_IF_NOT_EXPLICITLY_SET);
        \\        }
        \\      }
        \\      else
        ,
    },
    .{
        .id = "P14-push-font-memory-variations-guard",
        .summary = "Skip variation writes after a memory-font initialization failure.",
        .old =
        \\        if(!Error)
        \\        {
        \\          kbts__InitializeContextFont(Context, ContextFont, Result);
        \\
        \\          kbts__ShapeSetFontVariations(Context, ContextFontHandle, Variations, VariationCount, KBTS__SHAPE_SET_FONT_VARIATIONS_FLAG_SET_TO_DEFAULT_IF_NOT_EXPLICITLY_SET);
        \\        }
        \\        else
        ,
        .new =
        \\        if(!Error)
        \\        {
        \\          kbts__InitializeContextFont(Context, ContextFont, Result);
        \\
        \\          if(!Context->Error) /* warkocz patch. */
        \\          {
        \\            kbts__ShapeSetFontVariations(Context, ContextFontHandle, Variations, VariationCount, KBTS__SHAPE_SET_FONT_VARIATIONS_FLAG_SET_TO_DEFAULT_IF_NOT_EXPLICITLY_SET);
        \\          }
        \\        }
        \\        else
        ,
    },
    .{
        .id = "P15-font-block-sentinel-prev",
        .summary = "ShapePopFont must use the sentinel pointer directly, not its address.",
        .old =
        \\    kbts__context_font_block *Block = (kbts__context_font_block *)&Context->FontBlockSentinel.Prev;
        ,
        .new =
        \\    kbts__context_font_block *Block = (kbts__context_font_block *)Context->FontBlockSentinel.Prev; /* warkocz patch. */
        ,
    },
    .{
        .id = "P16-gb11-extended-pictographic-zwj",
        .summary = "UAX #29 GB11: keep ExtendedPictographic state after EP Extend* ZWJ.",
        .old =
        \\  /* 16 */ {24,24,24,24,24,24,24,16,24,24, 0,24, 8},
        ,
        .new =
        \\  /* 16 */ {24,24,24,24,24,24,24,16,24,24, 8,24, 8}, /* warkocz patch: GB11 EP Extend* ZWJ x EP. */
        ,
    },
};

pub fn pinMatches(upstream: []const u8) bool {
    std.debug.assert(upstream.len > 0);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(upstream, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, upstream_sha256);
}

pub fn patchedMatches(patched: []const u8) bool {
    std.debug.assert(patched.len > 0);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(patched, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, patched_sha256);
}

/// Applies `table` in order to `upstream`. Every context must occur exactly
/// once; the result must hash to `expected_patched_sha256`. On failure the
/// optional `failure` records which patch failed and why.
pub fn apply(
    allocator: std.mem.Allocator,
    upstream: []const u8,
    table: []const Patch,
    expected_patched_sha256: []const u8,
    failure: ?*Failure,
) Error![]u8 {
    std.debug.assert(upstream.len > 0);
    std.debug.assert(table.len > 0);
    std.debug.assert(expected_patched_sha256.len == 64);
    var current = allocator.dupe(u8, upstream) catch return fail(failure, error.OutOfMemory, null, 0);
    errdefer allocator.free(current);
    for (table, 0..) |patch, index| {
        const occurrences = countOccurrences(current, patch.old);
        if (occurrences != 1) {
            const kind: Error = if (occurrences == 0) error.PatchContextMissing else error.PatchContextAmbiguous;
            return fail(failure, kind, index, occurrences);
        }
        const position = std.mem.indexOf(u8, current, patch.old).?;
        const replaced = try replaceOnce(allocator, current, position, patch, failure);
        allocator.free(current);
        current = replaced;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(current, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, expected_patched_sha256)) {
        return fail(failure, error.PatchedHashMismatch, null, 0);
    }
    return current;
}

/// Human-facing explanation for a failed `apply`, including the update
/// procedure. The returned slice is allocated and owned by the caller.
pub fn helpMessage(
    allocator: std.mem.Allocator,
    failure: Failure,
    expected_patched_sha256: []const u8,
) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(expected_patched_sha256.len == 64);
    return switch (failure.kind) {
        error.OutOfMemory => allocator.dupe(u8, "kb patching ran out of memory"),
        error.PatchedHashMismatch => std.fmt.allocPrint(
            allocator,
            "kb patching: patched output does not hash to pinned {s}. A patch was edited without refreshing patched_sha256, or the vendored header changed. Refresh the golden hash from the 'zig build test' failure output and follow third_party/kb/README.md.",
            .{expected_patched_sha256},
        ),
        error.PatchContextMissing, error.PatchContextAmbiguous => blk: {
            const patch = patches[failure.patch_index.?];
            break :blk std.fmt.allocPrint(
                allocator,
                "kb patch '{s}' ({s}): expected exactly 1 occurrence of its pinned context in the vendored kb_text_shape.h, found {d}. Upstream kb was likely updated after these patches were written. Re-evaluate third_party/kb/patches.zig: check whether upstream {s} already fixed this, port or delete the patch (the goal is zero patches), refresh patched_sha256, and re-run 'zig build test'. See third_party/kb/README.md.",
                .{ patch.id, patch.summary, failure.occurrences, upstream_repository },
            );
        },
    };
}

fn fail(failure: ?*Failure, kind: Error, patch_index: ?usize, occurrences: usize) Error {
    if (failure) |record| record.* = .{ .kind = kind, .patch_index = patch_index, .occurrences = occurrences };
    return kind;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    std.debug.assert(needle.len > 0);
    var count: usize = 0;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |position| {
        count += 1;
        cursor = position + needle.len;
    }
    return count;
}

fn replaceOnce(
    allocator: std.mem.Allocator,
    current: []const u8,
    position: usize,
    patch: Patch,
    failure: ?*Failure,
) Error![]u8 {
    std.debug.assert(position + patch.old.len <= current.len);
    const replaced = std.mem.concat(
        allocator,
        u8,
        &.{ current[0..position], patch.new, current[position + patch.old.len ..] },
    ) catch return fail(failure, error.OutOfMemory, null, 0);
    return replaced;
}
