const std = @import("std");
const mem = std.mem;
const fs = std.fs;

fn isAsciiSpace(b: u8) bool {
    return b == ' ' or b == '\t';
}

fn trimAsciiSpaces(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;

    while (start < end and isAsciiSpace(s[start])) {
        start += 1;
    }
    while (end > start and isAsciiSpace(s[end - 1])) {
        end -= 1;
    }
    return s[start..end];
}

fn parseUInt(s: []const u8, max_digits: usize) ?u32 {
    if (s.len == 0 or s.len > max_digits) return null;

    var v: u32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b < '0' or b > '9') return null;
        const digit: u32 = @intCast(b - '0');
        v = v * 10 + digit;
    }
    return v;
}

fn isLeapYear(year: u32) bool {
    if (year % 400 == 0) return true;
    if (year % 100 == 0) return false;
    return (year % 4 == 0);
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

/// Parse user-style due date into canonical "YYYY-MM-DD".
/// Returns true on success.
/// Accepts:
///   - "YYYY-MM-DD"
///   - "D/M/YYYY", "DD/MM/YYYY", and same with '-'
///   - "D/M/YY" or "DD/MM/YY"
pub fn parseUserDueDateCanonical(input: []const u8, out: *[10]u8) bool {
    var s = trimAsciiSpaces(input);
    if (s.len == 0) return false;

    // ISO "YYYY-MM-DD"
    if (s.len == 10 and s[4] == '-' and s[7] == '-') {
        const y = parseUInt(s[0..4], 4) orelse return false;
        const m = parseUInt(s[5..7], 2) orelse return false;
        const d = parseUInt(s[8..10], 2) orelse return false;

        if (y < 1970 or y > 9999) return false;
        if (m < 1 or m > 12) return false;
        const dim = daysInMonth(y, m);
        if (d < 1 or d > dim) return false;

        out[0] = s[0];
        out[1] = s[1];
        out[2] = s[2];
        out[3] = s[3];
        out[4] = '-';
        out[5] = s[5];
        out[6] = s[6];
        out[7] = '-';
        out[8] = s[8];
        out[9] = s[9];
        return true;
    }

    // D/M/YYYY or D-M-YYYY (or with two-digit year)
    var sep: u8 = 0;
    var found_slash = false;
    var found_dash = false;

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '/') {
            found_slash = true;
            break;
        } else if (s[i] == '-') {
            found_dash = true;
            break;
        }
    }

    if (found_slash) {
        sep = '/';
    } else if (found_dash) {
        sep = '-';
    } else {
        return false;
    }

    var first_sep: ?usize = null;
    var second_sep: ?usize = null;
    i = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == sep) {
            if (first_sep == null) {
                first_sep = i;
            } else {
                second_sep = i;
                break;
            }
        }
    }

    if (first_sep == null or second_sep == null) return false;
    const s1 = first_sep.?;
    const s2 = second_sep.?;

    if (s1 == 0) return false;
    if (s2 <= s1 + 1) return false;
    if (s2 + 1 >= s.len) return false;

    const day_slice = s[0..s1];
    const month_slice = s[s1 + 1 .. s2];
    const year_slice = s[s2 + 1 .. s.len];

    const day_val_u32 = parseUInt(day_slice, 2) orelse return false;
    const month_val_u32 = parseUInt(month_slice, 2) orelse return false;
    const year_val_raw = parseUInt(year_slice, 4) orelse return false;

    var year: u32 = undefined;
    if (year_slice.len == 2) {
        const yy = year_val_raw;
        if (yy <= 68) {
            year = 2000 + yy;
        } else {
            year = 1900 + yy;
        }
    } else if (year_slice.len == 4) {
        year = year_val_raw;
    } else {
        return false;
    }

    const day_val = day_val_u32;
    const month_val = month_val_u32;

    if (year < 1970 or year > 9999) return false;
    if (month_val < 1 or month_val > 12) return false;
    const dim2 = daysInMonth(year, month_val);
    if (day_val < 1 or day_val > dim2) return false;

    const y_thousands: u8 = @as(u8, @intCast((year / 1000) % 10));
    const y_hundreds:  u8 = @as(u8, @intCast((year / 100) % 10));
    const y_tens:      u8 = @as(u8, @intCast((year / 10) % 10));
    const y_ones:      u8 = @as(u8, @intCast(year % 10));

    out[0] = '0' + y_thousands;
    out[1] = '0' + y_hundreds;
    out[2] = '0' + y_tens;
    out[3] = '0' + y_ones;
    out[4] = '-';

    // Month MM
    const m_tens: u8 = @as(u8, @intCast((month_val / 10) % 10));
    const m_ones: u8 = @as(u8, @intCast(month_val % 10));
    out[5] = '0' + m_tens;
    out[6] = '0' + m_ones;
    out[7] = '-';

    // Day DD
    const d_tens2: u8 = @as(u8, @intCast((day_val / 10) % 10));
    const d_ones2: u8 = @as(u8, @intCast(day_val % 10));
    out[8] = '0' + d_tens2;
    out[9] = '0' + d_ones2;

    return true;
}

/// Parse user-style due time into canonical "HH:MM" 24h.
/// Returns true on success.
/// Accepts:
///   24h:
///     "H:MM", "HH:MM", "HHMM"
///   12h:
///     "H am", "Hpm", "H:MM am", "H:MMpm", case-insensitive, optional spaces.
pub fn parseUserDueTimeCanonical(input: []const u8, out: *[5]u8) bool {
    var s = trimAsciiSpaces(input);
    if (s.len == 0) return false;

    var i: usize = s.len;
    while (i > 0 and isAsciiSpace(s[i - 1])) : (i -= 1) {}

    var suffix: u8 = 0; // 0 = none, 'a' = am, 'p' = pm
    var time_end: usize = i;

    if (i >= 2) {
        const c1 = s[i - 2];
        const c2 = s[i - 1];

        const lower1: u8 = if (c1 >= 'A' and c1 <= 'Z') c1 + 32 else c1;
        const lower2: u8 = if (c2 >= 'A' and c2 <= 'Z') c2 + 32 else c2;

        if (lower2 == 'm' and (lower1 == 'a' or lower1 == 'p')) {
            suffix = lower1;
            time_end = i - 2;
        }
    }

    var core = s[0..time_end];
    core = trimAsciiSpaces(core);
    if (core.len == 0) return false;

    var hour: u32 = 0;
    var minute: u32 = 0;

    // Find colon if any
    var colon_index: ?usize = null;
    i = 0;
    while (i < core.len) : (i += 1) {
        if (core[i] == ':') {
            if (colon_index != null) return false;
            colon_index = i;
        }
    }

    if (suffix == 0) {
        // 24-hour variants
        if (colon_index) |ci| {
            if (ci == 0) return false;
            const left = core[0..ci];
            const right = core[ci + 1 .. core.len];
            if (right.len != 2) return false;

            const h = parseUInt(left, 2) orelse return false;
            const m = parseUInt(right, 2) orelse return false;
            if (h > 23 or m > 59) return false;

            hour = h;
            minute = m;
        } else {
            if (core.len != 4) return false;
            const h = parseUInt(core[0..2], 2) orelse return false;
            const m = parseUInt(core[2..4], 2) orelse return false;
            if (h > 23 or m > 59) return false;

            hour = h;
            minute = m;
        }
    } else {
        // 12-hour variants with am/pm
        if (colon_index) |ci| {
            if (ci == 0) return false;
            const left = core[0..ci];
            const right = core[ci + 1 .. core.len];
            if (right.len != 2) return false;

            const h = parseUInt(left, 2) orelse return false;
            const m = parseUInt(right, 2) orelse return false;

            if (h < 1 or h > 12) return false;
            if (m > 59) return false;

            hour = h;
            minute = m;
        } else {
            const h = parseUInt(core, 2) orelse return false;
            if (h < 1 or h > 12) return false;
            hour = h;
            minute = 0;
        }

        if (suffix == 'a') {
            if (hour == 12) hour = 0;
        } else {
            if (hour != 12) hour += 12;
        }
    }

    const h_tens:  u8 = @as(u8, @intCast(hour / 10));
    const h_ones:  u8 = @as(u8, @intCast(hour % 10));
    const m_tens2: u8 = @as(u8, @intCast(minute / 10));
    const m_ones2: u8 = @as(u8, @intCast(minute % 10));

    out[0] = '0' + h_tens;
    out[1] = '0' + h_ones;
    out[2] = ':';
    out[3] = '0' + m_tens2;
    out[4] = '0' + m_ones2;

    return true;
}

/// ------------------------------
/// Due rendering config + formatter
/// ------------------------------

pub const DueFormatConfig = struct {
    date: CompiledFormat,
    time: CompiledFormat,
    tmpl: CompiledTemplate,

    editor_date: ?CompiledFormat = null,

    pub fn deinit(self: *DueFormatConfig, allocator: mem.Allocator) void {
        self.date.deinit(allocator);
        self.time.deinit(allocator);
        self.tmpl.deinit(allocator);
        if (self.editor_date) |*f| f.deinit(allocator);
        self.* = undefined;
    }
};


pub fn loadDueFormatConfigFromFile(
    allocator: mem.Allocator,
    file: fs.File,
) !DueFormatConfig {
    // Start with compiled defaults (so invalid lines simply do nothing).
    var date_fmt = try CompiledFormat.init(allocator, "%x");
    errdefer date_fmt.deinit(allocator);

    var time_fmt = try CompiledFormat.init(allocator, "%H:%M");
    errdefer time_fmt.deinit(allocator);

    var tmpl = try CompiledTemplate.init(allocator, "date time");
    errdefer tmpl.deinit(allocator);


    var editor_date: ?CompiledFormat = try CompiledFormat.init(allocator, "%x");
    errdefer if (editor_date) |*f| f.deinit(allocator);

    // Read config file once.
    try file.seekTo(0);
    const st = try file.stat();

    // If empty, seed explicit defaults and return compiled defaults.
    if (st.size == 0) {
        const seed =
            "due_date = \"%x\"\n" ++
            "due_time = \"%H:%M\"\n" ++
            "due = \"date time\"\n" ++
            "editor_due_date = \"%x\"\n";
        _ = try file.writeAll(seed);
        return .{ .date = date_fmt, .time = time_fmt, .tmpl = tmpl, .editor_date = editor_date };
    }

    // Cap size to keep latency bounded. Too big => keep defaults.
    if (st.size > 16 * 1024) {
        return .{ .date = date_fmt, .time = time_fmt, .tmpl = tmpl, .editor_date = editor_date };
    }

    var buf = try allocator.alloc(u8, @intCast(st.size));
    defer allocator.free(buf);

    try file.seekTo(0);
    const n = try file.readAll(buf);
    const src = buf[0..n];

    // Parse key = value, ASCII, line-based.
    var it = mem.splitScalar(u8, src, '\n');
    while (it.next()) |line_raw| {
        var line = trimAscii(line_raw);
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        // strip inline comments starting at '#' or ';' (not inside quotes).
        line = stripInlineComment(line);

        const eqi = mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trimAscii(line[0..eqi]);
        var val = trimAscii(line[eqi + 1 ..]);

        if (key.len == 0 or val.len == 0) continue;

        val = unquoteAscii(val);

        if (eqLower(key, "due_date")) {
            const nf = CompiledFormat.init(allocator, val) catch continue;
            date_fmt.deinit(allocator);
            date_fmt = nf;
            continue;
        }

        if (eqLower(key, "due_time")) {
            const nf = CompiledFormat.init(allocator, val) catch continue;
            time_fmt.deinit(allocator);
            time_fmt = nf;
            continue;
        }

        if (eqLower(key, "due")) {
            const nt = CompiledTemplate.init(allocator, val) catch continue;
            tmpl.deinit(allocator);
            tmpl = nt;
            continue;
        }

        if (eqLower(key, "editor_due_date")) {
            // Empty value disables strict editor parsing.
            if (val.len == 0) {
                if (editor_date) |*f| f.deinit(allocator);
                editor_date = null;
                continue;
            }

            var nf = CompiledFormat.init(allocator, val) catch continue;
            if (!isValidEditorDateFormat(&nf)) {
                nf.deinit(allocator);
                continue;
            }

            if (editor_date) |*f| f.deinit(allocator);
            editor_date = nf;
            continue;
        }
    }

    return .{ .date = date_fmt, .time = time_fmt, .tmpl = tmpl, .editor_date = editor_date };
}


fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

fn yyToYear(yy: u32) u32 {
    return if (yy <= 68) (2000 + yy) else (1900 + yy);
}

fn writeCanonYMD(out: *[10]u8, y: u32, m: u32, d: u32) void {
    out[0] = '0' + @as(u8, @intCast((y / 1000) % 10));
    out[1] = '0' + @as(u8, @intCast((y / 100) % 10));
    out[2] = '0' + @as(u8, @intCast((y / 10) % 10));
    out[3] = '0' + @as(u8, @intCast(y % 10));
    out[4] = '-';
    out[5] = '0' + @as(u8, @intCast((m / 10) % 10));
    out[6] = '0' + @as(u8, @intCast(m % 10));
    out[7] = '-';
    out[8] = '0' + @as(u8, @intCast((d / 10) % 10));
    out[9] = '0' + @as(u8, @intCast(d % 10));
}

fn parseFixedDigits(s: []const u8, pos: *usize, n: usize) ?u32 {
    if (pos.* + n > s.len) return null;
    var v: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const b = s[pos.* + i];
        if (!isDigit(b)) return null;
        v = v * 10 + @as(u32, b - '0');
    }
    pos.* += n;
    return v;
}

// For %-d / %-m / %-y: accept 1 or 2 digits; reject a padded 2-digit form like "01".
fn parseVarDigitsNoPad(s: []const u8, pos: *usize, min: usize, max: usize) ?u32 {
    if (pos.* >= s.len) return null;

    var n: usize = 0;
    var v: u32 = 0;
    var first: u8 = 0;

    while (pos.* < s.len and n < max) {
        const b = s[pos.*];
        if (!isDigit(b)) break;
        if (n == 0) first = b;

        v = v * 10 + @as(u32, b - '0');
        pos.* += 1;
        n += 1;
    }

    if (n < min) return null;
    if (n == 2 and first == '0') return null; // strict no-pad
    return v;
}

fn parseIsoYmdStrictToBuf(s: []const u8, out: *[10]u8) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;

    var pos: usize = 0;
    const y = parseFixedDigits(s, &pos, 4) orelse return false;
    if (pos >= s.len or s[pos] != '-') return false;
    pos += 1;
    const m = parseFixedDigits(s, &pos, 2) orelse return false;
    if (pos >= s.len or s[pos] != '-') return false;
    pos += 1;
    const d = parseFixedDigits(s, &pos, 2) orelse return false;
    if (pos != s.len) return false;

    if (y < 1970 or y > 9999) return false;
    if (m < 1 or m > 12) return false;
    const dim = daysInMonth(y, m);
    if (d < 1 or d > dim) return false;

    writeCanonYMD(out, y, m, d);
    return true;
}

fn isValidEditorDateFormat(fmt: *const CompiledFormat) bool {
    var i: usize = 0;
    while (i < fmt.toks.len) : (i += 1) {
        const t = fmt.toks[i];
        if (t.kind != .spec) continue;

        const spec: Spec = @enumFromInt(@as(u8, @intCast(t.a)));
        switch (spec) {
            .percent,
            .d0, .d,
            .m0, .m,
            .y0, .y,
            .Y,
            .x,
            => {},

            else => return false,
        }
    }
    return true;
}

// Strict parser driven by CompiledFormat tokens.
// Consumes the whole input, and produces canonical YYYY-MM-DD.
pub fn parseUserDueDateCanonicalByFormat(fmt: *const CompiledFormat, input: []const u8, out: *[10]u8) bool {
    const s = trimAsciiSpaces(input);
    if (s.len == 0) return false;

    var pos: usize = 0;

    var have_y = false;
    var have_m = false;
    var have_d = false;

    var y: u32 = 0;
    var m: u32 = 0;
    var d: u32 = 0;

    var ti: usize = 0;
    while (ti < fmt.toks.len) : (ti += 1) {
        const t = fmt.toks[ti];

        if (t.kind == .lit) {
            const off: usize = t.a;
            const len: usize = t.b;
            if (pos + len > s.len) return false;
            if (!mem.eql(u8, s[pos .. pos + len], fmt.raw[off .. off + len])) return false;
            pos += len;
            continue;
        }

        const spec: Spec = @enumFromInt(@as(u8, @intCast(t.a)));
        switch (spec) {
            .percent => {
                if (pos >= s.len or s[pos] != '%') return false;
                pos += 1;
            },

            .x => {
                if (pos + 10 > s.len) return false;
                var tmp: [10]u8 = undefined;
                if (!parseIsoYmdStrictToBuf(s[pos .. pos + 10], &tmp)) return false;

                // decode back into y/m/d so we can validate presence if mixed formats are ever allowed
                // and unify the final writer path.
                var yy: u32 = 0;
                var mm: u32 = 0;
                var dd: u32 = 0;
                if (!parseCanonDate(tmp[0..], &yy, &mm, &dd)) return false;

                y = yy; m = mm; d = dd;
                have_y = true; have_m = true; have_d = true;
                pos += 10;
            },

            .d0 => {
                const v = parseFixedDigits(s, &pos, 2) orelse return false;
                d = v; have_d = true;
            },
            .d => {
                const v = parseVarDigitsNoPad(s, &pos, 1, 2) orelse return false;
                d = v; have_d = true;
            },

            .m0 => {
                const v = parseFixedDigits(s, &pos, 2) orelse return false;
                m = v; have_m = true;
            },
            .m => {
                const v = parseVarDigitsNoPad(s, &pos, 1, 2) orelse return false;
                m = v; have_m = true;
            },

            .y0 => {
                const v = parseFixedDigits(s, &pos, 2) orelse return false;
                y = yyToYear(v); have_y = true;
            },
            .y => {
                const v = parseVarDigitsNoPad(s, &pos, 1, 2) orelse return false;
                y = yyToYear(v); have_y = true;
            },

            .Y => {
                const v = parseFixedDigits(s, &pos, 4) orelse return false;
                y = v; have_y = true;
            },

            else => return false,
        }
    }

    if (pos != s.len) return false;
    if (!have_y or !have_m or !have_d) return false;

    if (y < 1970 or y > 9999) return false;
    if (m < 1 or m > 12) return false;
    const dim = daysInMonth(y, m);
    if (d < 1 or d > dim) return false;

    writeCanonYMD(out, y, m, d);
    return true;
}

// Editor entry point.
// Accepts ISO YYYY-MM-DD always.
// If editor_due_date exists, accept exactly that format (strict) as the alternative.
// If editor_due_date is disabled/null, fall back to your original relaxed parser.
pub fn parseUserEditorDueDateCanonical(cfg: *const DueFormatConfig, input: []const u8, out: *[10]u8) bool {
    const s = trimAsciiSpaces(input);
    if (s.len == 0) return false;

    if (parseIsoYmdStrictToBuf(s, out)) return true;

    if (cfg.editor_date) |*f| {
        return parseUserDueDateCanonicalByFormat(f, s, out);
    }

    return parseUserDueDateCanonical(s, out);
}



/// Formats the due payload inside `d:[...]`.
/// If date is empty -> returns empty.
/// If time is empty -> date only.
/// If time exists -> applies template with date/time substitutions.
pub fn formatDueForSuffix(
    cfg: *const DueFormatConfig,
    due_date_canon: []const u8,
    due_time_canon: []const u8,
    out: []u8,
) []const u8 {
    if (due_date_canon.len == 0 or out.len == 0) return out[0..0];

    var y: u32 = 0;
    var m: u32 = 0;
    var d: u32 = 0;

    if (!parseCanonDate(due_date_canon, &y, &m, &d)) {
        // If storage is corrupted, degrade gracefully.
        const n = @min(out.len, due_date_canon.len);
        mem.copyForwards(u8, out[0..n], due_date_canon[0..n]);
        return out[0..n];
    }

    // Precompute formatted date.
    var date_buf: [64]u8 = undefined;
    const date_s = cfg.date.formatDate(y, m, d, date_buf[0..]);

    if (due_time_canon.len == 0) {
        const n = @min(out.len, date_s.len);
        mem.copyForwards(u8, out[0..n], date_s[0..n]);
        return out[0..n];
    }

    var hh: u32 = 0;
    var mm_: u32 = 0;
    if (!parseCanonTime(due_time_canon, &hh, &mm_)) {
        // Time malformed; date only.
        const n = @min(out.len, date_s.len);
        mem.copyForwards(u8, out[0..n], date_s[0..n]);
        return out[0..n];
    }

    var time_buf: [32]u8 = undefined;
    const time_s = cfg.time.formatTime(hh, mm_, time_buf[0..]);

    return cfg.tmpl.render(date_s, time_s, out);
}

/// ------------------------------
/// Internal: template compiler
/// ------------------------------

const TemplateTokKind = enum(u8) { lit, date, time };

const TemplateTok = packed struct {
    kind: TemplateTokKind,
    off:  u16,
    len:  u16,
};

const CompiledTemplate = struct {
    raw:   []u8,
    toks:  []TemplateTok,

    pub fn init(allocator: mem.Allocator, src: []const u8) !CompiledTemplate {
        // Always own raw to keep lifetime trivial.
        const raw = try allocator.dupe(u8, src);
        errdefer allocator.free(raw);

        var list: std.ArrayListUnmanaged(TemplateTok) = .{};
        errdefer list.deinit(allocator);

        // Tokenize: supports {date}/{time} and bare whole-word "date"/"time".
        var i: usize = 0;
        var lit_start: usize = 0;

        while (i < raw.len) {
            // Curly placeholders.
            if (raw[i] == '{') {
                if (matchLit(raw, i, "{date}")) {
                    try appendLitTok(allocator, &list, lit_start, i);
                    try list.append(allocator, .{ .kind = .date, .off = 0, .len = 0 });
                    i += "{date}".len;
                    lit_start = i;
                    continue;
                }
                if (matchLit(raw, i, "{time}")) {
                    try appendLitTok(allocator, &list, lit_start, i);
                    try list.append(allocator, .{ .kind = .time, .off = 0, .len = 0 });
                    i += "{time}".len;
                    lit_start = i;
                    continue;
                }
            }

            i += 1;
        }

        try appendLitTok(allocator, &list, lit_start, raw.len);

        const toks = try list.toOwnedSlice(allocator);
        errdefer allocator.free(toks);

        return .{ .raw = raw, .toks = toks };
    }

    pub fn deinit(self: *CompiledTemplate, allocator: mem.Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.toks);
        self.* = undefined;
    }

    pub fn render(
        self: *const CompiledTemplate,
        date_s: []const u8,
        time_s: []const u8,
        out: []u8,
    ) []const u8 {
        var pos: usize = 0;

        var ti: usize = 0;
        while (ti < self.toks.len and pos < out.len) : (ti += 1) {
            const t = self.toks[ti];
            switch (t.kind) {
                .lit => {
                    const off: usize = t.off;
                    const len: usize = t.len;
                    if (len == 0) continue;
                    const n = @min(out.len - pos, len);
                    mem.copyForwards(u8, out[pos .. pos + n], self.raw[off .. off + n]);
                    pos += n;
                },
                .date => {
                    const n = @min(out.len - pos, date_s.len);
                    mem.copyForwards(u8, out[pos .. pos + n], date_s[0..n]);
                    pos += n;
                },
                .time => {
                    const n = @min(out.len - pos, time_s.len);
                    mem.copyForwards(u8, out[pos .. pos + n], time_s[0..n]);
                    pos += n;
                },
            }
        }

        return out[0..pos];
    }
};


fn trimCfg(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn stripQuotesCfg(s0: []const u8) []const u8 {
    const s = trimCfg(s0);
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn appendLitTok(
    allocator: mem.Allocator,
    list: *std.ArrayListUnmanaged(TemplateTok),
    a: usize,
    b: usize,
) !void {
    if (b <= a) return;
    const len = b - a;
    if (len > std.math.maxInt(u16)) return error.TemplateTooLong;
    const off_u16: u16 = @intCast(a);
    const len_u16: u16 = @intCast(len);
    try list.append(allocator, .{ .kind = .lit, .off = off_u16, .len = len_u16 });
}

fn matchLit(s: []const u8, at: usize, lit: []const u8) bool {
    if (at + lit.len > s.len) return false;
    return mem.eql(u8, s[at .. at + lit.len], lit);
}

fn isWordChar(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

fn matchWord(s: []const u8, at: usize, w: []const u8) bool {
    if (at + w.len > s.len) return false;
    if (!mem.eql(u8, s[at .. at + w.len], w)) return false;

    if (at > 0 and isWordChar(s[at - 1])) return false;
    if (at + w.len < s.len and isWordChar(s[at + w.len])) return false;

    return true;
}

fn trimAscii(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\t' or s[b - 1] == '\r')) b -= 1;
    return s[a..b];
}

fn stripInlineComment(s: []const u8) []const u8 {
    // Strip from first '#' or ';' that is not inside a double-quoted region.
    var in_q = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') in_q = !in_q;
        if (!in_q and (c == '#' or c == ';')) return trimAscii(s[0..i]);
    }
    return s;
}

fn unquoteAscii(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn asciiLower(b: u8) u8 {
    return if (b >= 'A' and b <= 'Z') b + 32 else b;
}

fn eqLower(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

/// ------------------------------
/// Internal: format compiler
/// ------------------------------

const Spec = enum(u8) {
    percent,
    a, A,
    b, B,
    d0, d,
    m0, m,
    y0, y,
    Y,
    H0, H,
    I0, I,
    M0, M,
    p,
    x, // ISO date
    X, // ISO time (HH:MM)
};


const TokKind = enum(u8) { lit, spec };

const Tok = packed struct {
    kind: TokKind,
    a: u16, // for lit: off, for spec: Spec
    b: u16, // for lit: len, for spec: unused
};

const CompiledFormat = struct {
    raw:  []u8,
    toks: []Tok,

    pub fn init(allocator: mem.Allocator, src: []const u8) !CompiledFormat {
        const raw = try allocator.dupe(u8, src);
        errdefer allocator.free(raw);

        var list: std.ArrayListUnmanaged(Tok) = .{};
        errdefer list.deinit(allocator);

        var i: usize = 0;
        var lit_start: usize = 0;

        while (i < raw.len) {
            if (raw[i] != '%') {
                i += 1;
                continue;
            }

            // Flush literal before '%'.
            if (i > lit_start) try appendFmtLit(allocator, &list, lit_start, i);

            i += 1;
            if (i >= raw.len) return error.InvalidFormat;

            var no_pad = false;
            if (raw[i] == '-') {
                no_pad = true;
                i += 1;
                if (i >= raw.len) return error.InvalidFormat;
            }

            const c = raw[i];
            i += 1;

            const spec: Spec = try specFromChar(c, no_pad);

            try list.append(allocator, .{
                .kind = .spec,
                .a = @intCast(@intFromEnum(spec)),
                .b = 0,
            });

            lit_start = i;
        }

        if (i > lit_start) try appendFmtLit(allocator, &list, lit_start, i);

        const toks = try list.toOwnedSlice(allocator);
        errdefer allocator.free(toks);

        return .{ .raw = raw, .toks = toks };
    }

    pub fn deinit(self: *CompiledFormat, allocator: mem.Allocator) void {
        allocator.free(self.raw);
        allocator.free(self.toks);
        self.* = undefined;
    }


    const DateCtx = struct { y: u32, m: u32, d: u32, wd: u32 };
    const TimeCtx = struct { hh: u32, mm: u32 };

    inline fn emitDate(spec: Spec, ctx: DateCtx, out: []u8, pos0: usize) usize {
        return emitDateSpec(spec, ctx.y, ctx.m, ctx.d, ctx.wd, out, pos0);
    }

    inline fn emitTime(spec: Spec, ctx: TimeCtx, out: []u8, pos0: usize) usize {
        return emitTimeSpec(spec, ctx.hh, ctx.mm, out, pos0);
    }

    inline fn formatCore(
        self: *const CompiledFormat,
        out: []u8,
        ctx: anytype,
        comptime emitFn: anytype,
    ) []const u8 {
        var pos: usize = 0;
        var i: usize = 0;
        while (i < self.toks.len and pos < out.len) : (i += 1) {
            const t = self.toks[i];
            if (t.kind == .lit) {
                const off: usize = t.a;
                const len: usize = t.b;
                const n = @min(out.len - pos, len);
                mem.copyForwards(u8, out[pos .. pos + n], self.raw[off .. off + n]);
                pos += n;
                continue;
            }
            const spec: Spec = @enumFromInt(@as(u8, @intCast(t.a)));
            pos = emitFn(spec, ctx, out, pos);
        }
        return out[0..pos];

    }

    pub fn formatDate(
        self: *const CompiledFormat,
        y: u32,
        m: u32,
        d: u32,
        out: []u8,
    ) []const u8 {
        const wd = weekdayFromYMD(y, m, d);
        return self.formatCore(out, DateCtx{ .y = y, .m = m, .d = d, .wd = wd }, emitDate);
  
    }

    pub fn formatTime(
        self: *const CompiledFormat,
        hh: u32,
        mm_: u32,
        out: []u8,
    ) []const u8 {
        return self.formatCore(out, TimeCtx{ .hh = hh, .mm = mm_ }, emitTime);
    }

    fn specFromChar(c: u8, no_pad: bool) !Spec {
        return switch (c) {
            '%' => .percent,

            'a' => .a,
            'A' => .A,
            'b' => .b,
            'B' => .B,

            'd' => if (no_pad) .d else .d0,
            'm' => if (no_pad) .m else .m0,
            'y' => if (no_pad) .y else .y0,

            'Y' => if (no_pad) error.InvalidFormat else .Y,

            'H' => if (no_pad) .H else .H0,
            'I' => if (no_pad) .I else .I0,
            'M' => if (no_pad) .M else .M0,

            'p' => if (no_pad) error.InvalidFormat else .p,
            'x' => if (no_pad) error.InvalidFormat else .x,
            'X' => if (no_pad) error.InvalidFormat else .X,

            else => error.InvalidFormat,
        };
    }
};

fn appendFmtLit(
    allocator: mem.Allocator,
    list: *std.ArrayListUnmanaged(Tok),
    a: usize,
    b: usize,
) !void {
    if (b <= a) return;
    const len = b - a;
    if (a > std.math.maxInt(u16) or len > std.math.maxInt(u16)) return error.FormatTooLong;
    try list.append(allocator, .{
        .kind = .lit,
        .a = @intCast(a),
        .b = @intCast(len),
    });
}

const MONTH_ABBR = [_][]const u8{
    "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec",
};
const MONTH_FULL = [_][]const u8{
    "January","February","March","April","May","June","July","August","September","October","November","December",
};
const WD_ABBR = [_][]const u8{
    "Sun","Mon","Tue","Wed","Thu","Fri","Sat",
};
const WD_FULL = [_][]const u8{
    "Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday",
};

fn emitDateSpec(spec: Spec, y: u32, m: u32, d: u32, wd: u32, out: []u8, pos0: usize) usize {
    var pos = pos0;
    switch (spec) {
        .percent => pos = emitByte('%', out, pos),

        .a => pos = emitStr(WD_ABBR[@intCast(wd)], out, pos),
        .A => pos = emitStr(WD_FULL[@intCast(wd)], out, pos),

        .b => pos = emitStr(MONTH_ABBR[@intCast(m - 1)], out, pos),
        .B => pos = emitStr(MONTH_FULL[@intCast(m - 1)], out, pos),

        .d0 => pos = emit2(d, out, pos),
        .d  => pos = emitU(d, out, pos),

        .m0 => pos = emit2(m, out, pos),
        .m  => pos = emitU(m, out, pos),

        .y0 => pos = emit2(y % 100, out, pos),
        .y  => pos = emitU(y % 100, out, pos),

        .Y  => pos = emit4(y, out, pos),

        .x  => pos = emitIsoDate(y, m, d, out, pos),

        // date formatter should not see time specs, but remain harmless.
        else => {},
    }
    return pos;
}

fn emitTimeSpec(spec: Spec, hh: u32, mm_: u32, out: []u8, pos0: usize) usize {
    var pos = pos0;

    const is_pm = hh >= 12;
    const hour12: u32 = blk: {
        var h = hh % 12;
        if (h == 0) h = 12;
        break :blk h;
    };

    switch (spec) {
        .percent => pos = emitByte('%', out, pos),

        .H0 => pos = emit2(hh, out, pos),
        .H  => pos = emitU(hh, out, pos),

        .I0 => pos = emit2(hour12, out, pos),
        .I  => pos = emitU(hour12, out, pos),

        .M0 => pos = emit2(mm_, out, pos),
        .M  => pos = emitU(mm_, out, pos),

        .p  => pos = emitStr(if (is_pm) "PM" else "AM", out, pos),

        .X  => pos = emitIsoTime(hh, mm_, out, pos),

        // time formatter should not see date specs, but remain harmless.
        else => {},
    }

    return pos;
}

fn emitIsoDate(y: u32, m: u32, d: u32, out: []u8, pos0: usize) usize {
    var pos = pos0;
    pos = emit4(y, out, pos);
    pos = emitByte('-', out, pos);
    pos = emit2(m, out, pos);
    pos = emitByte('-', out, pos);
    pos = emit2(d, out, pos);
    return pos;
}

fn emitIsoTime(hh: u32, mm_: u32, out: []u8, pos0: usize) usize {
    var pos = pos0;
    pos = emit2(hh, out, pos);
    pos = emitByte(':', out, pos);
    pos = emit2(mm_, out, pos);
    return pos;
}

fn emitStr(s: []const u8, out: []u8, pos0: usize) usize {
    const pos = pos0;
    if (pos >= out.len) return pos;
    const n = @min(out.len - pos, s.len);
    mem.copyForwards(u8, out[pos .. pos + n], s[0..n]);
    return pos + n;
}

fn emitByte(b: u8, out: []u8, pos0: usize) usize {
    if (pos0 >= out.len) return pos0;
    out[pos0] = b;
    return pos0 + 1;
}

fn emit2(v: u32, out: []u8, pos0: usize) usize {
    var pos = pos0;
    const tens: u8 = @intCast((v / 10) % 10);
    const ones: u8 = @intCast(v % 10);
    pos = emitByte('0' + tens, out, pos);
    pos = emitByte('0' + ones, out, pos);
    return pos;
}

fn emit4(v: u32, out: []u8, pos0: usize) usize {
    var pos = pos0;
    const a: u8 = @intCast((v / 1000) % 10);
    const b: u8 = @intCast((v / 100) % 10);
    const c: u8 = @intCast((v / 10) % 10);
    const d: u8 = @intCast(v % 10);
    pos = emitByte('0' + a, out, pos);
    pos = emitByte('0' + b, out, pos);
    pos = emitByte('0' + c, out, pos);
    pos = emitByte('0' + d, out, pos);
    return pos;
}

fn emitU(v: u32, out: []u8, pos0: usize) usize {
    // minimal decimal, no heap.
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        tmp[n] = @intCast('0' + (x % 10));
        n += 1;
        x /= 10;
        if (x == 0) break;
        if (n == tmp.len) break;
    }

    var pos = pos0;
    while (n > 0 and pos < out.len) {
        n -= 1;
        out[pos] = tmp[n];
        pos += 1;
    }
    return pos;
}

/// Canonical date parser: "YYYY-MM-DD"
fn parseCanonDate(s: []const u8, y: *u32, m: *u32, d: *u32) bool {
    if (s.len != 10) return false;
    if (s[4] != '-' or s[7] != '-') return false;

    const yv = parseDigits(s[0..4]) orelse return false;
    const mv = parseDigits(s[5..7]) orelse return false;
    const dv = parseDigits(s[8..10]) orelse return false;

    if (mv < 1 or mv > 12) return false;
    if (dv < 1 or dv > 31) return false;

    y.* = yv;
    m.* = mv;
    d.* = dv;
    return true;
}

/// Canonical time parser: "HH:MM"
fn parseCanonTime(s: []const u8, hh: *u32, mm_: *u32) bool {
    if (s.len != 5) return false;
    if (s[2] != ':') return false;
    const hv = parseDigits(s[0..2]) orelse return false;
    const mv = parseDigits(s[3..5]) orelse return false;
    if (hv > 23 or mv > 59) return false;
    hh.* = hv;
    mm_.* = mv;
    return true;
}

fn parseDigits(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b < '0' or b > '9') return null;
        v = v * 10 + @as(u32, b - '0');
    }
    return v;
}

// Sakamoto weekday, Gregorian calendar.
// returns 0=Sun..6=Sat
fn weekdayFromYMD(y_: u32, m_: u32, d_: u32) u32 {
    var y = @as(i32, @intCast(y_));
    const m = @as(i32, @intCast(m_));
    const d = @as(i32, @intCast(d_));

    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    if (m < 3) y -= 1;
    const w = y
        + @divTrunc(y, 4)
        - @divTrunc(y, 100)
        + @divTrunc(y, 400)
        + t[@intCast(m - 1)]
        + d;
    const r = @rem(w,7);
    return @intCast(if (r < 0) r + 7 else r);
}



test "editor_due_date strict %-d/%m/%Y rejects padded day" {
    var f = try CompiledFormat.init(std.testing.allocator, "%-d/%m/%Y");
    defer f.deinit(std.testing.allocator);

    try std.testing.expect(isValidEditorDateFormat(&f));

    var out: [10]u8 = undefined;

    // Accepts unpadded day for %-d
    try std.testing.expect(parseUserDueDateCanonicalByFormat(&f, "1/01/2025", &out));
    try std.testing.expectEqualStrings("2025-01-01", out[0..]);

    // Rejects padded day for %-d
    try std.testing.expect(!parseUserDueDateCanonicalByFormat(&f, "01/01/2025", &out));
}

test "editor_due_date strict %d/%m/%Y rejects unpadded day" {
    var f = try CompiledFormat.init(std.testing.allocator, "%d/%m/%Y");
    defer f.deinit(std.testing.allocator);

    try std.testing.expect(isValidEditorDateFormat(&f));

    var out: [10]u8 = undefined;

    // Accepts padded day for %d
    try std.testing.expect(parseUserDueDateCanonicalByFormat(&f, "01/01/2025", &out));
    try std.testing.expectEqualStrings("2025-01-01", out[0..]);

    // Rejects unpadded day for %d
    try std.testing.expect(!parseUserDueDateCanonicalByFormat(&f, "1/01/2025", &out));
}

test "editor_due_date allows %x (canonical ISO date) only" {
    var f = try CompiledFormat.init(std.testing.allocator, "%x");
    defer f.deinit(std.testing.allocator);

    try std.testing.expect(isValidEditorDateFormat(&f));

    var out: [10]u8 = undefined;

    try std.testing.expect(parseUserDueDateCanonicalByFormat(&f, "2025-12-31", &out));
    try std.testing.expectEqualStrings("2025-12-31", out[0..]);

    // Strict: does not accept non-ISO input under %x
    try std.testing.expect(!parseUserDueDateCanonicalByFormat(&f, "31/12/2025", &out));
}

test "editor_due_date rejects time-only formats" {
    var f = try CompiledFormat.init(std.testing.allocator, "%H:%M");
    defer f.deinit(std.testing.allocator);

    try std.testing.expect(!isValidEditorDateFormat(&f));
}
