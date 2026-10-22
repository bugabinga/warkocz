const std = @import("std");
const sdl = @import("sdl3");

pub const path_capacity = std.Io.Dir.max_path_bytes;
pub const Kind = enum { open_file, save_file, open_folder };
pub const Result = union(enum) { pending, cancelled, selected: []const u8, failed };

const Callback = *const fn (?*anyopaque, ?[*:null]const ?[*:0]const u8, c_int) callconv(.c) void;
extern fn SDL_ShowOpenFileDialog(Callback, ?*anyopaque, *sdl.SDL_Window, ?*const anyopaque, c_int, ?[*:0]const u8, bool) void;
extern fn SDL_ShowSaveFileDialog(Callback, ?*anyopaque, *sdl.SDL_Window, ?*const anyopaque, c_int, ?[*:0]const u8) void;
extern fn SDL_ShowOpenFolderDialog(Callback, ?*anyopaque, *sdl.SDL_Window, ?[*:0]const u8, bool) void;

/// Dialog callback owns one bounded copy because SDL owns filelist only during callback.
pub const State = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    result: Result = .cancelled,
    storage: [path_capacity]u8 = undefined,

    pub fn show(self: *State, kind: Kind, window: *sdl.SDL_Window) void {
        self.result = .pending;
        if (comptime @import("builtin").is_test) return;
        const userdata: ?*anyopaque = @ptrCast(self);
        switch (kind) {
            .open_file => SDL_ShowOpenFileDialog(callback, userdata, window, null, 0, null, false),
            .save_file => SDL_ShowSaveFileDialog(callback, userdata, window, null, 0, null),
            .open_folder => SDL_ShowOpenFolderDialog(callback, userdata, window, null, false),
        }
    }

    pub fn take(self: *State, io: std.Io) Result {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.result;
    }

    pub fn callback(userdata: ?*anyopaque, filelist: ?[*:null]const ?[*:0]const u8, _: c_int) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(userdata orelse return));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const first = filelist orelse {
            self.result = .failed;
            return;
        };
        const path = first[0] orelse {
            self.result = .cancelled;
            return;
        };
        const value = std.mem.span(path);
        if (value.len == 0 or value.len > self.storage.len) {
            self.result = .failed;
            return;
        }
        @memcpy(self.storage[0..value.len], value);
        self.result = .{ .selected = self.storage[0..value.len] };
    }
};

test "dialog result copies bounded path and cancellation remains distinct" {
    var state = State{ .io = std.testing.io };
    state.result = .cancelled;
    try std.testing.expect(state.take(std.testing.io) == .cancelled);
    const source: [:0]const u8 = "C:/fixture/left.txt";
    const paths = [_:null]?[*:0]const u8{source};
    State.callback(@ptrCast(&state), &paths, -1);
    switch (state.take(std.testing.io)) {
        .selected => |value| try std.testing.expectEqualStrings(source, value),
        else => return error.TestUnexpectedResult,
    }
}

test "dialog result rejects path beyond fixed backing" {
    var state = State{ .io = std.testing.io };
    var source: [path_capacity + 2:0]u8 = undefined;
    @memset(source[0 .. path_capacity + 1], 'x');
    source[path_capacity + 1] = 0;
    const paths = [_:null]?[*:0]const u8{&source};
    State.callback(@ptrCast(&state), &paths, -1);
    try std.testing.expect(state.take(std.testing.io) == .failed);
}
