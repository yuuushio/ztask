const std = @import("std");

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
