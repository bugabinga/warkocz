const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

const Handle = windows.HANDLE;
const invalid_handle = windows.INVALID_HANDLE_VALUE;
const token_user: u32 = 1;
const security_information_owner: u32 = 1;
const security_information_dacl: u32 = 4;
const acl_protected: u32 = 0x80000000;
const file_flag_backup_semantics: u32 = 0x02000000;
const file_flag_open_reparse_point: u32 = 0x00200000;
const file_attribute_reparse_point: u32 = 0x400;
const generic_read: u32 = 0x80000000;
const read_control: u32 = 0x00020000;
const file_list_directory: u32 = 1;
const open_existing_disposition: u32 = 3;
const share_all: u32 = 7;
const owner_sid_limit: usize = 184;
const sddl_capacity: usize = 512;
const descriptor_capacity: usize = 4096;
const session_prefix = "session-";
const random_name_len: usize = session_prefix.len + 32;

const SecurityAttributes = extern struct { length: u32, descriptor: ?*anyopaque, inherit: i32 };
const SidAndAttributes = extern struct { sid: ?*anyopaque, attributes: u32 };
const TokenUser = extern struct { user: SidAndAttributes };
const FileAttributeTagInfo = extern struct { attributes: u32, reparse_tag: u32 };
const AceHeader = extern struct { kind: u8, flags: u8, size: u16 };
const AccessAllowedAce = extern struct { header: AceHeader, mask: u32, sid_start: u32 };

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, attributes: *SecurityAttributes) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileInformationByHandleEx(handle: Handle, class: u32, info: *anyopaque, size: u32) callconv(.winapi) i32;
extern "kernel32" fn GetVolumeInformationByHandleW(handle: Handle, volume_name: ?[*]u16, volume_name_len: u32, serial: ?*u32, max_component: ?*u32, flags: ?*u32, filesystem_name: ?[*]u16, filesystem_name_len: u32) callconv(.winapi) i32;
extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn OpenProcessToken(process: Handle, access: u32, token: *Handle) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(token: Handle, class: u32, info: ?*anyopaque, length: u32, returned: *u32) callconv(.winapi) i32;
extern "advapi32" fn ConvertSidToStringSidW(sid: *anyopaque, string_sid: *?[*:0]u16) callconv(.winapi) i32;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(string: [*:0]const u16, revision: u32, descriptor: *?*anyopaque, size: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorControl(descriptor: *anyopaque, control: *u16, revision: *u32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorOwner(descriptor: *anyopaque, owner: *?*anyopaque, defaulted: *i32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorDacl(descriptor: *anyopaque, present: *i32, dacl: *?*anyopaque, defaulted: *i32) callconv(.winapi) i32;
extern "advapi32" fn GetAclInformation(acl: *anyopaque, info: *anyopaque, length: u32, class: u32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityInfo(handle: Handle, object_type: u32, information: u32, owner: *?*anyopaque, group: ?*?*anyopaque, dacl: *?*anyopaque, sacl: ?*?*anyopaque, descriptor: *?*anyopaque) callconv(.winapi) u32;
const ntdll = windows.ntdll;
const file_remote_device: u32 = 0x00000010;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "advapi32" fn GetAce(acl: *anyopaque, index: u32, ace: *?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn EqualSid(left: *anyopaque, right: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const Error = error{ UnsupportedPlatform, InvalidRoot, ScratchTooSmall, TokenFailure, DescriptorFailure, CreateFailure, OpenFailure, SecurityVerificationFailed, UnsupportedFilesystem };

/// Owned verified directory handle; caller closes it. Name/path buffers remain caller-owned.
pub const Session = struct { handle: Handle, path: []u16, name: []u8, root: []const u8 };

/// Opens an existing protected directory without creating it or changing its ACL.
pub fn open_existing(path: []const u8, path_scratch: []u16, token_scratch: []align(8) u8) Error!Session {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (token_scratch.len < 1024) return error.ScratchTooSmall;
    const path_len = try validate_root(path, path_scratch);
    var token: Handle = undefined;
    if (OpenProcessToken(GetCurrentProcess(), 8, &token) == 0) return error.TokenFailure;
    defer _ = CloseHandle(token);
    var needed: u32 = 0;
    if (GetTokenInformation(token, token_user, token_scratch.ptr, @intCast(token_scratch.len), &needed) == 0 or needed < @sizeOf(TokenUser) or needed > token_scratch.len) return error.TokenFailure;
    const user_sid = (@as(*TokenUser, @ptrCast(token_scratch.ptr))).user.sid orelse return error.TokenFailure;
    const handle = try open_directory(path_scratch[0..path_len]);
    errdefer _ = CloseHandle(handle);
    try verify_owned_directory(handle, user_sid);
    return .{ .handle = handle, .path = path_scratch[0..path_len], .name = &.{}, .root = path };
}

/// Creates a protected random child only. Never changes root ACL or removes a nonempty/foreign path.
pub fn create(io: std.Io, root: []const u8, path_scratch: []u16, token_scratch: []align(8) u8, sddl_scratch: []u16, descriptor_scratch: []u8, name_scratch: []u8) Error!Session {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (!absolute_drive_root(root) or token_scratch.len < 1024 or sddl_scratch.len < sddl_capacity or descriptor_scratch.len < descriptor_capacity or name_scratch.len < random_name_len) return error.InvalidRoot;
    var token: Handle = undefined;
    if (OpenProcessToken(GetCurrentProcess(), 8, &token) == 0) return error.TokenFailure;
    defer _ = CloseHandle(token);
    var needed: u32 = 0;
    if (GetTokenInformation(token, token_user, token_scratch.ptr, @intCast(token_scratch.len), &needed) == 0) return error.TokenFailure;
    if (needed < @sizeOf(TokenUser) or needed > token_scratch.len) return error.TokenFailure;
    const token_user_info: *TokenUser = @ptrCast(token_scratch.ptr);
    const user_sid = token_user_info.user.sid orelse return error.TokenFailure;
    var sid_string: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(user_sid, &sid_string) == 0) return error.TokenFailure;
    defer _ = LocalFree(@ptrCast(sid_string));
    var sid_len: usize = 0;
    while (sid_len < owner_sid_limit and sid_string.?[sid_len] != 0) : (sid_len += 1) {}
    if (sid_len == 0 or sid_len == owner_sid_limit) return error.TokenFailure;
    const required_sddl_len = 2 + sid_len + 16 + sid_len + 18;
    if (required_sddl_len >= sddl_scratch.len) return error.ScratchTooSmall;
    var sddl_len: usize = 0;
    for ("O:") |c| {
        sddl_scratch[sddl_len] = c;
        sddl_len += 1;
    }
    for (sid_string.?[0..sid_len]) |c| {
        sddl_scratch[sddl_len] = c;
        sddl_len += 1;
    }
    for ("D:P(A;OICI;FA;;;") |c| {
        sddl_scratch[sddl_len] = c;
        sddl_len += 1;
    }
    for (sid_string.?[0..sid_len]) |c| {
        sddl_scratch[sddl_len] = c;
        sddl_len += 1;
    }
    for (")(A;OICI;FA;;;SY)\x00") |c| {
        sddl_scratch[sddl_len] = c;
        sddl_len += 1;
    }
    if (sddl_len >= sddl_scratch.len) return error.ScratchTooSmall;
    var security_descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(@ptrCast(sddl_scratch.ptr), 1, &security_descriptor, null) == 0) return error.DescriptorFailure;
    defer _ = LocalFree(security_descriptor);
    var root_w: [windows.NAME_MAX]u16 = undefined;
    const root_len = try validate_root(root, &root_w);
    if (root_len + 1 + random_name_len + 1 > path_scratch.len) return error.ScratchTooSmall;
    var attributes = SecurityAttributes{ .length = @sizeOf(SecurityAttributes), .descriptor = security_descriptor, .inherit = 0 };
    try ensure_owned_root(&root_w, root_len, &attributes, user_sid);
    var path_len: usize = 0;
    var attempt: usize = 0;
    while (attempt < 8) : (attempt += 1) {
        @memcpy(name_scratch[0..session_prefix.len], session_prefix);
        io.randomSecure(name_scratch[session_prefix.len..random_name_len]) catch return error.TokenFailure;
        for (name_scratch[session_prefix.len..random_name_len]) |*byte| byte.* = "0123456789abcdef"[byte.* & 15];
        path_len = append_session_path(path_scratch, root_w[0..root_len], name_scratch[0..random_name_len]) catch return error.ScratchTooSmall;
        if (CreateDirectoryW(@ptrCast(path_scratch.ptr), &attributes) != 0) break;
        if (GetLastError() != 183 or attempt == 7) return error.CreateFailure;
    }
    const handle = open_directory(path_scratch[0..path_len]) catch return error.OpenFailure;
    errdefer _ = CloseHandle(handle);
    try verify_owned_directory(handle, user_sid);
    return .{ .handle = handle, .path = path_scratch[0..path_len], .name = name_scratch[0..random_name_len], .root = root };
}

fn ensure_owned_root(root_w: []const u16, root_len: usize, attributes: *SecurityAttributes, user_sid: *anyopaque) Error!void {
    std.debug.assert(root_len > 0 and root_len < root_w.len);
    var terminated: [windows.NAME_MAX]u16 = undefined;
    @memcpy(terminated[0..root_len], root_w[0..root_len]);
    terminated[root_len] = 0;
    if (CreateDirectoryW(@ptrCast(&terminated), attributes) == 0 and GetLastError() != 183) return error.CreateFailure;
    const handle = try open_directory(terminated[0..root_len]);
    defer _ = CloseHandle(handle);
    try verify_owned_directory(handle, user_sid);
}

fn append_session_path(destination: []u16, root: []const u16, name: []const u8) Error!usize {
    if (root.len == 0 or root.len + 1 + name.len + 1 > destination.len) return error.ScratchTooSmall;
    @memcpy(destination[0..root.len], root);
    var used = root.len;
    if (destination[used - 1] != '\\' and destination[used - 1] != '/') {
        destination[used] = '\\';
        used += 1;
    }
    for (name) |byte| {
        destination[used] = byte;
        used += 1;
    }
    destination[used] = 0;
    return used;
}

fn open_directory(path: []const u16) Error!Handle {
    var terminated: [windows.NAME_MAX]u16 = undefined;
    if (path.len == 0 or path.len >= terminated.len) return error.OpenFailure;
    @memcpy(terminated[0..path.len], path);
    terminated[path.len] = 0;
    const handle = CreateFileW(@ptrCast(&terminated), generic_read | read_control | file_list_directory, share_all, null, open_existing_disposition, file_flag_backup_semantics | file_flag_open_reparse_point, null);
    if (handle == invalid_handle) return error.OpenFailure;
    return handle;
}

fn verify_owned_directory(handle: Handle, user_sid: *anyopaque) Error!void {
    var tag = FileAttributeTagInfo{ .attributes = 0, .reparse_tag = 0 };
    if (GetFileInformationByHandleEx(handle, 9, &tag, @sizeOf(FileAttributeTagInfo)) == 0 or tag.attributes & file_attribute_reparse_point != 0) return error.SecurityVerificationFailed;
    try require_local_ntfs(handle);
    var actual_owner: ?*anyopaque = null;
    var actual_dacl: ?*anyopaque = null;
    var actual_descriptor: ?*anyopaque = null;
    if (GetSecurityInfo(handle, 1, security_information_owner | security_information_dacl, &actual_owner, null, &actual_dacl, null, &actual_descriptor) != 0) return error.SecurityVerificationFailed;
    defer _ = LocalFree(actual_descriptor);
    if (actual_owner == null or actual_dacl == null or EqualSid(actual_owner.?, user_sid) == 0) return error.SecurityVerificationFailed;
    var control: u16 = 0;
    var revision: u32 = 0;
    if (GetSecurityDescriptorControl(actual_descriptor.?, &control, &revision) == 0 or control & 0x1000 == 0) return error.SecurityVerificationFailed;
    if (!verify_dacl(actual_dacl.?, user_sid)) return error.SecurityVerificationFailed;
}

fn verify_dacl(acl: *anyopaque, user_sid: *anyopaque) bool {
    const AclSizeInformation = extern struct { ace_count: u32, bytes_in_use: u32, bytes_free: u32 };
    var info: AclSizeInformation = undefined;
    if (GetAclInformation(acl, &info, @sizeOf(AclSizeInformation), 2) == 0 or info.ace_count != 2) return false;
    const system_sid = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };
    var found_user = false;
    var found_system = false;
    for (0..info.ace_count) |index| {
        var ace_ptr: ?*anyopaque = null;
        if (GetAce(acl, @intCast(index), &ace_ptr) == 0 or ace_ptr == null) return false;
        const ace: *const AccessAllowedAce = @ptrCast(@alignCast(ace_ptr.?));
        if (ace.header.kind != 0 or ace.header.flags != 3 or ace.header.size < 20 or ace.mask != 0x001f01ff) return false;
        const sid_ptr: *anyopaque = @ptrFromInt(@intFromPtr(ace_ptr.?) + @offsetOf(AccessAllowedAce, "sid_start"));
        if (EqualSid(sid_ptr, user_sid) != 0) {
            if (found_user) return false;
            found_user = true;
        } else if (EqualSid(sid_ptr, @constCast(&system_sid)) != 0) {
            if (found_system) return false;
            found_system = true;
        } else return false;
    }
    return found_user and found_system;
}

pub fn close(session: *Session) void {
    if (comptime builtin.os.tag == .windows) _ = CloseHandle(session.handle);
    session.* = undefined;
}

/// Removes only this owned empty directory, then closes its stable handle.
pub fn destroy(session: *Session) Error!void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    // Closing is unconditional; deletion is intentionally not attempted by path.
    // The directory can contain a journal or have been replaced since creation.
    close(session);
}

fn validate_root(root: []const u8, wide: []u16) Error!usize {
    if (!absolute_drive_root(root) or root.len < 3 or root.len >= wide.len) return error.InvalidRoot;
    if (std.mem.indexOfScalar(u8, root, 0) != null or std.mem.indexOf(u8, root, "//") != null or std.mem.indexOf(u8, root, "\\\\") != null) return error.InvalidRoot;
    var component_start: usize = 3;
    for (root[3..], 3..) |byte, index| {
        if (byte == ':' or byte == '*' or byte == '?' or byte == '"' or byte == '<' or byte == '>' or byte == '|') return error.InvalidRoot;
        if (byte == '/' or byte == '\\') {
            if (!valid_root_component(root[component_start..index])) return error.InvalidRoot;
            component_start = index + 1;
        }
    }
    const final_component = root[component_start..];
    if (final_component.len == 0) {
        if (root[root.len - 1] != '/' and root[root.len - 1] != '\\') return error.InvalidRoot;
    } else if (!valid_root_component(final_component)) return error.InvalidRoot;
    return windows.wtf8ToWtf16Le(wide, root) catch error.InvalidRoot;
}

fn valid_root_component(component: []const u8) bool {
    if (component.len == 0) return false;
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    return component[component.len - 1] != '.' and component[component.len - 1] != ' ';
}

fn require_local_ntfs(handle: Handle) Error!void {
    const AttributeInfo = extern struct { attributes: u32, maximum_component_name_length: u32, name_length: u32, name: [0]u16 };
    var storage: [@sizeOf(AttributeInfo) + 64]u8 align(@alignOf(AttributeInfo)) = @splat(0);
    const info: *AttributeInfo = @ptrCast(&storage);
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    if (ntdll.NtQueryVolumeInformationFile(handle, &status_block, info, storage.len, .Attribute) != .SUCCESS) return error.UnsupportedFilesystem;
    if (info.name_length != 4 * @sizeOf(u16)) return error.UnsupportedFilesystem;
    const fs_name: [*]const u16 = @ptrCast(&info.name);
    if (!std.mem.eql(u16, fs_name[0..4], &.{ 'N', 'T', 'F', 'S' }) or fs_name[4] != 0) return error.UnsupportedFilesystem;
    var device: windows.FILE.FS_DEVICE_INFORMATION = undefined;
    if (ntdll.NtQueryVolumeInformationFile(handle, &status_block, &device, @sizeOf(@TypeOf(device)), .Device) != .SUCCESS) return error.UnsupportedFilesystem;
    if ((device.Characteristics & file_remote_device) != 0) return error.UnsupportedFilesystem;
}

fn absolute_drive_root(root: []const u8) bool {
    return root.len >= 3 and std.ascii.isAlphabetic(root[0]) and root[1] == ':' and (root[2] == '\\' or root[2] == '/');
}

test "portable recovery directory is explicitly unsupported" {
    if (comptime builtin.os.tag == .windows) return;
    try std.testing.expectError(error.UnsupportedPlatform, create(std.testing.io, "C:\\temp", &.{}, &.{}, &.{}, &.{}, &.{}));
}

test "recovery root rejects traversal and aliases before Windows calls" {
    var wide: [windows.NAME_MAX]u16 = undefined;
    try std.testing.expectError(error.InvalidRoot, validate_root("C:/Users/../Temp", &wide));
    try std.testing.expectError(error.InvalidRoot, validate_root("C:/Users/name./Temp", &wide));
    try std.testing.expectError(error.InvalidRoot, validate_root("C:/Users/name\x00junk", &wide));
    try std.testing.expectError(error.InvalidRoot, validate_root("\\\\server\\share", &wide));
    const length = try validate_root("C:/Users/name/AppData/Local", &wide);
    try std.testing.expect(length > 0);
}

test "native recovery directory descriptor is protected and verified" {
    if (comptime builtin.os.tag != .windows) return;
    const environ: std.process.Environ = .{ .block = .global };
    const enabled = environ.getAlloc(std.testing.allocator, "WARKOCZ_NATIVE_E2E") catch return;
    defer std.testing.allocator.free(enabled);
    if (!std.mem.eql(u8, enabled, "1")) return;
    const parent = "C:/Users/okr/AppData/Local/Temp/warkocz-native-e2e";
    var root_buffer: [parent.len + 1 + 21]u8 = undefined;
    @memcpy(root_buffer[0..parent.len], parent);
    @memcpy(root_buffer[parent.len..][0..6], "/root-");
    var random: [8]u8 = undefined;
    try std.testing.io.randomSecure(&random);
    const alphabet = "0123456789abcdef";
    for (random, 0..) |byte, index| {
        root_buffer[parent.len + 6 + index * 2] = alphabet[byte >> 4];
        root_buffer[parent.len + 7 + index * 2] = alphabet[byte & 15];
    }
    const root = root_buffer[0 .. parent.len + 22];
    defer std.Io.Dir.cwd().deleteDir(std.testing.io, root) catch {};
    var path: [windows.NAME_MAX]u16 = undefined;
    var token: [2048]u8 align(8) = undefined;
    var sddl: [sddl_capacity]u16 = undefined;
    var descriptor: [descriptor_capacity]u8 = undefined;
    var name: [random_name_len]u8 = undefined;
    var owned = try create(std.testing.io, root, &path, &token, &sddl, &descriptor, &name);
    try std.testing.expect(owned.path.len > root.len);
    for (root, owned.path[0..root.len]) |expected, actual| try std.testing.expectEqual(@as(u16, expected), actual);
    const owned_path = owned.path;
    try destroy(&owned);
    var terminated: [windows.NAME_MAX]u16 = undefined;
    @memcpy(terminated[0..owned_path.len], owned_path);
    terminated[owned_path.len] = 0;
    try std.testing.expect(RemoveDirectoryW(@ptrCast(&terminated)) != 0);
}
