const std = @import("std");

/// Pass process arguments excluding argv[0].
pub const usage =
    \\Usage:
    \\  warkocz [--help | --version]
    \\  warkocz diff --left PATH --right PATH --output PATH [--left-label VALUE] [--right-label VALUE] [--output-label VALUE] [--wait]
    \\  warkocz merge --base PATH --left PATH --right PATH --output PATH [--base-label VALUE] [--left-label VALUE] [--right-label VALUE] [--output-label VALUE] [--wait]
;

pub const ParseError = error{
    UnknownArgument,
    UnexpectedArgument,
    MissingValue,
    DuplicateOption,
    MissingRequiredOption,
    EmptyPath,
    NulByte,
    ModeInapplicableOption,
};

pub const DiffRequest = struct {
    left: []const u8,
    right: []const u8,
    output: []const u8,
    left_label: ?[]const u8,
    right_label: ?[]const u8,
    output_label: ?[]const u8,
    wait: bool,
};

pub const MergeRequest = struct {
    base: []const u8,
    left: []const u8,
    right: []const u8,
    output: []const u8,
    base_label: ?[]const u8,
    left_label: ?[]const u8,
    right_label: ?[]const u8,
    output_label: ?[]const u8,
    wait: bool,
};

pub const Request = union(enum) {
    bootstrap,
    help,
    version,
    diff: DiffRequest,
    merge: MergeRequest,
};

const Option = enum {
    base,
    left,
    right,
    output,
    base_label,
    left_label,
    right_label,
    output_label,
    wait,
};

const Options = struct {
    base: ?[]const u8 = null,
    left: ?[]const u8 = null,
    right: ?[]const u8 = null,
    output: ?[]const u8 = null,
    base_label: ?[]const u8 = null,
    left_label: ?[]const u8 = null,
    right_label: ?[]const u8 = null,
    output_label: ?[]const u8 = null,
    wait: bool = false,
};

/// Parses an explicit invocation without allocation or filesystem access.
pub fn parse(arguments: []const []const u8) ParseError!Request {
    if (arguments.len == 0) return .bootstrap;

    const command = arguments[0];
    if (std.mem.eql(u8, command, "--help")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        return .help;
    }
    if (std.mem.eql(u8, command, "--version")) {
        if (arguments.len != 1) return error.UnexpectedArgument;
        return .version;
    }
    if (std.mem.eql(u8, command, "diff")) return .{ .diff = try finish_diff(try parse_options(arguments[1..], false)) };
    if (std.mem.eql(u8, command, "merge")) return .{ .merge = try finish_merge(try parse_options(arguments[1..], true)) };
    return error.UnknownArgument;
}

fn parse_options(arguments: []const []const u8, allow_base: bool) ParseError!Options {
    var options = Options{};
    var index: usize = 0;
    while (index < arguments.len) {
        const option_index = index;
        const option = option_from_argument(arguments[index]) orelse return error.UnknownArgument;
        index += 1;
        std.debug.assert(index == option_index + 1);
        try set_option(&options, option, arguments, &index, allow_base);
        std.debug.assert(index > option_index);
        std.debug.assert(index <= arguments.len);
    }
    std.debug.assert(index == arguments.len);
    return options;
}

fn option_from_argument(argument: []const u8) ?Option {
    const names = [_]struct { name: []const u8, option: Option }{
        .{ .name = "--base", .option = .base },
        .{ .name = "--left", .option = .left },
        .{ .name = "--right", .option = .right },
        .{ .name = "--output", .option = .output },
        .{ .name = "--base-label", .option = .base_label },
        .{ .name = "--left-label", .option = .left_label },
        .{ .name = "--right-label", .option = .right_label },
        .{ .name = "--output-label", .option = .output_label },
        .{ .name = "--wait", .option = .wait },
    };
    for (names) |entry| {
        if (std.mem.eql(u8, argument, entry.name)) return entry.option;
    }
    return null;
}

fn set_option(options: *Options, option: Option, arguments: []const []const u8, index: *usize, allow_base: bool) ParseError!void {
    std.debug.assert(index.* <= arguments.len);
    if (option == .wait) {
        if (options.wait) return error.DuplicateOption;
        options.wait = true;
        return;
    }
    if (!allow_base and (option == .base or option == .base_label)) return error.ModeInapplicableOption;

    const value = try take_value(arguments, index);
    switch (option) {
        .base => try set_path(&options.base, value),
        .left => try set_path(&options.left, value),
        .right => try set_path(&options.right, value),
        .output => try set_path(&options.output, value),
        .base_label => try set_label(&options.base_label, value),
        .left_label => try set_label(&options.left_label, value),
        .right_label => try set_label(&options.right_label, value),
        .output_label => try set_label(&options.output_label, value),
        .wait => unreachable,
    }
}

fn take_value(arguments: []const []const u8, index: *usize) ParseError![]const u8 {
    std.debug.assert(index.* <= arguments.len);
    if (index.* == arguments.len) return error.MissingValue;
    const value_index = index.*;
    const value = arguments[value_index];
    index.* += 1;
    std.debug.assert(index.* <= arguments.len);
    return value;
}

fn set_path(slot: *?[]const u8, value: []const u8) ParseError!void {
    try validate_path(value);
    if (slot.* != null) return error.DuplicateOption;
    slot.* = value;
}

fn set_label(slot: *?[]const u8, value: []const u8) ParseError!void {
    try validate_label(value);
    if (slot.* != null) return error.DuplicateOption;
    slot.* = value;
}

fn validate_path(value: []const u8) ParseError!void {
    if (value.len == 0) return error.EmptyPath;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.NulByte;
}

fn validate_label(value: []const u8) ParseError!void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.NulByte;
}

fn finish_diff(options: Options) ParseError!DiffRequest {
    std.debug.assert(options.base == null and options.base_label == null);
    const request = DiffRequest{
        .left = options.left orelse return error.MissingRequiredOption,
        .right = options.right orelse return error.MissingRequiredOption,
        .output = options.output orelse return error.MissingRequiredOption,
        .left_label = options.left_label,
        .right_label = options.right_label,
        .output_label = options.output_label,
        .wait = options.wait,
    };
    std.debug.assert(request.left.len > 0 and std.mem.indexOfScalar(u8, request.left, 0) == null);
    std.debug.assert(request.right.len > 0 and std.mem.indexOfScalar(u8, request.right, 0) == null);
    std.debug.assert(request.output.len > 0 and std.mem.indexOfScalar(u8, request.output, 0) == null);
    std.debug.assert(request.left_label == null or std.mem.indexOfScalar(u8, request.left_label.?, 0) == null);
    std.debug.assert(request.right_label == null or std.mem.indexOfScalar(u8, request.right_label.?, 0) == null);
    std.debug.assert(request.output_label == null or std.mem.indexOfScalar(u8, request.output_label.?, 0) == null);
    return request;
}

fn finish_merge(options: Options) ParseError!MergeRequest {
    const request = MergeRequest{
        .base = options.base orelse return error.MissingRequiredOption,
        .left = options.left orelse return error.MissingRequiredOption,
        .right = options.right orelse return error.MissingRequiredOption,
        .output = options.output orelse return error.MissingRequiredOption,
        .base_label = options.base_label,
        .left_label = options.left_label,
        .right_label = options.right_label,
        .output_label = options.output_label,
        .wait = options.wait,
    };
    std.debug.assert(request.base.len > 0 and std.mem.indexOfScalar(u8, request.base, 0) == null);
    std.debug.assert(request.left.len > 0 and std.mem.indexOfScalar(u8, request.left, 0) == null);
    std.debug.assert(request.right.len > 0 and std.mem.indexOfScalar(u8, request.right, 0) == null);
    std.debug.assert(request.output.len > 0 and std.mem.indexOfScalar(u8, request.output, 0) == null);
    std.debug.assert(request.base_label == null or std.mem.indexOfScalar(u8, request.base_label.?, 0) == null);
    std.debug.assert(request.left_label == null or std.mem.indexOfScalar(u8, request.left_label.?, 0) == null);
    std.debug.assert(request.right_label == null or std.mem.indexOfScalar(u8, request.right_label.?, 0) == null);
    std.debug.assert(request.output_label == null or std.mem.indexOfScalar(u8, request.output_label.?, 0) == null);
    return request;
}

test "parser accepts every request form" {
    try std.testing.expectEqual(Request.bootstrap, try parse(&.{}));
    try std.testing.expectEqual(Request.help, try parse(&.{"--help"}));
    try std.testing.expectEqual(Request.version, try parse(&.{"--version"}));

    const diff = try parse(&.{ "diff", "--left", "left", "--right", "right", "--output", "result", "--left-label", "L", "--right-label", "R", "--output-label", "O", "--wait" });
    switch (diff) {
        .diff => |request| {
            try std.testing.expectEqualStrings("left", request.left);
            try std.testing.expectEqualStrings("right", request.right);
            try std.testing.expectEqualStrings("result", request.output);
            try std.testing.expectEqualStrings("L", request.left_label.?);
            try std.testing.expectEqualStrings("R", request.right_label.?);
            try std.testing.expectEqualStrings("O", request.output_label.?);
            try std.testing.expect(request.wait);
        },
        else => return error.TestUnexpectedResult,
    }

    const merge = try parse(&.{ "merge", "--base", "base", "--left", "left", "--right", "right", "--output", "result", "--base-label", "B", "--left-label", "L", "--right-label", "R", "--output-label", "O", "--wait" });
    switch (merge) {
        .merge => |request| {
            try std.testing.expectEqualStrings("base", request.base);
            try std.testing.expectEqualStrings("left", request.left);
            try std.testing.expectEqualStrings("right", request.right);
            try std.testing.expectEqualStrings("result", request.output);
            try std.testing.expectEqualStrings("B", request.base_label.?);
            try std.testing.expectEqualStrings("L", request.left_label.?);
            try std.testing.expectEqualStrings("R", request.right_label.?);
            try std.testing.expectEqualStrings("O", request.output_label.?);
            try std.testing.expect(request.wait);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parser preserves literal path values" {
    const values = [_][]const u8{ "-leading", "--right", "space path", "quote\"path", "C:\\native\\path", "żółć" };
    for (values) |value| {
        const arguments = [_][]const u8{ "diff", "--left", value, "--right", value, "--output", value };
        const request = try parse(&arguments);
        switch (request) {
            .diff => |diff| {
                try std.testing.expectEqualStrings(value, diff.left);
                try std.testing.expectEqualStrings(value, diff.right);
                try std.testing.expectEqualStrings(value, diff.output);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "parser rejects malformed invocations" {
    try std.testing.expectError(error.UnknownArgument, parse(&.{"unknown"}));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "--help", "diff" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "--version", "diff" }));
    try std.testing.expectError(error.UnknownArgument, parse(&.{ "diff", "--unknown" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "diff", "--left" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "diff", "--left", "a", "--left", "b" }));
    try std.testing.expectError(error.MissingRequiredOption, parse(&.{ "diff", "--left", "a", "--right", "b" }));
    try std.testing.expectError(error.ModeInapplicableOption, parse(&.{ "diff", "--base", "a" }));
    try std.testing.expectError(error.ModeInapplicableOption, parse(&.{ "diff", "--base-label", "a" }));
    try std.testing.expectError(error.EmptyPath, parse(&.{ "diff", "--left", "", "--right", "b", "--output", "c" }));
    try std.testing.expectError(error.NulByte, parse(&.{ "merge", "--base", "a", "--left", "b\x00c", "--right", "c", "--output", "d" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "merge", "--base", "a", "--left", "b", "--right", "c", "--output", "d", "--wait", "--wait" }));
}
