const std = @import("std");
const fs = std.fs;
const mem = std.mem;

pub const Task = struct {
    text: []const u8,
};

pub const FileImage = struct {
    tasks: []Task,
    text_buf: []u8,
};

const ParseError = error{
    InvalidJson,
};

pub fn loadFile(allocator: mem.Allocator, file: fs.File) !FileImage {
    const stat = try file.stat();
    if (stat.size == 0) {
        return FileImage{
            .tasks = &[_]Task{},
            .text_buf = &[_]u8{},
        };
    }

    const size: usize = @intCast(stat.size);

    // Read whole file in one go.
    var raw = try allocator.alloc(u8, size);
    errdefer allocator.free(raw);

    const got = try file.readAll(raw);
    const raw_slice = raw[0..got];

    if (raw_slice.len == 0) {
        allocator.free(raw);
        return FileImage{
            .tasks = &[_]Task{},
            .text_buf = &[_]u8{},
        };
    }

    // Decide format: JSON-lines (preferred) vs legacy plain text.
    var is_json = false;
    {
        var found = false;
        var idx: usize = 0;
        while (idx < raw_slice.len) : (idx += 1) {
            const b = raw_slice[idx];
            if (b == ' ' or b == '\t' or b == '\n' or b == '\r') continue;
            is_json = (b == '{');
            found = true;
            break;
        }
        if (!found) {
            allocator.free(raw);
            return FileImage{
                .tasks = &[_]Task{},
                .text_buf = &[_]u8{},
            };
        }
    }

    // Count logical lines.
    var line_count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < raw_slice.len) : (i += 1) {
        if (raw_slice[i] == '\n') {
            line_count += 1;
            start = i + 1;
        }
    }
    if (start < raw_slice.len) {
        line_count += 1;
    }

    var tasks = try allocator.alloc(Task, line_count);
    var text_buf = try allocator.alloc(u8, raw_slice.len);
    var parse_ok = false;
    defer {
        if (!parse_ok) {
            allocator.free(tasks);
            allocator.free(text_buf);
        }
    }

    var text_cursor: usize = 0;
    var task_index: usize = 0;
    var line_start: usize = 0;

    i = 0;
    while (i < raw_slice.len) : (i += 1) {
        if (raw_slice[i] == '\n') {
            const line = raw_slice[line_start..i];
            const text_slice = if (line.len == 0)
                text_buf[text_cursor..text_cursor]
            else if (is_json)
                try parseTextFromJsonLine(line, text_buf, &text_cursor)
            else
                copyPlainLine(line, text_buf, &text_cursor);

            tasks[task_index] = .{ .text = text_slice };
            task_index += 1;
            line_start = i + 1;
        }
    }

    if (line_start < raw_slice.len) {
        const line = raw_slice[line_start..raw_slice.len];
        const text_slice = if (line.len == 0)
            text_buf[text_cursor..text_cursor]
        else if (is_json)
            try parseTextFromJsonLine(line, text_buf, &text_cursor)
        else
            copyPlainLine(line, text_buf, &text_cursor);

        tasks[task_index] = .{ .text = text_slice };
        task_index += 1;
    }

    parse_ok = true;
    allocator.free(raw);

    return FileImage{
        .tasks = tasks[0..task_index],
        .text_buf = text_buf,
    };
}

/// Append a single task line to a file in JSON-lines format:
///   {"text":"..."}\n
pub fn appendJsonTaskLine(
    allocator: mem.Allocator,
    file: *fs.File,
    text: []const u8,
) !void {
    const stat = try file.stat();
    try file.seekTo(stat.size);
    try writeJsonLineForText(allocator, file, text);
}

/// Rewrite entire file in JSON-lines format using `tasks`,
/// optionally skipping the element at `skip_index` (used by :d).
///
/// NOTE: this rewrites the entire file on each mutation.
/// For very large files and many state changes the optimal design
/// is to maintain append-only logs and an in-memory “live set” of
/// task indices, and only occasionally rewrite compacted files.
pub fn rewriteJsonFileWithoutIndex(
    allocator: mem.Allocator,
    file: *fs.File,
    tasks: []const Task,
    skip_index: usize,
) !void {
    try file.seekTo(0);
    try file.setEndPos(0);

    var i: usize = 0;
    while (i < tasks.len) : (i += 1) {
        if (i == skip_index) continue;
        try writeJsonLineForText(allocator, file, tasks[i].text);
    }
}

// ----------------- internal helpers -----------------

fn parseTextFromJsonLine(
    line: []const u8,
    text_buf: []u8,
    cursor: *usize,
) ParseError![]const u8 {
    const len = line.len;
    if (len == 0) return text_buf[cursor.* .. cursor.*];

    // Search for "text" key at top level.
    var i: usize = 0;
    var key_pos: ?usize = null;
    while (i + 6 <= len) : (i += 1) {
        if (line[i] == '"' and
            line[i + 1] == 't' and
            line[i + 2] == 'e' and
            line[i + 3] == 'x' and
            line[i + 4] == 't' and
            line[i + 5] == '"')
        {
            key_pos = i;
            break;
        }
    }
    if (key_pos == null) return ParseError.InvalidJson;

    i = key_pos.? + 6;

    // Find ':'
    while (i < len and line[i] != ':') : (i += 1) {}
    if (i == len) return ParseError.InvalidJson;
    i += 1;

    // Skip spaces.
    while (i < len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i == len or line[i] != '"') return ParseError.InvalidJson;
    i += 1; // at start of string

    const dst_start = cursor.*;
    var dst = dst_start;

    while (i < len) {
        const b = line[i];
        if (b == '\\') {
            if (i + 1 >= len) return ParseError.InvalidJson;
            const esc = line[i + 1];
            var out: u8 = undefined;
            switch (esc) {
                'n' => out = '\n',
                'r' => out = '\r',
                't' => out = '\t',
                '\\' => out = '\\',
                '"' => out = '"',
                else => out = esc,
            }
            text_buf[dst] = out;
            dst += 1;
            i += 2;
        } else if (b == '"') {
            i += 1;
            break;
        } else {
            text_buf[dst] = b;
            dst += 1;
            i += 1;
        }
    }

    const slice = text_buf[dst_start..dst];
    cursor.* = dst;
    return slice;
}

fn copyPlainLine(
    line: []const u8,
    text_buf: []u8,
    cursor: *usize,
) []const u8 {
    var end = line.len;
    // Strip trailing '\r' from CRLF if present.
    if (end > 0 and line[end - 1] == '\r') {
        end -= 1;
    }

    const dst_start = cursor.*;
    const len = end;

    if (len != 0) {
        @memcpy(text_buf[dst_start .. dst_start + len], line[0..len]);
    }

    cursor.* = dst_start + len;
    return text_buf[dst_start .. dst_start + len];
}

fn writeJsonLineForText(
    allocator: mem.Allocator,
    file: *fs.File,
    text: []const u8,
) !void {
    const stack_cap: usize = 1024;
    const overhead: usize = 16; // {"text":""}\n plus escapes

    if (text.len + overhead <= stack_cap) {
        var buf: [stack_cap]u8 = undefined;
        var pos: usize = 0;

        // {"text":"
        buf[pos] = '{'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = 'e'; pos += 1;
        buf[pos] = 'x'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = ':'; pos += 1;
        buf[pos] = '"'; pos += 1;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            switch (b) {
                '"' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '"'; pos += 1;
                },
                '\\' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '\\'; pos += 1;
                },
                '\n' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'n'; pos += 1;
                },
                '\r' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'r'; pos += 1;
                },
                '\t' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 't'; pos += 1;
                },
                else => {
                    buf[pos] = b;
                    pos += 1;
                },
            }
        }

        buf[pos] = '"'; pos += 1;
        buf[pos] = '}'; pos += 1;
        buf[pos] = '\n'; pos += 1;

        try file.writeAll(buf[0..pos]);
    } else {
        const cap: usize = text.len * 2 + overhead;
        var buf = try allocator.alloc(u8, cap);
        defer allocator.free(buf);

        var pos: usize = 0;

        buf[pos] = '{'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = 'e'; pos += 1;
        buf[pos] = 'x'; pos += 1;
        buf[pos] = 't'; pos += 1;
        buf[pos] = '"'; pos += 1;
        buf[pos] = ':'; pos += 1;
        buf[pos] = '"'; pos += 1;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const b = text[i];
            switch (b) {
                '"' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '"'; pos += 1;
                },
                '\\' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = '\\'; pos += 1;
                },
                '\n' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'n'; pos += 1;
                },
                '\r' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 'r'; pos += 1;
                },
                '\t' => {
                    buf[pos] = '\\'; pos += 1;
                    buf[pos] = 't'; pos += 1;
                },
                else => {
                    buf[pos] = b;
                    pos += 1;
                },
            }
        }

        buf[pos] = '"'; pos += 1;
        buf[pos] = '}'; pos += 1;
        buf[pos] = '\n'; pos += 1;

        try file.writeAll(buf[0..pos]);
    }
}
