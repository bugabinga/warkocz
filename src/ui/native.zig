const std = @import("std");
const sdl = @import("sdl3");
const files = @import("../files.zig");
const invocation = @import("../invocation.zig");
const save = @import("../save.zig");
const recovery = @import("../recovery.zig");
const recovery_directory = @import("../recovery_directory.zig");
const recovery_discovery = @import("../recovery_discovery.zig");
const recovery_retention = @import("../recovery_retention.zig");
const session = @import("../session.zig");
const json_merge = @import("../engine/json_merge.zig");
const zig_merge = @import("../engine/zig_merge.zig");
const repository = @import("repository.zig");
const action_registry = @import("actions.zig");
const glyph_text = @import("text.zig");
const editor = @import("editor.zig");
const dialog = @import("dialog.zig");
const ui_lsp = @import("lsp.zig");

const input_capacity = 192 * 1024;
const result_capacity = input_capacity;
const history_capacity = 768 * 1024;
const history_records = 32;
const metadata_capacity = dialog.path_capacity * 8;
const json_member_capacity = 1024;
const json_key_capacity = 16 * 1024;
const json_scanner_capacity = 8 * 1024;
// Provisional per-LoadJob ceiling: 4096 declarations/side, 64 KiB names/side, 2 MiB parser scratch.
const zig_declaration_capacity = 4096;
const zig_name_capacity = 64 * 1024;
const zig_scratch_capacity = 2 * 1024 * 1024;
const backing_capacity = input_capacity * 4 + result_capacity * 2 + history_capacity + history_records * @sizeOf(session.Record) + (input_capacity + 1) * @sizeOf(u32) * 3 + save.path_storage_capacity + save.content_capacity * 2 + metadata_capacity + recovery.Controller.ciphertext_capacity * 3 + recovery.Controller.plaintext_capacity * 3 + recovery.Controller.path_capacity * 24 + 256 * 3 + 64 * 3 + 1024 * 3 + recovery.Controller.result_capacity * 3 + 48 * 3 + @sizeOf(u16) * 1024 + 2048 + 4096 + 32 + input_capacity + 1 + multi_line_capacity * @sizeOf(@import("../engine/diff.zig").Line) * 4 + multi_cell_capacity * @sizeOf(@import("../engine/diff.zig").Cell) * 2 + multi_line_capacity * @sizeOf(@import("../engine/diff.zig").Hunk) * 2 + multi_line_capacity * @sizeOf(@import("../engine/multihunk.zig").Conflict) + json_member_capacity * @sizeOf(json_merge.Member) * 3 + json_key_capacity * 3 + json_scanner_capacity + zig_declaration_capacity * @sizeOf(zig_merge.Declaration) * 3 + zig_name_capacity * 3 + zig_scratch_capacity + @sizeOf(ui_lsp.Storage) + @sizeOf(ui_lsp.Service) + 8192;
const glyph_width = 8;
const row_height = 12;
const action_count = actions.len;
const multi_line_capacity = 128;
const multi_cell_capacity = (multi_line_capacity + 1) * (multi_line_capacity + 1);

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: [*]u16, size: u32) callconv(.winapi) u32;

pub const Error = error{ ResolutionIncomplete, ProvisionalCapacityExceeded, CompiledShaderUnavailable, GraphicsUnavailable, RenderFailed, ReadOnly, ClipboardUnavailable };
const Action = action_registry.Id;
const Mode = enum { welcome, diff, merge };
const ActionInfo = struct { action: Action, name: []const u8, help: []const u8, key: sdl.SDL_Keycode, binding: []const u8 };
const actions = [_]ActionInfo{
    .{ .action = .choose_base, .name = "Base", .help = "Replace whole result with merge base bytes.", .key = sdl.SDLK_B, .binding = "B" },
    .{ .action = .choose_left, .name = "Left", .help = "Replace whole result with left source bytes.", .key = sdl.SDLK_L, .binding = "L" },
    .{ .action = .choose_right, .name = "Right", .help = "Replace whole result with right source bytes.", .key = sdl.SDLK_R, .binding = "R" },
    .{ .action = .reset, .name = "Reset", .help = "Restore initial result; reset is undoable.", .key = sdl.SDLK_ESCAPE, .binding = "Esc" },
    .{ .action = .undo, .name = "Undo", .help = "Restore previous in-memory result decision.", .key = sdl.SDLK_Z, .binding = "Ctrl+Z" },
    .{ .action = .redo, .name = "Redo", .help = "Restore next in-memory result decision.", .key = sdl.SDLK_Y, .binding = "Ctrl+Y" },
    .{ .action = .mark_resolved, .name = "Resolve", .help = "Mark in-memory result resolved; does not save.", .key = sdl.SDLK_M, .binding = "M" },
    .{ .action = .save, .name = "Save", .help = "Publish result as a durable new destination file.", .key = sdl.SDLK_S, .binding = "S" },
    .{ .action = .complete, .name = "Complete", .help = "Finish only after current durable output is verified.", .key = sdl.SDLK_RETURN, .binding = "Enter" },
    .{ .action = .next_change, .name = "Next change", .help = "Navigate exact bounded line-diff changes in source panes.", .key = sdl.SDLK_N, .binding = "N" },
    .{ .action = .copy, .name = "Copy", .help = "Copy selected editable result bytes to clipboard.", .key = sdl.SDLK_C, .binding = "Ctrl+C" },
    .{ .action = .cut, .name = "Cut", .help = "Copy selection then delete it from editable result.", .key = sdl.SDLK_X, .binding = "Ctrl+X" },
    .{ .action = .paste, .name = "Paste", .help = "Insert supported clipboard bytes at result selection.", .key = sdl.SDLK_V, .binding = "Ctrl+V" },
    .{ .action = .select_all, .name = "Select all", .help = "Select whole editable result.", .key = sdl.SDLK_A, .binding = "Ctrl+A" },
    .{ .action = .export_recovery, .name = "Export encrypted recovery draft", .help = "Export an additional encrypted DPAPI draft; automatic recovery remains separate.", .key = sdl.SDLK_S, .binding = "Ctrl+Shift+S" },
    .{ .action = .attach_result_language_server, .name = "Attach result language server", .help = "Choose exact server executable and workspace; review trust before it starts.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
    .{ .action = .confirm_result_language_server_trust, .name = "Confirm language server trust", .help = "Start reviewed exact executable for exact workspace once.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
    .{ .action = .detach_result_language_server, .name = "Detach language server", .help = "Stop, reap, and revoke result language server.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
    .{ .action = .hover, .name = "Hover", .help = "Request hover at result caret from attached server.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
    .{ .action = .symbols, .name = "Document symbols", .help = "List symbols in current result document.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
    .{ .action = .definition, .name = "Definition", .help = "Find definition at current result caret.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
    .{ .action = .references, .name = "References", .help = "Find references at current result caret.", .key = sdl.SDLK_UNKNOWN, .binding = "Palette" },
};

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fn contains(self: Rect, x: f32, y: f32) bool {
        std.debug.assert(self.w >= 0 and self.h >= 0);
        std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
    fn sdl_rect(self: Rect) sdl.SDL_FRect {
        std.debug.assert(self.w >= 0 and self.h >= 0);
        std.debug.assert(std.math.isFinite(self.x) and std.math.isFinite(self.y));
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }
};
const Layout = struct { width: f32, height: f32, buttons: [action_count]Rect, panes: [3]Rect, palette: Rect };
const Scroll = struct { line: usize = 0, column: usize = 0 };
const Model = struct {
    mode: Mode,
    palette_open: bool = false,
    text_input_active: bool = false,
    status: []const u8,
    selected: usize = 0,
    help_presented: ?usize = null,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    focus: usize = 1,
    scroll: [3]Scroll = .{ .{}, .{}, .{} },
    layout: Layout = layout_for(640, 380),
    mouse_scale_x: f32 = 1,
    mouse_scale_y: f32 = 1,
    durable_generation: ?u64 = null,
    durable_receipt: ?@import("../output.zig").Receipt = null,
    observed_save_generation: ?u64 = null,
    completion_job_id: ?u64 = null,
    change_index: usize = 0,
    completed: bool = false,
    exit_requested: bool = false,
    exit_ready: bool = false,
    editor: ?editor.State = null,
    dragging_result: bool = false,
    recovery_picker: dialog.State = undefined,
    lsp_picker: dialog.State = undefined,
    lsp_picker_pending: bool = false,
    lsp_picking_workspace: bool = false,
    lsp_synced_generation: ?u64 = null,
    lsp_navigation_open: bool = false,
    lsp_navigation_selected: usize = 0,
    lsp_text: [256]u8 = undefined,
    lsp_text_len: usize = 0,
    lsp_status: [64]u8 = undefined,
    lsp_status_len: usize = 0,
    lsp_review_identity: ?@import("../lsp/client.zig").Identity = null,
    lsp_review_presented_at: u64 = 0,
    lsp_review_width: f32 = 0,
    lsp_review_height: f32 = 0,
    lsp_confirmation_timestamp: ?u64 = null,
    window: ?*sdl.SDL_Window = null,
    recovery_picker_pending: bool = false,
    recovery_observed: bool = false,
    auto_recovery_state: ?recovery.Journal.State = null,
    clipboard: ?[:0]u8 = null,
    clipboard_len: usize = 0,
};
const Labels = struct { base: []const u8, left: []const u8, right: []const u8, output: []const u8 };
const Lines = struct { offsets: []u32, count: usize = 0 };
const LauncherStage = enum { idle, diff_left, diff_right, diff_output, merge_base, merge_left, merge_right, merge_output, repo_folder, repo_git, restore_recovery, restore_output };
const launcher_action_count = 6;
const LauncherAction = enum { open_two_way, open_merge, open_repository, restore_recovery, find_recovery_drafts, forget_selected_draft };
const LauncherActionInfo = struct { action: LauncherAction, name: []const u8, aliases: []const u8, help: []const u8, binding: []const u8 };
const launcher_actions = [_]LauncherActionInfo{ .{ .action = .open_two_way, .name = "Open two-way comparison", .aliases = "open diff compare two-way", .help = "Choose left and right read-only inputs, then a new output filename.", .binding = "D" }, .{ .action = .open_merge, .name = "Open three-way merge", .aliases = "open merge three-way", .help = "Choose base, left, right read-only inputs, then a new output filename.", .binding = "M" }, .{ .action = .open_repository, .name = "Open repository", .aliases = "open repo inspect", .help = "Choose repository folder and explicit installed Git executable for read-only inspection.", .binding = "R" }, .{ .action = .restore_recovery, .name = "Restore encrypted recovery", .aliases = "restore recovery draft encrypted dpapi", .help = "Choose an encrypted recovery file; originals are revalidated before its unreviewed draft opens.", .binding = "K" }, .{ .action = .find_recovery_drafts, .name = "Find recovery drafts", .aliases = "find discover recovery drafts", .help = "Scan existing protected recovery storage; select a draft to restore after choosing a new output.", .binding = "F" }, .{ .action = .forget_selected_draft, .name = "Forget selected encrypted draft", .aliases = "forget delete remove recovery draft", .help = "Request deletion of only selected encrypted generation; repeat after reviewing session and generation to confirm.", .binding = "X" } };
const DiscoveryJob = struct {
    const State = enum { searching, ready, failed };
    const Kind = enum { scan, forget };
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: State = .searching,
    failure: anyerror = error.Unexpected,
    root: [dialog.path_capacity]u8 = undefined,
    root_len: usize = 0,
    candidates: []recovery_discovery.Candidate,
    ciphertext: []u8,
    plaintext: []u8,
    path_scratch: []u16,
    token_scratch: []align(8) u8,
    outcome: recovery_discovery.Outcome = .{},
    kind: Kind = .scan,
    forget_candidate: recovery_discovery.Candidate = undefined,
    retention_ciphertext: []u8,
    retention_plaintext: []u8,
    session_path: []u8,

    fn init(io: std.Io, root: []const u8, allocator: std.mem.Allocator) !DiscoveryJob {
        if (root.len == 0 or root.len >= dialog.path_capacity) return error.InvalidRoot;
        var job: DiscoveryJob = .{
            .io = io,
            .candidates = try allocator.alloc(recovery_discovery.Candidate, recovery_discovery.max_sessions),
            .ciphertext = try allocator.alloc(u8, recovery_discovery.max_ciphertext),
            .plaintext = try allocator.alloc(u8, recovery_discovery.max_plaintext),
            .path_scratch = try allocator.alloc(u16, std.os.windows.NAME_MAX),
            .token_scratch = try allocator.alignedAlloc(u8, .of(u64), 1024),
            .retention_ciphertext = try allocator.alloc(u8, recovery_discovery.max_ciphertext),
            .retention_plaintext = try allocator.alloc(u8, recovery_discovery.max_plaintext),
            .session_path = try allocator.alloc(u8, dialog.path_capacity),
        };
        @memcpy(job.root[0..root.len], root);
        job.root_len = root.len;
        return job;
    }

    fn start(self: *DiscoveryJob) !void {
        std.debug.assert(self.thread == null);
        self.state = .searching;
        self.failure = error.Unexpected;
        self.outcome = .{};
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
    }

    fn restart(self: *DiscoveryJob, root: []const u8) !void {
        if (root.len == 0 or root.len >= self.root.len) return error.InvalidRoot;
        self.join();
        if (!std.mem.eql(u8, self.root[0..self.root_len], root)) @memcpy(self.root[0..root.len], root);
        self.root_len = root.len;
        self.kind = .scan;
        try self.start();
    }

    fn start_forget(self: *DiscoveryJob, candidate: recovery_discovery.Candidate) !void {
        self.join();
        self.kind = .forget;
        self.forget_candidate = candidate;
        try self.start();
    }

    fn worker(self: *DiscoveryJob) void {
        if (self.kind == .forget) {
            recovery_retention.forget(self.root[0..self.root_len], self.forget_candidate, .{
                .ciphertext = self.retention_ciphertext,
                .plaintext = self.retention_plaintext,
                .path_scratch = self.path_scratch,
                .token_scratch = self.token_scratch,
                .session_path = self.session_path,
            }) catch |err| {
                self.finish(.failed, err, .{});
                return;
            };
            self.finish(.ready, error.Unexpected, .{});
            return;
        }
        const outcome = recovery_discovery.scan(self.io, self.root[0..self.root_len], self.candidates, .{
            .ciphertext = self.ciphertext,
            .plaintext = self.plaintext,
            .path_scratch = self.path_scratch,
            .token_scratch = self.token_scratch,
        }) catch |err| {
            self.finish(.failed, err, .{});
            return;
        };
        self.finish(.ready, error.Unexpected, outcome);
    }

    fn finish(self: *DiscoveryJob, state: State, failure: anyerror, outcome: recovery_discovery.Outcome) void {
        self.mutex.lockUncancelable(self.io);
        self.failure = failure;
        self.outcome = outcome;
        self.state = state;
        self.mutex.unlock(self.io);
    }

    fn join(self: *DiscoveryJob) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn deinit(self: *DiscoveryJob) void {
        self.join();
    }

    fn view(self: *DiscoveryJob) struct { state: State, failure: anyerror, outcome: recovery_discovery.Outcome } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .state = self.state, .failure = self.failure, .outcome = self.outcome };
    }
};

const Launcher = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    dialog_state: dialog.State,
    stage: LauncherStage = .idle,
    paths: [4][dialog.path_capacity]u8 = undefined,
    lengths: [4]usize = .{ 0, 0, 0, 0 },
    recovery_path: [dialog.path_capacity]u8 = undefined,
    recovery_path_len: usize = 0,
    discovery: ?DiscoveryJob = null,
    discovery_selected: usize = 0,
    forget_confirmation: ?recovery_discovery.Candidate = null,
    selected: usize = 0,
    palette_open: bool = false,
    query: [64]u8 = undefined,
    query_len: usize = 0,
    help_presented: ?usize = null,
    status: []const u8 = "Choose visible action or Ctrl+P: Open comparison, merge, repository, or encrypted recovery",

    fn init(io: std.Io, allocator: std.mem.Allocator) Launcher {
        return .{ .io = io, .allocator = allocator, .dialog_state = .{ .io = io } };
    }

    fn start(self: *Launcher, stage: LauncherStage, window: *sdl.SDL_Window) void {
        std.debug.assert(self.stage == .idle);
        self.stage = stage;
        self.status = "Native picker open | cancellation keeps welcome unchanged";
        self.dialog_state.show(if (stage == .diff_output or stage == .merge_output or stage == .restore_output) .save_file else if (stage == .repo_folder) .open_folder else .open_file, window);
    }

    fn start_discovery(self: *Launcher, allocator: std.mem.Allocator) !void {
        var root_storage: [dialog.path_capacity]u8 = undefined;
        const root_len = recovery_root(&root_storage) catch |err| {
            self.status = @errorName(err);
            return;
        };
        if (self.discovery) |*job| {
            try job.restart(root_storage[0..root_len]);
        } else {
            var job = try DiscoveryJob.init(self.io, root_storage[0..root_len], allocator);
            try job.start();
            self.discovery = job;
        }
        self.discovery_selected = 0;
        self.status = "Searching protected recovery drafts...";
    }

    fn accept(self: *Launcher, value: []const u8) bool {
        const index = path_index(self.stage);
        if (value.len == 0 or value.len > self.paths[index].len) return false;
        @memcpy(self.paths[index][0..value.len], value);
        self.lengths[index] = value.len;
        return true;
    }

    fn path(self: *const Launcher, index: usize) []const u8 {
        std.debug.assert(index < self.paths.len and self.lengths[index] <= self.paths[index].len);
        return self.paths[index][0..self.lengths[index]];
    }
};

fn path_index(stage: LauncherStage) usize {
    return switch (stage) {
        .diff_left, .merge_base, .repo_folder => 0,
        .diff_right, .merge_left, .repo_git => 1,
        .merge_right => 2,
        .restore_recovery, .restore_output => 3,
        .diff_output, .merge_output => 3,
        .idle => unreachable,
    };
}

const LspJob = struct {
    const State = enum { idle, working, reviewed, started, revoked, failed };
    const Operation = enum { review, confirm, close, revoke };

    io: std.Io,
    service: *ui_lsp.Service,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    state: State = .idle,
    failure: ?anyerror = null,
    operation: Operation = .review,
    result: [@import("../lsp/client.zig").max_document_bytes]u8 = undefined,
    result_len: usize = 0,
    result_generation: u64 = 0,

    fn init(self: *LspJob, io: std.Io, service: *ui_lsp.Service) void {
        self.* = .{ .io = io, .service = service };
    }

    fn start_review(self: *LspJob) !void {
        try self.start(.review, "", 0);
    }

    fn start_confirm(self: *LspJob, result: []const u8, generation: u64) !void {
        try self.start(.confirm, result, generation);
    }

    fn start_close(self: *LspJob) !void {
        try self.start(.close, "", 0);
    }

    fn start_revoke(self: *LspJob) !void {
        try self.start(.revoke, "", 0);
    }

    fn start(self: *LspJob, operation: Operation, result: []const u8, generation: u64) !void {
        if (result.len > self.result.len) return error.DocumentTooLarge;
        if (self.view().state == .working) return error.LspJobBusy;
        self.join();
        self.operation = operation;
        self.result_generation = generation;
        self.result_len = result.len;
        @memcpy(self.result[0..result.len], result);
        self.mutex.lockUncancelable(self.io);
        self.state = .working;
        self.failure = null;
        self.mutex.unlock(self.io);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.finish(.failed, err);
            return err;
        };
    }

    fn worker(self: *LspJob) void {
        const outcome: State = switch (self.operation) {
            .review => blk: {
                _ = self.service.review(self.io) catch |err| {
                    self.finish(.failed, err);
                    return;
                };
                break :blk .reviewed;
            },
            .confirm => blk: {
                self.service.confirm(self.io, self.result[0..self.result_len]) catch |err| {
                    self.finish(.failed, err);
                    return;
                };
                break :blk .started;
            },
            .close => blk: {
                self.service.close();
                break :blk .revoked;
            },
            .revoke => blk: {
                self.service.revoke();
                break :blk .revoked;
            },
        };
        self.finish(outcome, null);
    }

    fn finish(self: *LspJob, state: State, failure: ?anyerror) void {
        self.mutex.lockUncancelable(self.io);
        self.state = state;
        self.failure = failure;
        self.mutex.unlock(self.io);
    }

    fn view(self: *LspJob) struct { state: State, failure: ?anyerror } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .state = self.state, .failure = self.failure };
    }

    fn join(self: *LspJob) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn deinit(self: *LspJob) void {
        self.join();
    }
};

const Opened = struct {
    active: session.Session,
    labels: Labels,
    destination: []const u8,
    input_paths: save.InputPaths,
    lines: [3]Lines,
    save: save.Controller = undefined,
    save_paths: []u8 = &.{},
    save_content: []u8 = &.{},
    save_preflight: []u8 = &.{},
    save_initialized: bool = false,
    recovery: recovery.Controller = undefined,
    recovery_storage: recovery.Controller.Storage = undefined,
    auto_recovery: recovery.Journal = undefined,
    auto_recovery_storage: recovery.Journal.Storage = undefined,
    recovery_directory: ?recovery_directory.Session = null,
    recovery_root: []u8 = &.{},
    recovery_directory_path: []u16 = &.{},
    recovery_token: []align(8) u8 = &.{},
    recovery_sddl: []u16 = &.{},
    recovery_descriptor: []u8 = &.{},
    recovery_name: []u8 = &.{},
    clipboard: [:0]u8 = undefined,
    recovery_initialized: bool = false,
    auto_recovery_initialized: bool = false,
    lsp: ?*ui_lsp.Service = null,
    lsp_job: ?LspJob = null,

    fn init_save(self: *Opened, io: std.Io) !void {
        std.debug.assert(!self.save_initialized);
        try self.save.init(io, self.save_paths, self.save_content, self.save_preflight);
        self.save_initialized = true;
    }

    fn init_save_with(self: *Opened, io: std.Io, paths: []u8, content: []u8, preflight: []u8) !void {
        self.save_paths = paths;
        self.save_content = content;
        self.save_preflight = preflight;
        try self.init_save(io);
    }

    fn init_recovery(self: *Opened, io: std.Io) !void {
        try self.recovery.init(io, self.recovery_storage);
        self.recovery_initialized = true;
    }

    fn init_auto_recovery(self: *Opened, io: std.Io, root_override: ?[]const u8) !void {
        if (@import("builtin").is_test and root_override == null) return error.TestRecoveryRootRequired;
        if (comptime @import("builtin").os.tag != .windows) return error.UnsupportedPlatform;
        const root_len = if (root_override) |root| blk: {
            if (root.len == 0 or root.len >= self.recovery_root.len or std.mem.indexOfScalar(u8, root, 0) != null) return error.InvalidRoot;
            @memcpy(self.recovery_root[0..root.len], root);
            break :blk root.len;
        } else blk: {
            var root_w: [1024]u16 = undefined;
            const root_w_len = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &root_w, root_w.len);
            if (root_w_len == 0 or root_w_len >= root_w.len) return error.InvalidRoot;
            const local_len = std.unicode.wtf16LeToWtf8(self.recovery_root, root_w[0..root_w_len]);
            const suffix = "\\warkocz-recovery";
            if (local_len == 0 or local_len + suffix.len >= self.recovery_root.len or std.mem.indexOfScalar(u8, self.recovery_root[0..local_len], 0) != null) return error.InvalidRoot;
            @memcpy(self.recovery_root[local_len..][0..suffix.len], suffix);
            break :blk local_len + suffix.len;
        };
        const owned = try recovery_directory.create(io, self.recovery_root[0..root_len], self.recovery_directory_path, self.recovery_token, self.recovery_sddl, self.recovery_descriptor, self.recovery_name);
        self.recovery_directory = owned;
        errdefer {
            var directory = self.recovery_directory.?;
            recovery_directory.destroy(&directory) catch {};
            self.recovery_directory = null;
        }
        self.auto_recovery = try recovery.Journal.init(io, &self.recovery_directory.?, self.auto_recovery_storage, recovery_clock);
        self.auto_recovery_initialized = true;
    }

    fn start_auto_recovery(self: *Opened) !void {
        std.debug.assert(self.auto_recovery_initialized);
        try self.auto_recovery.start();
    }

    fn deinit(self: *Opened) void {
        if (self.lsp_job) |*job| job.deinit();
        if (self.lsp) |service| service.revoke();
        if (self.auto_recovery_initialized) self.auto_recovery.deinit();
        if (self.recovery_directory) |*directory| recovery_directory.destroy(directory) catch {};
        if (self.recovery_initialized) self.recovery.deinit();
        if (self.save_initialized) self.save.deinit();
        self.auto_recovery_initialized = false;
        self.recovery_directory = null;
        self.recovery_initialized = false;
        self.save_initialized = false;
    }
};

const LaunchResult = union(enum) { request: invocation.Request, opened: Opened };

pub fn run(init: std.process.Init, request: invocation.Request) !void {
    std.debug.assert(request == .bootstrap or request == .diff or request == .merge or request == .repo);
    const backing = try std.heap.page_allocator.alloc(u8, backing_capacity);
    defer std.heap.page_allocator.free(backing);
    if (request == .repo) return repository.run(init, request.repo);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const window = try create_window();
    defer sdl.SDL_Quit();
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return graphics_failure("SDL_CreateGPURenderer failed");
    defer sdl.SDL_DestroyRenderer(renderer);
    var restored = false;
    var scene_request = request;
    var launcher = Launcher.init(init.io, allocator.allocator());
    defer if (launcher.discovery) |*job| job.deinit();
    var opened: Opened = undefined;
    if (request == .bootstrap) switch ((try launcher_event_loop(renderer, window, &launcher, allocator.allocator())) orelse return) {
        .request => |value| scene_request = value,
        .opened => |value| {
            opened = value;
            restored = true;
        },
    };
    if (!restored) {
        if (scene_request == .repo) return repository.run_initialized(init, scene_request.repo);
        opened = (try load_session(renderer, window, init.io, scene_request, allocator.allocator())) orelse return;
    }
    try opened.init_save(init.io);
    try opened.init_recovery(init.io);
    if (opened.auto_recovery_initialized) opened.start_auto_recovery() catch {
        opened.auto_recovery_initialized = false;
        if (opened.recovery_directory) |*directory| recovery_directory.destroy(directory) catch {};
        opened.recovery_directory = null;
    };
    const automatic_recovery_ready = opened.auto_recovery_initialized;
    defer opened.deinit();
    var model = Model{ .mode = if (opened.active.mode == .two_way) .diff else .merge, .status = "Ctrl+P actions | ASCII diagnostic byte-view, not editor", .recovery_picker = .{ .io = init.io }, .lsp_picker = .{ .io = init.io }, .window = window, .clipboard = opened.clipboard };
    model.editor = editor.State.init(opened.active.result());
    model.status = if (restored) "RECOVERY RESTORED | originals revalidated | unresolved and unreviewed | reconcile manually before Save" else if (!automatic_recovery_ready) "RECOVERY UNPROTECTED | automatic encrypted recovery unavailable | editor remains usable" else if (model.editor == null) "READ-ONLY BYTE REVIEW | recovery ready | unsupported control, binary, or non-ASCII bytes remain exact review" else "EDITABLE ASCII RESULT | CRLF preserved | automatic recovery ready";
    try event_loop(renderer, window, &model, &opened);
}

fn create_window() Error!*sdl.SDL_Window {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return graphics_failure("SDL video initialization failed");
    errdefer sdl.SDL_Quit();
    const flags = sdl.SDL_WINDOW_RESIZABLE | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    const window = sdl.SDL_CreateWindow("warkocz native byte-view", 1280, 760, flags) orelse return graphics_failure("SDL_CreateWindow failed");
    errdefer sdl.SDL_DestroyWindow(window);
    if (!sdl.SDL_SetWindowMinimumSize(window, 960, 640)) return graphics_failure("SDL_SetWindowMinimumSize failed");
    return window;
}

fn create_device() Error!*sdl.SDL_GPUDevice {
    if (@import("builtin").os.tag == .macos) return graphics_failure("macOS needs bundled metallib shaders; runtime MSL is unsupported");
    const formats = sdl.SDL_GPU_SHADERFORMAT_DXIL | sdl.SDL_GPU_SHADERFORMAT_SPIRV;
    return sdl.SDL_CreateGPUDevice(formats, false, null) orelse graphics_failure("No compatible DXIL or SPIR-V GPU device");
}

fn launcher_event_loop(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, launcher: *Launcher, allocator: std.mem.Allocator) !?LaunchResult {
    var model = Model{ .mode = .welcome, .status = launcher.status };
    while (true) {
        if (try consume_discovery(launcher, window)) |value| {
            const opened = (try load_recovery_session(renderer, window, launcher.io, value.recovery, value.output, allocator)) orelse return null;
            return .{ .opened = opened };
        }
        if (try launcher_recovery_path(launcher, window)) |value| {
            const opened = (try load_recovery_session(renderer, window, launcher.io, value.recovery, value.output, allocator)) orelse return null;
            return .{ .opened = opened };
        }
        if (launcher.stage != .restore_recovery and launcher.stage != .restore_output) {
            if (try launcher_result(launcher, window)) |request| return .{ .request = request };
        }
        model.status = launcher.status;
        try update_layout(renderer, window, &model);
        try render_launcher(renderer, &model, launcher);
        launcher.help_presented = if (!launcher.palette_open or launcher_matches(launcher, launcher.selected)) launcher.selected else null;
        var event: sdl.SDL_Event = undefined;
        if (!sdl.SDL_WaitEventTimeout(&event, 50)) continue;
        if (event.type == sdl.SDL_EVENT_QUIT or event.type == sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
            if (launcher.stage == .idle) return null;
            launcher.status = "Picker still pending | dismiss picker before closing; callback state remains alive";
            continue;
        }
        try handle_launcher_event(&event, window, &model, launcher);
    }
}

fn recovery_root(buffer: []u8) !usize {
    if (comptime @import("builtin").os.tag != .windows) return error.UnsupportedPlatform;
    var local: [1024]u16 = undefined;
    const length = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &local, local.len);
    if (length == 0 or length >= local.len) return error.RecoveryRootUnavailable;
    const used = std.unicode.wtf16LeToWtf8(buffer, local[0..length]);
    const suffix = "\\warkocz-recovery";
    if (used == 0 or used + suffix.len >= buffer.len) return error.RecoveryRootUnavailable;
    @memcpy(buffer[used..][0..suffix.len], suffix);
    return used + suffix.len;
}

fn request_forget_selected_draft(launcher: *Launcher) void {
    const job = if (launcher.discovery) |*value| value else return;
    const view = job.view();
    if (view.state != .ready or job.kind != .scan or launcher.discovery_selected >= view.outcome.count) {
        launcher.status = "Select a discovered encrypted draft before forgetting";
        return;
    }
    const selected = job.candidates[launcher.discovery_selected];
    if (launcher.forget_confirmation) |candidate| {
        if (!same_candidate(candidate, selected)) {
            launcher.forget_confirmation = null;
            launcher.status = "Selection changed | Forget confirmation cancelled; no files changed";
            return;
        }
        launcher.forget_confirmation = null;
        job.start_forget(selected) catch |err| {
            launcher.status = @errorName(err);
            return;
        };
        launcher.status = "Forgetting selected encrypted draft generation...";
        return;
    }
    launcher.forget_confirmation = selected;
    launcher.status = "Confirm Forget | selected session and generation shown below; X again confirms, Esc cancels";
}

fn same_candidate(left: recovery_discovery.Candidate, right: recovery_discovery.Candidate) bool {
    return left.path_len == right.path_len and left.generation == right.generation and std.mem.eql(u8, left.path[0..left.path_len], right.path[0..right.path_len]) and std.mem.eql(u8, &left.ciphertext_digest, &right.ciphertext_digest);
}

fn select_discovery_candidate(launcher: *Launcher, window: *sdl.SDL_Window) void {
    const job = if (launcher.discovery) |*value| value else return;
    const view = job.view();
    if (view.state != .ready or launcher.discovery_selected >= view.outcome.count) return;
    const candidate = job.candidates[launcher.discovery_selected];
    @memcpy(launcher.recovery_path[0..candidate.path_len], candidate.path[0..candidate.path_len]);
    launcher.recovery_path_len = candidate.path_len;
    launcher.start(.restore_output, window);
    launcher.status = "Draft selected | choose a new output; originals revalidated before restore";
}

fn consume_discovery(launcher: *Launcher, window: *sdl.SDL_Window) !?RecoveryLaunch {
    const job = if (launcher.discovery) |*value| value else return null;
    const view = job.view();
    if (view.state == .searching) return null;
    if (job.kind == .forget) {
        if (view.state == .ready) {
            const root = job.root[0..job.root_len];
            job.restart(root) catch |err| {
                launcher.status = @errorName(err);
                return null;
            };
            launcher.status = "Draft forgotten | refreshing protected recovery discovery...";
        } else {
            launcher.status = @errorName(view.failure);
            job.restart(job.root[0..job.root_len]) catch {};
        }
        return null;
    }
    if (view.state == .failed) {
        launcher.status = if (view.failure == error.FileNotFound or view.failure == error.PathAlreadyExists) "No recovery drafts found" else @errorName(view.failure);
        return null;
    }
    if (view.outcome.count == 0) {
        launcher.status = if (view.outcome.skipped == 0) "No recovery drafts found" else "No valid recovery drafts found | corrupt or foreign records skipped";
    } else if (view.outcome.truncated or view.outcome.resource_limited) {
        launcher.status = "Recovery results bounded | more drafts may exist; select listed draft or retry";
    } else {
        launcher.status = "Recovery drafts found | arrows select, Enter restores to new output";
    }
    if (launcher.stage == .restore_output) return launcher_recovery_path(launcher, window);
    return null;
}

fn launcher_matches(launcher: *const Launcher, index: usize) bool {
    std.debug.assert(index < launcher_actions.len and launcher.query_len <= launcher.query.len);
    const action = launcher_actions[index];
    const query = launcher.query[0..launcher.query_len];
    return std.ascii.findIgnoreCase(action.name, query) != null or std.ascii.findIgnoreCase(action.aliases, query) != null or std.ascii.findIgnoreCase(action.help, query) != null;
}

fn launcher_disabled_reason(launcher: *const Launcher, index: usize) ?[]const u8 {
    std.debug.assert(index < launcher_actions.len);
    return if (launcher.stage == .idle) null else "Native file picker is pending; dismiss it before another open action.";
}

fn request_launcher_action(index: usize, window: *sdl.SDL_Window, launcher: *Launcher) void {
    std.debug.assert(index < launcher_actions.len);
    launcher.selected = index;
    if (launcher_disabled_reason(launcher, index)) |reason| {
        launcher.status = reason;
        return;
    }
    if (launcher.help_presented != index) {
        launcher.status = "Read selected action help; repeat click/key or Enter to open picker.";
        return;
    }
    const stage: LauncherStage = switch (launcher_actions[index].action) {
        .open_two_way => .diff_left,
        .open_merge => .merge_base,
        .open_repository => .repo_folder,
        .restore_recovery => .restore_recovery,
        .find_recovery_drafts, .forget_selected_draft => .idle,
    };
    if (launcher_actions[index].action == .find_recovery_drafts) {
        launcher.start_discovery(launcher.allocator) catch |err| {
            launcher.status = @errorName(err);
        };
        return;
    }
    if (launcher_actions[index].action == .forget_selected_draft) {
        request_forget_selected_draft(launcher);
        return;
    }
    launcher.start(stage, window);
}

fn handle_launcher_event(event: *const sdl.SDL_Event, window: *sdl.SDL_Window, model: *Model, launcher: *Launcher) !void {
    if (event.type == sdl.SDL_EVENT_WINDOW_RESIZED or event.type == sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED or event.type == sdl.SDL_EVENT_WINDOW_EXPOSED) return;
    if (event.type == sdl.SDL_EVENT_TEXT_INPUT and launcher.palette_open) {
        for (std.mem.span(event.text.text)) |byte| {
            if (launcher.query_len == launcher.query.len) break;
            if (byte >= 32 and byte <= 126) {
                launcher.query[launcher.query_len] = byte;
                launcher.query_len += 1;
            }
        }
        for (launcher_actions, 0..) |_, index| if (launcher_matches(launcher, index)) {
            launcher.selected = index;
            break;
        };
        return;
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN and event.button.button == sdl.SDL_BUTTON_LEFT and launcher.stage == .idle) {
        const x = event.button.x * model.mouse_scale_x;
        const y = event.button.y * model.mouse_scale_y;
        if (launcher.discovery) |*job| {
            const view = job.view();
            if (view.state == .ready and view.outcome.count > 0) {
                const first_row = model.layout.buttons[launcher_action_count - 1].y + 48;
                if (x >= 4 and y >= first_row) {
                    const row: usize = @intFromFloat(@floor((y - first_row) / 12));
                    if (row < view.outcome.count and row < 8) {
                        if (row != launcher.discovery_selected and launcher.forget_confirmation != null) {
                            launcher.forget_confirmation = null;
                            launcher.status = "Selection changed | Forget confirmation cancelled; no files changed";
                        }
                        launcher.discovery_selected = row;
                        return;
                    }
                }
            }
        }
        for (model.layout.buttons[0..launcher_action_count], 0..) |rect, index| if (rect.contains(x, y)) {
            request_launcher_action(index, window, launcher);
            return;
        };
        return;
    }
    if (event.type != sdl.SDL_EVENT_KEY_DOWN) return;
    const key = event.key.key;
    if ((event.key.mod & sdl.SDL_KMOD_CTRL) != 0 and key == sdl.SDLK_P) {
        launcher.palette_open = !launcher.palette_open;
        launcher.query_len = 0;
        return;
    }
    if (launcher.palette_open) {
        if (key == sdl.SDLK_ESCAPE) {
            launcher.palette_open = false;
            if (launcher.forget_confirmation != null) {
                launcher.forget_confirmation = null;
                launcher.status = "Forget cancelled | no files changed";
            }
        } else if (key == sdl.SDLK_BACKSPACE) launcher.query_len -|= 1 else if (key == sdl.SDLK_RETURN and launcher_matches(launcher, launcher.selected)) request_launcher_action(launcher.selected, window, launcher) else if (key == sdl.SDLK_UP or key == sdl.SDLK_DOWN) {
            const delta: usize = if (key == sdl.SDLK_DOWN) 1 else launcher_actions.len - 1;
            launcher.selected = (launcher.selected + delta) % launcher_actions.len;
        }
        return;
    }
    if (launcher.stage != .idle) return;
    if (key == sdl.SDLK_ESCAPE and launcher.forget_confirmation != null) {
        launcher.forget_confirmation = null;
        launcher.status = "Forget cancelled | no files changed";
        return;
    }
    if (launcher.discovery) |*job| {
        const view = job.view();
        if (view.state == .ready and view.outcome.count > 0) {
            if (key == sdl.SDLK_UP or key == sdl.SDLK_DOWN) {
                const next = if (key == sdl.SDLK_UP) launcher.discovery_selected -| 1 else @min(view.outcome.count - 1, launcher.discovery_selected + 1);
                if (next != launcher.discovery_selected and launcher.forget_confirmation != null) {
                    launcher.forget_confirmation = null;
                    launcher.status = "Selection changed | Forget confirmation cancelled; no files changed";
                }
                launcher.discovery_selected = next;
            } else if (key == sdl.SDLK_RETURN) select_discovery_candidate(launcher, window) else if (key == sdl.SDLK_X) request_forget_selected_draft(launcher);
            return;
        }
    }
    const index: ?usize = switch (key) {
        sdl.SDLK_D => 0,
        sdl.SDLK_M => 1,
        sdl.SDLK_R => 2,
        sdl.SDLK_K => 3,
        sdl.SDLK_F => 4,
        else => null,
    };
    if (index) |value| request_launcher_action(value, window, launcher);
}

const RecoveryLaunch = struct { recovery: []const u8, output: []const u8 };

fn launcher_recovery_path(launcher: *Launcher, window: *sdl.SDL_Window) !?RecoveryLaunch {
    if (launcher.stage != .restore_recovery and launcher.stage != .restore_output) return null;
    switch (launcher.dialog_state.take(launcher.io)) {
        .pending => return null,
        .cancelled => {
            launcher.stage = .idle;
            launcher.status = "RECOVERY RESTORE CANCELLED | welcome unchanged";
            return null;
        },
        .failed => {
            launcher.stage = .idle;
            launcher.status = "RECOVERY PICKER FAILED | welcome unchanged";
            return null;
        },
        .selected => |path| {
            if (launcher.stage == .restore_recovery) {
                if (path.len == 0 or path.len > launcher.recovery_path.len) {
                    launcher.stage = .idle;
                    launcher.status = "Recovery path exceeds bounded capacity | welcome unchanged";
                    return null;
                }
                @memcpy(launcher.recovery_path[0..path.len], path);
                launcher.recovery_path_len = path.len;
                launcher.stage = .idle;
                launcher.start(.restore_output, window);
                launcher.status = "RECOVERY FILE SELECTED | choose a new output filename; encrypted file remains untouched and existing files are never replaced";
                return null;
            }
            if (!launcher.accept(path)) {
                launcher.stage = .idle;
                launcher.status = "Output path exceeds bounded capacity | welcome unchanged";
                return null;
            }
            launcher.stage = .idle;
            return .{ .recovery = launcher.recovery_path[0..launcher.recovery_path_len], .output = launcher.path(3) };
        },
    }
}

fn launcher_result(launcher: *Launcher, window: *sdl.SDL_Window) !?invocation.Request {
    switch (launcher.dialog_state.take(launcher.io)) {
        .pending => return null,
        .cancelled => {
            if (launcher.stage != .idle) launcher.status = "Picker cancelled | welcome unchanged";
            launcher.stage = .idle;
            return null;
        },
        .failed => {
            launcher.stage = .idle;
            launcher.status = "Picker failed | welcome unchanged";
            return null;
        },
        .selected => |path| if (!launcher.accept(path)) {
            launcher.stage = .idle;
            launcher.status = "Picker path exceeds bounded capacity | welcome unchanged";
            return null;
        },
    }
    return advance_launcher(launcher, window);
}

fn advance_launcher(launcher: *Launcher, window: *sdl.SDL_Window) ?invocation.Request {
    const next: ?LauncherStage = switch (launcher.stage) {
        .diff_left => .diff_right,
        .diff_right => .diff_output,
        .merge_base => .merge_left,
        .merge_left => .merge_right,
        .merge_right => .merge_output,
        .repo_folder => .repo_git,
        .diff_output, .merge_output, .repo_git, .restore_recovery, .restore_output, .idle => null,
    };
    if (next) |stage| {
        launcher.stage = .idle;
        launcher.start(stage, window);
        return null;
    }
    const request: invocation.Request = switch (launcher.stage) {
        .diff_output => .{ .diff = .{ .left = launcher.path(0), .right = launcher.path(1), .output = launcher.path(3), .left_label = null, .right_label = null, .output_label = null, .wait = false } },
        .merge_output => .{ .merge = .{ .base = launcher.path(0), .left = launcher.path(1), .right = launcher.path(2), .output = launcher.path(3), .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } },
        .repo_git => .{ .repo = .{ .path = launcher.path(0), .git = launcher.path(1), .history_limit = 32 } },
        else => unreachable,
    };
    launcher.stage = .idle;
    return request;
}

fn graphics_failure(summary: []const u8) Error {
    std.debug.assert(summary.len > 0);
    std.debug.assert(summary.len < 512);
    var buffer: [1536]u8 = undefined;
    const detail = std.mem.span(sdl.SDL_GetError());
    const message = std.fmt.bufPrintSentinel(&buffer, "{s}\nSDL: {s}{s}\nUpdate GPU driver or use a compatible GPU. No input files opened during graphics initialization.", .{ summary, detail[0..@min(detail.len, 512)], if (detail.len > 512) " [detail clipped; inspect stderr]" else "" }, 0) catch unreachable;
    std.debug.print("SDL detail: {s}\n", .{detail});
    std.debug.print("warkocz: {s}\n", .{message});
    _ = sdl.SDL_ShowSimpleMessageBox(sdl.SDL_MESSAGEBOX_ERROR, "warkocz graphics unavailable", message, null);
    return if (@import("builtin").os.tag == .macos) error.CompiledShaderUnavailable else error.GraphicsUnavailable;
}

fn show_recovery_load_failure(err: anyerror) void {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buffer, "Recovery was not restored: {s}.\nOriginal input changed or is unavailable, encrypted recovery file remains untouched. Reconcile original paths then retry.", .{@errorName(err)}, 0) catch unreachable;
    _ = sdl.SDL_ShowSimpleMessageBox(sdl.SDL_MESSAGEBOX_ERROR, "warkocz recovery requires reconciliation", message, null);
}

fn show_load_failure(err: anyerror) void {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrintSentinel(&buffer, "Cannot open file session: {s}.\nCheck literal paths and permissions. Each input/result is limited to 192 KiB in this provisional slice. No file was written.", .{@errorName(err)}, 0) catch unreachable;
    _ = sdl.SDL_ShowSimpleMessageBox(sdl.SDL_MESSAGEBOX_ERROR, "warkocz input unavailable", message, null);
}

fn mode_for_request(request: invocation.Request) Mode {
    std.debug.assert(request != .help and request != .version and request != .repo);
    return switch (request) {
        .bootstrap => .welcome,
        .diff => .diff,
        .merge => .merge,
        .help, .version, .repo => unreachable,
    };
}

fn recovery_storage(allocator: std.mem.Allocator) !recovery.Controller.Storage {
    return .{
        .destination = try allocator.alloc(u8, recovery.Controller.path_capacity),
        .paths = .{ try allocator.alloc(u8, recovery.Controller.path_capacity), try allocator.alloc(u8, recovery.Controller.path_capacity), try allocator.alloc(u8, recovery.Controller.path_capacity) },
        .engine = try allocator.alloc(u8, 256),
        .engine_version = try allocator.alloc(u8, 64),
        .provenance = try allocator.alloc(u8, 1024),
        .result = try allocator.alloc(u8, recovery.Controller.result_capacity),
        .plaintext = try allocator.alloc(u8, recovery.Controller.plaintext_capacity),
        .ciphertext = try allocator.alloc(u8, recovery.Controller.ciphertext_capacity),
        .publish_scratch = try allocator.alloc(u8, 48),
    };
}

fn recovery_clock() u64 {
    return GetTickCount64() * std.time.ns_per_ms;
}

const OpenStorage = struct {
    base: []u8,
    left: []u8,
    right: []u8,
    recovery_storage: recovery.Controller.Storage,
    auto_recovery_storage: recovery.Journal.Storage,
    recovery_root: []u8,
    recovery_directory_path: []u16,
    recovery_token: []align(8) u8,
    recovery_sddl: []u16,
    recovery_descriptor: []u8,
    recovery_name: []u8,
    clipboard: [:0]u8,
    session_storage: session.Storage,
    save_paths: []u8,
    save_content: []u8,
    save_preflight: []u8,
    metadata: []u8,
    job_recovery_path: []u8,
    job_recovery_output: []u8,
    job_paths: [4][]u8,
    job_labels: [4][]u8,
    line_offsets: [3][]u32,
    json_members: [3][]json_merge.Member,
    json_keys: [3][]u8,
    json_scanner: []u8,
    json_workspace: json_merge.Workspace,
    zig_declarations: [3][]zig_merge.Declaration,
    zig_names: [3][]u8,
    zig_scratch: []u8,
    zig_workspace: zig_merge.Workspace,
    lsp_storage: *ui_lsp.Storage,
    lsp_service: *ui_lsp.Service,

    fn init(allocator: std.mem.Allocator, mode: session.Mode) !OpenStorage {
        var storage = session.Storage{
            .result = try allocator.alloc(u8, result_capacity),
            .scratch = try allocator.alloc(u8, result_capacity),
            .history = try allocator.alloc(u8, history_capacity),
            .records = try allocator.alignedAlloc(session.Record, null, history_records),
        };
        if (mode == .three_way) {
            const diff = @import("../engine/diff.zig");
            const multihunk = @import("../engine/multihunk.zig");
            storage.multi_storage = .{
                .left = .{ .base_lines = try allocator.alloc(diff.Line, multi_line_capacity), .other_lines = try allocator.alloc(diff.Line, multi_line_capacity), .cells = try allocator.alloc(diff.Cell, multi_cell_capacity) },
                .right = .{ .base_lines = try allocator.alloc(diff.Line, multi_line_capacity), .other_lines = try allocator.alloc(diff.Line, multi_line_capacity), .cells = try allocator.alloc(diff.Cell, multi_cell_capacity) },
                .left_hunks = try allocator.alloc(diff.Hunk, multi_line_capacity),
                .right_hunks = try allocator.alloc(diff.Hunk, multi_line_capacity),
            };
            storage.multi_conflicts = try allocator.alloc(multihunk.Conflict, multi_line_capacity);
            storage.multi_max_work = 1_000_000;
        }
        const json_members = .{ try allocator.alloc(json_merge.Member, json_member_capacity), try allocator.alloc(json_merge.Member, json_member_capacity), try allocator.alloc(json_merge.Member, json_member_capacity) };
        const json_keys = .{ try allocator.alloc(u8, json_key_capacity), try allocator.alloc(u8, json_key_capacity), try allocator.alloc(u8, json_key_capacity) };
        const json_scanner = try allocator.alloc(u8, json_scanner_capacity);
        const zig_declarations = .{ try allocator.alloc(zig_merge.Declaration, zig_declaration_capacity), try allocator.alloc(zig_merge.Declaration, zig_declaration_capacity), try allocator.alloc(zig_merge.Declaration, zig_declaration_capacity) };
        const zig_names = .{ try allocator.alloc(u8, zig_name_capacity), try allocator.alloc(u8, zig_name_capacity), try allocator.alloc(u8, zig_name_capacity) };
        const zig_scratch = try allocator.alloc(u8, zig_scratch_capacity);
        const lsp_storage = try allocator.create(ui_lsp.Storage);
        const lsp_service = try allocator.create(ui_lsp.Service);
        lsp_service.init(lsp_storage);
        return .{
            .base = try allocator.alloc(u8, input_capacity),
            .left = try allocator.alloc(u8, input_capacity),
            .right = try allocator.alloc(u8, input_capacity),
            .recovery_storage = try recovery_storage(allocator),
            .auto_recovery_storage = .{
                .directory = try allocator.alloc(u8, recovery.Controller.path_capacity),
                .snapshots = .{ try recovery_storage(allocator), try recovery_storage(allocator) },
            },
            .recovery_root = try allocator.alloc(u8, recovery.Controller.path_capacity),
            .recovery_directory_path = try allocator.alloc(u16, 1024),
            .recovery_token = try allocator.alignedAlloc(u8, .@"8", 2048),
            .recovery_sddl = try allocator.alloc(u16, 512),
            .recovery_descriptor = try allocator.alloc(u8, 4096),
            .recovery_name = try allocator.alloc(u8, 40),
            .clipboard = try allocator.allocSentinel(u8, input_capacity, 0),
            .session_storage = storage,
            .save_paths = try allocator.alloc(u8, save.path_storage_capacity),
            .save_content = try allocator.alloc(u8, save.content_capacity),
            .save_preflight = try allocator.alloc(u8, save.content_capacity),
            .metadata = try allocator.alloc(u8, metadata_capacity),
            .job_recovery_path = try allocator.alloc(u8, dialog.path_capacity),
            .job_recovery_output = try allocator.alloc(u8, dialog.path_capacity),
            .job_paths = .{ try allocator.alloc(u8, dialog.path_capacity), try allocator.alloc(u8, dialog.path_capacity), try allocator.alloc(u8, dialog.path_capacity), try allocator.alloc(u8, dialog.path_capacity) },
            .job_labels = .{ try allocator.alloc(u8, dialog.path_capacity), try allocator.alloc(u8, dialog.path_capacity), try allocator.alloc(u8, dialog.path_capacity), try allocator.alloc(u8, dialog.path_capacity) },
            .line_offsets = .{ try allocator.alloc(u32, input_capacity + 1), try allocator.alloc(u32, input_capacity + 1), try allocator.alloc(u32, input_capacity + 1) },
            .json_members = json_members,
            .json_keys = json_keys,
            .json_scanner = json_scanner,
            .json_workspace = .{ .base = .{ .members = json_members[0], .keys = json_keys[0] }, .left = .{ .members = json_members[1], .keys = json_keys[1] }, .right = .{ .members = json_members[2], .keys = json_keys[2] }, .scanner_memory = json_scanner },
            .zig_declarations = zig_declarations,
            .zig_names = zig_names,
            .zig_scratch = zig_scratch,
            .zig_workspace = .{ .base = .{ .declarations = zig_declarations[0], .names = zig_names[0] }, .left = .{ .declarations = zig_declarations[1], .names = zig_names[1] }, .right = .{ .declarations = zig_declarations[2], .names = zig_names[2] }, .scratch_memory = zig_scratch },
            .lsp_storage = lsp_storage,
            .lsp_service = lsp_service,
        };
    }
};

/// One initial-load worker owns a single preallocated slot until publication or discard.
/// Paths are copied before spawn; SDL and renderer APIs remain on the calling thread.
const LoadJob = struct {
    const State = enum { loading, ready, failed, discarded };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    state: State = .loading,
    failure: anyerror = error.Unexpected,
    merge: bool,
    restoring: bool = false,
    recovery_path: []u8,
    recovery_path_len: usize = 0,
    recovery_output: []u8,
    recovery_output_len: usize = 0,
    paths: [4][]u8,
    path_lens: [4]usize = .{ 0, 0, 0, 0 },
    labels: [4][]u8,
    label_lens: [4]usize = .{ 0, 0, 0, 0 },
    storage: OpenStorage,
    opened: ?Opened = null,

    fn init(io: std.Io, request: invocation.Request, allocator: std.mem.Allocator) !LoadJob {
        std.debug.assert(request == .diff or request == .merge);
        const storage = try OpenStorage.init(allocator, if (request == .merge) .three_way else .two_way);
        var job: LoadJob = .{ .io = io, .merge = request == .merge, .recovery_path = storage.job_recovery_path, .recovery_output = storage.job_recovery_output, .paths = storage.job_paths, .labels = storage.job_labels, .storage = storage };
        try job.copy_request(request);
        return job;
    }

    fn init_recovery(io: std.Io, path: []const u8, output_path: []const u8, allocator: std.mem.Allocator) !LoadJob {
        if (path.len == 0 or path.len >= dialog.path_capacity or output_path.len == 0 or output_path.len >= dialog.path_capacity) return error.PathTooLong;
        const storage = try OpenStorage.init(allocator, .three_way);
        var job: LoadJob = .{ .io = io, .merge = true, .restoring = true, .recovery_path = storage.job_recovery_path, .recovery_output = storage.job_recovery_output, .paths = storage.job_paths, .labels = storage.job_labels, .storage = storage };
        @memcpy(job.recovery_path[0..path.len], path);
        @memcpy(job.recovery_output[0..output_path.len], output_path);
        job.recovery_path_len = path.len;
        job.recovery_output_len = output_path.len;
        return job;
    }

    fn start(self: *LoadJob) !void {
        std.debug.assert(self.thread == null and self.state == .loading);
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        std.debug.assert(self.thread != null);
    }

    fn deinit(self: *LoadJob) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.opened) |*opened| opened.deinit();
        self.opened = null;
        std.debug.assert(self.stopping);
    }

    fn view(self: *LoadJob) struct { state: State, failure: anyerror } {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{ .state = self.state, .failure = self.failure };
    }

    fn take(self: *LoadJob) Opened {
        self.mutex.lockUncancelable(self.io);
        std.debug.assert(self.state == .ready and self.opened != null);
        const opened = self.opened.?;
        self.opened = null;
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        return opened;
    }

    fn copy_request(self: *LoadJob, request: invocation.Request) !void {
        const values: [4][]const u8 = switch (request) {
            .diff => |diff| .{ "", diff.left, diff.right, diff.output },
            .merge => |merge| .{ merge.base, merge.left, merge.right, merge.output },
            else => unreachable,
        };
        const supplied_labels: [4]?[]const u8 = switch (request) {
            .diff => |diff| .{ null, diff.left_label, diff.right_label, diff.output_label },
            .merge => |merge| .{ merge.base_label, merge.left_label, merge.right_label, merge.output_label },
            else => unreachable,
        };
        for (values, 0..) |value, index| {
            if (value.len > self.paths[index].len) return error.PathTooLong;
            @memcpy(self.paths[index][0..value.len], value);
            self.path_lens[index] = value.len;
            if (supplied_labels[index]) |label| {
                if (label.len > self.labels[index].len) return error.PathTooLong;
                @memcpy(self.labels[index][0..label.len], label);
                self.label_lens[index] = label.len;
            }
        }
    }

    fn to_request(self: *const LoadJob) invocation.Request {
        const path = struct {
            fn get(job: *const LoadJob, index: usize) []const u8 {
                std.debug.assert(index < job.paths.len and job.path_lens[index] <= job.paths[index].len);
                return job.paths[index][0..job.path_lens[index]];
            }
        }.get;
        const label = struct {
            fn get(job: *const LoadJob, index: usize) ?[]const u8 {
                std.debug.assert(index < job.labels.len and job.label_lens[index] <= job.labels[index].len);
                return if (job.label_lens[index] == 0) null else job.labels[index][0..job.label_lens[index]];
            }
        }.get;
        return if (self.merge) .{ .merge = .{ .base = path(self, 0), .left = path(self, 1), .right = path(self, 2), .output = path(self, 3), .base_label = label(self, 0), .left_label = label(self, 1), .right_label = label(self, 2), .output_label = label(self, 3), .wait = false } } else .{ .diff = .{ .left = path(self, 1), .right = path(self, 2), .output = path(self, 3), .left_label = label(self, 1), .right_label = label(self, 2), .output_label = label(self, 3), .wait = false } };
    }

    fn worker(self: *LoadJob) void {
        var value = (if (self.restoring) open_recovery_session(self.io, self.recovery_path[0..self.recovery_path_len], self.recovery_output[0..self.recovery_output_len], &self.storage) else open_session(self.io, self.to_request(), &self.storage)) catch |err| {
            self.publish_failure(err);
            return;
        };
        value.init_auto_recovery(self.io, null) catch {};
        self.mutex.lockUncancelable(self.io);
        if (self.stopping) {
            self.state = .discarded;
            self.mutex.unlock(self.io);
            value.deinit();
            return;
        }
        self.opened = value;
        self.state = .ready;
        self.mutex.unlock(self.io);
    }

    fn publish_failure(self: *LoadJob, err: anyerror) void {
        self.mutex.lockUncancelable(self.io);
        if (!self.stopping) {
            self.failure = err;
            self.state = .failed;
        } else self.state = .discarded;
        self.mutex.unlock(self.io);
    }
};

/// Decrypted record views borrow `recovery_plaintext`; metadata and session state copy
/// every required byte before it is wiped, so no recovery plaintext escapes this worker.
fn open_recovery_session(io: std.Io, path: []const u8, output_path: []const u8, storage: *OpenStorage) !Opened {
    const decoded = try recovery.load(io, path, storage.recovery_storage.ciphertext, storage.recovery_storage.plaintext);
    defer recovery.wipe(storage.recovery_storage.plaintext);
    const request: invocation.Request = switch (decoded.mode) {
        .two_way => .{ .diff = .{ .left = decoded.source_paths.left, .right = decoded.source_paths.right, .output = output_path, .left_label = null, .right_label = null, .output_label = null, .wait = false } },
        .three_way => .{ .merge = .{ .base = decoded.source_paths.base.?, .left = decoded.source_paths.left, .right = decoded.source_paths.right, .output = output_path, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } },
    };
    var opened = try open_session(io, request, storage);
    try recovery.restore_into(&opened.active, decoded);
    index_lines(&opened.lines[1], opened.active.result());
    std.debug.assert(opened.active.current_state().unresolved and !opened.active.current_state().reviewed);
    std.debug.assert(opened.lines[1].count > 0);
    return opened;
}

fn open_session(io: std.Io, request: invocation.Request, storage: *OpenStorage) !Opened {
    std.debug.assert(request == .diff or request == .merge);
    const loaded = try load_inputs(io, request, storage.base, storage.left, storage.right);
    const metadata = try stable_metadata(request, storage.metadata);
    const active = if (request == .diff)
        try session.Session.init_two_way(loaded.inputs.left, loaded.inputs.right, storage.session_storage)
    else blk: {
        if (explicit_json_sources(request)) storage.session_storage.json_workspace = &storage.json_workspace;
        if (explicit_zig_sources(request)) storage.session_storage.zig_workspace = &storage.zig_workspace;
        break :blk try session.Session.init(loaded.inputs, storage.session_storage);
    };
    var opened = Opened{
        .active = active,
        .labels = metadata.labels,
        .destination = metadata.destination,
        .input_paths = metadata.input_paths,
        .lines = undefined,
        .save_paths = storage.save_paths,
        .save_content = storage.save_content,
        .save_preflight = storage.save_preflight,
        .recovery_storage = storage.recovery_storage,
        .auto_recovery_storage = storage.auto_recovery_storage,
        .recovery_root = storage.recovery_root,
        .recovery_directory_path = storage.recovery_directory_path,
        .recovery_token = storage.recovery_token,
        .recovery_sddl = storage.recovery_sddl,
        .recovery_descriptor = storage.recovery_descriptor,
        .recovery_name = storage.recovery_name,
        .clipboard = storage.clipboard,
        .lsp = storage.lsp_service,
    };
    opened.lsp_job = .{ .io = io, .service = storage.lsp_service };
    opened.lsp_job.?.init(io, storage.lsp_service);
    for (&opened.lines, storage.line_offsets) |*lines, offsets| lines.* = .{ .offsets = offsets };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    std.debug.assert(opened.lines[0].count > 0 and opened.lines[2].count > 0);
    return opened;
}

/// JSON structure is opt-in only when every three-way source path explicitly names JSON.
fn explicit_json_sources(request: invocation.Request) bool {
    const merge = switch (request) {
        .merge => |value| value,
        else => return false,
    };
    return has_json_extension(merge.base) and has_json_extension(merge.left) and has_json_extension(merge.right);
}

fn explicit_zig_sources(request: invocation.Request) bool {
    const merge = switch (request) {
        .merge => |value| value,
        else => return false,
    };
    return has_zig_extension(merge.base) and has_zig_extension(merge.left) and has_zig_extension(merge.right);
}

fn has_zig_extension(path: []const u8) bool {
    return path.len >= 4 and std.ascii.eqlIgnoreCase(path[path.len - 4 ..], ".zig");
}

fn has_json_extension(path: []const u8) bool {
    return path.len >= 5 and std.ascii.eqlIgnoreCase(path[path.len - 5 ..], ".json");
}

const StableMetadata = struct { labels: Labels, destination: []const u8, input_paths: save.InputPaths };
const MetadataStore = struct {
    bytes: []u8,
    used: usize = 0,

    fn copy(self: *MetadataStore, source: []const u8) ![]const u8 {
        if (source.len > self.bytes.len - self.used) return error.PathTooLong;
        const destination = self.bytes[self.used..][0..source.len];
        @memcpy(destination, source);
        self.used += source.len;
        return destination;
    }
};

/// Returned views borrow process backing, never request or LoadJob stack storage.
fn stable_metadata(request: invocation.Request, backing: []u8) !StableMetadata {
    var store = MetadataStore{ .bytes = backing };
    return switch (request) {
        .diff => |diff| blk: {
            const left = try store.copy(diff.left);
            const right = try store.copy(diff.right);
            const output = try store.copy(diff.output);
            break :blk .{
                .labels = .{ .base = "No base in two-way diff", .left = if (diff.left_label) |label| try store.copy(label) else left, .right = if (diff.right_label) |label| try store.copy(label) else right, .output = if (diff.output_label) |label| try store.copy(label) else output },
                .destination = output,
                .input_paths = .{ .base = null, .left = left, .right = right },
            };
        },
        .merge => |merge| blk: {
            const base = try store.copy(merge.base);
            const left = try store.copy(merge.left);
            const right = try store.copy(merge.right);
            const output = try store.copy(merge.output);
            break :blk .{
                .labels = .{ .base = if (merge.base_label) |label| try store.copy(label) else base, .left = if (merge.left_label) |label| try store.copy(label) else left, .right = if (merge.right_label) |label| try store.copy(label) else right, .output = if (merge.output_label) |label| try store.copy(label) else output },
                .destination = output,
                .input_paths = .{ .base = base, .left = left, .right = right },
            };
        },
        else => unreachable,
    };
}

test "three-way structural engines require explicit source extensions" {
    const zig_request: invocation.Request = .{ .merge = .{ .base = "base.zig", .left = "left.ZIG", .right = "right.zig", .output = "result.zig", .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    const mixed_request: invocation.Request = .{ .merge = .{ .base = "base.zig", .left = "left.zig", .right = "right.txt", .output = "result.zig", .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    try std.testing.expect(explicit_zig_sources(zig_request));
    try std.testing.expect(!explicit_zig_sources(mixed_request));
}

test "three-way JSON engine requires explicit JSON source paths" {
    const json_request: invocation.Request = .{ .merge = .{ .base = "base.json", .left = "left.JSON", .right = "right.json", .output = "result.json", .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    const text_request: invocation.Request = .{ .merge = .{ .base = "base.json", .left = "left.txt", .right = "right.json", .output = "result.json", .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    try std.testing.expect(explicit_json_sources(json_request));
    try std.testing.expect(!explicit_json_sources(text_request));
}

test "initial-load metadata outlives mutable request paths" {
    var base = [_]u8{ 'b', 'a', 's', 'e' };
    var left = [_]u8{ 'l', 'e', 'f', 't' };
    var right = [_]u8{ 'r', 'i', 'g', 'h', 't' };
    var output = [_]u8{ 'o', 'u', 't' };
    var base_label = [_]u8{'B'};
    var left_label = [_]u8{'L'};
    var right_label = [_]u8{'R'};
    var output_label = [_]u8{'O'};
    var backing: [metadata_capacity]u8 = undefined;
    const metadata = try stable_metadata(.{ .merge = .{ .base = &base, .left = &left, .right = &right, .output = &output, .base_label = &base_label, .left_label = &left_label, .right_label = &right_label, .output_label = &output_label, .wait = false } }, &backing);
    @memset(&base, 'x');
    @memset(&left, 'x');
    @memset(&right, 'x');
    @memset(&output, 'x');
    @memset(&base_label, 'x');
    @memset(&left_label, 'x');
    @memset(&right_label, 'x');
    @memset(&output_label, 'x');
    try std.testing.expectEqualStrings("base", metadata.input_paths.base.?);
    try std.testing.expectEqualStrings("left", metadata.input_paths.left);
    try std.testing.expectEqualStrings("right", metadata.input_paths.right);
    try std.testing.expectEqualStrings("out", metadata.destination);
    try std.testing.expectEqualStrings("B", metadata.labels.base);
    try std.testing.expectEqualStrings("L", metadata.labels.left);
    try std.testing.expectEqualStrings("R", metadata.labels.right);
    try std.testing.expectEqualStrings("O", metadata.labels.output);
}

fn load_recovery_session(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, io: std.Io, path: []const u8, output_path: []const u8, allocator: std.mem.Allocator) !?Opened {
    var job = try LoadJob.init_recovery(io, path, output_path, allocator);
    try job.start();
    defer job.deinit();
    var model = Model{ .mode = .welcome, .status = "RESTORING RECOVERY | decrypting draft and revalidating original input hashes" };
    while (true) {
        const view = job.view();
        switch (view.state) {
            .ready => return job.take(),
            .failed => {
                show_recovery_load_failure(view.failure);
                return view.failure;
            },
            .discarded => return null,
            .loading => {
                try update_layout(renderer, window, &model);
                try render_loading(renderer, &model);
                var event: sdl.SDL_Event = undefined;
                if (sdl.SDL_WaitEventTimeout(&event, 50) and (event.type == sdl.SDL_EVENT_QUIT or event.type == sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED or (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE))) return null;
            },
        }
    }
}

fn load_session(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, io: std.Io, request: invocation.Request, allocator: std.mem.Allocator) !?Opened {
    var job = try LoadJob.init(io, request, allocator);
    try job.start();
    defer job.deinit();
    var model = Model{ .mode = .welcome, .status = "LOADING | reading inputs and initializing bounded merge off UI thread" };
    var redraw = true;
    while (true) {
        const view = job.view();
        switch (view.state) {
            .ready => return job.take(),
            .failed => {
                show_load_failure(view.failure);
                return view.failure;
            },
            .discarded => return null,
            .loading => {},
        }
        try update_layout(renderer, window, &model);
        if (redraw) {
            try render_loading(renderer, &model);
            redraw = false;
        }
        var event: sdl.SDL_Event = undefined;
        if (sdl.SDL_WaitEventTimeout(&event, 50)) {
            if (event.type == sdl.SDL_EVENT_QUIT or event.type == sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED or (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE)) return null;
            redraw = true;
        }
    }
}

fn render_loading(renderer: *sdl.SDL_Renderer, model: *const Model) !void {
    if (!sdl.SDL_SetRenderScale(renderer, 2, 2)) return error.RenderFailed;
    try color(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderClear(renderer)) return error.RenderFailed;
    try color(renderer, 230, 235, 244);
    try debug_text(renderer, 4, 4, "warkocz | initial load");
    try debug_text(renderer, 4, 18, model.status);
    try debug_text(renderer, 4, 42, "Loading remains cancellable: Esc or window close discards unpresented session after worker joins.");
    try debug_text(renderer, 4, 56, "No renderer or SDL calls occur in load worker. No input or output file is changed.");
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
}

const LoadedInputs = struct { inputs: session.Inputs };
fn load_inputs(io: std.Io, request: invocation.Request, base: []u8, left: []u8, right: []u8) !LoadedInputs {
    std.debug.assert(base.len == input_capacity and left.len == input_capacity);
    std.debug.assert(right.len == input_capacity);
    return switch (request) {
        .diff => |diff| .{ .inputs = .{ .base = "", .left = (try files.load(io, diff.left, left)).bytes, .right = (try files.load(io, diff.right, right)).bytes } },
        .merge => |merge| .{ .inputs = .{ .base = (try files.load(io, merge.base, base)).bytes, .left = (try files.load(io, merge.left, left)).bytes, .right = (try files.load(io, merge.right, right)).bytes } },
        else => unreachable,
    };
}

fn index_lines(lines: *Lines, source: []const u8) void {
    std.debug.assert(source.len <= input_capacity);
    std.debug.assert(lines.offsets.len > source.len);
    lines.count = 1;
    lines.offsets[0] = 0;
    for (source, 0..) |byte, index| if (byte == '\n' or (byte == '\r' and (index + 1 == source.len or source[index + 1] != '\n'))) {
        lines.offsets[lines.count] = @intCast(index + 1);
        lines.count += 1;
    };
    std.debug.assert(lines.count <= lines.offsets.len);
    std.debug.assert(lines.offsets[lines.count - 1] <= source.len);
}

fn layout_for(width: f32, height: f32) Layout {
    std.debug.assert(width >= 0 and height >= 0);
    std.debug.assert(std.math.isFinite(width) and std.math.isFinite(height));
    const columns: usize = @intFromFloat(@max(1, @min(action_count, @floor(width / 80))));
    var layout: Layout = undefined;
    layout.width = width;
    layout.height = height;
    for (&layout.buttons, 0..) |*button, index| button.* = .{ .x = @as(f32, @floatFromInt(index % columns)) * 80, .y = 36 + @as(f32, @floatFromInt(index / columns)) * 16, .w = @min(78, width), .h = 14 };
    const top = 36 + @as(f32, @floatFromInt((action_count + columns - 1) / columns)) * 16 + 30;
    const usable = @max(0, width - 16);
    const side = usable * 0.24;
    const body_height = @max(0, height - top - 30);
    layout.panes = .{
        .{ .x = 4, .y = top, .w = side, .h = body_height },
        .{ .x = 8 + side, .y = top, .w = usable * 0.52, .h = body_height },
        .{ .x = 12 + usable * 0.76, .y = top, .w = side, .h = body_height },
    };
    layout.palette = .{ .x = 4, .y = 36, .w = @max(0, width - 8), .h = @max(0, @min(height - 40, 216)) };
    std.debug.assert(layout.panes[1].w >= layout.panes[0].w);
    return layout;
}

fn update_layout(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, model: *Model) !void {
    var width: c_int = 0;
    var height: c_int = 0;
    var window_width: c_int = 0;
    var window_height: c_int = 0;
    if (!sdl.SDL_GetRenderOutputSize(renderer, &width, &height) or !sdl.SDL_GetWindowSize(window, &window_width, &window_height)) return error.RenderFailed;
    if (width <= 0 or height <= 0 or window_width <= 0 or window_height <= 0) return;
    std.debug.assert(width > 0 and height > 0);
    const layout = layout_for(@as(f32, @floatFromInt(width)) / 2, @as(f32, @floatFromInt(height)) / 2);
    if (layout.width != model.layout.width or layout.height != model.layout.height) clear_lsp_review_latch(model);
    model.layout = layout;
    model.mouse_scale_x = model.layout.width / @as(f32, @floatFromInt(window_width));
    model.mouse_scale_y = model.layout.height / @as(f32, @floatFromInt(window_height));
    std.debug.assert(model.mouse_scale_x > 0 and model.mouse_scale_y > 0);
}

fn event_loop(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, model: *Model, opened: ?*Opened) !void {
    try sync_text_input(window, model);
    var running = true;
    var redraw = true;
    defer _ = sdl.SDL_StopTextInput(window);
    while (!event_loop_finished(running, model)) {
        if (opened) |current| {
            consume_recovery_picker(model, current, window, &redraw);
            consume_lsp_picker(model, current, window, &redraw);
            consume_lsp_job(model, current, &redraw);
            advance_exit_drain(model, current, &redraw);
            if (model.exit_ready) running = false;
            sync_lsp_result(model, current);
            consume_lsp_publications(model, current, &redraw);
            consume_recovery_result(model, current, &redraw);
            consume_auto_recovery_result(model, current, &redraw);
            consume_save_result(model, current, &redraw);
            consume_completion_result(model, current, &redraw);
        }
        try update_layout(renderer, window, model);
        const processed = try drain_events(64, window, model, opened, &running, &redraw);
        if (running and redraw) {
            try render(renderer, model, opened);
            model.help_presented = if (!model.palette_open or matches(model, model.selected)) model.selected else null;
            redraw = false;
        }
        if (running and processed == 0) {
            var event: sdl.SDL_Event = undefined;
            if (sdl.SDL_WaitEventTimeout(&event, 50)) try route_event(&event, window, model, opened, &running, &redraw);
        }
    }
    std.debug.assert(event_loop_finished(running, model));
    try resolution_close_result(model);
}

fn resolution_close_result(model: *const Model) Error!void {
    if (model.mode != .welcome and !model.completed) return error.ResolutionIncomplete;
}

fn event_loop_finished(running: bool, model: *const Model) bool {
    return !running or (model.completed and model.exit_ready);
}

fn request_exit_drain(model: *Model, current: *const Opened) void {
    std.debug.assert(current.lsp == null or current.lsp_job != null);
    model.exit_requested = true;
    if (model.recovery_picker_pending or model.lsp_picker_pending) {
        model.status = if (model.lsp_picker_pending) "EXIT PENDING | language-server picker remains live; dismiss it before closing" else "EXIT PENDING | recovery picker remains live; dismiss it before closing";
        return;
    }
    model.status = "EXIT DRAINING | result retained until language-server teardown completes";
}

fn advance_exit_drain(model: *Model, current: *Opened, redraw: *bool) void {
    if (!model.exit_requested or model.exit_ready) return;
    if (model.recovery_picker_pending or model.lsp_picker_pending) {
        model.status = "EXIT PENDING | picker callback remains live; dismiss picker before closing";
        redraw.* = true;
        return;
    }
    if (lsp_job_working(current)) return;
    const service = current.lsp orelse {
        model.exit_ready = true;
        return;
    };
    if (service.stage == .detached) {
        model.exit_ready = true;
        return;
    }
    const job = if (current.lsp_job) |*value| value else {
        model.exit_requested = false;
        model.exit_ready = false;
        model.completed = false;
        model.status = "EXIT DRAIN FAILED | language-server teardown storage unavailable; result remains open";
        redraw.* = true;
        return;
    };
    job.start_close() catch {
        model.exit_requested = false;
        model.exit_ready = false;
        model.completed = false;
        model.status = "EXIT DRAIN FAILED | language-server teardown not queued; result remains open";
        redraw.* = true;
        return;
    };
    model.status = "EXIT DRAINING | graceful language-server close queued";
    redraw.* = true;
}

fn drain_events(limit: usize, window: *sdl.SDL_Window, model: *Model, opened: ?*Opened, running: *bool, redraw: *bool) !usize {
    std.debug.assert(limit > 0);
    var event: sdl.SDL_Event = undefined;
    var processed: usize = 0;
    while (processed < limit and sdl.SDL_PollEvent(&event)) : (processed += 1) try route_event(&event, window, model, opened, running, redraw);
    std.debug.assert(processed <= limit);
    return processed;
}

fn route_event(event: *const sdl.SDL_Event, window: *sdl.SDL_Window, model: *Model, opened: ?*Opened, running: *bool, redraw: *bool) !void {
    if (event.type == sdl.SDL_EVENT_QUIT or event.type == sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED) {
        if (opened) |current| {
            if (model.completion_job_id != null) {
                model.completion_job_id = null;
                model.completed = false;
                model.exit_ready = false;
                model.status = "EXIT INCOMPLETE | pending Complete verification will not acknowledge success";
            }
            request_exit_drain(model, current);
            redraw.* = true;
            return;
        }
        running.* = false;
        return;
    }
    redraw.* = (try handle_event(event, window, model, opened)) or redraw.*;
}

fn handle_event(event: *const sdl.SDL_Event, window: *sdl.SDL_Window, model: *Model, opened: ?*Opened) !bool {
    std.debug.assert(model.focus < model.scroll.len);
    std.debug.assert(model.selected < actions.len);
    if (event.type == sdl.SDL_EVENT_WINDOW_RESIZED or event.type == sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        clear_lsp_review_latch(model);
        return true;
    }
    if (event.type == sdl.SDL_EVENT_WINDOW_EXPOSED) return true;
    if (model.exit_requested) return false;
    if (model.lsp_navigation_open and !model.palette_open) {
        if (opened) |current| if (handle_lsp_navigation(event, model, current)) |handled| return handled;
    }
    if (event.type == sdl.SDL_EVENT_KEY_DOWN) {
        model.lsp_confirmation_timestamp = if (!event.key.repeat and event.key.timestamp > 0) event.key.timestamp else null;
        defer model.lsp_confirmation_timestamp = null;
        return handle_key(event.key.key, event.key.mod, window, model, opened);
    }
    if (!model.palette_open and lsp_review_mode(opened) and event.type != sdl.SDL_EVENT_MOUSE_BUTTON_DOWN) return false;
    if (event.type == sdl.SDL_EVENT_TEXT_INPUT) {
        const text = std.mem.span(event.text.text);
        if (model.palette_open) append_query(model, text) else try insert_text(text, model, opened);
        return true;
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_MOTION and !model.palette_open and !lsp_review_mode(opened)) {
        const x = event.motion.x * model.mouse_scale_x;
        const y = event.motion.y * model.mouse_scale_y;
        if (model.dragging_result) {
            update_drag_selection(x, y, model, opened);
            return true;
        }
        for (model.layout.buttons, 0..) |rect, index| if (rect.contains(x, y)) {
            model.selected = index;
            return true;
        };
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN and event.button.button == sdl.SDL_BUTTON_LEFT) {
        model.lsp_confirmation_timestamp = if (event.button.timestamp > 0) event.button.timestamp else null;
        defer model.lsp_confirmation_timestamp = null;
        return try handle_click(event.button.x * model.mouse_scale_x, event.button.y * model.mouse_scale_y, (sdl.SDL_GetModState() & sdl.SDL_KMOD_SHIFT) != 0, window, model, opened);
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_UP and event.button.button == sdl.SDL_BUTTON_LEFT) {
        model.dragging_result = false;
        return true;
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_WHEEL and !model.palette_open and !lsp_review_mode(opened)) {
        const sign: f32 = if (event.wheel.direction == sdl.SDL_MOUSEWHEEL_FLIPPED) -1 else 1;
        const x = event.wheel.mouse_x * model.mouse_scale_x;
        const y = event.wheel.mouse_y * model.mouse_scale_y;
        for (model.layout.panes, 0..) |rect, index| if (rect.contains(x, y)) {
            model.focus = index;
        };
        try sync_text_input(window, model);
        scroll_view(model, opened, -event.wheel.y * sign * 3, -event.wheel.x * sign * 4);
        return true;
    }
    return false;
}

fn toggle_palette(window: *sdl.SDL_Window, model: *Model) !void {
    model.palette_open = !model.palette_open;
    model.query_len = 0;
    if (model.palette_open) model.selected = 0;
    try sync_text_input(window, model);
    std.debug.assert(model.query_len == 0);
    std.debug.assert(model.selected < actions.len);
}

fn sync_text_input(window: *sdl.SDL_Window, model: *Model) !void {
    const wanted = model.palette_open or (model.focus == 1 and model.editor != null);
    if (wanted == model.text_input_active) return;
    if (wanted) {
        if (!sdl.SDL_StartTextInput(window)) return graphics_failure("SDL_StartTextInput failed");
    } else if (!sdl.SDL_StopTextInput(window)) return graphics_failure("SDL_StopTextInput failed");
    model.text_input_active = wanted;
    std.debug.assert(model.text_input_active == wanted);
}

fn handle_key(key: sdl.SDL_Keycode, modifiers: sdl.SDL_Keymod, window: *sdl.SDL_Window, model: *Model, opened: ?*Opened) !bool {
    std.debug.assert(model.selected < actions.len);
    std.debug.assert(model.query_len <= model.query.len);
    if ((modifiers & sdl.SDL_KMOD_CTRL) != 0 and key == sdl.SDLK_P) {
        try toggle_palette(window, model);
        return true;
    }
    if (model.palette_open) {
        if (key == sdl.SDLK_ESCAPE) try toggle_palette(window, model) else handle_palette_key(key, model, opened);
        try sync_text_input(window, model);
        return true;
    }
    if (lsp_review_mode(opened)) {
        if (key == sdl.SDLK_RETURN) apply_action(action_index(.confirm_result_language_server_trust), model, opened) else if (key == sdl.SDLK_ESCAPE) apply_action(action_index(.detach_result_language_server), model, opened);
        return true;
    }
    const ctrl = (modifiers & sdl.SDL_KMOD_CTRL) != 0;
    if (ctrl and key == sdl.SDLK_A) {
        apply_action(action_index(.select_all), model, opened);
        try sync_text_input(window, model);
        return true;
    }
    if (ctrl and key == sdl.SDLK_S and (modifiers & sdl.SDL_KMOD_SHIFT) != 0) {
        apply_action(action_index(.export_recovery), model, opened);
        return true;
    }
    if (ctrl and (key == sdl.SDLK_C or key == sdl.SDLK_X or key == sdl.SDLK_V or key == sdl.SDLK_Z or key == sdl.SDLK_Y or key == sdl.SDLK_S)) {
        const action: Action = switch (key) {
            sdl.SDLK_C => .copy,
            sdl.SDLK_X => .cut,
            sdl.SDLK_V => .paste,
            sdl.SDLK_Z => .undo,
            sdl.SDLK_Y => .redo,
            sdl.SDLK_S => .save,
            else => unreachable,
        };
        apply_action(action_index(action), model, opened);
        try sync_text_input(window, model);
        return true;
    }
    if (model.focus == 1 and model.editor != null and (key == sdl.SDLK_LEFT or key == sdl.SDLK_RIGHT or key == sdl.SDLK_HOME or key == sdl.SDLK_END)) {
        model.editor.?.move(opened.?.active.result(), switch (key) {
            sdl.SDLK_LEFT => .left,
            sdl.SDLK_RIGHT => .right,
            sdl.SDLK_HOME => .home,
            sdl.SDLK_END => .end,
            else => unreachable,
        }, (modifiers & sdl.SDL_KMOD_SHIFT) != 0);
        scroll_to_editor(model, opened.?);
        return true;
    }
    if (model.focus == 1 and model.editor != null and (key == sdl.SDLK_BACKSPACE or key == sdl.SDLK_DELETE)) {
        try delete_editor_selection(key == sdl.SDLK_BACKSPACE, model, opened);
        return true;
    }
    if (key == sdl.SDLK_TAB) {
        model.focus = (model.focus + 1) % 3;
        try sync_text_input(window, model);
        return true;
    }
    const amount: f32 = if (key == sdl.SDLK_PAGEUP or key == sdl.SDLK_PAGEDOWN) 12 else 1;
    if (key == sdl.SDLK_UP or key == sdl.SDLK_PAGEUP or key == sdl.SDLK_DOWN or key == sdl.SDLK_PAGEDOWN) {
        scroll_view(model, opened, if (key == sdl.SDLK_UP or key == sdl.SDLK_PAGEUP) -amount else amount, 0);
        return true;
    }
    if (key == sdl.SDLK_LEFT or key == sdl.SDLK_RIGHT) {
        scroll_view(model, opened, 0, if (key == sdl.SDLK_LEFT) -4 else 4);
        return true;
    }
    // Text-focused result keys must reach SDL text input only, never resolution or Save.
    if (model.focus != 1) for (actions, 0..) |info, index| if (!ctrl and info.key != sdl.SDLK_UNKNOWN and key == info.key) {
        request_action(index, model, opened);
        try sync_text_input(window, model);
        return true;
    };
    return false;
}

fn action_index(action: Action) usize {
    for (actions, 0..) |info, index| if (info.action == action) return index;
    unreachable;
}

fn insert_text(text: []const u8, model: *Model, opened: ?*Opened) !void {
    if (!editor.insertion_allowed(text)) {
        model.status = "EDIT REJECTED | printable ASCII plus TAB, CR, LF only; result unchanged";
        return;
    }
    const current = opened orelse return;
    if (model.editor == null) {
        model.status = "READ-ONLY BYTE REVIEW | result unchanged";
        return;
    }
    replace_editor_selection(text, model, current) catch return;
}

fn delete_editor_selection(backspace: bool, model: *Model, opened: ?*Opened) !void {
    const current = opened orelse return;
    var state = model.editor orelse return;
    const source = current.active.result();
    if (!state.has_selection()) {
        if (backspace) state.anchor = editor.previous_boundary(source, state.cursor) else state.cursor = editor.next_boundary(source, state.cursor);
    }
    model.editor = state;
    replace_editor_selection("", model, current) catch return;
}

fn replace_editor_selection(replacement: []const u8, model: *Model, current: *Opened) !void {
    var state = model.editor orelse return;
    state.clamp(current.active.result());
    const source = current.active.result();
    const range = state.replacement_range(source);
    const edits = [_]@import("../bytes.zig").Edit{.{ .start = range.start, .end = range.end, .replacement = replacement }};
    current.active.apply_edits(current.active.generation, &edits) catch |err| {
        model.status = "EDIT REJECTED | bounded history or result capacity retained current bytes";
        return err;
    };
    state.cursor = range.start + replacement.len;
    state.anchor = state.cursor;
    model.editor = state;
    index_lines(&current.lines[1], current.active.result());
    model.scroll[1].line = @min(model.scroll[1].line, current.lines[1].count - 1);
    scroll_to_editor(model, current);
    model.durable_generation = null;
    model.durable_receipt = null;
    model.status = "EDITED ASCII RESULT | unsaved | Save receipt invalidated";
    request_auto_recovery(model, current);
    sync_lsp_result(model, current);
}

fn request_auto_recovery(model: *Model, current: *Opened) void {
    if (!current.auto_recovery_initialized) {
        model.status = "RECOVERY UNPROTECTED | automatic encrypted recovery unavailable | editor remains usable";
        return;
    }
    const state = current.active.current_state();
    const identity = current.active.identity();
    const value: recovery.Record = .{ .mode = current.active.mode, .generation = identity.generation, .identity = identity.inputs, .source_paths = .{ .base = current.input_paths.base, .left = current.input_paths.left, .right = current.input_paths.right }, .result = current.active.result(), .origin = state.origin, .reviewed = state.reviewed, .unresolved = state.unresolved, .engine = .{ .name = identity.engine.name, .version = identity.engine.version }, .provenance = "automatic encrypted recovery" };
    current.auto_recovery.request(value) catch |err| {
        model.status = if (err == error.ResourceExhausted) "RECOVERY FAILED | guarantee unavailable | editor remains usable" else @errorName(err);
        return;
    };
    model.status = "RECOVERY PENDING | encrypted DPAPI snapshot due within 500 ms";
}

fn copy_selection(model: *Model, current: *const Opened) !void {
    const state = model.editor orelse return error.ReadOnly;
    const range = state.replacement_range(current.active.result());
    const source = current.active.result()[range.start..range.end];
    const clipboard = model.clipboard orelse return error.ProvisionalCapacityExceeded;
    if (source.len > clipboard.len) return error.ProvisionalCapacityExceeded;
    @memcpy(clipboard[0..source.len], source);
    clipboard[source.len] = 0;
    model.clipboard_len = source.len;
    if (!sdl.SDL_SetClipboardText(clipboard.ptr)) {
        model.status = "COPY FAILED | result and bounded clipboard copy retained";
        return error.ClipboardUnavailable;
    }
    model.status = "COPIED RESULT SELECTION | explicit clipboard action";
}

fn paste_clipboard(model: *Model, opened: ?*Opened) !void {
    const value = sdl.SDL_GetClipboardText();
    if (value == null) return error.ClipboardUnavailable;
    defer sdl.SDL_free(value);
    const text = std.mem.span(value);
    if (!editor.insertion_allowed(text)) {
        model.status = "PASTE REJECTED | clipboard is not printable ASCII plus TAB, CR, LF; result unchanged";
        return;
    }
    try insert_text(text, model, opened);
}

fn handle_palette_key(key: sdl.SDL_Keycode, model: *Model, opened: ?*Opened) void {
    std.debug.assert(model.palette_open);
    std.debug.assert(model.selected < actions.len);
    if (key == sdl.SDLK_BACKSPACE) {
        model.query_len -|= 1;
        select_first_match(model);
    } else if (key == sdl.SDLK_UP or key == sdl.SDLK_DOWN) {
        move_selection(model, key == sdl.SDLK_DOWN);
    } else if (key == sdl.SDLK_RETURN and matches(model, model.selected)) {
        request_action(model.selected, model, opened);
    }
}

fn append_query(model: *Model, text: []const u8) void {
    std.debug.assert(model.query_len <= model.query.len);
    for (text[0..@min(text.len, model.query.len)]) |byte| {
        if (model.query_len == model.query.len) break;
        if (byte >= 32 and byte <= 126) {
            model.query[model.query_len] = byte;
            model.query_len += 1;
        }
    }
    select_first_match(model);
    std.debug.assert(model.query_len <= model.query.len);
}

fn matches(model: *const Model, index: usize) bool {
    std.debug.assert(index < actions.len);
    std.debug.assert(model.query_len <= model.query.len);
    return std.ascii.findIgnoreCase(actions[index].name, model.query[0..model.query_len]) != null or std.ascii.findIgnoreCase(action_registry.aliases(actions[index].action), model.query[0..model.query_len]) != null or std.ascii.findIgnoreCase(actions[index].help, model.query[0..model.query_len]) != null;
}

fn select_first_match(model: *Model) void {
    std.debug.assert(model.selected < actions.len);
    for (actions, 0..) |_, index| if (matches(model, index)) {
        model.selected = index;
        break;
    };
    std.debug.assert(model.selected < actions.len);
}

fn move_selection(model: *Model, forward: bool) void {
    std.debug.assert(model.selected < actions.len);
    var next = model.selected;
    for (0..actions.len) |_| {
        next = if (forward) (next + 1) % actions.len else (next + actions.len - 1) % actions.len;
        if (matches(model, next)) {
            model.selected = next;
            break;
        }
    }
    std.debug.assert(model.selected < actions.len);
}

fn disabled_reason(index: usize, model: *const Model, opened: ?*const Opened) ?[]const u8 {
    std.debug.assert(index < actions.len);
    if (opened == null) return "No open file result. Launch diff or merge with literal paths.";
    const current = opened.?;
    std.debug.assert(current.active.cursor < current.active.record_count);
    if (model.exit_requested) return "Exit drain in progress; result remains immutable until teardown completes.";
    const action = actions[index].action;
    if ((action == .attach_result_language_server or action == .confirm_result_language_server_trust or action == .detach_result_language_server or action == .hover or action == .symbols or action == .definition or action == .references) and lsp_job_working(current)) return "Language-server operation is in progress.";
    return switch (action) {
        .choose_base => if (model.mode == .diff) "Two-way diff has no base; select Left or Right." else null,
        .undo => if (current.active.cursor == 0) "No earlier decision." else null,
        .redo => if (current.active.cursor + 1 == current.active.record_count) "No later decision." else null,
        .export_recovery => if (model.recovery_picker_pending) "Recovery file picker is pending." else if (!current.recovery_initialized) "Encrypted recovery worker unavailable." else switch (@constCast(&current.recovery).observe()) {
            .pending => "Encrypted recovery export in progress.",
            else => null,
        },
        .save => if (current.active.current_state().unresolved) "Resolve result before Save." else if (model_has_durable_receipt(model, current)) "Current generation already has durable new-file receipt." else switch (@constCast(&current.save).observe().result) {
            .pending => "Save or Complete verification in progress; closing waits for its worker step.",
            else => null,
        },
        .complete => if (current.active.current_state().unresolved) "Resolve result before Complete." else if (model.completion_job_id != null) "Complete verification in progress; closing remains incomplete." else if (!model_has_durable_receipt(model, current)) "Complete requires durable Save for current generation." else null,
        .next_change => if (current.active.left_changes.len == 0 and current.active.right_changes.len == 0) "No bounded multi-hunk source changes available." else null,
        .copy, .cut, .paste, .select_all => if (model.editor == null) "Result editing supports printable ASCII plus TAB, CR, LF only; unsupported controls, binary, or non-ASCII bytes remain exact read-only review." else null,
        .attach_result_language_server => if (current.lsp == null) "Language-server storage unavailable." else if (model.lsp_picker_pending) "Language-server selection is in progress." else if (current.lsp.?.stage != .detached) "Detach current language server before attaching another." else null,
        .confirm_result_language_server_trust => if (current.lsp == null or current.lsp.?.stage != .review) "Choose executable and workspace, then wait for readonly review." else if (!lsp_review_ready(model, current)) "Display complete exact trust review before Confirm." else null,
        .detach_result_language_server => if (current.lsp == null or current.lsp.?.stage == .detached) "No attached language server." else if (model.lsp_picker_pending) "Language-server selection is in progress." else null,
        .hover => lsp_action_reason(current, .hover),
        .symbols => lsp_action_reason(current, .document_symbol),
        .definition => lsp_action_reason(current, .definition),
        .references => lsp_action_reason(current, .references),
        else => null,
    };
}

fn model_has_durable_receipt(model: *const Model, current: *const Opened) bool {
    return model.durable_generation != null and model.durable_generation.? == current.active.generation and model.durable_receipt != null;
}

fn request_action(index: usize, model: *Model, opened: ?*Opened) void {
    std.debug.assert(index < actions.len);
    std.debug.assert(model.selected < actions.len);
    model.selected = index;
    if (model.help_presented == index) apply_action(index, model, opened) else {
        model.status = "Read selected action help; repeat key/click or Enter to execute.";
    }
}

fn apply_action(index: usize, model: *Model, opened: ?*Opened) void {
    std.debug.assert(index < actions.len);
    if (disabled_reason(index, model, opened)) |reason| {
        model.status = reason;
        return;
    }
    const current = opened.?;
    std.debug.assert((model.mode == .diff) == (current.active.mode == .two_way));
    const generation = current.active.identity().generation;
    if (actions[index].action == .next_change) {
        navigate_change(model, current);
        return;
    }
    const result = switch (actions[index].action) {
        .choose_base => current.active.choose(generation, .base),
        .choose_left => current.active.choose(generation, .left),
        .choose_right => current.active.choose(generation, .right),
        .reset => current.active.reset_original(generation),
        .undo => current.active.undo(generation),
        .redo => current.active.redo(generation),
        .mark_resolved => current.active.mark_resolved(generation),
        .find_recovery_drafts => unreachable,
        .export_recovery => {
            model.recovery_picker_pending = true;
            model.recovery_observed = false;
            const window = model.window orelse {
                model.recovery_picker_pending = false;
                model.status = "Encrypted recovery picker unavailable.";
                return;
            };
            model.recovery_picker.show(.save_file, window);
            model.status = "RECOVERY PICKER OPEN | choose a new encrypted draft filename";
            return;
        },
        .save => {
            current.active.preflight_save(generation) catch |err| {
                model.status = @errorName(err);
                return;
            };
            current.save.request(generation, current.active.input_identity, current.input_paths, current.destination, current.active.result()) catch |err| {
                model.status = @errorName(err);
                return;
            };
            model.observed_save_generation = null;
            model.status = "SAVE IN PROGRESS | immutable current-generation snapshot | new file only";
            return;
        },
        .complete => {
            const receipt = model.durable_receipt orelse {
                model.status = "Complete requires durable Save for current generation.";
                return;
            };
            const job_id = current.save.request_verify(generation, current.active.input_identity, current.input_paths, current.destination, receipt) catch |err| {
                model.status = @errorName(err);
                return;
            };
            model.completion_job_id = job_id;
            model.status = "COMPLETE VERIFYING | rereading output and source identities";
            return;
        },
        .copy => {
            copy_selection(model, current) catch |err| {
                model.status = @errorName(err);
            };
            return;
        },
        .cut => {
            if (!model.editor.?.has_selection()) {
                model.status = "CUT REQUIRES RESULT SELECTION | result unchanged";
                return;
            }
            copy_selection(model, current) catch |err| {
                model.status = @errorName(err);
                return;
            };
            replace_editor_selection("", model, current) catch |err| {
                model.status = @errorName(err);
            };
            return;
        },
        .paste => {
            paste_clipboard(model, opened) catch |err| {
                model.status = @errorName(err);
            };
            return;
        },
        .select_all => {
            model.editor.?.select_all(current.active.result());
            scroll_to_editor(model, current);
            model.status = "RESULT SELECTION | all bytes";
            return;
        },
        .next_change => unreachable,
        .attach_result_language_server => {
            clear_lsp_review_latch(model);
            model.lsp_picker_pending = true;
            model.lsp_picking_workspace = false;
            model.lsp_picker.show(.open_file, model.window orelse {
                model.lsp_picker_pending = false;
                model.status = "Language-server picker unavailable.";
                return;
            });
            model.status = "LANGUAGE-SERVER EXECUTABLE PICKER OPEN | exact absolute executable required";
            return;
        },
        .confirm_result_language_server_trust => {
            if (!lsp_review_confirmation_allowed(model, current)) {
                model.status = "Display complete exact trust review, then use a fresh non-repeating confirmation.";
                return;
            }
            current.lsp_job.?.start_confirm(current.active.result(), current.active.generation) catch |err| {
                model.status = @errorName(err);
                return;
            };
            if (current.lsp_job.?.view().state == .working) model.status = "LANGUAGE-SERVER TRUST CONFIRMING | exact reviewed executable and workspace";
            return;
        },
        .detach_result_language_server => {
            clear_lsp_review_latch(model);
            current.lsp_job.?.start_revoke() catch |err| {
                model.status = @errorName(err);
                return;
            };
            model.lsp_synced_generation = null;
            model.lsp_text_len = 0;
            model.lsp_status_len = 0;
            model.lsp_navigation_open = false;
            model.lsp_navigation_selected = 0;
            model.status = "LANGUAGE SERVER DETACHING | process teardown and trust revocation pending";
            return;
        },
        .hover => {
            request_lsp_action(model, current, .hover);
            return;
        },
        .symbols => {
            request_lsp_action(model, current, .document_symbol);
            return;
        },
        .definition => {
            request_lsp_action(model, current, .definition);
            return;
        },
        .references => {
            request_lsp_action(model, current, .references);
            return;
        },
        .close_repository => unreachable,
    };
    result catch |err| {
        model.status = @errorName(err);
        return;
    };
    model.durable_generation = null;
    model.durable_receipt = null;
    model.observed_save_generation = null;
    model.completion_job_id = null;
    index_lines(&current.lines[1], current.active.result());
    model.scroll[1].line = @min(model.scroll[1].line, current.lines[1].count - 1);
    model.editor = editor.State.init(current.active.result());
    scroll_to_editor(model, current);
    model.status = if (model.editor == null) "READ-ONLY BYTE REVIEW | result contains unsupported control, binary, or non-ASCII bytes; exact whole-side choices only" else session_status(&current.active);
    request_auto_recovery(model, current);
    sync_lsp_result(model, current);
    std.debug.assert(current.lines[1].count > model.scroll[1].line);
}

fn navigate_change(model: *Model, current: *const Opened) void {
    const count = @max(current.active.left_changes.len, current.active.right_changes.len);
    std.debug.assert(count > 0);
    const index = model.change_index % count;
    if (index < current.active.left_changes.len) model.scroll[0].line = line_for_offset(current.lines[0], current.active.left_changes[index].other.start);
    if (index < current.active.right_changes.len) model.scroll[2].line = line_for_offset(current.lines[2], current.active.right_changes[index].other.start);
    model.focus = if (index < current.active.left_changes.len) 0 else 2;
    model.change_index = (index + 1) % count;
    model.status = "CHANGE NAVIGATION | exact bounded multi-hunk source range | source panes highlighted";
}

fn line_for_offset(lines: Lines, offset: usize) usize {
    std.debug.assert(lines.count > 0 and lines.count <= lines.offsets.len);
    var line: usize = 0;
    while (line + 1 < lines.count and lines.offsets[line + 1] <= offset) line += 1;
    std.debug.assert(line < lines.count);
    return line;
}

fn lsp_job_working(current: *const Opened) bool {
    const job = if (current.lsp_job) |*value| value else return false;
    return @constCast(job).view().state == .working;
}

fn clear_lsp_review_latch(model: *Model) void {
    model.lsp_review_identity = null;
    model.lsp_review_presented_at = 0;
    model.lsp_review_width = 0;
    model.lsp_review_height = 0;
}

fn lsp_review_mode(opened: ?*const Opened) bool {
    const current = opened orelse return false;
    if (lsp_job_working(current)) return false;
    return current.lsp != null and current.lsp.?.stage == .review;
}

fn lsp_review_ready(model: *const Model, current: *const Opened) bool {
    if (lsp_job_working(current)) return false;
    const service = current.lsp orelse return false;
    const identity = service.identity orelse return false;
    return service.stage == .review and model.lsp_review_identity != null and model.lsp_review_identity.?.eql(identity) and model.lsp_review_width == model.layout.width and model.lsp_review_height == model.layout.height;
}

fn lsp_review_confirmation_allowed(model: *const Model, current: *const Opened) bool {
    const timestamp = model.lsp_confirmation_timestamp orelse return false;
    return lsp_review_ready(model, current) and timestamp > model.lsp_review_presented_at;
}

fn latch_lsp_review(model: *Model, opened: *const Opened, complete: bool) void {
    if (lsp_job_working(opened)) {
        clear_lsp_review_latch(model);
        return;
    }
    const service = opened.lsp orelse {
        clear_lsp_review_latch(model);
        return;
    };
    const identity = service.identity orelse {
        clear_lsp_review_latch(model);
        return;
    };
    if (!complete or service.stage != .review) {
        clear_lsp_review_latch(model);
        return;
    }
    if (model.palette_open) {
        if (!lsp_review_ready(model, opened)) clear_lsp_review_latch(model);
        return;
    }
    if (!lsp_review_ready(model, opened)) model.lsp_review_presented_at = sdl.SDL_GetTicksNS();
    model.lsp_review_identity = identity;
    model.lsp_review_width = model.layout.width;
    model.lsp_review_height = model.layout.height;
}

fn consume_lsp_picker(model: *Model, current: *Opened, window: *sdl.SDL_Window, redraw: *bool) void {
    if (!model.lsp_picker_pending) return;
    const service = current.lsp orelse return;
    const job = if (current.lsp_job) |*value| value else return;
    switch (model.lsp_picker.take(job.io)) {
        .pending => {},
        .cancelled => {
            model.lsp_picker_pending = false;
            model.status = "LANGUAGE-SERVER PICKER CANCELLED | server not started";
            redraw.* = true;
        },
        .failed => {
            model.lsp_picker_pending = false;
            model.status = "LANGUAGE-SERVER PICKER FAILED | server not started";
            redraw.* = true;
        },
        .selected => |path| {
            if (!model.lsp_picking_workspace) {
                service.choose_executable(path) catch |err| {
                    model.lsp_picker_pending = false;
                    model.status = @errorName(err);
                    redraw.* = true;
                    return;
                };
                model.lsp_picking_workspace = true;
                model.lsp_picker.show(.open_folder, window);
                model.status = "LANGUAGE-SERVER WORKSPACE PICKER OPEN | server not started";
                redraw.* = true;
                return;
            }
            clear_lsp_review_latch(model);
            service.choose_workspace(path, current.destination, current.active.result()) catch |err| {
                model.lsp_picker_pending = false;
                model.status = @errorName(err);
                redraw.* = true;
                return;
            };
            model.lsp_picker_pending = false;
            current.lsp_job.?.start_review() catch |err| {
                model.status = @errorName(err);
                redraw.* = true;
                return;
            };
            model.status = "LANGUAGE-SERVER REVIEWING | readonly executable hash | server not started";
            redraw.* = true;
        },
    }
}

fn consume_lsp_job(model: *Model, current: *Opened, redraw: *bool) void {
    const job = if (current.lsp_job) |*value| value else return;
    const view = job.view();
    if (view.state == .idle or view.state == .working) return;
    job.join();
    switch (view.state) {
        .reviewed => {
            clear_lsp_review_latch(model);
            model.status = "LANGUAGE-SERVER REVIEW READY | inspect exact executable, workspace, and identity before Confirm";
        },
        .started => {
            model.lsp_synced_generation = job.result_generation;
            model.status = "LANGUAGE SERVER ATTACHED | snapshot opened; subsequent edits synchronizing";
        },
        .revoked => model.status = "LANGUAGE SERVER DETACHED | process reaped | trust revoked",
        .failed => {
            if (current.lsp) |service| {
                service.stage = .failed;
                service.failure = view.failure;
            }
            model.status = @errorName(view.failure orelse error.Unexpected);
        },
        .idle, .working => unreachable,
    }
    job.state = .idle;
    redraw.* = true;
}

fn consume_lsp_publications(model: *Model, current: *Opened, redraw: *bool) void {
    if (lsp_job_working(current)) return;
    const service = current.lsp orelse return;
    if (service.stage != .ready or model.lsp_synced_generation != current.active.generation) return;
    for (0..@import("../lsp/client.zig").max_results) |_| {
        const publication = service.poll() orelse break;
        const amount = @min(publication.json.len, model.lsp_text.len);
        @memcpy(model.lsp_text[0..amount], publication.json[0..amount]);
        model.lsp_text_len = amount;
        if (publication.capability == .definition or publication.capability == .references or publication.capability == .document_symbol) {
            model.lsp_navigation_open = service.storage.navigation.count > 0;
            model.lsp_navigation_selected = 0;
            if (service.navigation_error) |err| {
                model.status = if (err == error.NavigationCapacity) "LSP target capacity exceeded; result bytes preserved" else @errorName(err);
                redraw.* = true;
                continue;
            }
            if (service.storage.navigation.count == 0) {
                model.status = "LSP navigation | no current result targets";
                model.lsp_text_len = 0;
                redraw.* = true;
                continue;
            }
        }
        if (publication.capability == .diagnostics) {
            set_lsp_diagnostics_status(model, service.diagnostics);
        } else {
            model.status = switch (publication.capability) {
                .hover => "LSP HOVER | current result version | response below",
                .definition => "LSP DEFINITION | current result version | targets reviewed below",
                .references => "LSP REFERENCES | current result version | targets reviewed below",
                .document_symbol => "LSP DOCUMENT SYMBOLS | current result version | response below",
                .diagnostics => unreachable,
            };
        }
        redraw.* = true;
    }
    if (service.storage.worker.failed()) |failure| {
        clear_failed_lsp_presentation(model, service, failure);
        redraw.* = true;
    }
}

fn clear_failed_lsp_presentation(model: *Model, service: *ui_lsp.Service, failure: anyerror) void {
    model.lsp_synced_generation = null;
    model.lsp_text_len = 0;
    model.lsp_status_len = 0;
    model.lsp_navigation_open = false;
    model.lsp_navigation_selected = 0;
    service.diagnostics = 0;
    service.diagnostics_version = null;
    service.navigation_error = null;
    service.storage.navigation.count = 0;
    service.stage = .failed;
    service.failure = failure;
    model.status = @errorName(failure);
    std.debug.assert(service.stage == .failed and model.lsp_text_len == 0);
}

fn handle_lsp_navigation(event: *const sdl.SDL_Event, model: *Model, current: *Opened) ?bool {
    if (lsp_job_working(current) or current.lsp == null) return true;
    const service = current.lsp.?;
    const navigation = &service.storage.navigation;
    if (navigation.count == 0 or navigation.version != service.version or model.lsp_synced_generation != current.active.generation) {
        model.lsp_navigation_open = false;
        model.status = "LSP navigation expired after result change";
        return true;
    }
    if (event.type == sdl.SDL_EVENT_TEXT_INPUT) return true;
    if (event.type == sdl.SDL_EVENT_KEY_DOWN) {
        const key = event.key.key;
        if (key == sdl.SDLK_P and event.key.mod & sdl.SDL_KMOD_CTRL != 0) {
            model.lsp_navigation_open = false;
            return null;
        }
        if (key == sdl.SDLK_ESCAPE) model.lsp_navigation_open = false;
        if (key == sdl.SDLK_UP) model.lsp_navigation_selected -|= 1;
        if (key == sdl.SDLK_DOWN) model.lsp_navigation_selected = @min(model.lsp_navigation_selected + 1, navigation.count - 1);
        if (key == sdl.SDLK_RETURN) navigate_lsp_selection(model, current);
        return true;
    }
    if (event.type == sdl.SDL_EVENT_MOUSE_BUTTON_DOWN and event.button.button == sdl.SDL_BUTTON_LEFT) {
        const x = event.button.x * model.mouse_scale_x;
        const y = event.button.y * model.mouse_scale_y;
        if (x >= 8 and x < model.layout.width - 8 and y >= 48 and y < 48 + 14 * @as(f32, @floatFromInt(@min(8, navigation.count)))) {
            const row: usize = @intFromFloat((y - 48) / 14);
            const index = (model.lsp_navigation_selected / 8) * 8 + row;
            if (index < navigation.count) {
                model.lsp_navigation_selected = index;
                navigate_lsp_selection(model, current);
            }
            return true;
        }
        model.lsp_navigation_open = false;
    }
    return null;
}

fn navigate_lsp_selection(model: *Model, current: *Opened) void {
    const service = current.lsp orelse return;
    if (model.editor == null) {
        model.status = "LSP navigation unavailable for read-only byte review";
        return;
    }
    const range = service.storage.navigation.selection(model.lsp_navigation_selected, service.uri(), service.version, current.active.result()) catch |err| {
        model.status = if (err == error.ExternalTargetUnsupported) "External target requires a validated workspace view; no file opened" else @errorName(err);
        return;
    };
    model.editor.?.anchor = range.start;
    model.editor.?.cursor = range.end;
    model.focus = 1;
    model.lsp_navigation_open = false;
    scroll_to_editor(model, current);
    model.status = "LSP navigation selected current result range; bytes unchanged";
}

fn render_lsp_navigation(renderer: *sdl.SDL_Renderer, model: *const Model, current: *const Opened) !void {
    const service = current.lsp orelse return;
    const navigation = &service.storage.navigation;
    const first = (model.lsp_navigation_selected / 8) * 8;
    if (first >= navigation.count) return;
    const last = @min(first + 8, navigation.count);
    var panel = sdl.SDL_FRect{ .x = 8, .y = 32, .w = @max(0, model.layout.width - 16), .h = 18 + 14 * @as(f32, @floatFromInt(last - first)) };
    try color(renderer, 43, 48, 62);
    if (!sdl.SDL_RenderFillRect(renderer, &panel)) return error.RenderFailed;
    try color(renderer, 240, 242, 250);
    try debug_text(renderer, 12, 34, "LSP targets | arrows / Enter / click | Esc closes | external targets disabled");
    for (navigation.items[first..last], first..) |item, index| {
        var buffer: [256]u8 = undefined;
        const external = !std.mem.eql(u8, item.uri[0..item.uri_len], service.uri());
        const label = try std.fmt.bufPrint(&buffer, "{s} {s} {d}:{d} {s}{s}", .{
            if (index == model.lsp_navigation_selected) ">" else " ", item.label[0..item.label_len],
            @as(u64, item.start.line) + 1,                            @as(u64, item.start.character) + 1,
            if (external) "[external] " else "",                      item.uri[0..@min(96, item.uri_len)],
        });
        try debug_text(renderer, 12, 48 + 14 * @as(f32, @floatFromInt(index - first)), label);
    }
}

fn set_lsp_diagnostics_status(model: *Model, count: usize) void {
    const text = std.fmt.bufPrint(&model.lsp_status, "LSP DIAGNOSTICS | {d} current document version", .{count}) catch unreachable;
    model.lsp_status_len = text.len;
    model.status = model.lsp_status[0..model.lsp_status_len];
    std.debug.assert(model.lsp_status_len > 0);
}

fn sync_lsp_result(model: *Model, current: *Opened) void {
    if (lsp_job_working(current)) return;
    const service = current.lsp orelse return;
    if (service.stage != .ready or model.lsp_synced_generation == current.active.generation) return;
    model.lsp_text_len = 0;
    model.lsp_navigation_open = false;
    service.change(current.active.result()) catch |err| {
        model.status = if (err == error.CapacityExceeded) "LSP OUT OF SYNC | command queue exhausted | result preserved" else @errorName(err);
        return;
    };
    model.lsp_synced_generation = current.active.generation;
}

fn lsp_action_reason(current: *const Opened, capability: @import("../lsp/protocol.zig").Capability) ?[]const u8 {
    const service = current.lsp orelse return "Attach and confirm a result language server first.";
    if (service.stage != .ready) return "Attach and confirm a result language server first.";
    if (!service.storage.worker.supports(capability)) return "Attached server did not advertise this capability.";
    return null;
}

fn request_lsp_action(model: *Model, current: *Opened, capability: @import("../lsp/protocol.zig").Capability) void {
    if (model.lsp_synced_generation != current.active.generation) {
        model.status = "LSP OUT OF SYNC | wait for current result synchronization";
        return;
    }
    const state = model.editor orelse {
        model.status = "LSP ACTION UNAVAILABLE | result is not valid UTF-8 editor text";
        return;
    };
    const source = current.active.result();
    const range = state.replacement_range(source);
    const position = lsp_position(source, current.lines[1], range.start);
    current.lsp.?.request(capability, position) catch |err| {
        model.status = @errorName(err);
        return;
    };
    model.status = switch (capability) {
        .hover => "LSP HOVER REQUESTED | current result caret",
        .document_symbol => "LSP SYMBOLS REQUESTED | current result document",
        .definition => "LSP DEFINITION REQUESTED | current result caret",
        .references => "LSP REFERENCES REQUESTED | current result caret",
        .diagnostics => unreachable,
    };
}

/// LSP positions count UTF-16 code units, unlike editor display columns with expanded tabs.
fn lsp_position(source: []const u8, lines: Lines, offset: usize) @import("../lsp/protocol.zig").Position {
    std.debug.assert(offset <= source.len);
    const line = line_for_offset(lines, offset);
    const line_start = lines.offsets[line];
    std.debug.assert(line_start <= offset and offset <= source.len);
    const character = utf16_column(source[line_start..offset]);
    std.debug.assert(character <= offset - line_start);
    return .{ .line = @intCast(line), .character = @intCast(character) };
}

fn utf16_column(prefix: []const u8) usize {
    std.debug.assert(std.unicode.utf8ValidateSlice(prefix));
    var count: usize = 0;
    var iterator = (std.unicode.Utf8View.init(prefix) catch unreachable).iterator();
    while (iterator.nextCodepoint()) |codepoint| count += if (codepoint > 0xffff) 2 else 1;
    return count;
}

test "LSP position columns count UTF-16 code units" {
    try std.testing.expectEqual(@as(usize, 4), utf16_column("aé😀"));
    try std.testing.expectEqual(@as(usize, 0), utf16_column(""));
}

fn consume_recovery_picker(model: *Model, current: *Opened, _: *sdl.SDL_Window, redraw: *bool) void {
    if (!model.recovery_picker_pending or !current.recovery_initialized) return;
    switch (model.recovery_picker.take(current.recovery.io)) {
        .pending => {},
        .cancelled => {
            model.recovery_picker_pending = false;
            model.status = "RECOVERY EXPORT CANCELLED | current draft unchanged";
            redraw.* = true;
        },
        .failed => {
            model.recovery_picker_pending = false;
            model.status = "RECOVERY PICKER FAILED | current draft unchanged";
            redraw.* = true;
        },
        .selected => |destination| {
            const state = current.active.current_state();
            const identity = current.active.identity();
            const value: recovery.Record = .{ .mode = current.active.mode, .generation = identity.generation, .identity = identity.inputs, .source_paths = .{ .base = current.input_paths.base, .left = current.input_paths.left, .right = current.input_paths.right }, .result = current.active.result(), .origin = state.origin, .reviewed = state.reviewed, .unresolved = state.unresolved, .engine = .{ .name = identity.engine.name, .version = identity.engine.version }, .provenance = "manual encrypted recovery export" };
            current.recovery.request(destination, value) catch |err| {
                model.status = @errorName(err);
                model.recovery_picker_pending = false;
                redraw.* = true;
                return;
            };
            model.recovery_picker_pending = false;
            model.recovery_observed = false;
            model.status = "RECOVERY EXPORT IN PROGRESS | immutable DPAPI snapshot | new file only";
            redraw.* = true;
        },
    }
}

fn consume_recovery_result(model: *Model, current: *Opened, redraw: *bool) void {
    if (!current.recovery_initialized or model.recovery_observed) return;
    switch (current.recovery.observe()) {
        .idle, .pending => {},
        .succeeded => {
            model.recovery_observed = true;
            model.status = "RECOVERY EXPORTED DURABLY | encrypted DPAPI draft | manual export only";
            redraw.* = true;
        },
        .failed => |err| {
            model.recovery_observed = true;
            model.status = @errorName(err);
            redraw.* = true;
        },
    }
}

fn consume_auto_recovery_result(model: *Model, current: *Opened, redraw: *bool) void {
    if (!current.auto_recovery_initialized) return;
    const status = current.auto_recovery.status();
    if (model.auto_recovery_state != null and model.auto_recovery_state.? == status.state) return;
    model.auto_recovery_state = status.state;
    model.status = switch (status.state) {
        .idle => "RECOVERY READY | waiting for first edit",
        .pending => "RECOVERY PENDING | encrypted DPAPI snapshot due within 500 ms",
        .publishing => "RECOVERY WRITING | encrypted DPAPI snapshot",
        .healthy => "RECOVERY DURABLE | encrypted DPAPI draft retained",
        .degraded => "RECOVERY FAILED | crash-loss guarantee unavailable | editor remains usable",
        .cancelled => "RECOVERY CANCELLED | prior encrypted draft retained",
    };
    redraw.* = true;
}

fn consume_save_result(model: *Model, current: *Opened, redraw: *bool) void {
    const identity = current.active.identity();
    const observed = current.save.observe();
    if (observed.kind != .save) return;
    switch (observed.result) {
        .idle, .pending => {},
        .succeeded => |receipt| {
            if (model.observed_save_generation != null and model.observed_save_generation.? == observed.generation) return;
            model.observed_save_generation = observed.generation;
            if (observed.generation != identity.generation or !std.meta.eql(observed.identity, identity.inputs)) {
                model.durable_generation = null;
                model.durable_receipt = null;
                model.status = "STALE SAVE PUBLISHED | destination retained; review or recover bytes before saving current result";
            } else if (!receipt_matches(receipt, current.active.result())) {
                model.durable_generation = null;
                model.durable_receipt = null;
                model.status = "SAVE RECEIPT REJECTED | bytes differ from current result";
            } else {
                model.durable_generation = identity.generation;
                model.durable_receipt = receipt;
                model.status = "SAVED DURABLY | new file only | Complete verifies current output";
            }
            redraw.* = true;
        },
        .failed => |err| {
            if (model.observed_save_generation != null and model.observed_save_generation.? == observed.generation) return;
            model.observed_save_generation = observed.generation;
            model.durable_generation = null;
            model.durable_receipt = null;
            model.status = if (observed.generation != identity.generation or !std.meta.eql(observed.identity, identity.inputs))
                "STALE SAVE FAILED | current result remains unsaved; retry Save after reviewing destination"
            else if (err == error.PublishedNotDurable)
                "SAVE FAILED: PublishedNotDurable | destination retained for recovery; unresolved"
            else
                @errorName(err);
            redraw.* = true;
        },
    }
}

fn consume_completion_result(model: *Model, current: *Opened, redraw: *bool) void {
    const job_id = model.completion_job_id orelse return;
    const observed = current.save.observe();
    if (observed.kind != .verify or observed.id != job_id) return;
    switch (observed.result) {
        .idle, .pending => {},
        .succeeded => |receipt| {
            model.completion_job_id = null;
            if (observed.generation == current.active.generation and std.meta.eql(observed.identity, current.active.input_identity) and model_has_durable_receipt(model, current) and model.durable_receipt != null and std.meta.eql(receipt, model.durable_receipt.?)) {
                model.completed = true;
                request_exit_drain(model, current);
                if (model.exit_requested) model.status = "COMPLETE VERIFIED | exit draining language-server teardown";
            } else {
                model.durable_generation = null;
                model.durable_receipt = null;
                model.status = "COMPLETE VERIFY STALE | Save current result again";
            }
            redraw.* = true;
        },
        .failed => |err| {
            model.completion_job_id = null;
            model.durable_generation = null;
            model.durable_receipt = null;
            model.status = if (err == error.OutputChanged) "COMPLETE VERIFY FAILED | output changed or was deleted; output retained" else if (err == error.InputChanged) "COMPLETE VERIFY FAILED | source changed; output retained" else @errorName(err);
            redraw.* = true;
        },
    }
}

fn receipt_matches(receipt: @import("../output.zig").Receipt, bytes: []const u8) bool {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return receipt.bytes_written == bytes.len and std.mem.eql(u8, &receipt.digest, &digest);
}

fn session_status(active: *const session.Session) []const u8 {
    const state = active.current_state();
    std.debug.assert(state.written == active.result().len);
    if (active.degradation()) |reason| return switch (reason) {
        .resource_limited => if (state.unresolved) "RESOURCE-LIMITED BYTE REVIEW | no structural or automatic merge claim | unresolved" else "RESOURCE-LIMITED BYTE REVIEW | no structural or automatic merge claim",
        .ambiguous_alignment => if (state.unresolved) "AMBIGUOUS BYTE REVIEW | no structural or automatic merge claim | unresolved" else "AMBIGUOUS BYTE REVIEW | no structural or automatic merge claim",
        .json_malformed => if (state.unresolved) "JSON MALFORMED | exact byte review | unresolved" else "JSON MALFORMED | exact byte review",
        .json_unsupported_root => if (state.unresolved) "JSON ROOT UNSUPPORTED | exact byte review | unresolved" else "JSON ROOT UNSUPPORTED | exact byte review",
        .json_duplicate_key => if (state.unresolved) "JSON DUPLICATE KEY | exact byte review | unresolved" else "JSON DUPLICATE KEY | exact byte review",
        .json_member_set_changed => if (state.unresolved) "JSON MEMBER SET CHANGED | exact byte review | unresolved" else "JSON MEMBER SET CHANGED | exact byte review",
        .json_member_order_changed => if (state.unresolved) "JSON MEMBER ORDER CHANGED | exact byte review | unresolved" else "JSON MEMBER ORDER CHANGED | exact byte review",
        .json_ambiguous_formatting => if (state.unresolved) "JSON FORMAT CHANGED | exact byte review | unresolved" else "JSON FORMAT CHANGED | exact byte review",
        .zig_malformed_source => if (state.unresolved) "ZIG MALFORMED | exact byte review | unresolved" else "ZIG MALFORMED | exact byte review",
        .zig_unsupported_declaration => if (state.unresolved) "ZIG DECLARATION UNSUPPORTED | exact byte review | unresolved" else "ZIG DECLARATION UNSUPPORTED | exact byte review",
        .zig_duplicate_name => if (state.unresolved) "ZIG DUPLICATE NAME | exact byte review | unresolved" else "ZIG DUPLICATE NAME | exact byte review",
        .zig_declaration_set_changed => if (state.unresolved) "ZIG DECLARATION SET CHANGED | exact byte review | unresolved" else "ZIG DECLARATION SET CHANGED | exact byte review",
        .zig_declaration_order_changed => if (state.unresolved) "ZIG DECLARATION ORDER CHANGED | exact byte review | unresolved" else "ZIG DECLARATION ORDER CHANGED | exact byte review",
        .zig_ambiguous_shell => if (state.unresolved) "ZIG SHELL AMBIGUOUS | exact byte review | unresolved" else "ZIG SHELL AMBIGUOUS | exact byte review",
    };
    return if (state.unresolved) "UNRESOLVED | review required | in-memory only; no disk writes" else "PENDING UNSAVED | new file only; Save required before Complete";
}

fn palette_row(layout: Layout, row: usize) Rect {
    std.debug.assert(row < actions.len);
    std.debug.assert(layout.palette.w >= 0);
    return .{ .x = layout.palette.x + 4, .y = layout.palette.y + 28 + @as(f32, @floatFromInt(row)) * 16, .w = @max(0, layout.palette.w - 8), .h = 16 };
}

fn handle_click(x: f32, y: f32, extend: bool, window: *sdl.SDL_Window, model: *Model, opened: ?*Opened) !bool {
    std.debug.assert(model.selected < actions.len);
    if (model.palette_open) {
        var row: usize = 0;
        for (actions, 0..) |_, index| {
            if (!matches(model, index)) continue;
            const rect = palette_row(model.layout, row);
            row += 1;
            if (model.layout.palette.contains(x, y) and rect.contains(x, y)) {
                // Help must have been presented before execution, even within an event batch.
                request_action(index, model, opened);
                try sync_text_input(window, model);
                return true;
            }
        }
        return false;
    }
    if (lsp_review_mode(opened)) return handle_lsp_review_click(x, y, model, opened);
    for (model.layout.buttons, 0..) |rect, index| if (rect.contains(x, y)) {
        request_action(index, model, opened);
        try sync_text_input(window, model);
        return true;
    };
    for (model.layout.panes, 0..) |rect, index| if (rect.contains(x, y)) {
        model.focus = index;
        if (index == 1) {
            set_editor_cursor_from_mouse(x, y, extend, model, opened);
            model.dragging_result = model.editor != null;
        }
        try sync_text_input(window, model);
        return true;
    };
    std.debug.assert(model.focus < model.scroll.len);
    return false;
}

fn set_editor_cursor_from_mouse(x: f32, y: f32, extend: bool, model: *Model, opened: ?*const Opened) void {
    const current = opened orelse return;
    var state = model.editor orelse return;
    const rect = model.layout.panes[1];
    const lines = current.lines[1];
    const clamped_y = std.math.clamp(y, rect.y + 40, @max(rect.y + 40, rect.y + rect.h - 1));
    const row: usize = @intFromFloat(@max(0, @floor((clamped_y - (rect.y + 40)) / row_height)));
    const line = @min(lines.count - 1, model.scroll[1].line + row);
    const start = lines.offsets[line];
    const source = current.active.result();
    const cell: usize = @as(usize, @intFromFloat(@max(0, @floor((x - (rect.x + 2)) / glyph_width)))) + model.scroll[1].column;
    state.cursor = editor.offset_for_column(source, start, cell);
    if (!extend) state.anchor = state.cursor;
    state.clamp(source);
    model.editor = state;
    model.status = if (extend) "RESULT SELECTION | Shift-click extended" else "RESULT CURSOR | mouse selection anchor";
}

fn update_drag_selection(x: f32, y: f32, model: *Model, opened: ?*const Opened) void {
    const current = opened orelse return;
    const rect = model.layout.panes[1];
    if (y < rect.y + 40) scroll_view(model, opened, -3, 0) else if (y >= rect.y + rect.h) scroll_view(model, opened, 3, 0);
    set_editor_cursor_from_mouse(x, y, true, model, opened);
    model.status = "RESULT SELECTION | drag";
    std.debug.assert(model.scroll[1].line < current.lines[1].count);
}

fn scroll_to_editor(model: *Model, current: *const Opened) void {
    const state = model.editor orelse return;
    const source = current.active.result();
    const line = line_for_offset(current.lines[1], state.cursor);
    const rows: usize = @intFromFloat(@max(1, @floor((model.layout.panes[1].h - 50) / row_height)));
    if (line < model.scroll[1].line) model.scroll[1].line = line else if (line >= model.scroll[1].line + rows) model.scroll[1].line = line - rows + 1;
    const start = current.lines[1].offsets[line];
    const column = editor.column_for_offset(source, start, state.cursor);
    const cells: usize = @intFromFloat(@max(1, @floor((model.layout.panes[1].w - 4) / glyph_width)));
    if (column < model.scroll[1].column) model.scroll[1].column = column else if (column >= model.scroll[1].column + cells) model.scroll[1].column = column - cells + 1;
    std.debug.assert(model.scroll[1].line < current.lines[1].count);
}

fn scroll_view(model: *Model, opened: ?*const Opened, rows: f32, columns: f32) void {
    std.debug.assert(model.focus < model.scroll.len);
    const current = opened orelse return;
    const view = &model.scroll[model.focus];
    const max_line = current.lines[model.focus].count - 1;
    view.line = shifted(view.line, rows, max_line);
    // A byte expands to at most four cells; all source columns remain reachable.
    view.column = shifted(view.column, columns, input_capacity * 4);
    std.debug.assert(view.line <= max_line);
    std.debug.assert(view.column <= input_capacity * 4);
}

fn shifted(value: usize, delta: f32, maximum: usize) usize {
    std.debug.assert(value <= maximum);
    std.debug.assert(std.math.isFinite(delta));
    const result: usize = @intFromFloat(@max(0, @min(@as(f32, @floatFromInt(maximum)), @as(f32, @floatFromInt(value)) + delta)));
    std.debug.assert(result <= maximum);
    return result;
}

fn render_launcher(renderer: *sdl.SDL_Renderer, model: *const Model, launcher: *Launcher) !void {
    if (!sdl.SDL_SetRenderScale(renderer, 2, 2)) return error.RenderFailed;
    try color(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderClear(renderer)) return error.RenderFailed;
    try color(renderer, 230, 235, 244);
    try debug_text(renderer, 4, 4, "warkocz | welcome | Ctrl+P action search");
    try debug_text(renderer, 4, 18, launcher.status);
    var buffer: [192]u8 = undefined;
    for (launcher_actions, model.layout.buttons[0..launcher_action_count], 0..) |info, rect, index| {
        try color(renderer, if (index == launcher.selected) 66 else 40, 48, 66);
        var box = rect.sdl_rect();
        if (!sdl.SDL_RenderFillRect(renderer, &box)) return error.RenderFailed;
        try color(renderer, if (launcher_disabled_reason(launcher, index) == null) 240 else 170, 240, 250);
        const label = try std.fmt.bufPrint(&buffer, "{s} [{s}]{s}", .{ info.name, info.binding, if (launcher_disabled_reason(launcher, index) == null) "" else " [!]" });
        try debug_text(renderer, rect.x + 2, rect.y + 3, label);
    }
    const selected = launcher_actions[launcher.selected];
    if (launcher.discovery) |*job| {
        const view = job.view();
        if (view.state == .ready) {
            var row: usize = 0;
            while (row < view.outcome.count and row < 8) : (row += 1) {
                const candidate = job.candidates[row];
                var detail: [128]u8 = undefined;
                const confirming = if (launcher.forget_confirmation) |pending| same_candidate(pending, candidate) else false;
                const text = try std.fmt.bufPrint(&detail, "{s} | generation {d} | {d} result bytes{s}{s}", .{ candidate.session_name[0..], candidate.generation, candidate.result_len, if (row == launcher.discovery_selected) " | selected" else "", if (confirming) " | CONFIRM DELETE" else "" });
                try color(renderer, 230, 235, 244);
                try debug_text(renderer, 4, model.layout.buttons[launcher_action_count - 1].y + 48 + @as(f32, @floatFromInt(row)) * 12, text);
            }
        }
    }
    try color(renderer, 230, 235, 244);
    try debug_text(renderer, 4, model.layout.buttons[launcher_action_count - 1].y + 18, selected.help);
    try debug_text(renderer, 4, model.layout.buttons[launcher_action_count - 1].y + 30, launcher_disabled_reason(launcher, launcher.selected) orelse "Click/key selects; repeat click/key or Enter executes after help.");
    try debug_text(renderer, 4, model.layout.panes[0].y, "OS picker interaction is manual. Injected tests cover only SDL routing and copied callback results.");
    try debug_text(renderer, 4, model.layout.panes[0].y + 14, "Forget selected encrypted draft: click action, X, or Ctrl+P; repeat X/action to confirm; Esc cancels.");
    try debug_text(renderer, 4, model.layout.panes[0].y + 28, "Picker-pending close is blocked: dismiss picker first so callback state stays valid.");
    if (launcher.palette_open) {
        var palette = model.layout.palette.sdl_rect();
        try color(renderer, 43, 48, 62);
        if (!sdl.SDL_RenderFillRect(renderer, &palette)) return error.RenderFailed;
        try color(renderer, 240, 242, 250);
        try debug_text(renderer, palette.x + 4, palette.y + 2, "ACTION PALETTE | arrows | Enter | Esc");
        try debug_text(renderer, palette.x + 4, palette.y + 14, launcher.query[0..launcher.query_len]);
        var row: usize = 0;
        for (launcher_actions, 0..) |info, index| {
            if (!launcher_matches(launcher, index)) continue;
            const y = palette.y + 30 + @as(f32, @floatFromInt(row)) * 30;
            try debug_text(renderer, palette.x + 4, y, if (index == launcher.selected) ">" else " ");
            try debug_text(renderer, palette.x + 16, y, info.name);
            try debug_text(renderer, palette.x + 16, y + 12, info.help);
            if (launcher_disabled_reason(launcher, index)) |reason| try debug_text(renderer, palette.x + 16, y + 22, reason);
            row += 1;
        }
    }
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
}

fn render(renderer: *sdl.SDL_Renderer, model: *Model, opened: ?*const Opened) !void {
    std.debug.assert(model.focus < model.scroll.len);
    std.debug.assert((opened == null) == (model.mode == .welcome));
    var complete_lsp_review = false;
    if (!sdl.SDL_SetRenderScale(renderer, 2, 2)) return error.RenderFailed;
    try color(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderClear(renderer)) return error.RenderFailed;
    try color(renderer, 230, 235, 244);
    try debug_text(renderer, 4, 4, "warkocz | Ctrl+P substring actions | ASCII diagnostic byte-view");
    try debug_text(renderer, 4, 18, model.status);
    try render_buttons(renderer, model, opened);
    if (opened) |current| {
        try render_session(renderer, model, current);
    } else {
        try debug_text(renderer, 4, model.layout.panes[0].y, "Welcome: D open two-way comparison | M open three-way merge | R open repository actions.");
        try debug_text(renderer, 4, model.layout.panes[0].y + 14, "Each source picker is read-only. Output picker chooses a NEW filename; existing files never replace.");
        try debug_text(renderer, 4, model.layout.panes[0].y + 28, "Repository picker also requires explicit installed Git executable; no relative repository executable lookup.");
    }
    try color(renderer, 230, 235, 244);
    try debug_text(renderer, 4, @max(0, model.layout.height - 24), "Tab focus | arrows/Pg/wheel scroll | action key selects; repeat executes");
    try debug_text(renderer, 4, @max(0, model.layout.height - 12), "LF rows; tab=4 cells; CR/control/nonASCII=\\xHH; horizontal clipping");
    if (opened) |current| complete_lsp_review = try render_lsp_review(renderer, model, current);
    if (model.palette_open) try render_palette(renderer, model, opened);
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
    if (opened) |current| latch_lsp_review(model, current, complete_lsp_review);
}

fn review_text_rows(value: []const u8, columns: usize) usize {
    std.debug.assert(columns > 0);
    var cells: usize = 0;
    for (value) |byte| cells += if (byte == '\t') 4 - cells % 4 else if (byte >= 32 and byte <= 126) 1 else 4;
    return @max(@as(usize, 1), (cells + columns - 1) / columns);
}

fn render_review_text(renderer: *sdl.SDL_Renderer, x: f32, y: *f32, value: []const u8, columns: usize) !void {
    std.debug.assert(columns > 0 and columns <= 256);
    const rows = review_text_rows(value, columns);
    var line: [256]u8 = undefined;
    for (0..rows) |row| {
        const length = diagnostic_line(value, row * columns, line[0..columns]);
        try debug_text(renderer, x, y.*, line[0..length]);
        y.* += row_height;
    }
}

const ReviewControls = struct { confirm: Rect, cancel: Rect };

fn review_columns(width: f32) ?usize {
    std.debug.assert(width >= 0);
    if (width <= 16) return null;
    const columns: usize = @intFromFloat(@floor((width - 16) / glyph_width));
    return if (columns == 0) null else @min(columns, 256);
}

fn review_controls(layout: Layout, rows: usize) ?ReviewControls {
    const content_height: f32 = @floatFromInt(rows * row_height);
    if (layout.width < 168 or layout.height < content_height + 30) return null;
    return .{ .confirm = .{ .x = 8, .y = layout.height - 20, .w = 72, .h = 14 }, .cancel = .{ .x = 88, .y = layout.height - 20, .w = 72, .h = 14 } };
}

fn review_rows(service: *const ui_lsp.Service, executable_hash: []const u8, workspace_identity: []const u8, columns: usize) usize {
    return review_text_rows("LANGUAGE SERVER TRUST REVIEW | server has not started", columns) +
        review_text_rows("WARNING: server and project tooling may execute with your user permissions.", columns) +
        review_text_rows("Exact executable:", columns) + review_text_rows(service.executable(), columns) +
        review_text_rows("Exact workspace:", columns) + review_text_rows(service.storage.workspace[0..service.workspace_len], columns) +
        review_text_rows(executable_hash, columns) + review_text_rows(workspace_identity, columns) +
        review_text_rows("Confirm only with fresh Enter/click after this complete review.", columns);
}

fn render_lsp_review(renderer: *sdl.SDL_Renderer, model: *const Model, opened: *const Opened) !bool {
    if (lsp_job_working(opened)) return false;
    const service = opened.lsp orelse return false;
    if (service.stage != .review) {
        if (model.lsp_navigation_open) try render_lsp_navigation(renderer, model, opened) else if (model.lsp_text_len > 0) try debug_text(renderer, 4, 32, model.lsp_text[0..model.lsp_text_len]);
        return false;
    }
    var backdrop = (Rect{ .x = 0, .y = 0, .w = model.layout.width, .h = model.layout.height }).sdl_rect();
    try color(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderFillRect(renderer, &backdrop)) return error.RenderFailed;
    const identity = service.identity orelse return render_review_refusal(renderer, model, "Trust review unavailable; server remains stopped.");
    const columns = review_columns(model.layout.width) orelse return render_review_refusal(renderer, model, "Trust review needs a wider window; server remains stopped.");
    var hash: [128]u8 = undefined;
    const executable_hash = try std.fmt.bufPrint(&hash, "observed executable sha256={x}", .{identity.executable});
    var workspace_hash: [128]u8 = undefined;
    const workspace_identity = try std.fmt.bufPrint(&workspace_hash, "observed workspace sha256={x}", .{identity.workspace});
    const controls = review_controls(model.layout, review_rows(service, executable_hash, workspace_identity, columns)) orelse return render_review_refusal(renderer, model, "Trust review needs a larger window; server remains stopped.");
    try color(renderer, 240, 242, 250);
    var y: f32 = 4;
    inline for ([_][]const u8{ "LANGUAGE SERVER TRUST REVIEW | server has not started", "WARNING: server and project tooling may execute with your user permissions.", "Exact executable:" }) |value| try render_review_text(renderer, 8, &y, value, columns);
    try render_review_text(renderer, 8, &y, service.executable(), columns);
    try render_review_text(renderer, 8, &y, "Exact workspace:", columns);
    try render_review_text(renderer, 8, &y, service.storage.workspace[0..service.workspace_len], columns);
    try render_review_text(renderer, 8, &y, executable_hash, columns);
    try render_review_text(renderer, 8, &y, workspace_identity, columns);
    try render_review_text(renderer, 8, &y, "Confirm only with fresh Enter/click after this complete review.", columns);
    try render_review_controls(renderer, controls);
    return true;
}

fn render_review_refusal(renderer: *sdl.SDL_Renderer, model: *const Model, message: []const u8) !bool {
    _ = model;
    try color(renderer, 240, 242, 250);
    try debug_text(renderer, 4, 4, message);
    return false;
}

fn render_review_controls(renderer: *sdl.SDL_Renderer, controls: ReviewControls) !void {
    inline for ([_]struct { rect: Rect, label: []const u8 }{ .{ .rect = controls.confirm, .label = "CONFIRM" }, .{ .rect = controls.cancel, .label = "CANCEL" } }) |control| {
        try color(renderer, 66, 48, 66);
        var box = control.rect.sdl_rect();
        if (!sdl.SDL_RenderFillRect(renderer, &box)) return error.RenderFailed;
        try color(renderer, 240, 242, 250);
        try debug_text(renderer, control.rect.x + 2, control.rect.y + 3, control.label);
    }
}

fn handle_lsp_review_click(x: f32, y: f32, model: *Model, opened: ?*Opened) bool {
    const current = opened orelse return false;
    const service = current.lsp orelse return false;
    const identity = service.identity orelse return false;
    const columns = review_columns(model.layout.width) orelse return false;
    var hash: [128]u8 = undefined;
    const executable_hash = std.fmt.bufPrint(&hash, "observed executable sha256={x}", .{identity.executable}) catch return false;
    var workspace_hash: [128]u8 = undefined;
    const workspace_identity = std.fmt.bufPrint(&workspace_hash, "observed workspace sha256={x}", .{identity.workspace}) catch return false;
    const controls = review_controls(model.layout, review_rows(service, executable_hash, workspace_identity, columns)) orelse return false;
    if (controls.confirm.contains(x, y)) apply_action(action_index(.confirm_result_language_server_trust), model, opened) else if (controls.cancel.contains(x, y)) apply_action(action_index(.detach_result_language_server), model, opened) else return false;
    return true;
}

fn render_buttons(renderer: *sdl.SDL_Renderer, model: *const Model, opened: ?*const Opened) !void {
    std.debug.assert(model.selected < actions.len);
    var buffer: [128]u8 = undefined;
    for (actions, model.layout.buttons, 0..) |info, rect, index| {
        try color(renderer, if (index == model.selected) 66 else 40, 48, 66);
        var box = rect.sdl_rect();
        if (!sdl.SDL_RenderFillRect(renderer, &box)) return error.RenderFailed;
        const disabled = disabled_reason(index, model, opened) != null;
        try color(renderer, if (disabled) 170 else 240, if (disabled) 175 else 240, if (disabled) 185 else 250);
        const label = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ info.name, if (disabled) " [!]" else "" });
        try debug_text(renderer, rect.x + 2, rect.y + 3, label);
    }
    const last = model.layout.buttons[action_count - 1];
    try color(renderer, 230, 235, 244);
    const info = actions[model.selected];
    try debug_text(renderer, 4, last.y + 18, info.help);
    const detail = disabled_reason(model.selected, model, opened) orelse if (info.action == .choose_base) opened.?.labels.base else info.binding;
    try debug_text(renderer, 4, last.y + 30, detail);
    std.debug.assert(last.y >= model.layout.buttons[0].y);
}

fn render_session(renderer: *sdl.SDL_Renderer, model: *const Model, opened: *const Opened) !void {
    const sources = [_][]const u8{ opened.active.inputs.left, opened.active.result(), opened.active.inputs.right };
    const labels = [_][]const u8{ opened.labels.left, opened.labels.output, opened.labels.right };
    const result_role = if (opened.active.current_state().unresolved) engine_label(&opened.active, "RESULT | UNRESOLVED | REVIEW REQUIRED") else engine_label(&opened.active, "RESULT | PENDING UNSAVED | REVIEW STATUS");
    const roles = [_][]const u8{ "LEFT", result_role, "RIGHT" };
    std.debug.assert(model.focus < sources.len);
    for (sources, labels, roles, model.layout.panes, model.scroll, opened.lines, 0..) |source, label, role, rect, scroll, lines, index| {
        const changes = if (index == 0) opened.active.left_changes else if (index == 2) opened.active.right_changes else &.{};
        try render_pane(renderer, source, label, role, rect, scroll, lines, changes, index != 1, index == model.focus, if (index == 1) model.editor else null);
    }
    std.debug.assert(sources[1].len <= result_capacity);
}

/// Engine/version provenance remains visible in the result pane, including byte-review fallback.
fn engine_label(active: *const session.Session, fallback: []const u8) []const u8 {
    const identity = active.identity();
    if (std.mem.eql(u8, identity.engine.name, session.Session.json_engine.name)) return "RESULT | JSON root-object merge v1 | provenance: automatic/source bytes";
    if (std.mem.eql(u8, identity.engine.name, session.Session.zig_engine.name)) return "RESULT | Zig declaration merge v1 | whole-declaration changes | provenance: automatic/source bytes";
    if (std.mem.eql(u8, identity.engine.name, session.Session.degraded_byte_review_engine.name)) return "RESULT | byte review v1 | provenance: unsupported or budget fallback";
    if (std.mem.eql(u8, identity.engine.name, session.Session.multi_hunk_engine.name)) return "RESULT | multihunk v1 | provenance: automatic/source bytes";
    return fallback;
}

fn line_changed(changes: []const @import("../engine/multihunk.zig").Hunk, start: u32, stop: usize, source_is_other: bool) bool {
    const start_usize: usize = start;
    for (changes) |change| {
        const range = if (source_is_other) change.other else change.base;
        if (range.start == range.end) {
            if (range.start == start_usize) return true;
        } else if (range.start < stop and start_usize < range.end) return true;
    }
    return false;
}

fn set_clip(renderer: *sdl.SDL_Renderer, rect: ?Rect) !void {
    if (rect) |value| {
        var clip = sdl.SDL_Rect{ .x = @intFromFloat(value.x), .y = @intFromFloat(value.y), .w = @intFromFloat(value.w), .h = @intFromFloat(value.h) };
        if (!sdl.SDL_SetRenderClipRect(renderer, &clip)) return error.RenderFailed;
    } else if (!sdl.SDL_SetRenderClipRect(renderer, null)) return error.RenderFailed;
}

fn render_pane(renderer: *sdl.SDL_Renderer, source: []const u8, label: []const u8, role: []const u8, rect: Rect, scroll: Scroll, lines: Lines, changes: []const @import("../engine/multihunk.zig").Hunk, source_is_other: bool, focused: bool, editor_state: ?editor.State) !void {
    std.debug.assert(lines.count > 0 and lines.count <= lines.offsets.len);
    std.debug.assert(source.len <= input_capacity);
    std.debug.assert(lines.offsets[0] == 0);
    std.debug.assert(lines.offsets[lines.count - 1] <= source.len);
    try set_clip(renderer, rect);
    defer set_clip(renderer, null) catch {};
    try color(renderer, if (focused) 36 else 29, 35, 48);
    var box = rect.sdl_rect();
    if (!sdl.SDL_RenderFillRect(renderer, &box)) return error.RenderFailed;
    try color(renderer, 235, 239, 250);
    var buffer: [192]u8 = undefined;
    const header = if (editor_state) |state|
        try std.fmt.bufPrint(&buffer, "{s}{s} | {d} lines | cursor {d} sel {d}-{d}", .{ if (focused) ">" else "", role, lines.count, state.cursor, state.selection_start(), state.selection_end() })
    else
        try std.fmt.bufPrint(&buffer, "{s}{s} | {d} lines", .{ if (focused) ">" else "", role, lines.count });
    try debug_text(renderer, rect.x + 2, rect.y + 2, header);
    try debug_text(renderer, rect.x + 2, rect.y + 14, label);
    const first = @min(scroll.line, lines.count - 1);
    const row_count: usize = @intFromFloat(@max(0, @floor((rect.h - 50) / row_height)));
    const end = @min(lines.count, first + @min(row_count, 256));
    const position = try std.fmt.bufPrint(&buffer, "rows {d}-{d}/{d} col {d}", .{ first + 1, end, lines.count, scroll.column + 1 });
    try debug_text(renderer, rect.x + 2, rect.y + 26, position);
    const cells: usize = @intFromFloat(@max(0, @floor((rect.w - 4) / glyph_width)));
    for (first..end) |line| {
        const start = lines.offsets[line];
        const stop = if (line + 1 < lines.count) lines.offsets[line + 1] - 1 else source.len;
        std.debug.assert(start <= stop);
        std.debug.assert(stop <= source.len);
        if (line_changed(changes, start, stop, source_is_other)) {
            try color(renderer, 72, 58, 42);
            var changed = sdl.SDL_FRect{ .x = rect.x + 1, .y = rect.y + 39 + @as(f32, @floatFromInt(line - first)) * row_height, .w = @max(0, rect.w - 2), .h = row_height };
            if (!sdl.SDL_RenderFillRect(renderer, &changed)) return error.RenderFailed;
        }
        if (editor_state) |state| {
            const selection_start = state.selection_start();
            const selection_end = state.selection_end();
            const selected_start = @max(@as(usize, start), selection_start);
            const selected_end = @min(stop, selection_end);
            if (selected_start < selected_end) {
                const left = editor.column_for_offset(source, start, selected_start);
                const right = editor.column_for_offset(source, start, selected_end);
                if (right > scroll.column and left < scroll.column + cells) {
                    try color(renderer, 69, 91, 138);
                    var selected = sdl.SDL_FRect{ .x = rect.x + 2 + @as(f32, @floatFromInt(left -| scroll.column)) * glyph_width, .y = rect.y + 39 + @as(f32, @floatFromInt(line - first)) * row_height, .w = @as(f32, @floatFromInt(@min(right, scroll.column + cells) - @max(left, scroll.column))) * glyph_width, .h = row_height };
                    if (!sdl.SDL_RenderFillRect(renderer, &selected)) return error.RenderFailed;
                }
            }
        }
        try color(renderer, 235, 239, 250);
        var text: [257:0]u8 = undefined;
        const length = diagnostic_line(source[start..stop], scroll.column, text[0..@min(cells, 256)]);
        text[length] = 0;
        if (!sdl.SDL_RenderDebugText(renderer, rect.x + 2, rect.y + 40 + @as(f32, @floatFromInt(line - first)) * row_height, &text)) return error.RenderFailed;
    }
    try debug_text(renderer, rect.x + 2, @max(rect.y + 38, rect.y + rect.h - 10), "clip: scroll rows/cols");
}

// Display-only byte escapes, never written back to source. LF is handled by the line index.
fn diagnostic_line(source: []const u8, first_column: usize, output: []u8) usize {
    std.debug.assert(source.len <= input_capacity);
    std.debug.assert(output.len <= 256);
    var column: usize = 0;
    var written: usize = 0;
    for (source) |byte| {
        var escaped: [4]u8 = undefined;
        const count: usize = if (byte == '\t') 4 - column % 4 else if (byte >= 32 and byte <= 126) 1 else 4;
        if (byte == '\t') @memset(&escaped, ' ') else if (count == 1) escaped[0] = byte else {
            const hex = "0123456789ABCDEF";
            escaped = .{ '\\', 'x', hex[byte >> 4], hex[byte & 15] };
        }
        for (escaped[0..count]) |cell| {
            if (column >= first_column and written < output.len) {
                output[written] = cell;
                written += 1;
            }
            column += 1;
        }
        if (written == output.len) break;
    }
    std.debug.assert(written <= output.len);
    return written;
}

fn render_palette(renderer: *sdl.SDL_Renderer, model: *const Model, opened: ?*const Opened) !void {
    std.debug.assert(model.selected < actions.len);
    std.debug.assert(model.query_len <= model.query.len);
    try set_clip(renderer, model.layout.palette);
    defer set_clip(renderer, null) catch {};
    var box = model.layout.palette.sdl_rect();
    try color(renderer, 43, 48, 62);
    if (!sdl.SDL_RenderFillRect(renderer, &box)) return error.RenderFailed;
    try color(renderer, 240, 242, 250);
    var buffer: [192]u8 = undefined;
    try debug_text(renderer, box.x + 4, box.y + 2, "Substring search | arrows select | Enter executes | Esc closes");
    const query = try std.fmt.bufPrint(&buffer, "> {s}{s}", .{ model.query[0..model.query_len], if (model.query_len == model.query.len) " [query full]" else "" });
    try debug_text(renderer, box.x + 4, box.y + 14, query);
    var row: usize = 0;
    for (actions, 0..) |info, index| {
        if (!matches(model, index)) continue;
        const rect = palette_row(model.layout, row);
        row += 1;
        if (index == model.selected) {
            try color(renderer, 69, 79, 101);
            var selected = rect.sdl_rect();
            if (!sdl.SDL_RenderFillRect(renderer, &selected)) return error.RenderFailed;
        }
        try color(renderer, 240, 242, 250);
        const name = try std.fmt.bufPrint(&buffer, "{s} [{s}]{s}", .{ info.name, info.binding, if (disabled_reason(index, model, opened) != null) " disabled" else "" });
        try debug_text(renderer, rect.x + 2, rect.y + 3, name);
    }
    const y = box.y + 28 + @as(f32, @floatFromInt(row)) * 16;
    try debug_text(renderer, box.x + 4, y + 2, if (row == 0) "No matching action." else actions[model.selected].help);
    if (row > 0) try debug_text(renderer, box.x + 4, y + 14, disabled_reason(model.selected, model, opened) orelse "Click selects; second click/Enter executes.");
    std.debug.assert(row <= actions.len);
}

fn color(renderer: *sdl.SDL_Renderer, red: u8, green: u8, blue: u8) !void {
    if (!sdl.SDL_SetRenderDrawColor(renderer, red, green, blue, 255)) return error.RenderFailed;
}

const ui_font_pixel_size = 12;
const ui_font_cell_width = glyph_width;
const ui_font_row_baseline = 10;

/// Renderer-bound FreeType glyph textures for product text. Textures belong
/// to the SDL renderer, which frees them when it is destroyed; the cache
/// therefore drops (never destroys) textures when the renderer changes.
/// The pool and font bytes live for the process lifetime via the C allocator
/// because SDL keeps the textures alive for the renderer's lifetime.
const UiFont = struct {
    renderer: *sdl.SDL_Renderer,
    rasterizer: glyph_text.Renderer,
    pool: []u8,
    font_bytes: []u8,
    ascent: c_int,
    textures: [glyph_text.slot_count]?CachedGlyphTexture,
    next_eviction: usize,

    fn drop(self: *UiFont) void {
        self.rasterizer.deinit();
        std.heap.c_allocator.free(self.pool);
        std.heap.c_allocator.free(self.font_bytes);
        self.* = undefined;
    }

    fn texture(self: *UiFont, codepoint: u8) !*sdl.SDL_Texture {
        for (self.textures) |maybe| {
            if (maybe) |cached| {
                if (cached.codepoint == codepoint) return cached.texture;
            }
        }
        const glyph = try self.rasterizer.glyph(codepoint);
        const index = self.next_eviction;
        self.next_eviction = (index + 1) % glyph_text.slot_count;
        if (self.textures[index]) |stale| {
            sdl.SDL_DestroyTexture(stale.texture);
        }
        var pixels: [glyph_text.max_glyph_width * glyph_text.max_glyph_rows * 4]u8 = @splat(0);
        std.debug.assert(glyph.width > 0 and glyph.rows > 0 and glyph.pixels.len == @as(usize, glyph.width) * glyph.rows);
        for (0..glyph.rows) |row| {
            for (0..glyph.width) |column| {
                const coverage = glyph.pixels[row * glyph.width + column];
                const target = 4 * (row * glyph_text.max_glyph_width + column);
                pixels[target] = 255;
                pixels[target + 1] = 255;
                pixels[target + 2] = 255;
                pixels[target + 3] = coverage;
            }
        }
        const created = sdl.SDL_CreateTexture(
            self.renderer,
            sdl.SDL_PIXELFORMAT_RGBA8888,
            sdl.SDL_TEXTUREACCESS_STATIC,
            @intCast(glyph.width),
            @intCast(glyph.rows),
        ) orelse return error.RenderFailed;
        if (!sdl.SDL_UpdateTexture(created, null, &pixels, glyph_text.max_glyph_width * 4)) {
            sdl.SDL_DestroyTexture(created);
            return error.RenderFailed;
        }
        if (!sdl.SDL_SetTextureScaleMode(created, sdl.SDL_SCALEMODE_NEAREST)) return error.RenderFailed;
        self.textures[index] = .{ .codepoint = codepoint, .texture = created };
        return created;
    }
};

const CachedGlyphTexture = struct { codepoint: u8, texture: *sdl.SDL_Texture };

var ui_font: ?UiFont = null;
var ui_font_unavailable = false;

/// Loads the developer-provided font once; without WARKOCZ_FONT the product
/// falls back to SDL's debug font. The font is presentation-only and never
/// touches authoritative bytes.
fn ensure_ui_font(renderer: *sdl.SDL_Renderer) void {
    if (ui_font) |*existing| {
        if (existing.renderer == renderer) return;
        existing.drop();
        ui_font = null;
    }
    if (ui_font_unavailable) return;
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const environ: std.process.Environ = .{ .block = .global };
    const font_path = environ.getAlloc(std.heap.c_allocator, "WARKOCZ_FONT") catch return;
    defer std.heap.c_allocator.free(font_path);
    if (font_path.len == 0 or !std.fs.path.isAbsolute(font_path)) {
        ui_font_unavailable = true;
        return;
    }
    const font_bytes = std.Io.Dir.cwd().readFileAlloc(io, font_path, std.heap.c_allocator, .limited(8 << 20)) catch {
        ui_font_unavailable = true;
        return;
    };
    const pool = std.heap.c_allocator.alloc(u8, glyph_text.pool_capacity) catch {
        std.heap.c_allocator.free(font_bytes);
        ui_font_unavailable = true;
        return;
    };
    ui_font = .{
        .renderer = renderer,
        .rasterizer = glyph_text.Renderer.init(pool, font_bytes, ui_font_pixel_size) catch {
            std.heap.c_allocator.free(pool);
            std.heap.c_allocator.free(font_bytes);
            ui_font_unavailable = true;
            return;
        },
        .pool = pool,
        .font_bytes = font_bytes,
        .ascent = ui_font_row_baseline,
        .textures = @splat(null),
        .next_eviction = 0,
    };
}

fn draw_freetype_text(renderer: *sdl.SDL_Renderer, x: f32, y: f32, value: []const u8) !bool {
    ensure_ui_font(renderer);
    const font = &(ui_font orelse return false);
    std.debug.assert(font.renderer == renderer);
    var pen: f32 = 0;
    for (value) |byte| {
        defer pen += ui_font_cell_width;
        if (byte < 0x20 or byte > 0x7e) continue;
        const glyph = font.rasterizer.glyph(byte) catch continue;
        if (glyph.width == 0 or glyph.rows == 0) continue;
        const texture = try font.texture(byte);
        const origin_x = x + pen + @as(f32, @floatFromInt(glyph.left));
        const origin_y = y + @as(f32, @floatFromInt(font.ascent - glyph.top));
        const destination = sdl.SDL_FRect{
            .x = origin_x,
            .y = origin_y,
            .w = @floatFromInt(glyph.width),
            .h = @floatFromInt(glyph.rows),
        };
        if (!sdl.SDL_RenderTexture(renderer, texture, null, &destination)) return error.RenderFailed;
    }
    return true;
}

fn debug_text(renderer: *sdl.SDL_Renderer, x: f32, y: f32, value: []const u8) !void {
    std.debug.assert(std.math.isFinite(x) and std.math.isFinite(y));
    var buffer: [257:0]u8 = undefined;
    const length = diagnostic_line(value[0..@min(value.len, input_capacity)], 0, buffer[0..256]);
    buffer[length] = 0;
    std.debug.assert(length < buffer.len);
    if (try draw_freetype_text(renderer, x, y, buffer[0..length])) return;
    if (!sdl.SDL_RenderDebugText(renderer, x, y, &buffer)) return error.RenderFailed;
}

/// Bounded SDL-event integration only: injected queue events are not OS input acceptance evidence.
pub fn gpu_event_integration_test() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz GPU integration", 640, 380, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [256]u8 = undefined;
    var records: [8]session.Record = undefined;
    var offsets: [3][8]u32 = undefined;
    var opened = Opened{
        .active = try session.Session.init(.{ .base = "base\r\n", .left = "left\r\n", .right = "right\r\n" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
        .labels = .{ .base = "base", .left = "left", .right = "right", .output = "result" },
        .destination = "result",
        .input_paths = .{ .base = "base", .left = "left", .right = "right" },
        .lines = undefined,
        .save = undefined,
    };
    var save_paths: [save.path_storage_capacity]u8 = undefined;
    var save_content: [save.content_capacity]u8 = undefined;
    var save_preflight: [save.content_capacity]u8 = undefined;
    try opened.init_save_with(std.testing.io, &save_paths, &save_content, &save_preflight);
    defer opened.deinit();
    for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    var model = Model{ .mode = .merge, .status = session_status(&opened.active) };
    var running = true;
    var redraw = true;
    try update_layout(renderer, window, &model);
    try render_and_present_help(renderer, &model, &opened);
    const before = try rendered_hash(renderer);
    sdl.SDL_FlushEvents(sdl.SDL_EVENT_FIRST, sdl.SDL_EVENT_LAST);

    model.focus = 0;
    try push_key(sdl.SDLK_L, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try render_and_present_help(renderer, &model, &opened);
    try push_key(sdl.SDLK_L, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("left\r\n", opened.active.result());
    try std.testing.expectEqualStrings("base\r\n", opened.active.inputs.base);
    try std.testing.expectEqualStrings("left\r\n", opened.active.inputs.left);
    try std.testing.expectEqualStrings("right\r\n", opened.active.inputs.right);
    try std.testing.expect(!opened.active.current_state().unresolved);
    try render_and_present_help(renderer, &model, &opened);
    const after_choose = try rendered_hash(renderer);
    try std.testing.expect(before != after_choose);

    try push_key(sdl.SDLK_Z, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try render_and_present_help(renderer, &model, &opened);
    try push_key(sdl.SDLK_Z, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("base\r\n", opened.active.result());
    try push_key(sdl.SDLK_Y, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try render_and_present_help(renderer, &model, &opened);
    try push_key(sdl.SDLK_Y, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("left\r\n", opened.active.result());
    try std.testing.expect(model.editor != null);
    model.focus = 1;
    // Physical text keys precede SDL text events; focused editing must not route X/C/S/M actions.
    try push_key(sdl.SDLK_X, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try push_key(sdl.SDLK_S, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("left\r\n", opened.active.result());
    try std.testing.expect(opened.save.observe().result == .idle);
    try push_text("X");
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("left\r\nX", opened.active.result());
    try push_key(sdl.SDLK_Z, sdl.SDL_KMOD_CTRL);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("left\r\n", opened.active.result());

    try push_key(sdl.SDLK_P, sdl.SDL_KMOD_CTRL);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try push_text("redo");
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expect(model.palette_open);
    try std.testing.expectEqual(Action.redo, actions[model.selected].action);
    try push_key(sdl.SDLK_ESCAPE, 0);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expect(running);
    try std.testing.expect(disabled_reason(7, &model, &opened) == null);
    try std.testing.expect(disabled_reason(8, &model, &opened) != null);
}

/// Real GPU fixture: picker callback copies exact selections, review cannot spawn,
/// confirm starts only generated fake server, edits flow through native events, then revocation reaps it.
pub fn gpu_lsp_fixture_e2e_test(server_executable: []const u8) !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    const absolute_server = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, server_executable, std.testing.allocator);
    defer std.testing.allocator.free(absolute_server);
    if (!std.fs.path.isAbsolute(absolute_server)) return error.InvalidExecutable;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz GUI LSP fixture", 1280, 760, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const temporary = try (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TEMP");
    defer std.testing.allocator.free(temporary);
    if (!std.fs.path.isAbsolute(temporary)) return error.InvalidTempRoot;
    const root = try std.fmt.allocPrint(std.testing.allocator, "{s}/warkocz-lsp-gpu-{x}", .{ temporary, std.Io.Clock.real.now(io).nanoseconds });
    defer std.testing.allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const left_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/left.zig", .{root});
    defer std.testing.allocator.free(left_path);
    const right_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/right.zig", .{root});
    defer std.testing.allocator.free(right_path);
    const output_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/result.zig", .{root});
    defer std.testing.allocator.free(output_path);
    try write_native_file(io, left_path, "const left = 1;\n");
    try write_native_file(io, right_path, "const right = 2;\n");

    var lsp_backing: [@sizeOf(ui_lsp.Storage) + @sizeOf(ui_lsp.Service) + 64]u8 align(@alignOf(ui_lsp.Storage)) = undefined;
    var lsp_arena = std.heap.FixedBufferAllocator.init(&lsp_backing);
    const lsp_storage = try lsp_arena.allocator().create(ui_lsp.Storage);
    const lsp_service = try lsp_arena.allocator().create(ui_lsp.Service);
    lsp_service.init(lsp_storage);
    var result: [128]u8 = undefined;
    var scratch: [128]u8 = undefined;
    var history: [1024]u8 = undefined;
    var records: [16]session.Record = undefined;
    var offsets: [3][32]u32 = undefined;
    var save_paths: [save.path_storage_capacity]u8 = undefined;
    var save_content: [save.content_capacity]u8 = undefined;
    var save_preflight: [save.content_capacity]u8 = undefined;
    var opened = Opened{
        .active = try session.Session.init_two_way("const left = 1;\n", "const right = 2;\n", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
        .labels = .{ .base = "none", .left = "left", .right = "right", .output = "result" },
        .destination = output_path,
        .input_paths = .{ .base = null, .left = left_path, .right = right_path },
        .lines = undefined,
        .save = undefined,
        .lsp = lsp_service,
    };
    opened.lsp_job = .{ .io = io, .service = lsp_service };
    opened.lsp_job.?.init(io, lsp_service);
    try opened.init_save_with(io, &save_paths, &save_content, &save_preflight);
    defer opened.deinit();
    for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    var model = Model{ .mode = .diff, .status = "LSP fixture", .editor = editor.State.init(opened.active.result()), .lsp_picker = .{ .io = io }, .window = window };
    try exercise_lsp_fixture(renderer, window, &model, &opened, absolute_server, root, io);
    try expect_native_file(io, left_path, "const left = 1;\n");
    try expect_native_file(io, right_path, "const right = 2;\n");
    try expect_absent_native_file(io, output_path);
}

fn exercise_lsp_fixture(renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, model: *Model, opened: *Opened, absolute_server: []const u8, root: []const u8, io: std.Io) !void {
    const lsp_service = opened.lsp.?;
    const lsp_storage = lsp_service.storage;
    const service_address = @intFromPtr(lsp_service);
    var running = true;
    var redraw = true;
    try update_layout(renderer, window, model);
    try render_and_present_help(renderer, model, opened);

    apply_action(action_index(.attach_result_language_server), model, opened);
    try std.testing.expect(model.lsp_picker_pending);
    try lsp_fixture_select(&model.lsp_picker, absolute_server);
    consume_lsp_picker(model, opened, window, &redraw);
    try std.testing.expect(model.lsp_picking_workspace and lsp_service.stage == .picking_workspace);
    try lsp_fixture_select(&model.lsp_picker, root);
    consume_lsp_picker(model, opened, window, &redraw);
    try wait_for_lsp_job(model, opened, &redraw, .review);
    try std.testing.expect(lsp_storage.worker.worker_thread == null and lsp_storage.worker.reader_thread == null);
    try std.testing.expect(lsp_service.stage == .review and lsp_service.identity != null and !lsp_storage.state.running);
    // Direct fixture calls cannot authorize before presentation.
    apply_action(action_index(.confirm_result_language_server_trust), model, opened);
    try std.testing.expect(lsp_service.stage == .review and lsp_storage.worker.worker_thread == null);
    try render(renderer, model, opened);
    try std.testing.expect(model.lsp_review_identity != null);
    if (!sdl.SDL_SetWindowSize(window, 200, 100) or !sdl.SDL_SyncWindow(window)) return error.WindowResizeFailed;
    try update_layout(renderer, window, model);
    try render(renderer, model, opened);
    try std.testing.expect(model.lsp_review_identity == null);
    if (!sdl.SDL_SetWindowSize(window, 1280, 760) or !sdl.SDL_SyncWindow(window)) return error.WindowResizeFailed;
    try update_layout(renderer, window, model);
    _ = try drain_events(64, window, model, opened, &running, &redraw);
    try update_layout(renderer, window, model);
    try render(renderer, model, opened);
    const reviewed_identity = lsp_service.identity.?;
    var changed_identity = reviewed_identity;
    changed_identity.executable[0] ^= 1;
    lsp_service.identity = changed_identity;
    model.lsp_confirmation_timestamp = sdl.SDL_GetTicksNS();
    try std.testing.expect(!lsp_review_confirmation_allowed(model, opened));
    model.lsp_confirmation_timestamp = null;
    lsp_service.identity = reviewed_identity;
    try std.testing.expect(model.lsp_review_identity != null);
    try confirm_lsp_fixture(window, model, opened);
    apply_action(action_index(.choose_left), model, opened);
    try wait_for_lsp_job(model, opened, &redraw, .ready);
    try std.testing.expect(model.lsp_synced_generation != opened.active.generation);
    sync_lsp_result(model, opened);
    try std.testing.expectEqual(opened.active.generation, model.lsp_synced_generation.?);
    try wait_for_lsp_capabilities(lsp_service, io);
    try std.testing.expect(@intFromPtr(lsp_service) == service_address);
    try std.testing.expect(lsp_service.storage.worker.supports(.hover));
    try std.testing.expect(lsp_service.storage.worker.supports(.definition));
    try std.testing.expect(lsp_service.storage.worker.supports(.references));
    try std.testing.expect(lsp_service.storage.worker.supports(.document_symbol));
    model.lsp_synced_generation = null;
    sync_lsp_result(model, opened);
    try wait_for_lsp_diagnostics(model, opened, &redraw, io);
    try std.testing.expectEqual(@as(usize, 1), lsp_service.diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, model.status, "1 current") != null);

    model.focus = 1;
    try push_text("X");
    _ = try drain_events(8, window, model, opened, &running, &redraw);
    try std.testing.expect(std.mem.endsWith(u8, opened.active.result(), "X"));
    apply_action(action_index(.choose_left), model, opened);
    model.lsp_synced_generation = null;
    sync_lsp_result(model, opened);

    apply_action(action_index(.hover), model, opened);
    try wait_for_lsp_text(model, opened, &redraw, io, "hover-current");
    try std.testing.expect(std.mem.indexOf(u8, model.lsp_text[0..model.lsp_text_len], "hover-current") != null);
    try verify_lsp_capability_replies(model, opened, &redraw, window, renderer, io);
    lsp_storage.worker.mutex.lockUncancelable(io);
    var teardown_locked = true;
    defer if (teardown_locked) lsp_storage.worker.mutex.unlock(io);
    request_exit_drain(model, opened);
    advance_exit_drain(model, opened, &redraw);
    try std.testing.expect(opened.lsp_job.?.view().state == .working);
    try std.testing.expect(!model.exit_ready);
    try std.testing.expect(@intFromPtr(opened.lsp.?) == service_address);
    var expose_event: sdl.SDL_Event = .{ .window = .{ .type = sdl.SDL_EVENT_WINDOW_EXPOSED } };
    try std.testing.expect(try handle_event(&expose_event, window, model, opened));
    const generation = opened.active.generation;
    apply_action(action_index(.choose_left), model, opened);
    try std.testing.expectEqual(generation, opened.active.generation);
    lsp_storage.worker.mutex.unlock(io);
    teardown_locked = false;
    try wait_for_lsp_job(model, opened, &redraw, .detached);
    advance_exit_drain(model, opened, &redraw);
    try std.testing.expect(model.exit_ready);
    try std.testing.expect(lsp_storage.worker.worker_thread == null and lsp_storage.worker.reader_thread == null and lsp_storage.worker.reader_done);
}

fn confirm_lsp_fixture(window: *sdl.SDL_Window, model: *Model, opened: *Opened) !void {
    const action = action_index(.confirm_result_language_server_trust);
    model.palette_open = true;
    model.selected = action;
    model.help_presented = action;
    var event: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true, .timestamp = model.lsp_review_presented_at } };
    _ = try handle_event(&event, window, model, opened);
    try std.testing.expect(opened.lsp.?.stage == .review);
    event.key.timestamp = @max(sdl.SDL_GetTicksNS(), model.lsp_review_presented_at + 1);
    event.key.repeat = true;
    _ = try handle_event(&event, window, model, opened);
    try std.testing.expect(opened.lsp.?.stage == .review);
    model.palette_open = false;
    const identity = opened.lsp.?.identity.?;
    var hash: [128]u8 = undefined;
    const executable_hash = try std.fmt.bufPrint(&hash, "observed executable sha256={x}", .{identity.executable});
    var workspace_hash: [128]u8 = undefined;
    const workspace_identity = try std.fmt.bufPrint(&workspace_hash, "observed workspace sha256={x}", .{identity.workspace});
    const columns = review_columns(model.layout.width).?;
    const controls = review_controls(model.layout, review_rows(opened.lsp.?, executable_hash, workspace_identity, columns)).?;
    var click: sdl.SDL_Event = .{ .button = .{ .type = sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, .button = sdl.SDL_BUTTON_LEFT, .down = true, .x = (controls.confirm.x + 1) / model.mouse_scale_x, .y = (controls.confirm.y + 1) / model.mouse_scale_y, .timestamp = @max(sdl.SDL_GetTicksNS(), model.lsp_review_presented_at + 1) } };
    _ = try handle_event(&click, window, model, opened);
    const state = opened.lsp_job.?.view().state;
    try std.testing.expect(state == .working or state == .started);
}

fn lsp_fixture_select(state: *dialog.State, path: []const u8) !void {
    const selected = try std.testing.allocator.allocSentinel(u8, path.len, 0);
    defer std.testing.allocator.free(selected);
    @memcpy(selected[0..path.len], path);
    const paths = [_:null]?[*:0]const u8{selected.ptr};
    dialog.State.callback(@ptrCast(state), &paths, 0);
}

fn wait_for_lsp_job(model: *Model, opened: *Opened, redraw: *bool, expected: ui_lsp.Stage) !void {
    for (0..5000) |_| {
        consume_lsp_job(model, opened, redraw);
        const view = opened.lsp_job.?.view();
        if (view.state == .idle and opened.lsp.?.stage == .failed) return view.failure orelse error.Unexpected;
        if (opened.lsp.?.stage == expected and view.state == .idle) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real) catch {};
    }
    return error.LspJobBusy;
}

fn wait_for_lsp_capabilities(service: *ui_lsp.Service, io: std.Io) !void {
    for (0..5000) |_| {
        if (service.storage.worker.supports(.hover)) return;
        if (service.storage.worker.failed()) |failure| return failure;
        std.Io.sleep(io, .fromMilliseconds(1), .real) catch {};
    }
    return error.LspCapabilitiesBusy;
}

fn wait_for_lsp_diagnostics(model: *Model, opened: *Opened, redraw: *bool, io: std.Io) !void {
    for (0..5000) |_| {
        consume_lsp_publications(model, opened, redraw);
        if (opened.lsp.?.diagnostics_version == opened.lsp.?.version) return;
        if (opened.lsp.?.storage.worker.failed()) |failure| return failure;
        std.Io.sleep(io, .fromMilliseconds(1), .real) catch {};
    }
    return error.LspDiagnosticsBusy;
}

fn verify_lsp_capability_replies(model: *Model, opened: *Opened, redraw: *bool, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, io: std.Io) !void {
    const cases = [_]struct { action: Action, expected: []const u8 }{
        .{ .action = .definition, .expected = "file:///other.zig" },
        .{ .action = .references, .expected = "file:///other.zig" },
        .{ .action = .symbols, .expected = "fixture-symbol" },
    };
    for (cases) |case| {
        model.lsp_text_len = 0;
        apply_action(action_index(case.action), model, opened);
        try wait_for_lsp_text(model, opened, redraw, io, case.expected);
        try std.testing.expect(opened.lsp.?.navigation_error == null and model.lsp_navigation_open);
        try render(renderer, model, opened);
        const previous_cursor = model.editor.?.cursor;
        const previous_generation = opened.active.generation;
        try dispatch_navigation_event(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } }, window, model, opened, redraw);
        try std.testing.expectEqual(previous_generation, opened.active.generation);
        if (case.action == .symbols) {
            try std.testing.expectEqual(@as(usize, 0), model.editor.?.anchor);
            try std.testing.expectEqual(@as(usize, 5), model.editor.?.cursor);
        } else {
            try std.testing.expectEqual(previous_cursor, model.editor.?.cursor);
            try std.testing.expectEqualStrings("External target requires a validated workspace view; no file opened", model.status);
        }
    }
    try verify_lsp_mouse_and_stale_navigation(model, opened, redraw, window, renderer, io);
}

fn verify_lsp_mouse_and_stale_navigation(model: *Model, opened: *Opened, redraw: *bool, window: *sdl.SDL_Window, renderer: *sdl.SDL_Renderer, io: std.Io) !void {
    model.lsp_text_len = 0;
    apply_action(action_index(.symbols), model, opened);
    try wait_for_lsp_text(model, opened, redraw, io, "fixture-symbol");
    try render(renderer, model, opened);
    try dispatch_navigation_event(.{ .button = .{ .type = sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, .button = sdl.SDL_BUTTON_LEFT, .down = true, .x = 20 / model.mouse_scale_x, .y = 63 / model.mouse_scale_y } }, window, model, opened, redraw);
    try std.testing.expectEqual(@as(usize, 6), model.editor.?.anchor);
    try std.testing.expectEqual(@as(usize, 10), model.editor.?.cursor);
    apply_action(action_index(.choose_right), model, opened);
    const generation = opened.active.generation;
    const cursor = model.editor.?.cursor;
    model.lsp_navigation_open = true;
    try dispatch_navigation_event(.{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_RETURN, .down = true } }, window, model, opened, redraw);
    try std.testing.expect(!model.lsp_navigation_open);
    try std.testing.expectEqual(cursor, model.editor.?.cursor);
    try std.testing.expectEqual(generation, opened.active.generation);
}

fn dispatch_navigation_event(value: sdl.SDL_Event, window: *sdl.SDL_Window, model: *Model, opened: *Opened, redraw: *bool) !void {
    var injected = value;
    if (!sdl.SDL_PushEvent(&injected)) return error.EventInjectionFailed;
    var running = true;
    for (0..64) |_| {
        var received: sdl.SDL_Event = undefined;
        if (!sdl.SDL_WaitEventTimeout(&received, 100)) return error.EventInjectionFailed;
        try route_event(&received, window, model, opened, &running, redraw);
        if (!running) return error.UnexpectedWindowClose;
        if (received.type == value.type and (value.type != sdl.SDL_EVENT_KEY_DOWN or received.key.key == value.key.key)) return;
    }
    return error.InjectedEventNotObserved;
}

fn wait_for_lsp_text(model: *Model, opened: *Opened, redraw: *bool, io: std.Io, expected: []const u8) !void {
    for (0..5000) |_| {
        consume_lsp_publications(model, opened, redraw);
        if (std.mem.indexOf(u8, model.lsp_text[0..model.lsp_text_len], expected) != null) return;
        if (opened.lsp.?.storage.worker.failed()) |failure| return failure;
        std.Io.sleep(io, .fromMilliseconds(1), .real) catch {};
    }
    return error.LspResponseBusy;
}

const GpuSaveScenario = enum { happy, external_replacement, external_deletion, stale_save, existing_destination, close_pending_completion };

/// Real local-NTFS initial load: launcher-owned path copies feed the worker-owned
/// request, then only the UI thread renders the completed editable scene.
pub fn gpu_initial_load_e2e_test() !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz GUI initial load E2E", 640, 380, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_native_fixture(io, cwd, root, &fixture_memory);
    defer cleanup_native_dir(cwd, io, fixture);
    var left_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var right_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var output_memory: [root.len + 1 + 16 + 12]u8 = undefined;
    const left = try std.fmt.bufPrint(&left_memory, "{s}/left.bin", .{fixture});
    const right = try std.fmt.bufPrint(&right_memory, "{s}/right.bin", .{fixture});
    const output = try std.fmt.bufPrint(&output_memory, "{s}/loaded.bin", .{fixture});
    try write_native_file(io, left, "left\r\n");
    try write_native_file(io, right, "right\r\n");
    defer cleanup_native_file(cwd, io, right);
    defer cleanup_native_file(cwd, io, left);

    var launcher = Launcher.init(io, std.testing.allocator);
    launcher.stage = .diff_left;
    try std.testing.expect(launcher.accept(left));
    launcher.stage = .diff_right;
    try std.testing.expect(launcher.accept(right));
    launcher.stage = .diff_output;
    @memcpy(launcher.dialog_state.storage[0..output.len], output);
    launcher.dialog_state.result = .{ .selected = launcher.dialog_state.storage[0..output.len] };
    const request = (try launcher_result(&launcher, undefined)) orelse return error.TestUnexpectedResult;
    const backing = try std.heap.page_allocator.alloc(u8, backing_capacity);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened: Opened = undefined;
    var ready = false;
    for (0..5000) |_| {
        const view = job.view();
        if (view.state == .ready) {
            opened = job.take();
            ready = true;
            break;
        }
        if (view.state == .failed) return view.failure;
        std.Io.sleep(io, .fromMilliseconds(1), .real) catch {};
    }
    if (!ready) return error.Busy;
    defer opened.deinit();
    // `opened` must retain backing-owned metadata after its LoadJob stack slot dies.
    for (&job.paths) |*path_storage| @memset(path_storage.*, 'x');
    for (&job.labels) |*label_storage| @memset(label_storage.*, 'x');
    var model = Model{ .mode = .diff, .status = "EDITABLE ASCII RESULT | CRLF preserved | Ctrl+P actions", .editor = editor.State.init(opened.active.result()) };
    try update_layout(renderer, window, &model);
    try render(renderer, &model, &opened);
    try std.testing.expectEqualStrings("left\r\n", opened.active.inputs.left);
    try std.testing.expectEqualStrings("right\r\n", opened.active.result());
    try std.testing.expectEqualStrings(left, opened.input_paths.left);
    try std.testing.expectEqualStrings(right, opened.input_paths.right);
    try std.testing.expectEqualStrings(output, opened.destination);
    try std.testing.expectEqualStrings(left, opened.labels.left);
    try std.testing.expectEqualStrings(right, opened.labels.right);
    try std.testing.expectEqualStrings(output, opened.labels.output);
    try std.testing.expect(model.editor != null);
    try expect_absent_native_file(io, output);
}

/// Real JSON files flow through the GPU merge session, structural composition, Save, and Complete.
pub fn gpu_json_merge_e2e_test() !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz JSON merge E2E", 1280, 760, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_native_fixture(io, cwd, root, &fixture_memory);
    defer cleanup_native_dir(cwd, io, fixture);
    var paths: [8][root.len + 1 + 16 + "/fallback-result.json".len]u8 = undefined;
    const base = try std.fmt.bufPrint(&paths[0], "{s}/base.json", .{fixture});
    const left = try std.fmt.bufPrint(&paths[1], "{s}/left.json", .{fixture});
    const right = try std.fmt.bufPrint(&paths[2], "{s}/right.json", .{fixture});
    const output = try std.fmt.bufPrint(&paths[3], "{s}/result.json", .{fixture});
    const fallback_base = try std.fmt.bufPrint(&paths[4], "{s}/fallback-base.json", .{fixture});
    const fallback_left = try std.fmt.bufPrint(&paths[5], "{s}/fallback-left.json", .{fixture});
    const fallback_right = try std.fmt.bufPrint(&paths[6], "{s}/fallback-right.json", .{fixture});
    const fallback_output = try std.fmt.bufPrint(&paths[7], "{s}/fallback-result.json", .{fixture});
    const base_bytes = "{\"left\":0,\"right\":0}\n";
    const left_bytes = "{\"left\":1,\"right\":0}\n";
    const right_bytes = "{\"left\":0,\"right\":2}\n";
    const expected = "{\"left\":1,\"right\":2}\n";
    try write_native_file(io, base, base_bytes);
    try write_native_file(io, left, left_bytes);
    try write_native_file(io, right, right_bytes);
    defer cleanup_native_file(cwd, io, fallback_output);
    defer cleanup_native_file(cwd, io, fallback_right);
    defer cleanup_native_file(cwd, io, fallback_left);
    defer cleanup_native_file(cwd, io, fallback_base);
    defer cleanup_native_file(cwd, io, output);
    defer cleanup_native_file(cwd, io, right);
    defer cleanup_native_file(cwd, io, left);
    defer cleanup_native_file(cwd, io, base);
    try run_json_save_e2e(io, renderer, window, base, left, right, output, expected);

    const key_len = json_key_capacity + 1;
    const oversized = try std.testing.allocator.alloc(u8, key_len + 6);
    defer std.testing.allocator.free(oversized);
    @memcpy(oversized[0..2], "{\"");
    @memset(oversized[2 .. 2 + key_len], 'k');
    @memcpy(oversized[2 + key_len ..], "\":0}");
    try write_native_file(io, fallback_base, oversized);
    try write_native_file(io, fallback_left, oversized);
    try write_native_file(io, fallback_right, oversized);
    try run_json_capacity_fallback_e2e(io, fallback_base, fallback_left, fallback_right, fallback_output, oversized);
}

/// Real Zig source fixtures traverse native GPU LoadJob, exact-byte merge, Save, and Complete.
pub fn gpu_zig_merge_e2e_test() !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz Zig merge E2E", 1280, 760, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_native_fixture(io, cwd, root, &fixture_memory);
    defer cleanup_native_dir(cwd, io, fixture);
    var paths: [8][root.len + 1 + 16 + "/malformed-output.zig".len]u8 = undefined;
    const base_path = try std.fmt.bufPrint(&paths[0], "{s}/base.zig", .{fixture});
    const left_path = try std.fmt.bufPrint(&paths[1], "{s}/left.zig", .{fixture});
    const right_path = try std.fmt.bufPrint(&paths[2], "{s}/right.zig", .{fixture});
    const output_path = try std.fmt.bufPrint(&paths[3], "{s}/result.zig", .{fixture});
    const bad_base = try std.fmt.bufPrint(&paths[4], "{s}/malformed-base.zig", .{fixture});
    const bad_left = try std.fmt.bufPrint(&paths[5], "{s}/malformed-left.zig", .{fixture});
    const bad_right = try std.fmt.bufPrint(&paths[6], "{s}/malformed-right.zig", .{fixture});
    const bad_output = try std.fmt.bufPrint(&paths[7], "{s}/malformed-output.zig", .{fixture});
    const base = "// retained\r\npub fn alpha() u8 { return 1; }\r\npub fn beta() u8 { return 1; }\r\n";
    const left = "// retained\r\npub fn alpha() u8 { return 2; }\r\npub fn beta() u8 { return 1; }\r\n";
    const right = "// retained\r\npub fn alpha() u8 { return 1; }\r\npub fn beta() u8 { return 3; }\r\n";
    const expected = "// retained\r\npub fn alpha() u8 { return 2; }\r\npub fn beta() u8 { return 3; }\r\n";
    const malformed = "pub fn broken( {";
    try write_native_file(io, base_path, base);
    try write_native_file(io, left_path, left);
    try write_native_file(io, right_path, right);
    try write_native_file(io, bad_base, malformed);
    try write_native_file(io, bad_left, malformed);
    try write_native_file(io, bad_right, malformed);
    defer cleanup_native_file(cwd, io, bad_output);
    defer cleanup_native_file(cwd, io, bad_right);
    defer cleanup_native_file(cwd, io, bad_left);
    defer cleanup_native_file(cwd, io, bad_base);
    defer cleanup_native_file(cwd, io, output_path);
    defer cleanup_native_file(cwd, io, right_path);
    defer cleanup_native_file(cwd, io, left_path);
    defer cleanup_native_file(cwd, io, base_path);
    try run_zig_save_e2e(io, renderer, window, base_path, left_path, right_path, output_path, expected);

    const backing = try std.heap.page_allocator.alloc(u8, backing_capacity);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const request: invocation.Request = .{ .merge = .{ .base = bad_base, .left = bad_left, .right = bad_right, .output = bad_output, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try std.testing.expectEqual(session.Session.degraded_byte_review_engine, opened.active.identity().engine);
    try std.testing.expectEqual(session.DegradedReason.zig_malformed_source, opened.active.degradation().?);
    try std.testing.expect(opened.active.current_state().unresolved);
    try std.testing.expectEqualStrings(malformed, opened.active.result());
    try expect_absent_native_file(io, bad_output);
}

fn run_zig_save_e2e(io: std.Io, renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, base: []const u8, left: []const u8, right: []const u8, output: []const u8, expected: []const u8) !void {
    const backing = try std.heap.page_allocator.alloc(u8, backing_capacity);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const request: invocation.Request = .{ .merge = .{ .base = base, .left = left, .right = right, .output = output, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try std.testing.expectEqual(session.Session.zig_engine, opened.active.identity().engine);
    try std.testing.expectEqualStrings(expected, opened.active.result());
    try std.testing.expect(!opened.active.current_state().unresolved);
    try opened.init_save(io);
    var model = Model{ .mode = .merge, .status = session_status(&opened.active) };
    var redraw = true;
    try update_layout(renderer, window, &model);
    try render(renderer, &model, &opened);
    apply_action(action_index(.save), &model, &opened);
    try wait_for_gui_save(&model, &opened, &redraw);
    try expect_native_file(io, output, expected);
    apply_action(action_index(.complete), &model, &opened);
    try wait_for_gui_completion(&model, &opened, &redraw);
    try std.testing.expect(model.completed);
}

fn run_json_save_e2e(io: std.Io, renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, base: []const u8, left: []const u8, right: []const u8, output: []const u8, expected: []const u8) !void {
    const backing = try std.heap.page_allocator.alloc(u8, backing_capacity);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const request: invocation.Request = .{ .merge = .{ .base = base, .left = left, .right = right, .output = output, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try std.testing.expectEqual(session.Session.json_engine, opened.active.identity().engine);
    try std.testing.expectEqualStrings(expected, opened.active.result());
    try std.testing.expect(!opened.active.current_state().unresolved);
    try opened.init_save(io);
    var model = Model{ .mode = .merge, .status = session_status(&opened.active) };
    var redraw = true;
    try update_layout(renderer, window, &model);
    try render(renderer, &model, &opened);
    apply_action(action_index(.save), &model, &opened);
    try wait_for_gui_save(&model, &opened, &redraw);
    try expect_native_file(io, output, expected);
    apply_action(action_index(.complete), &model, &opened);
    try wait_for_gui_completion(&model, &opened, &redraw);
    try std.testing.expect(model.completed);
}

fn run_json_capacity_fallback_e2e(io: std.Io, base: []const u8, left: []const u8, right: []const u8, output: []const u8, expected_base: []const u8) !void {
    const backing = try std.heap.page_allocator.alloc(u8, backing_capacity);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const request: invocation.Request = .{ .merge = .{ .base = base, .left = left, .right = right, .output = output, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try std.testing.expectEqual(session.Session.degraded_byte_review_engine, opened.active.identity().engine);
    try std.testing.expectEqual(session.DegradedReason.resource_limited, opened.active.degradation().?);
    try std.testing.expect(opened.active.current_state().unresolved);
    try std.testing.expectEqualStrings(expected_base, opened.active.result());
    try expect_absent_native_file(io, output);
}

/// Real local-NTFS GUI path: injected UI events only drive actions; publication
/// still uses the production worker and Windows output primitive.
pub fn gpu_save_e2e_test() !void {
    try gpu_save_e2e_scenario(.happy);
}

pub fn gpu_save_external_replacement_test() !void {
    try gpu_save_e2e_scenario(.external_replacement);
}

pub fn gpu_save_external_deletion_test() !void {
    try gpu_save_e2e_scenario(.external_deletion);
}

pub fn gpu_save_stale_publication_test() !void {
    try gpu_save_e2e_scenario(.stale_save);
}

pub fn gpu_save_existing_destination_test() !void {
    try gpu_save_e2e_scenario(.existing_destination);
}

pub fn gpu_save_close_pending_completion_test() !void {
    try gpu_save_e2e_scenario(.close_pending_completion);
}

/// Real local-NTFS recovery GUI seams: a normal LoadJob opens originals, the
/// recovery-picker result starts the DPAPI worker, and welcome's copied restore
/// paths feed a distinct recovery LoadJob.  OS picker presentation remains manual.
pub fn gpu_recovery_restore_e2e_test() !void {
    for ([_][]const u8{ "lefT\r\n", "", "first\r\nsecond\nthird", "bare\rcarriage" }) |draft| try gpu_recovery_restore_scenario(draft);
}

fn gpu_recovery_restore_scenario(draft: []const u8) !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz GUI recovery E2E", 640, 380, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_native_fixture(io, cwd, root, &fixture_memory);
    defer cleanup_native_dir(cwd, io, fixture);
    var base_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var left_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var right_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var recovery_memory: [root.len + 1 + 16 + 13]u8 = undefined;
    var output_memory: [root.len + 1 + 16 + "/restored.bin".len]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_memory, "{s}/base.bin", .{fixture});
    const left = try std.fmt.bufPrint(&left_memory, "{s}/left.bin", .{fixture});
    const right = try std.fmt.bufPrint(&right_memory, "{s}/right.bin", .{fixture});
    const recovery_path = try std.fmt.bufPrint(&recovery_memory, "{s}/draft.rec", .{fixture});
    const output = try std.fmt.bufPrint(&output_memory, "{s}/restored.bin", .{fixture});
    defer cleanup_native_file(cwd, io, output);
    defer cleanup_native_file(cwd, io, recovery_path);
    defer cleanup_native_file(cwd, io, right);
    defer cleanup_native_file(cwd, io, left);
    defer cleanup_native_file(cwd, io, base);
    try write_native_file(io, base, "base\r\n");
    try write_native_file(io, left, "left\r\n");
    try write_native_file(io, right, "right\r\n");

    const backing = try std.testing.allocator.alloc(u8, backing_capacity);
    defer std.testing.allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const request: invocation.Request = .{ .merge = .{ .base = base, .left = left, .right = right, .output = output, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    const encrypted = try recovery_export_scenario(io, window, recovery_path, request, &allocator, draft);
    @memset(backing, 0);
    allocator.reset();
    const encrypted_before = try std.testing.allocator.dupe(u8, encrypted);
    defer std.testing.allocator.free(encrypted_before);
    std.testing.allocator.free(encrypted);
    try recovery_restore_scenario(io, renderer, window, recovery_path, output, &allocator, draft);
    @memset(backing, 0);
    allocator.reset();
    try replace_native_file(io, cwd, left, "LEFT\r\n");
    try recovery_changed_source_scenario(io, recovery_path, output, encrypted_before, &allocator);
}

/// Exercises the production GPU edit route, stable Opened journal worker, receipt, and DPAPI decode.
pub fn gpu_auto_recovery_e2e_test() !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz auto-recovery E2E", 640, 380, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    var parent_memory: [dialog.path_capacity]u8 = undefined;
    const parent = try native_temp_root(&parent_memory);
    try cwd.createDirPath(io, parent);
    var fixture_memory: [dialog.path_capacity + 1 + 16]u8 = undefined;
    const fixture = try create_native_fixture(io, cwd, parent, fixture_memory[0 .. parent.len + 1 + 16]);
    defer cleanup_native_dir(cwd, io, fixture);
    var input_memories: [4][dialog.path_capacity + 1 + 16 + "/right.bin".len]u8 = undefined;
    const base = try std.fmt.bufPrint(&input_memories[0], "{s}/base.bin", .{fixture});
    const left = try std.fmt.bufPrint(&input_memories[1], "{s}/left.bin", .{fixture});
    const right = try std.fmt.bufPrint(&input_memories[2], "{s}/right.bin", .{fixture});
    const output = try std.fmt.bufPrint(&input_memories[3], "{s}/out.bin", .{fixture});
    try write_native_file(io, base, "base\r\n");
    try write_native_file(io, left, "left\r\n");
    try write_native_file(io, right, "right\r\n");
    defer cleanup_native_file(cwd, io, right);
    defer cleanup_native_file(cwd, io, left);
    defer cleanup_native_file(cwd, io, base);

    var root_memory: [dialog.path_capacity + 1 + 16 + 14]u8 = undefined;
    const app_root = try std.fmt.bufPrint(&root_memory, "{s}/recovery-root", .{fixture});
    var session_dir_memory: [recovery.Controller.path_capacity]u8 = undefined;
    var journal_file_memory: [recovery.Controller.path_capacity]u8 = undefined;
    var owned_directory_path: []const u8 = "";
    var owned_journal_path: []const u8 = "";
    defer {
        if (owned_journal_path.len != 0) cwd.deleteFile(io, owned_journal_path) catch {};
        if (owned_directory_path.len != 0) cwd.deleteDir(io, owned_directory_path) catch {};
        cwd.deleteDir(io, app_root) catch {};
    }

    const recovery_test_capacity = backing_capacity * 2 + recovery_discovery.max_sessions * @sizeOf(recovery_discovery.Candidate) + recovery_discovery.max_ciphertext * 2 + recovery_discovery.max_plaintext * 2 + @sizeOf(u16) * std.os.windows.NAME_MAX + dialog.path_capacity + 2048;
    const backing = try std.heap.page_allocator.alloc(u8, recovery_test_capacity);
    defer std.heap.page_allocator.free(backing);
    var allocator = std.heap.FixedBufferAllocator.init(backing);
    const request: invocation.Request = .{ .merge = .{ .base = base, .left = left, .right = right, .output = output, .base_label = null, .left_label = null, .right_label = null, .output_label = null, .wait = false } };
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try opened.init_auto_recovery(io, app_root);
    try opened.start_auto_recovery();
    owned_directory_path = try std.fmt.bufPrint(&session_dir_memory, "{s}/{s}", .{ app_root, opened.recovery_directory.?.name });
    defer {
        opened.auto_recovery.deinit();
        opened.auto_recovery_initialized = false;
        for (opened.auto_recovery.owned_paths, opened.auto_recovery.owned_lens) |path, length| {
            if (length != 0) cleanup_native_file(cwd, io, path[0..length]);
        }
    }
    const original_identity = opened.active.identity().inputs;
    var model = Model{ .mode = .merge, .status = session_status(&opened.active), .editor = editor.State.init(opened.active.result()) };
    index_lines(&opened.lines[1], opened.active.result());
    model.editor.?.cursor = opened.active.result().len;
    model.editor.?.anchor = model.editor.?.cursor;
    var expected_storage: [input_capacity + 1]u8 = undefined;
    const original_result = opened.active.result();
    @memcpy(expected_storage[0..original_result.len], original_result);
    expected_storage[original_result.len] = '!';
    const expected = expected_storage[0 .. original_result.len + 1];
    try insert_text("!", &model, &opened);
    try std.testing.expectEqualStrings(expected, opened.active.result());
    try std.testing.expectEqual(original_identity, opened.active.identity().inputs);

    var status = opened.auto_recovery.status();
    for (0..5000) |_| {
        if (status.state == .healthy) break;
        if (status.state == .degraded) return status.failure orelse error.AutoRecoveryFailed;
        std.Io.sleep(io, .fromMilliseconds(10), .real) catch {};
        status = opened.auto_recovery.status();
    }
    try std.testing.expectEqual(recovery.Journal.State.healthy, status.state);
    try std.testing.expectEqual(opened.active.identity().generation, status.generation);
    const journal = &opened.auto_recovery;
    const owned_index = if (journal.owned_lens[0] != 0) @as(usize, 0) else 1;
    const journal_path = journal.owned_paths[owned_index][0..journal.owned_lens[owned_index]];
    @memcpy(journal_file_memory[0..journal_path.len], journal_path);
    owned_journal_path = journal_file_memory[0..journal_path.len];
    const owned = opened.recovery_directory.?;
    owned_directory_path = try std.fmt.bufPrint(&session_dir_memory, "{s}/{s}", .{ app_root, owned.name });
    try std.testing.expect(std.mem.startsWith(u8, owned_directory_path, app_root));
    try std.testing.expect(std.mem.startsWith(u8, journal_path, owned_directory_path));
    const encrypted = try read_native_file(io, journal_path, recovery.Controller.ciphertext_capacity);
    defer std.testing.allocator.free(encrypted);
    var plaintext: [recovery.Controller.plaintext_capacity]u8 = undefined;
    const decoded = try recovery.decode(encrypted, &plaintext);
    defer recovery.wipe(&plaintext);
    try std.testing.expectEqualStrings(expected, decoded.result);
    try std.testing.expectEqual(original_identity, decoded.identity);
    try std.testing.expect(encrypted.len > 0 and journal.owned_durable[owned_index]);

    var corrupt_memory: [recovery.Controller.path_capacity]u8 = undefined;
    const corrupt_path = try std.fmt.bufPrint(&corrupt_memory, "{s}/recovery-corrupt-999.bin", .{owned_directory_path});
    try write_native_file(io, corrupt_path, "not an encrypted recovery record");
    defer cleanup_native_file(cwd, io, corrupt_path);
    try recovery_discovery_restore_scenario(io, window, app_root, fixture, journal_path, corrupt_path, expected, &allocator, cwd);
}

fn recovery_discovery_restore_scenario(io: std.Io, window: *sdl.SDL_Window, app_root: []const u8, fixture: []const u8, journal_path: []const u8, corrupt_path: []const u8, expected: []const u8, allocator: *std.heap.FixedBufferAllocator, cwd: std.Io.Dir) !void {
    var discovery = try DiscoveryJob.init(io, app_root, allocator.allocator());
    defer discovery.deinit();
    try discovery.start();
    var discovered = discovery.view();
    for (0..5000) |_| {
        if (discovered.state != .searching) break;
        std.Io.sleep(io, .fromMilliseconds(10), .real) catch {};
        discovered = discovery.view();
    }
    try std.testing.expectEqual(DiscoveryJob.State.ready, discovered.state);
    try std.testing.expectEqual(@as(usize, 1), discovered.outcome.count);
    try std.testing.expect(discovered.outcome.skipped > 0);
    const candidate = discovery.candidates[0];
    try std.testing.expectEqualStrings(journal_path, candidate.path[0..candidate.path_len]);
    try std.testing.expect(!std.mem.eql(u8, candidate.path[0..candidate.path_len], corrupt_path));
    try recovery_restore_discovered_scenario(io, window, fixture, journal_path, candidate, expected, allocator, cwd);
    try recovery_forget_discovered_scenario(io, window, &discovery, journal_path, corrupt_path, cwd);
}

fn recovery_forget_discovered_scenario(io: std.Io, window: *sdl.SDL_Window, discovery: *DiscoveryJob, journal_path: []const u8, corrupt_path: []const u8, cwd: std.Io.Dir) !void {
    var foreign_path_storage: [dialog.path_capacity]u8 = undefined;
    const foreign_path = try std.fmt.bufPrint(&foreign_path_storage, "{s}/foreign-recovery.bin", .{discovery.root[0..discovery.root_len]});
    try write_native_file(io, foreign_path, "foreign protected data");
    defer cleanup_native_file(cwd, io, foreign_path);
    var launcher = Launcher.init(io, std.testing.allocator);
    launcher.discovery = discovery.*;
    discovery.thread = null;
    defer if (launcher.discovery) |*job| job.deinit();
    const job = if (launcher.discovery) |*value| value else unreachable;
    var view = job.view();
    try std.testing.expectEqual(DiscoveryJob.State.ready, view.state);
    try std.testing.expectEqual(@as(usize, 1), view.outcome.count);
    launcher.discovery_selected = 0;
    const candidate = job.candidates[0];
    try std.testing.expectEqualStrings(journal_path, candidate.path[0..candidate.path_len]);

    var model = Model{ .mode = .welcome, .status = launcher.status };
    var event: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = sdl.SDLK_X, .down = true } };
    try handle_launcher_event(&event, window, &model, &launcher);
    try std.testing.expect(launcher.forget_confirmation != null);
    const encrypted_before = try read_native_file(io, journal_path, recovery.Controller.ciphertext_capacity);
    defer std.testing.allocator.free(encrypted_before);
    event.key.key = sdl.SDLK_ESCAPE;
    try handle_launcher_event(&event, window, &model, &launcher);
    try std.testing.expect(launcher.forget_confirmation == null);
    const encrypted_after_cancel = try read_native_file(io, journal_path, recovery.Controller.ciphertext_capacity);
    defer std.testing.allocator.free(encrypted_after_cancel);
    try std.testing.expectEqualSlices(u8, encrypted_before, encrypted_after_cancel);
    try std.testing.expect((cwd.statFile(io, corrupt_path, .{}) catch null) != null);

    event.key.key = sdl.SDLK_X;
    try handle_launcher_event(&event, window, &model, &launcher);
    try handle_launcher_event(&event, window, &model, &launcher);
    try std.testing.expectEqual(DiscoveryJob.Kind.forget, job.kind);
    view = job.view();
    for (0..5000) |_| {
        if (view.state != .searching) break;
        std.Io.sleep(io, .fromMilliseconds(10), .real) catch {};
        view = job.view();
    }
    try std.testing.expectEqual(DiscoveryJob.State.ready, view.state);
    _ = try consume_discovery(&launcher, window);
    try std.testing.expectEqual(DiscoveryJob.Kind.scan, job.kind);
    try std.testing.expect((cwd.statFile(io, journal_path, .{}) catch null) == null);
    try std.testing.expect((cwd.statFile(io, corrupt_path, .{}) catch null) != null);
    const corrupt = try read_native_file(io, corrupt_path, 128);
    defer std.testing.allocator.free(corrupt);
    try std.testing.expectEqualStrings("not an encrypted recovery record", corrupt);
    const foreign = try read_native_file(io, foreign_path, 128);
    defer std.testing.allocator.free(foreign);
    try std.testing.expectEqualStrings("foreign protected data", foreign);
}

fn recovery_restore_discovered_scenario(io: std.Io, window: *sdl.SDL_Window, fixture: []const u8, journal_path: []const u8, candidate: recovery_discovery.Candidate, expected: []const u8, allocator: *std.heap.FixedBufferAllocator, cwd: std.Io.Dir) !void {
    var output_memory: [recovery.Controller.path_capacity]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_memory, "{s}/discovered-result.bin", .{fixture});
    var launcher = Launcher.init(io, allocator.allocator());
    @memcpy(launcher.recovery_path[0..candidate.path_len], candidate.path[0..candidate.path_len]);
    launcher.recovery_path_len = candidate.path_len;
    launcher.stage = .restore_output;
    @memcpy(launcher.dialog_state.storage[0..output.len], output);
    launcher.dialog_state.result = .{ .selected = launcher.dialog_state.storage[0..output.len] };
    const selected = (try launcher_recovery_path(&launcher, window)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(journal_path, selected.recovery);
    try std.testing.expectEqualStrings(output, selected.output);
    var job = try LoadJob.init_recovery(io, selected.recovery, selected.output, allocator.allocator());
    try job.start();
    defer job.deinit();
    var restored = try wait_for_load_job(&job);
    defer restored.deinit();
    try std.testing.expectEqualStrings(expected, restored.active.result());
    defer cleanup_native_file(cwd, io, output);
}

fn recovery_export_scenario(io: std.Io, window: *sdl.SDL_Window, recovery_path: []const u8, request: invocation.Request, allocator: *std.heap.FixedBufferAllocator, draft: []const u8) ![]u8 {
    var job = try LoadJob.init(io, request, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try opened.init_save(io);
    try opened.init_recovery(io);
    try opened.active.choose(opened.active.identity().generation, .left);
    try opened.active.apply_edits(opened.active.identity().generation, &.{.{ .start = 0, .end = opened.active.result().len, .replacement = draft }});
    try std.testing.expectEqualStrings(draft, opened.active.result());
    var model = Model{ .mode = .merge, .status = "RECOVERY PICKER OPEN", .recovery_picker = .{ .io = io }, .window = window, .clipboard = opened.clipboard };
    @memcpy(model.recovery_picker.storage[0..recovery_path.len], recovery_path);
    model.recovery_picker.result = .{ .selected = model.recovery_picker.storage[0..recovery_path.len] };
    model.recovery_picker_pending = true;
    var redraw = false;
    consume_recovery_picker(&model, &opened, window, &redraw);
    try std.testing.expect(!model.recovery_picker_pending);
    try wait_for_gui_recovery(&model, &opened, &redraw);
    try std.testing.expect(std.mem.indexOf(u8, model.status, "EXPORTED DURABLY") != null);
    const encrypted = try read_native_file(io, recovery_path, recovery.Controller.ciphertext_capacity);
    defer std.testing.allocator.free(encrypted);
    try std.testing.expect(encrypted.len > opened.active.result().len);
    try std.testing.expect(std.mem.indexOf(u8, encrypted, "left\r\n") == null);
    if (draft.len > 0) try std.testing.expect(std.mem.indexOf(u8, encrypted, draft) == null);
    return try std.testing.allocator.dupe(u8, encrypted);
}

fn recovery_restore_scenario(io: std.Io, renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, recovery_path: []const u8, output: []const u8, allocator: *std.heap.FixedBufferAllocator, draft: []const u8) !void {
    var launcher = Launcher.init(io, allocator.allocator());
    launcher.stage = .restore_output;
    @memcpy(launcher.recovery_path[0..recovery_path.len], recovery_path);
    launcher.recovery_path_len = recovery_path.len;
    @memcpy(launcher.dialog_state.storage[0..output.len], output);
    launcher.dialog_state.result = .{ .selected = launcher.dialog_state.storage[0..output.len] };
    const paths = (try launcher_recovery_path(&launcher, window)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(recovery_path, paths.recovery);
    try std.testing.expectEqualStrings(output, paths.output);
    var job = try LoadJob.init_recovery(io, paths.recovery, paths.output, allocator.allocator());
    try job.start();
    defer job.deinit();
    var opened = try wait_for_load_job(&job);
    defer opened.deinit();
    try opened.init_save(io);
    try std.testing.expectEqualStrings(draft, opened.active.result());
    const expected_lines = 1 + std.mem.count(u8, draft, "\n") + std.mem.count(u8, draft, "\r") - std.mem.count(u8, draft, "\r\n");
    try std.testing.expectEqual(expected_lines, opened.lines[1].count);
    try std.testing.expect(opened.active.current_state().unresolved and !opened.active.current_state().reviewed);
    var model = Model{ .mode = .merge, .status = session_status(&opened.active), .editor = editor.State.init(opened.active.result()), .clipboard = opened.clipboard };
    try update_layout(renderer, window, &model);
    try render(renderer, &model, &opened);
    try std.testing.expect(std.mem.indexOf(u8, model.status, "UNRESOLVED") != null);
    try std.testing.expect(disabled_reason(action_index(.save), &model, &opened) != null);
    try std.testing.expect(disabled_reason(action_index(.complete), &model, &opened) != null);
    try opened.active.mark_resolved(opened.active.identity().generation);
    try std.testing.expect(disabled_reason(action_index(.save), &model, &opened) == null);
    apply_action(action_index(.save), &model, &opened);
    var redraw = false;
    try wait_for_gui_save(&model, &opened, &redraw);
    try expect_native_file(io, output, draft);
    apply_action(action_index(.complete), &model, &opened);
    try wait_for_gui_completion(&model, &opened, &redraw);
    try std.testing.expect(model.completed);
}

fn recovery_changed_source_scenario(io: std.Io, recovery_path: []const u8, output: []const u8, encrypted: []const u8, allocator: *std.heap.FixedBufferAllocator) !void {
    var job = try LoadJob.init_recovery(io, recovery_path, output, allocator.allocator());
    try job.start();
    defer job.deinit();
    try std.testing.expectError(error.ChangedInput, wait_for_load_job(&job));
    const encrypted_after = try read_native_file(io, recovery_path, recovery.Controller.ciphertext_capacity);
    defer std.testing.allocator.free(encrypted_after);
    try std.testing.expectEqualSlices(u8, encrypted, encrypted_after);
}

fn gpu_save_e2e_scenario(scenario: GpuSaveScenario) !void {
    if (comptime @import("builtin").os.tag != .windows) return;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz GUI Save E2E", 1280, 760, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    try cwd.createDirPath(io, root);
    var fixture_memory: [root.len + 1 + 16]u8 = undefined;
    const fixture = try create_native_fixture(io, cwd, root, &fixture_memory);
    defer cleanup_native_dir(cwd, io, fixture);
    var base_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var left_memory: [root.len + 1 + 16 + 9]u8 = undefined;
    var right_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var saved_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    var deleted_memory: [root.len + 1 + 16 + 12]u8 = undefined;
    var stale_memory: [root.len + 1 + 16 + 10]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_memory, "{s}/base.bin", .{fixture});
    const left = try std.fmt.bufPrint(&left_memory, "{s}/left.bin", .{fixture});
    const right = try std.fmt.bufPrint(&right_memory, "{s}/right.bin", .{fixture});
    try write_native_file(io, base, "base\r\n");
    try write_native_file(io, left, "left\r\n");
    try write_native_file(io, right, "right\r\n");
    const saved = try std.fmt.bufPrint(&saved_memory, "{s}/saved.bin", .{fixture});
    const deleted = try std.fmt.bufPrint(&deleted_memory, "{s}/deleted.bin", .{fixture});
    const stale = try std.fmt.bufPrint(&stale_memory, "{s}/stale.bin", .{fixture});
    const rejected = try std.fmt.allocPrint(std.testing.allocator, "{s}/rejected.bin", .{fixture});
    defer std.testing.allocator.free(rejected);
    const closed = try std.fmt.allocPrint(std.testing.allocator, "{s}/closed.bin", .{fixture});
    defer std.testing.allocator.free(closed);
    defer cleanup_native_file(cwd, io, closed);
    defer cleanup_native_file(cwd, io, rejected);
    defer cleanup_native_file(cwd, io, stale);
    defer cleanup_native_file(cwd, io, deleted);
    defer cleanup_native_file(cwd, io, saved);
    defer cleanup_native_file(cwd, io, right);
    defer cleanup_native_file(cwd, io, left);
    defer cleanup_native_file(cwd, io, base);

    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [256]u8 = undefined;
    var records: [8]session.Record = undefined;
    var offsets: [3][8]u32 = undefined;
    var save_paths: [save.path_storage_capacity]u8 = undefined;
    var save_content: [save.content_capacity]u8 = undefined;
    var save_preflight: [save.content_capacity]u8 = undefined;
    var opened = Opened{
        .active = try session.Session.init(.{ .base = "base\r\n", .left = "left\r\n", .right = "right\r\n" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
        .labels = .{ .base = "base", .left = "left", .right = "right", .output = "saved" },
        .destination = saved,
        .input_paths = .{ .base = base, .left = left, .right = right },
        .lines = undefined,
        .save = undefined,
    };
    try opened.init_save_with(io, &save_paths, &save_content, &save_preflight);
    defer opened.deinit();
    for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    var model = Model{ .mode = .merge, .status = session_status(&opened.active) };
    var running = true;
    var redraw = true;
    try update_layout(renderer, window, &model);
    try render_and_present_help(renderer, &model, &opened);

    // Opened session → mouse-select Left → drag/Shift-click result range → edit → undo/redo → Save → Complete.
    try inject_click(model.layout.buttons[action_index(.choose_left)], renderer, window, &model, &opened, &running, &redraw, false);
    try std.testing.expectEqual(action_index(.choose_left), model.selected);
    try std.testing.expectEqual(action_index(.choose_left), model.help_presented.?);
    // The same action seam used by mouse/menu/palette applies the already presented choice.
    apply_action(action_index(.choose_left), &model, &opened);
    try std.testing.expectEqualStrings("left\r\n", opened.active.result());
    const result_rect = model.layout.panes[1];
    const text_y = result_rect.y + 41;
    const t_x = result_rect.x + 2 + 3 * glyph_width;
    const after_t_x = result_rect.x + 2 + 4 * glyph_width;
    try std.testing.expect(result_rect.contains(t_x, text_y));
    sdl.SDL_FlushEvents(sdl.SDL_EVENT_FIRST, sdl.SDL_EVENT_LAST);
    try push_mouse_down(injected_mouse_coordinate(t_x, model.mouse_scale_x), injected_mouse_coordinate(text_y, model.mouse_scale_y), false);
    try push_mouse_motion(injected_mouse_coordinate(after_t_x, model.mouse_scale_x), injected_mouse_coordinate(text_y, model.mouse_scale_y), true);
    try push_mouse_up(injected_mouse_coordinate(after_t_x, model.mouse_scale_x), injected_mouse_coordinate(text_y, model.mouse_scale_y), false);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqual(@as(usize, 3), model.editor.?.selection_start());
    try std.testing.expectEqual(@as(usize, 4), model.editor.?.selection_end());
    try push_text("T");
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("lefT\r\n", opened.active.result());
    try push_key(sdl.SDLK_Z, sdl.SDL_KMOD_CTRL);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("left\r\n", opened.active.result());
    try push_key(sdl.SDLK_Y, sdl.SDL_KMOD_CTRL);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try std.testing.expectEqualStrings("lefT\r\n", opened.active.result());
    try push_key(sdl.SDLK_S, sdl.SDL_KMOD_CTRL);
    _ = try drain_events(8, window, &model, &opened, &running, &redraw);
    try wait_for_gui_save(&model, &opened, &redraw);
    try std.testing.expect(model.durable_generation != null);
    try expect_native_file(io, saved, "lefT\r\n");
    try inject_click(model.layout.buttons[action_index(.complete)], renderer, window, &model, &opened, &running, &redraw, false);
    apply_action(action_index(.complete), &model, &opened);
    try std.testing.expect(!model.completed);
    try std.testing.expect(model.completion_job_id != null);
    try wait_for_gui_completion(&model, &opened, &redraw);
    try std.testing.expect(model.completed);
    if (scenario == .happy) return;
    model.completed = false;
    model.exit_requested = false;
    model.exit_ready = false;
    if (scenario == .external_replacement) {
        model.completed = false;
        try replace_native_file(io, cwd, saved, "righT\r\n");
        apply_action(action_index(.complete), &model, &opened);
        try wait_for_gui_completion(&model, &opened, &redraw);
        try std.testing.expect(!model.completed);
        try std.testing.expect(std.mem.indexOf(u8, model.status, "output changed") != null);
        try expect_native_file(io, saved, "righT\r\n");
        return;
    }
    if (scenario == .external_deletion) {
        apply_action(2, &model, &opened);
        apply_action(1, &model, &opened);
        opened.destination = deleted;
        apply_action(7, &model, &opened);
        try wait_for_gui_save(&model, &opened, &redraw);
        try cwd.deleteFile(io, deleted);
        try expect_absent_native_file(io, deleted);
        apply_action(action_index(.complete), &model, &opened);
        try wait_for_gui_completion(&model, &opened, &redraw);
        try std.testing.expect(!model.completed);
        try expect_absent_native_file(io, deleted);
        return;
    }
    if (scenario == .stale_save) {
        apply_action(2, &model, &opened);
        try std.testing.expect(model.durable_generation == null);
        try std.testing.expect(disabled_reason(8, &model, &opened) != null);
        opened.destination = stale;
        apply_action(1, &model, &opened);
        apply_action(7, &model, &opened);
        apply_action(2, &model, &opened);
        try wait_for_gui_save(&model, &opened, &redraw);
        try std.testing.expect(std.mem.indexOf(u8, model.status, "STALE SAVE PUBLISHED") != null);
        try std.testing.expect(model.durable_generation == null);
        try expect_native_file(io, stale, "left\r\n");
        try std.testing.expectEqualStrings("right\r\n", opened.active.result());
        return;
    }
    if (scenario == .existing_destination) {
        apply_action(action_index(.choose_right), &model, &opened);
        var existing = try cwd.createFile(io, rejected, .{ .exclusive = true });
        try existing.writeStreamingAll(io, "existing\r\n");
        try existing.sync(io);
        existing.close(io);
        opened.destination = rejected;
        apply_action(7, &model, &opened);
        try wait_for_gui_save(&model, &opened, &redraw);
        try std.testing.expect(std.mem.indexOf(u8, model.status, "PathAlreadyExists") != null);
        try expect_native_file(io, rejected, "existing\r\n");
        return;
    }
    if (scenario == .close_pending_completion) {
        apply_action(action_index(.choose_right), &model, &opened);
        opened.destination = closed;
        apply_action(7, &model, &opened);
        try wait_for_gui_save(&model, &opened, &redraw);
        apply_action(8, &model, &opened);
        const completion_job_id = model.completion_job_id.?;
        try std.testing.expect(completion_job_id != 0);
        var close_event: sdl.SDL_Event = .{ .quit = .{ .type = sdl.SDL_EVENT_QUIT } };
        try route_event(&close_event, window, &model, &opened, &running, &redraw);
        try std.testing.expect(running and !model.completed and model.exit_requested and model.completion_job_id == null);
        var expose_event: sdl.SDL_Event = .{ .window = .{ .type = sdl.SDL_EVENT_WINDOW_EXPOSED } };
        try std.testing.expect(try handle_event(&expose_event, window, &model, &opened));
        model.exit_ready = false;
        consume_completion_result(&model, &opened, &redraw);
        try std.testing.expect(!model.completed and model.completion_job_id == null);
        try std.testing.expectError(error.ResolutionIncomplete, resolution_close_result(&model));
        for (0..5000) |_| {
            if (opened.save.observe().result != .pending) break;
            std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real) catch {};
        }
        consume_completion_result(&model, &opened, &redraw);
        try std.testing.expect(!model.completed and model.completion_job_id == null and opened.save.observe().id == completion_job_id and opened.save.observe().result == .succeeded);
        advance_exit_drain(&model, &opened, &redraw);
        try std.testing.expect(model.exit_ready);
        try expect_native_file(io, closed, "right\r\n");
        return;
    }
    unreachable;
}

fn injected_mouse_coordinate(logical: f32, scale: f32) f32 {
    std.debug.assert(std.math.isFinite(logical) and scale > 0);
    return logical / scale;
}

fn inject_click(rect: Rect, renderer: *sdl.SDL_Renderer, window: *sdl.SDL_Window, model: *Model, opened: *Opened, running: *bool, redraw: *bool, shift: bool) !void {
    const x = rect.x + @min(@as(f32, 2), rect.w / 2);
    const y = rect.y + @min(@as(f32, 2), rect.h / 2);
    try push_mouse_motion(x / model.mouse_scale_x, y / model.mouse_scale_y, false);
    try push_mouse_down(x / model.mouse_scale_x, y / model.mouse_scale_y, shift);
    try push_mouse_up(x / model.mouse_scale_x, y / model.mouse_scale_y, shift);
    _ = try drain_events(8, window, model, opened, running, redraw);
    try render_and_present_help(renderer, model, opened);
}

fn wait_for_load_job(job: *LoadJob) !Opened {
    for (0..5000) |_| {
        const view = job.view();
        switch (view.state) {
            .ready => return job.take(),
            .failed => return view.failure,
            .discarded => return error.ResolutionIncomplete,
            .loading => std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real) catch {},
        }
    }
    return error.Busy;
}

fn wait_for_gui_recovery(model: *Model, opened: *Opened, redraw: *bool) !void {
    for (0..5000) |_| {
        consume_recovery_result(model, opened, redraw);
        if (model.recovery_observed) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real) catch {};
    }
    return error.Busy;
}

fn read_native_file(io: std.Io, path: []const u8, maximum: usize) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(std.testing.allocator, .limited(maximum));
}

fn wait_for_gui_save(model: *Model, opened: *Opened, redraw: *bool) !void {
    for (0..5000) |_| {
        consume_save_result(model, opened, redraw);
        if (model.observed_save_generation != null) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real) catch {};
    }
    return error.RenderFailed;
}

fn wait_for_gui_completion(model: *Model, opened: *Opened, redraw: *bool) !void {
    for (0..5000) |_| {
        consume_completion_result(model, opened, redraw);
        if (model.completion_job_id == null) return;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real) catch {};
    }
    return error.RenderFailed;
}

fn native_temp_root(storage: []u8) ![]const u8 {
    const approved_root = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    if (storage.len < approved_root.len) return error.ScratchTooSmall;
    @memcpy(storage[0..approved_root.len], approved_root);
    return storage[0..approved_root.len];
}

fn create_native_fixture(io: std.Io, cwd: std.Io.Dir, root: []const u8, memory: []u8) ![]const u8 {
    std.debug.assert(memory.len == root.len + 1 + 16);
    @memcpy(memory[0..root.len], root);
    memory[root.len] = '/';
    var random: [8]u8 = undefined;
    for (0..16) |_| {
        try io.randomSecure(&random);
        native_hex(memory[root.len + 1 ..], &random);
        cwd.createDir(io, memory, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |unexpected| return unexpected,
        };
        return memory;
    }
    return error.Busy;
}

fn native_hex(destination: []u8, source: []const u8) void {
    const alphabet = "0123456789abcdef";
    std.debug.assert(destination.len == source.len * 2);
    for (source, 0..) |byte, index| {
        destination[index * 2] = alphabet[byte >> 4];
        destination[index * 2 + 1] = alphabet[byte & 15];
    }
}

fn cleanup_native_file(cwd: std.Io.Dir, io: std.Io, path: []const u8) void {
    cwd.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => @panic(@errorName(err)),
    };
}

fn cleanup_native_dir(cwd: std.Io.Dir, io: std.Io, path: []const u8) void {
    cwd.deleteDir(io, path) catch |err| @panic(@errorName(err));
}

fn write_native_file(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn replace_native_file(io: std.Io, cwd: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    try cwd.deleteFile(io, path);
    try write_native_file(io, path, bytes);
}

fn expect_absent_native_file(io: std.Io, path: []const u8) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |unexpected| return unexpected,
    };
    file.close(io);
    return error.TestUnexpectedResult;
}

fn expect_native_file(io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [64]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const actual = try reader.interface.allocRemaining(std.testing.allocator, .limited(expected.len));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

fn render_and_present_help(renderer: *sdl.SDL_Renderer, model: *Model, opened: *Opened) !void {
    try render(renderer, model, opened);
    model.help_presented = if (!model.palette_open or matches(model, model.selected)) model.selected else null;
}

fn rendered_hash(renderer: *sdl.SDL_Renderer) !u64 {
    const surface = sdl.SDL_RenderReadPixels(renderer, null) orelse return error.RenderFailed;
    defer sdl.SDL_DestroySurface(surface);
    if (surface.*.w <= 0 or surface.*.h <= 0 or surface.*.pitch <= 0 or surface.*.pixels == null) return error.RenderFailed;
    const byte_count = std.math.mul(usize, @as(usize, @intCast(surface.*.pitch)), @as(usize, @intCast(surface.*.h))) catch return error.RenderFailed;
    const pixels: [*]const u8 = @ptrCast(surface.*.pixels.?);
    return std.hash.Wyhash.hash(0, pixels[0..byte_count]);
}

const Atlas = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    coverage: u32,
};

/// Composes one RGBA atlas row for the sample string; coverage bytes become
/// white with matching alpha so the GPU blends only the ink.
fn compose_glyph_atlas(arena: std.mem.Allocator, renderer: *glyph_text.Renderer, sample: []const u8) !Atlas {
    std.debug.assert(sample.len > 0 and sample.len <= 64);
    var placed: usize = 0;
    var max_top: u32 = 0;
    var max_below: u32 = 0;
    for (sample) |byte| {
        const glyph = try renderer.glyph(byte);
        std.debug.assert(glyph.top >= 0 and glyph.rows >= @as(u32, @intCast(glyph.top)));
        placed += @intCast(glyph.advance + 1);
        max_top = @max(max_top, @as(u32, @intCast(glyph.top)));
        max_below = @max(max_below, glyph.rows - @as(u32, @intCast(glyph.top)));
    }
    std.debug.assert(placed > 0 and placed <= 4096);
    const height: u32 = max_top + max_below;
    const stride = (placed + 3) & ~@as(usize, 3);
    const pixels = try arena.alloc(u8, 4 * stride * height);
    @memset(pixels, 0);
    var coverage: u32 = 0;
    var pen: usize = 0;
    for (sample) |byte| {
        const glyph = try renderer.glyph(byte);
        const origin_row: usize = @intCast(max_top - @as(u32, @intCast(glyph.top)));
        std.debug.assert(origin_row + glyph.rows <= height and pen + glyph.width <= stride);
        for (0..glyph.rows) |row| {
            for (0..glyph.width) |column| {
                const source = glyph.pixels[row * glyph.width + column];
                if (source == 0) continue;
                const target = 4 * ((origin_row + row) * stride + pen + column);
                pixels[target] = 255;
                pixels[target + 1] = 255;
                pixels[target + 2] = 255;
                pixels[target + 3] = source;
                coverage += @intFromBool(source > 127);
            }
        }
        pen += @intCast(glyph.advance + 1);
    }
    std.debug.assert(coverage > 0);
    return .{ .pixels = pixels, .width = @intCast(placed), .height = height, .stride = @intCast(stride), .coverage = coverage };
}

fn clear_frame(renderer: *sdl.SDL_Renderer, red: u8, green: u8, blue: u8) !void {
    try color(renderer, red, green, blue);
    if (!sdl.SDL_RenderClear(renderer)) return error.RenderFailed;
}

/// Deterministic FreeType→GPU pipeline proof: rasterize glyphs through the
/// bounded pool, upload one atlas texture, draw it, and verify the readback
/// is stable and distinct from the background. Requires WARKOCZ_TEST_FONT
/// (absolute path); injected readback is not OS visual acceptance evidence.
pub fn gpu_text_pipeline_test() !void {
    const io = std.testing.io;
    const environ: std.process.Environ = .{ .block = .global };
    const font_path = environ.getAlloc(std.testing.allocator, "WARKOCZ_TEST_FONT") catch return error.SkipZigTest;
    defer std.testing.allocator.free(font_path);
    if (font_path.len == 0 or !std.fs.path.isAbsolute(font_path)) return error.SkipZigTest;

    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.GraphicsUnavailable;
    defer sdl.SDL_Quit();
    const window = sdl.SDL_CreateWindow("warkocz FreeType pipeline", 512, 192, sdl.SDL_WINDOW_HIDDEN) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyWindow(window);
    const device = try create_device();
    defer sdl.SDL_DestroyGPUDevice(device);
    const renderer = sdl.SDL_CreateGPURenderer(device, window) orelse return error.GraphicsUnavailable;
    defer sdl.SDL_DestroyRenderer(renderer);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const font_bytes = try std.Io.Dir.cwd().readFileAlloc(io, font_path, arena, .limited(8 << 20));
    var pool: [glyph_text.pool_capacity]u8 = undefined;
    var text_renderer = try glyph_text.Renderer.init(&pool, font_bytes, 16);
    defer text_renderer.deinit();

    const atlas = try compose_glyph_atlas(arena, &text_renderer, "warkocz 01");
    const texture = sdl.SDL_CreateTexture(renderer, sdl.SDL_PIXELFORMAT_RGBA8888, sdl.SDL_TEXTUREACCESS_STATIC, @intCast(atlas.width), @intCast(atlas.height)) orelse return error.RenderFailed;
    defer sdl.SDL_DestroyTexture(texture);
    if (!sdl.SDL_UpdateTexture(texture, null, atlas.pixels.ptr, @intCast(atlas.stride * 4))) return error.RenderFailed;
    if (!sdl.SDL_SetTextureBlendMode(texture, sdl.SDL_BLENDMODE_BLEND)) return error.RenderFailed;

    const destination = sdl.SDL_FRect{ .x = 8, .y = 8, .w = @floatFromInt(atlas.width), .h = @floatFromInt(atlas.height) };
    try clear_frame(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderTexture(renderer, texture, null, &destination)) return error.RenderFailed;
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
    const drawn = try rendered_hash(renderer);
    try clear_frame(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
    const background = try rendered_hash(renderer);
    try clear_frame(renderer, 24, 28, 38);
    if (!sdl.SDL_RenderTexture(renderer, texture, null, &destination)) return error.RenderFailed;
    if (!sdl.SDL_RenderPresent(renderer)) return error.RenderFailed;
    const repeated = try rendered_hash(renderer);
    try std.testing.expectEqual(drawn, repeated);
    try std.testing.expect(drawn != background);
}

fn push_key(key: sdl.SDL_Keycode, modifiers: sdl.SDL_Keymod) !void {
    var event: sdl.SDL_Event = .{ .key = .{ .type = sdl.SDL_EVENT_KEY_DOWN, .key = key, .mod = modifiers, .down = true } };
    if (!sdl.SDL_PushEvent(&event)) return error.RenderFailed;
}

fn push_mouse_motion(x: f32, y: f32, left_down: bool) !void {
    var event: sdl.SDL_Event = .{ .motion = .{ .type = sdl.SDL_EVENT_MOUSE_MOTION, .x = x, .y = y, .state = if (left_down) sdl.SDL_BUTTON_LMASK else 0 } };
    if (!sdl.SDL_PushEvent(&event)) return error.RenderFailed;
}

fn push_mouse_down(x: f32, y: f32, shift: bool) !void {
    sdl.SDL_SetModState(if (shift) sdl.SDL_KMOD_SHIFT else 0);
    var event: sdl.SDL_Event = .{ .button = .{ .type = sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, .button = sdl.SDL_BUTTON_LEFT, .down = true, .x = x, .y = y } };
    if (!sdl.SDL_PushEvent(&event)) return error.RenderFailed;
}

fn push_mouse_up(x: f32, y: f32, shift: bool) !void {
    sdl.SDL_SetModState(if (shift) sdl.SDL_KMOD_SHIFT else 0);
    var event: sdl.SDL_Event = .{ .button = .{ .type = sdl.SDL_EVENT_MOUSE_BUTTON_UP, .button = sdl.SDL_BUTTON_LEFT, .down = false, .x = x, .y = y } };
    if (!sdl.SDL_PushEvent(&event)) return error.RenderFailed;
    if (shift) sdl.SDL_SetModState(0);
}

fn push_text(text: [*:0]const u8) !void {
    var event: sdl.SDL_Event = .{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .text = text } };
    if (!sdl.SDL_PushEvent(&event)) return error.RenderFailed;
}

test "launcher exposes named keyboard and palette actions with pending disabled reason" {
    var launcher = Launcher.init(std.testing.io, std.testing.allocator);
    try std.testing.expectEqualStrings("Open two-way comparison", launcher_actions[0].name);
    try std.testing.expect(std.mem.indexOf(u8, launcher_actions[2].help, "Git") != null);
    try std.testing.expect(std.mem.indexOf(u8, launcher_actions[3].help, "revalidated") != null);
    launcher.palette_open = true;
    for ("repository") |byte| {
        launcher.query[launcher.query_len] = byte;
        launcher.query_len += 1;
    }
    try std.testing.expect(launcher_matches(&launcher, 2));
    launcher.selected = 2;
    launcher.help_presented = 2;
    launcher.stage = .repo_folder;
    try std.testing.expect(launcher_disabled_reason(&launcher, 2) != null);
    try std.testing.expect(std.mem.indexOf(u8, launcher_disabled_reason(&launcher, 2).?, "picker") != null);
}

test "launcher preserves literal selected paths for native scenes" {
    var launcher = Launcher.init(std.testing.io, std.testing.allocator);
    const paths = [_][]const u8{ "C:/input one.txt", "C:/input two.txt", "unused", "C:/new output.txt" };
    for (paths, 0..) |path, index| {
        @memcpy(launcher.paths[index][0..path.len], path);
        launcher.lengths[index] = path.len;
    }
    launcher.stage = .diff_output;
    const request = advance_launcher(&launcher, undefined) orelse return error.TestUnexpectedResult;
    switch (request) {
        .diff => |diff| {
            try std.testing.expectEqualStrings(paths[0], diff.left);
            try std.testing.expectEqualStrings(paths[1], diff.right);
            try std.testing.expectEqualStrings(paths[3], diff.output);
            try std.testing.expect(diff.left_label == null and diff.output_label == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "native layout uses primary result and exact painted hit rectangles" {
    const layout = layout_for(640, 380);
    try std.testing.expect(layout.panes[1].w > layout.panes[0].w);
    try std.testing.expect(layout.buttons[1].contains(layout.buttons[1].x + 1, layout.buttons[1].y + 1));
    try std.testing.expect(!layout.buttons[1].contains(layout.buttons[1].x - 1, layout.buttons[1].y));
    try std.testing.expect(!layout.buttons[1].contains(layout.buttons[1].x + layout.buttons[1].w, layout.buttons[1].y));
    const tiny = layout_for(20, 10);
    try std.testing.expectEqual(@as(f32, 0), tiny.panes[1].h);
    try std.testing.expect(tiny.buttons[1].y > tiny.buttons[0].y);
}

test "LSP review wraps diagnostic cells and refuses tiny controls" {
    var line: [256]u8 = undefined;
    const value = "abcdef";
    const first = diagnostic_line(value, 0, line[0..3]);
    try std.testing.expectEqualStrings("abc", line[0..first]);
    const second = diagnostic_line(value, 3, line[0..3]);
    try std.testing.expectEqualStrings("def", line[0..second]);
    try std.testing.expectEqual(@as(usize, 2), review_text_rows(value, 3));
    try std.testing.expect(review_columns(16) == null);
    try std.testing.expect(review_controls(layout_for(20, 10), 1) == null);
}

test "LSP review readiness excludes active input timestamp" {
    var storage: ui_lsp.Storage = undefined;
    var service: ui_lsp.Service = undefined;
    service.init(&storage);
    service.stage = .review;
    const identity = std.mem.zeroes(@import("../lsp/client.zig").Identity);
    service.identity = identity;
    var opened: Opened = undefined;
    opened.lsp = &service;
    opened.lsp_job = null;
    var model = Model{ .mode = .diff, .status = "test", .layout = layout_for(640, 380) };
    model.lsp_review_identity = identity;
    model.lsp_review_width = model.layout.width;
    model.lsp_review_height = model.layout.height;
    model.lsp_review_presented_at = 10;
    try std.testing.expect(lsp_review_ready(&model, &opened));
    try std.testing.expect(!lsp_review_confirmation_allowed(&model, &opened));
    model.lsp_confirmation_timestamp = 10;
    try std.testing.expect(!lsp_review_confirmation_allowed(&model, &opened));
    model.lsp_confirmation_timestamp = 11;
    try std.testing.expect(lsp_review_confirmation_allowed(&model, &opened));
    model.palette_open = true;
    latch_lsp_review(&model, &opened, true);
    try std.testing.expect(lsp_review_ready(&model, &opened));
    try std.testing.expectEqual(@as(u64, 10), model.lsp_review_presented_at);
    clear_lsp_review_latch(&model);
    latch_lsp_review(&model, &opened, true);
    try std.testing.expect(model.lsp_review_identity == null);
}

test "LSP review blocks covered toolbar clicks" {
    var storage: ui_lsp.Storage = undefined;
    var service: ui_lsp.Service = undefined;
    service.init(&storage);
    service.stage = .review;
    var opened: Opened = undefined;
    opened.lsp = &service;
    opened.lsp_job = null;
    var model = Model{ .mode = .diff, .status = "test", .layout = layout_for(640, 380) };
    const button = model.layout.buttons[action_index(.choose_left)];
    const window: *sdl.SDL_Window = undefined;
    try std.testing.expect(!(try handle_click(button.x + 1, button.y + 1, false, window, &model, &opened)));
    try std.testing.expect(try handle_key(sdl.SDLK_S, 0, window, &model, &opened));
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    var input: sdl.SDL_Event = .{ .text = .{ .type = sdl.SDL_EVENT_TEXT_INPUT, .text = @constCast("x") } };
    try std.testing.expect(!(try handle_event(&input, window, &model, &opened)));
    try std.testing.expectEqualStrings("test", model.status);
}

test "native diagnostic view preserves bytes, tabs, escapes and partial horizontal cells" {
    const source = "a\t\r\x00\x1B\x7F\xC3\xA9z";
    var output: [64]u8 = undefined;
    const length = diagnostic_line(source, 0, &output);
    try std.testing.expectEqualStrings("a   \\x0D\\x00\\x1B\\x7F\\xC3\\xA9z", output[0..length]);
    const partial = diagnostic_line(source, 6, output[0..5]);
    try std.testing.expectEqualStrings("0D\\x0", output[0..partial]);
    try std.testing.expectEqualStrings("a\t\r\x00\x1B\x7F\xC3\xA9z", source);
    try std.testing.expectEqual(@as(usize, 0), diagnostic_line(source, 99, &output));
}

test "native line index retains empty lines and trailing LF" {
    var offsets: [8]u32 = undefined;
    var lines = Lines{ .offsets = &offsets };
    index_lines(&lines, "a\n\nb\n");
    try std.testing.expectEqual(@as(usize, 4), lines.count);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 5 }, lines.offsets[0..lines.count]);
    index_lines(&lines, "");
    try std.testing.expectEqual(@as(usize, 1), lines.count);
    try std.testing.expectEqual(@as(u32, 0), lines.offsets[0]);
}

test "native line index maps mixed CR LF and CRLF to editor and LSP positions" {
    const source = "a\rb\r\nc\n";
    var offsets: [source.len + 1]u32 = undefined;
    var lines = Lines{ .offsets = &offsets };
    index_lines(&lines, source);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 5, 7 }, lines.offsets[0..lines.count]);
    try std.testing.expectEqual(@as(usize, 2), editor.offset_for_column(source, lines.offsets[1], 0));
    try std.testing.expectEqual(@as(usize, 3), editor.offset_for_column(source, lines.offsets[1], 1));
    const position = lsp_position(source, lines, 3);
    try std.testing.expectEqual(@as(u32, 1), position.line);
    try std.testing.expectEqual(@as(u32, 1), position.character);
}

test "native editor replacement reindexes before scrolling shortened result" {
    var newline_result: [100]u8 = undefined;
    var ascii_replacement: [100]u8 = undefined;
    @memset(&newline_result, '\n');
    @memset(&ascii_replacement, 'x');
    var result: [256]u8 = undefined;
    var scratch: [256]u8 = undefined;
    var history: [4096]u8 = undefined;
    var records: [128]session.Record = undefined;
    var offsets: [3][128]u32 = undefined;
    var opened = Opened{
        .active = try session.Session.init_two_way(&newline_result, "", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
        .labels = .{ .base = "none", .left = "left", .right = "right", .output = "output" },
        .destination = "output",
        .input_paths = .{ .base = null, .left = "left", .right = "right" },
        .lines = undefined,
        .save = undefined,
    };
    try opened.active.choose(opened.active.generation, .left);
    for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    var state = editor.State.init(opened.active.result()).?;
    state.select_all(opened.active.result());
    var model = Model{ .mode = .diff, .status = "test", .editor = state, .focus = 1 };
    model.scroll[1].line = 100;
    try replace_editor_selection(&ascii_replacement, &model, &opened);
    try std.testing.expectEqual(@as(usize, 100), opened.active.result().len);
    try std.testing.expectEqual(@as(usize, 1), opened.lines[1].count);
    try std.testing.expectEqual(@as(usize, 0), model.scroll[1].line);
    scroll_view(&model, &opened, 1, 0);
    model.editor.?.select_all(opened.active.result());
    try replace_editor_selection("x", &model, &opened);
    try std.testing.expectEqualStrings("x", opened.active.result());
    scroll_view(&model, &opened, 1, 0);
    model.editor.?.select_all(opened.active.result());
    try replace_editor_selection("", &model, &opened);
    scroll_view(&model, &opened, 1, 0);
    try std.testing.expectEqualStrings("", opened.active.result());
    try std.testing.expectEqual(@as(usize, 0), model.scroll[1].line);
}

test "native LSP position ignores display width of tabs" {
    const source = "\tfoo\n";
    var offsets: [source.len + 1]u32 = undefined;
    var lines = Lines{ .offsets = &offsets };
    index_lines(&lines, source);
    try std.testing.expectEqual(@as(u32, 1), lsp_position(source, lines, 1).character);
    const position = lsp_position(source, lines, 4);
    try std.testing.expectEqual(@as(u32, 0), position.line);
    try std.testing.expectEqual(@as(u32, 4), position.character);
}

test "native palette matches aliases and never applies query letters" {
    var model = Model{ .mode = .welcome, .status = "test", .palette_open = true };
    append_query(&model, "publish");
    try std.testing.expectEqual(Action.save, actions[model.selected].action);
    model.query_len = 0;
    append_query(&model, "ReDo");
    try std.testing.expectEqual(Action.redo, actions[model.selected].action);
    try std.testing.expect(!matches(&model, 1));
    try std.testing.expect(disabled_reason(model.selected, &model, null) != null);
    handle_palette_key(sdl.SDLK_L, &model, null);
    try std.testing.expectEqualStrings("test", model.status);
    try std.testing.expectEqual(Action.redo, actions[model.selected].action);
    model.query_len = 0;
    move_selection(&model, true);
    try std.testing.expectEqual(Action.mark_resolved, actions[model.selected].action);
    try std.testing.expectEqual(@as(usize, 0), shifted(0, -3, 10));
    try std.testing.expectEqual(@as(usize, 10), shifted(9, 3, 10));
}

test "native change navigation and highlighting use exact source ranges" {
    var offsets: [5]u32 = undefined;
    var lines = Lines{ .offsets = &offsets };
    index_lines(&lines, "a\nb\n");
    const changes = [_]@import("../engine/multihunk.zig").Hunk{.{ .base = .{ .start = 0, .end = 2 }, .other = .{ .start = 0, .end = 2 } }};
    try std.testing.expect(line_changed(&changes, 0, 2, true));
    try std.testing.expect(!line_changed(&changes, 2, 4, true));
    try std.testing.expectEqual(@as(usize, 1), line_for_offset(lines, 2));
}

test "native session status explicitly distinguishes unresolved review state" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [64]u8 = undefined;
    var records: [4]session.Record = undefined;
    const active = try session.Session.init(.{ .base = "a\r\n", .left = "l\r\n", .right = "r\r\n" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records });
    try std.testing.expect(active.current_state().unresolved);
    try std.testing.expect(std.mem.indexOf(u8, session_status(&active), "UNRESOLVED") != null);
    try std.testing.expect(std.mem.indexOf(u8, session_status(&active), "review") != null);
    const result_role = if (active.current_state().unresolved) "RESULT | UNRESOLVED | REVIEW REQUIRED" else "RESULT | PENDING UNSAVED | REVIEW STATUS";
    try std.testing.expect(std.mem.indexOf(u8, result_role, "UNRESOLVED") != null);
}

test "native degradation status retains reason after explicit resolution" {
    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [128]u8 = undefined;
    var records: [4]session.Record = undefined;
    var base_members: [2]json_merge.Member = undefined;
    var left_members: [2]json_merge.Member = undefined;
    var right_members: [2]json_merge.Member = undefined;
    var base_keys: [16]u8 = undefined;
    var left_keys: [16]u8 = undefined;
    var right_keys: [16]u8 = undefined;
    var scanner: [256]u8 = undefined;
    var workspace = json_merge.Workspace{ .base = .{ .members = &base_members, .keys = &base_keys }, .left = .{ .members = &left_members, .keys = &left_keys }, .right = .{ .members = &right_members, .keys = &right_keys }, .scanner_memory = &scanner, .max_work = 0 };
    var active = try session.Session.init(.{ .base = "{\"a\":1}", .left = "{\"a\":2}", .right = "{\"a\":3}" }, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records, .json_workspace = &workspace });
    try std.testing.expect(std.mem.indexOf(u8, session_status(&active), "unresolved") != null);
    try active.choose(active.identity().generation, .left);
    const status = session_status(&active);
    try std.testing.expect(std.mem.indexOf(u8, status, "RESOURCE-LIMITED") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "unresolved") == null);
}

test "native real controls guard base, require visible help, choose, undo and scroll" {
    var result: [32]u8 = undefined;
    var scratch: [32]u8 = undefined;
    var history: [256]u8 = undefined;
    var records: [8]session.Record = undefined;
    var offsets: [3][8]u32 = undefined;
    var opened = Opened{
        .active = try session.Session.init_two_way("left\n", "right\n", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
        .labels = .{ .base = "none", .left = "left", .right = "right", .output = "output" },
        .destination = "output",
        .input_paths = .{ .base = null, .left = "left", .right = "right" },
        .lines = undefined,
        .save = undefined,
    };
    var save_paths: [save.path_storage_capacity]u8 = undefined;
    var save_content: [save.content_capacity]u8 = undefined;
    var save_preflight: [save.content_capacity]u8 = undefined;
    try opened.init_save_with(std.testing.io, &save_paths, &save_content, &save_preflight);
    defer opened.deinit();
    for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    var model = Model{ .mode = .diff, .status = "test" };
    try std.testing.expect(disabled_reason(0, &model, &opened) != null);
    apply_action(0, &model, &opened);
    try std.testing.expectEqualStrings("right\n", opened.active.result());
    request_action(1, &model, &opened);
    try std.testing.expectEqualStrings("right\n", opened.active.result());
    model.help_presented = 1;
    request_action(1, &model, &opened);
    try std.testing.expectEqualStrings("left\n", opened.active.result());
    try std.testing.expect(disabled_reason(4, &model, &opened) == null);
    apply_action(4, &model, &opened);
    try std.testing.expectEqualStrings("right\n", opened.active.result());
    try std.testing.expect(disabled_reason(5, &model, &opened) == null);
    scroll_view(&model, &opened, 999, 4);
    try std.testing.expectEqual(@as(usize, 1), model.scroll[1].line);
    try std.testing.expectEqual(@as(usize, 4), model.scroll[1].column);
    try std.testing.expect(disabled_reason(7, &model, &opened) == null);
    try std.testing.expect(disabled_reason(8, &model, &opened) != null);
    model.durable_generation = opened.active.generation;
    model.durable_receipt = .{ .bytes_written = opened.active.result().len, .digest = std.mem.zeroes([32]u8) };
    apply_action(8, &model, &opened);
    try std.testing.expect(!model.completed);
    try std.testing.expect(model.completion_job_id != null);
}

test "native collapsed cut retains result state without clipboard access" {
    var result: [16]u8 = undefined;
    var scratch: [16]u8 = undefined;
    var history: [64]u8 = undefined;
    var records: [4]session.Record = undefined;
    var offsets: [3][8]u32 = undefined;
    var clipboard: [4:0]u8 = .{ 'k', 'e', 'e', 'p' };
    var opened = Opened{
        .active = try session.Session.init_two_way("left", "abc", .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
        .labels = .{ .base = "none", .left = "left", .right = "right", .output = "output" },
        .destination = "output",
        .input_paths = .{ .base = null, .left = "left", .right = "right" },
        .lines = undefined,
        .save = undefined,
    };
    defer opened.deinit();
    for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
    index_lines(&opened.lines[0], opened.active.inputs.left);
    index_lines(&opened.lines[1], opened.active.result());
    index_lines(&opened.lines[2], opened.active.inputs.right);
    var model = Model{ .mode = .diff, .status = "test", .editor = editor.State.init(opened.active.result()), .clipboard = clipboard[0.. :0], .durable_generation = opened.active.generation, .durable_receipt = .{ .bytes_written = 3, .digest = std.mem.zeroes([32]u8) }, .lsp_synced_generation = opened.active.generation };
    model.editor.?.cursor = 1;
    model.editor.?.anchor = 1;
    const generation = opened.active.generation;
    const record_count = opened.active.record_count;
    const history_used = opened.active.history_used;
    const receipt = model.durable_receipt.?;
    apply_action(action_index(.cut), &model, &opened);
    try std.testing.expectEqualStrings("abc", opened.active.result());
    try std.testing.expectEqual(generation, opened.active.generation);
    try std.testing.expectEqual(record_count, opened.active.record_count);
    try std.testing.expectEqual(history_used, opened.active.history_used);
    try std.testing.expect(std.meta.eql(receipt, model.durable_receipt.?));
    try std.testing.expectEqual(@as(?u64, generation), model.durable_generation);
    try std.testing.expectEqual(@as(?u64, generation), model.lsp_synced_generation);
    try std.testing.expectEqual(@as(usize, 0), model.clipboard_len);
    try std.testing.expectEqualSlices(u8, "keep", clipboard[0..4]);
    try std.testing.expectEqual(@as(usize, 1), model.editor.?.cursor);
    try std.testing.expectEqual(@as(usize, 1), model.editor.?.anchor);
    try std.testing.expectEqualStrings("CUT REQUIRES RESULT SELECTION | result unchanged", model.status);
    // A selected Cut whose bounded clipboard storage is unavailable must not delete bytes either.
    model.clipboard = null;
    model.editor.?.anchor = 0;
    model.editor.?.cursor = 2;
    apply_action(action_index(.cut), &model, &opened);
    try std.testing.expectEqualStrings("ProvisionalCapacityExceeded", model.status);
    try std.testing.expectEqualStrings("abc", opened.active.result());
    try std.testing.expectEqual(generation, opened.active.generation);
    try std.testing.expectEqual(record_count, opened.active.record_count);
    try std.testing.expectEqual(history_used, opened.active.history_used);
    try std.testing.expect(std.meta.eql(receipt, model.durable_receipt.?));
    try std.testing.expectEqual(@as(usize, 0), model.editor.?.anchor);
    try std.testing.expectEqual(@as(usize, 2), model.editor.?.cursor);
}

test "native controls remain read-only with exact whole-side recovery" {
    for ([_][]const u8{ "\x00right\xff", "\x1babc", "\x7fabc", "\x1fabc" }) |unsupported| {
        var result: [16]u8 = undefined;
        var scratch: [16]u8 = undefined;
        var history: [64]u8 = undefined;
        var records: [4]session.Record = undefined;
        var offsets: [3][17]u32 = undefined;
        var opened = Opened{
            .active = try session.Session.init_two_way("left\r\n", unsupported, .{ .result = &result, .scratch = &scratch, .history = &history, .records = &records }),
            .labels = .{ .base = "none", .left = "left", .right = "right", .output = "output" },
            .destination = "output",
            .input_paths = .{ .base = null, .left = "left", .right = "right" },
            .lines = undefined,
            .save = undefined,
        };
        for (&opened.lines, &offsets) |*lines, *region| lines.* = .{ .offsets = region };
        index_lines(&opened.lines[0], opened.active.inputs.left);
        index_lines(&opened.lines[1], opened.active.result());
        index_lines(&opened.lines[2], opened.active.inputs.right);
        var model = Model{ .mode = .diff, .status = "test", .editor = editor.State.init(opened.active.result()) };
        try std.testing.expect(model.editor == null);
        try std.testing.expectEqualStrings(unsupported, opened.active.result());
        for ([_]usize{ action_index(.copy), action_index(.cut), action_index(.paste), action_index(.select_all) }) |index| {
            try std.testing.expect(disabled_reason(index, &model, &opened) != null);
        }
        try std.testing.expect(disabled_reason(action_index(.choose_left), &model, &opened) == null);
        try std.testing.expect(disabled_reason(action_index(.choose_right), &model, &opened) == null);
        apply_action(action_index(.choose_left), &model, &opened);
        try std.testing.expectEqualStrings("left\r\n", opened.active.result());
        try std.testing.expect(model.editor != null);
        apply_action(action_index(.choose_right), &model, &opened);
        try std.testing.expectEqualStrings(unsupported, opened.active.result());
        try std.testing.expect(model.editor == null);
    }
}

test "native event loop exits only after durable completion drain" {
    var model = Model{ .mode = .diff, .status = "test" };
    try std.testing.expect(event_loop_finished(false, &model));
    model.completed = true;
    try std.testing.expect(!event_loop_finished(true, &model));
    model.exit_ready = true;
    try std.testing.expect(event_loop_finished(true, &model));
    model.completed = false;
    try std.testing.expect(!event_loop_finished(true, &model));
}

test "native exit drain retains picker callback then exits without LSP" {
    var opened: Opened = undefined;
    opened.lsp = null;
    opened.lsp_job = null;
    var model = Model{ .mode = .diff, .status = "test", .lsp_picker_pending = true };
    var redraw = false;
    request_exit_drain(&model, &opened);
    advance_exit_drain(&model, &opened, &redraw);
    try std.testing.expect(model.exit_requested and !model.exit_ready);
    model.lsp_picker_pending = false;
    advance_exit_drain(&model, &opened, &redraw);
    try std.testing.expect(model.exit_ready);
}

test "native exit drain failure retains result" {
    const storage = try std.testing.allocator.create(ui_lsp.Storage);
    defer std.testing.allocator.destroy(storage);
    const service = try std.testing.allocator.create(ui_lsp.Service);
    defer std.testing.allocator.destroy(service);
    service.init(storage);
    service.stage = .review;
    var opened: Opened = undefined;
    opened.lsp = service;
    opened.lsp_job = null;
    var model = Model{ .mode = .diff, .status = "test", .exit_requested = true, .completed = true };
    model.durable_generation = 7;
    const receipt = @import("../output.zig").Receipt{ .bytes_written = 6, .digest = std.mem.zeroes([32]u8) };
    model.durable_receipt = receipt;
    var redraw = false;
    advance_exit_drain(&model, &opened, &redraw);
    try std.testing.expect(!model.exit_requested and !model.exit_ready and !model.completed and redraw);
    try std.testing.expectEqual(@as(?u64, 7), model.durable_generation);
    try std.testing.expect(std.meta.eql(receipt, model.durable_receipt.?));
    try std.testing.expect(std.mem.indexOf(u8, model.status, "FAILED") != null);
}
