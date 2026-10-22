/// Stable action identities shared by menus, keys, palette, contextual UI, and help.
pub const Id = enum {
    choose_base,
    choose_left,
    choose_right,
    reset,
    undo,
    redo,
    mark_resolved,
    export_recovery,
    find_recovery_drafts,
    save,
    complete,
    next_change,
    copy,
    cut,
    paste,
    select_all,
    attach_result_language_server,
    confirm_result_language_server_trust,
    detach_result_language_server,
    hover,
    symbols,
    definition,
    references,
    close_repository,
};

pub const Info = struct {
    id: Id,
    name: []const u8,
    aliases: []const u8,
    help: []const u8,
    binding: []const u8,
};

pub const result_actions = [_]Info{
    .{ .id = .choose_base, .name = "Base", .aliases = "base choose", .help = "Replace whole result with merge base bytes.", .binding = "provisional B" },
    .{ .id = .choose_left, .name = "Left", .aliases = "left choose", .help = "Replace whole result with left source bytes.", .binding = "provisional L" },
    .{ .id = .choose_right, .name = "Right", .aliases = "right choose", .help = "Replace whole result with right source bytes.", .binding = "provisional R" },
    .{ .id = .reset, .name = "Reset", .aliases = "reset original", .help = "Restore initial result; reset is undoable.", .binding = "Esc" },
    .{ .id = .undo, .name = "Undo", .aliases = "undo", .help = "Restore previous in-memory result decision.", .binding = "Ctrl+Z" },
    .{ .id = .redo, .name = "Redo", .aliases = "redo", .help = "Restore next in-memory result decision.", .binding = "Ctrl+Y" },
    .{ .id = .mark_resolved, .name = "Resolve", .aliases = "resolve", .help = "Mark in-memory result resolved; does not save.", .binding = "provisional M" },
    .{ .id = .export_recovery, .name = "Export encrypted recovery draft", .aliases = "recovery draft export encrypted", .help = "Export an additional encrypted DPAPI draft to a chosen new file; automatic recovery remains separate.", .binding = "Ctrl+Shift+S" },
    .{ .id = .find_recovery_drafts, .name = "Find recovery drafts", .aliases = "find discover recovery drafts", .help = "Scan existing protected recovery storage; select a draft to restore after choosing a new output.", .binding = "F" },
    .{ .id = .save, .name = "Save", .aliases = "save publish", .help = "Publish result as a durable new destination file.", .binding = "Ctrl+S" },
    .{ .id = .complete, .name = "Complete", .aliases = "complete finish", .help = "Finish only after current durable output is verified.", .binding = "Enter" },
    .{ .id = .next_change, .name = "Next change", .aliases = "next change", .help = "Navigate exact bounded line-diff changes in source panes.", .binding = "provisional N" },
    .{ .id = .copy, .name = "Copy", .aliases = "copy clipboard", .help = "Copy selected result ASCII bytes to clipboard.", .binding = "Ctrl+C" },
    .{ .id = .cut, .name = "Cut", .aliases = "cut clipboard", .help = "Copy selection then delete it from result.", .binding = "Ctrl+X" },
    .{ .id = .paste, .name = "Paste", .aliases = "paste clipboard", .help = "Insert ASCII clipboard bytes at result selection.", .binding = "Ctrl+V" },
    .{ .id = .select_all, .name = "Select all", .aliases = "select all", .help = "Select whole editable result.", .binding = "Ctrl+A" },
    .{ .id = .attach_result_language_server, .name = "Attach result language server", .aliases = "attach lsp language server", .help = "Choose exact server executable and workspace, then review one-session trust before it starts.", .binding = "provisional" },
    .{ .id = .confirm_result_language_server_trust, .name = "Confirm result language server trust", .aliases = "confirm lsp trust", .help = "Start reviewed server once; it may read local workspace files/config and use network.", .binding = "provisional" },
    .{ .id = .detach_result_language_server, .name = "Detach result language server", .aliases = "detach revoke lsp trust", .help = "Stop, reap, and revoke current result language server.", .binding = "provisional" },
    .{ .id = .hover, .name = "Hover", .aliases = "lsp hover", .help = "Request hover at current result caret from attached server.", .binding = "provisional" },
    .{ .id = .symbols, .name = "Symbols", .aliases = "lsp symbols document symbols", .help = "Request result document symbols from attached server.", .binding = "provisional" },
    .{ .id = .definition, .name = "Definition", .aliases = "lsp go definition", .help = "Request definition at current result caret from attached server.", .binding = "provisional" },
    .{ .id = .references, .name = "References", .aliases = "lsp references", .help = "Request references at current result caret from attached server.", .binding = "provisional" },
};

/// Repository record actions are deliberately whole-file only in this provisional UI.
/// Hunks, lines, amend, and fixup remain unavailable rather than being implied.
pub const RepositoryId = enum { refresh, review_worktree_status, history_selected, blame_selected, search_history, stage_selected, unstage_selected, commit_staged, branch_create, branch_rename, branch_delete, fetch, push, revoke_record_trust, close };
pub const RepositoryInfo = struct { id: RepositoryId, name: []const u8, aliases: []const u8, help: []const u8, binding: []const u8 };
pub const repository_actions = [_]RepositoryInfo{
    .{ .id = .refresh, .name = "Refresh repository", .aliases = "refresh reload metadata", .help = "Re-run bounded metadata/history inspection; worktree status remains not scanned.", .binding = "R" },
    .{ .id = .review_worktree_status, .name = "Review worktree status scan", .aliases = "status scan worktree filters clean process", .help = "Review one worktree status scan. Configured clean/process filters may execute; grant expires after one scan attempt.", .binding = "provisional" },
    .{ .id = .history_selected, .name = "History selected file", .aliases = "file history commits", .help = "Show bounded commit history for selected literal path, following renames.", .binding = "Palette" },
    .{ .id = .blame_selected, .name = "Blame selected file at HEAD", .aliases = "file blame annotations", .help = "Show read-only line attribution for committed HEAD content.", .binding = "Palette" },
    .{ .id = .search_history, .name = "Search history", .aliases = "history search query", .help = "Enter literal text; search bounded commit subjects/bodies for selected file.", .binding = "Palette" },
    .{ .id = .stage_selected, .name = "Stage selected file", .aliases = "stage add selected file index", .help = "Preflight then confirm one exact installed-Git whole-file stage operation.", .binding = "S" },
    .{ .id = .unstage_selected, .name = "Unstage selected file", .aliases = "unstage restore selected file index", .help = "Preflight then confirm one exact installed-Git whole-file unstage operation.", .binding = "U" },
    .{ .id = .commit_staged, .name = "Commit staged changes", .aliases = "commit record staged index", .help = "Enter an ASCII commit message, preflight, then confirm one exact installed-Git commit.", .binding = "C" },
    .{ .id = .branch_create, .name = "Create branch", .aliases = "branch create new start point", .help = "Enter bounded branch name and start ref, review resolved target OID, then confirm.", .binding = "B" },
    .{ .id = .branch_rename, .name = "Rename branch", .aliases = "branch rename selected", .help = "Rename selected local branch after exact preflight review.", .binding = "N" },
    .{ .id = .branch_delete, .name = "Delete merged branch", .aliases = "branch delete safe merged", .help = "Delete selected merged, non-current, non-worktree branch after exact review.", .binding = "D" },
    .{ .id = .fetch, .name = "Fetch configured remote", .aliases = "fetch remote network", .help = "Enter configured remote name, review network risk, then confirm one fetch.", .binding = "provisional" },
    .{ .id = .push, .name = "Push configured remote", .aliases = "push remote network", .help = "Enter configured remote name, review network risk, then confirm one normal push.", .binding = "provisional" },
    .{ .id = .revoke_record_trust, .name = "Revoke record trust", .aliases = "revoke trust stage unstage commit", .help = "Discard in-memory one-operation record authorization.", .binding = "provisional" },
    .{ .id = .close, .name = "Close repository", .aliases = "close exit quit", .help = "Close this repository inspection window.", .binding = "Esc" },
};

pub fn name(action: Id) []const u8 {
    for (result_actions) |info| if (info.id == action) return info.name;
    return "Close repository";
}

pub fn aliases(action: Id) []const u8 {
    for (result_actions) |info| if (info.id == action) return info.aliases;
    return "close exit quit";
}
