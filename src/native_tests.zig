const native = @import("ui/native.zig");
const repository = @import("ui/repository.zig");
const options = @import("native_test_options");

test {
    _ = native;
}

test "SDL GPU renderer event integration is opt-in" {
    if (!options.gpu) return;
    try native.gpu_event_integration_test();
}

test "SDL GUI repository inspection accepts injected palette and selection events" {
    if (!options.gpu) return;
    try repository.gpu_repository_event_integration_test();
}

test "SDL GPU selected-file history, literal search, and HEAD blame use synthetic revisions" {
    if (!options.gpu) return;
    try repository.gpu_repository_file_history_blame_test();
}

test "SDL GUI explicitly reviews worktree status scan before stage and unstage" {
    if (!options.gpu) return;
    try repository.gpu_repository_record_stage_unstage_test();
}

test "SDL GUI reviews sanitized local remote endpoints before fetch and normal push" {
    if (!options.gpu) return;
    try repository.gpu_repository_remote_review_test();
}

test "SDL GUI initial load copies launcher paths and enters editing" {
    if (!options.gpu) return;
    try native.gpu_initial_load_e2e_test();
}

test "SDL GPU JSON files compose distinct fields, Save, and Complete; capacity fallback stays unresolved" {
    if (!options.gpu) return;
    try native.gpu_json_merge_e2e_test();
}

test "SDL GPU Zig declarations compose exact bytes through Save and Complete; malformed source stays unresolved" {
    if (!options.gpu) return;
    try native.gpu_zig_merge_e2e_test();
}

test "SDL GUI Save completes only after durable output" {
    if (!options.gpu) return;
    try native.gpu_save_e2e_test();
}

test "SDL GUI recovery discovery selects encrypted draft and restores exact result; corrupt record skipped" {
    if (!options.gpu) return;
    try native.gpu_auto_recovery_e2e_test();
}

test "SDL GUI encrypted recovery export and welcome restore revalidate originals" {
    if (!options.gpu) return;
    try native.gpu_recovery_restore_e2e_test();
}

test "SDL GUI Save rejects externally replaced output" {
    if (!options.gpu) return;
    try native.gpu_save_external_replacement_test();
}

test "SDL GUI Save rejects externally deleted output" {
    if (!options.gpu) return;
    try native.gpu_save_external_deletion_test();
}

test "SDL GUI Save marks stale publication unsaved" {
    if (!options.gpu) return;
    try native.gpu_save_stale_publication_test();
}

test "SDL GUI Save never overwrites existing destination" {
    if (!options.gpu) return;
    try native.gpu_save_existing_destination_test();
}

test "SDL GUI result LSP fixture trusts only after review and rejects stale diagnostics" {
    if (!options.gpu) return;
    try native.gpu_lsp_fixture_e2e_test(options.lsp_fixture_executable);
}

test "SDL GUI close remains incomplete during pending completion" {
    if (!options.gpu) return;
    try native.gpu_save_close_pending_completion_test();
}
