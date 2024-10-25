const std = @import("std");
const syntax = @import("syntax");
const builtin = @import("builtin");

const checkmark_width = if (builtin.os.tag != .windows) 2 else 3;

const success_mark = if (builtin.os.tag != .windows) "✓ " else "[y]";
const fail_mark = if (builtin.os.tag != .windows) "✘ " else "[n]";

pub fn list(allocator: std.mem.Allocator, writer: anytype, tty_config: std.io.tty.Config) !void {
    var max_language_len: usize = 0;
    var max_langserver_len: usize = 0;
    var max_formatter_len: usize = 0;
    var max_extensions_len: usize = 0;

    for (syntax.FileType.file_types) |file_type| {
        max_language_len = @max(max_language_len, file_type.name.len);
        max_langserver_len = @max(max_langserver_len, args_string_length(file_type.language_server));
        max_formatter_len = @max(max_formatter_len, args_string_length(file_type.formatter));
        max_extensions_len = @max(max_extensions_len, args_string_length(file_type.extensions));
    }

    try tty_config.setColor(writer, .yellow);
    try write_string(writer, "Language", max_language_len + 1);
    try write_string(writer, "Extensions", max_extensions_len + 1 + checkmark_width);
    try write_string(writer, "Language Server", max_langserver_len + 1 + checkmark_width);
    try write_string(writer, "Formatter", max_formatter_len);
    try tty_config.setColor(writer, .reset);
    try writer.writeAll("\n");

    const bin_paths = std.process.getEnvVarOwned(allocator, "PATH") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => &.{},
    };

    defer allocator.free(bin_paths);

    for (syntax.FileType.file_types) |file_type| {
        try write_string(writer, file_type.name, max_language_len + 1);
        try write_segmented(writer, file_type.extensions, ",", max_extensions_len + 1, tty_config);

        if (file_type.language_server) |language_server|
            try write_checkmark(writer, try can_execute(allocator, bin_paths, language_server[0]), tty_config);

        try write_segmented(writer, file_type.language_server, " ", max_langserver_len + 1, tty_config);

        if (file_type.formatter) |formatter|
            try write_checkmark(writer, try can_execute(allocator, bin_paths, formatter[0]), tty_config);

        try write_segmented(writer, file_type.formatter, " ", max_formatter_len, tty_config);
        try writer.writeAll("\n");
    }
}

fn args_string_length(args_: ?[]const []const u8) usize {
    const args = args_ orelse return 0;
    var len: usize = 0;
    var first: bool = true;
    for (args) |arg| {
        if (first) first = false else len += 1;
        len += arg.len;
    }
    return len;
}

fn write_string(writer: anytype, string: []const u8, pad: usize) !void {
    try writer.writeAll(string);
    try write_padding(writer, string.len, pad);
}

fn write_checkmark(writer: anytype, success: bool, tty_config: std.io.tty.Config) !void {
    try tty_config.setColor(writer, if (success) .green else .red);
    if (success) try writer.writeAll(success_mark) else try writer.writeAll(fail_mark);
}

fn write_segmented(
    writer: anytype,
    args_: ?[]const []const u8,
    sep: []const u8,
    pad: usize,
    tty_config: std.io.tty.Config,
) !void {
    const args = args_ orelse return;
    var len: usize = 0;
    var first: bool = true;
    for (args) |arg| {
        if (first) first = false else {
            len += 1;
            try writer.writeAll(sep);
        }
        len += arg.len;
        try writer.writeAll(arg);
    }
    try tty_config.setColor(writer, .reset);
    try write_padding(writer, len, pad);
}

fn write_padding(writer: anytype, len: usize, pad_len: usize) !void {
    for (0..pad_len - len) |_| try writer.writeAll(" ");
}

const can_execute = switch (builtin.os.tag) {
    .windows => can_execute_windows,
    else => can_execute_posix,
};

fn can_execute_posix(allocator: std.mem.Allocator, bin_paths: []const u8, file_path: []const u8) std.mem.Allocator.Error!bool {
    if (!std.process.can_spawn) return false;

    var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);

    while (bin_path_iterator.next()) |bin_path| {
        const resolved_file_path = try std.fs.path.resolve(allocator, &.{ bin_path, file_path });
        defer allocator.free(resolved_file_path);

        std.posix.access(resolved_file_path, std.posix.X_OK) catch continue;

        return true;
    }

    return false;
}

fn can_execute_windows(allocator: std.mem.Allocator, bin_paths: []const u8, file_path_: []const u8) std.mem.Allocator.Error!bool {
    var path = std.ArrayList(u8).init(allocator);
    try path.appendSlice(file_path_);
    try path.appendSlice(".exe");
    const file_path = try path.toOwnedSlice();
    defer allocator.free(file_path);

    var bin_path_iterator = std.mem.splitScalar(u8, bin_paths, std.fs.path.delimiter);

    while (bin_path_iterator.next()) |bin_path| {
        if (!std.fs.path.isAbsolute(bin_path)) continue;
        var dir = std.fs.openDirAbsolute(bin_path, .{}) catch continue;
        defer dir.close();

        _ = dir.statFile(file_path) catch continue;
        return true;
    }

    return false;
}
