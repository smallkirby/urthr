//! Minimal regex matcher.
//!
//! Supports a small subset of POSIX ERE:
//!
//! - literal characters
//! - `.`
//! - `*`
//! - `+`
//! - `?`
//! - `[...]`
//! - `[^...]`
//! - `^`
//! - `$`
//! - `|`
//! - `\` (escape)

/// Returns whether `pattern` matches somewhere within `text`.
pub fn isMatch(pattern: []const u8, text: []const u8) bool {
    var alt_it = std.mem.splitScalar(u8, pattern, '|');
    while (alt_it.next()) |alt| {
        if (matchAlt(alt, text)) return true;
    }
    return false;
}

/// Check if `pattern` matches a `text`.
fn matchAlt(pattern: []const u8, text: []const u8) bool {
    if (pattern.len > 0 and pattern[0] == '^') {
        return matchHere(pattern[1..], text);
    }
    var t = text;
    while (t.len != 0) : (t = t[1..]) {
        if (matchHere(pattern, t)) return true;
    } else return false;
}

/// Check if `pattern` matches the beginning of `text`.
fn matchHere(pattern: []const u8, text: []const u8) bool {
    // Empty pattern.
    if (pattern.len == 0) return true;
    // '$' only.
    if (pattern.len == 1 and pattern[0] == '$') return text.len == 0;

    const alen = atomLen(pattern);
    const atom = pattern[0..alen];
    const rest = pattern[alen..];

    if (rest.len > 0) {
        switch (rest[0]) {
            '*' => return matchStar(atom, rest[1..], text),
            '+' => return text.len > 0 and
                matchAtom(atom, text[0]) and
                matchStar(atom, rest[1..], text[1..]),
            '?' => if (text.len > 0 and
                matchAtom(atom, text[0]) and
                matchHere(rest[1..], text[1..]))
                return true
            else
                return matchHere(rest[1..], text),
            else => {},
        }
    }

    if (text.len == 0 or !matchAtom(atom, text[0])) return false;
    return matchHere(rest, text[1..]);
}

/// Greedily match zero or more `atom`, backtracking until `rest` matches.
fn matchStar(atom: []const u8, rest: []const u8, text: []const u8) bool {
    var count: usize = 0;
    while (count < text.len and matchAtom(atom, text[count])) count += 1;
    while (true) : (count -= 1) {
        if (matchHere(rest, text[count..])) return true;
        if (count == 0) return false;
    }
}

/// Length in bytes of the next atom (literal char, `\`-escape, or `[...]` class).
fn atomLen(pattern: []const u8) usize {
    if (pattern[0] == '\\') {
        return if (pattern.len >= 2) 2 else 1;
    }
    if (pattern[0] == '[') {
        var i: usize = 1;
        if (i < pattern.len and pattern[i] == '^') i += 1;
        // A ']' as the first class member (after an optional '^') is literal.
        if (i < pattern.len and pattern[i] == ']') i += 1;
        while (i < pattern.len and pattern[i] != ']') i += 1;
        return if (i < pattern.len) i + 1 else pattern.len;
    }
    return 1;
}

/// Whether `c` matches the atom `pattern[0..atomLen(pattern)]`.
fn matchAtom(atom: []const u8, c: u8) bool {
    if (atom[0] == '\\') return atom[1] == c;
    if (atom[0] == '[') return matchClass(atom, c);
    return atom[0] == '.' or atom[0] == c;
}

/// Whether `c` matches the character class.
fn matchClass(atom: []const u8, c: u8) bool {
    var body = atom[1 .. atom.len - 1];
    var negate = false;
    if (body.len > 0 and body[0] == '^') {
        negate = true;
        body = body[1..];
    }

    var matched = false;
    var i: usize = 0;
    while (i < body.len) {
        if (i + 2 < body.len and body[i + 1] == '-') {
            if (c >= body[i] and c <= body[i + 2]) matched = true;
            i += 3;
        } else {
            if (body[i] == c) matched = true;
            i += 1;
        }
    }
    return matched != negate;
}

// =============================================================
// Tests
// =============================================================

test "literal substring" {
    try std.testing.expect(isMatch("bar", "foobarbaz"));
    try std.testing.expect(!isMatch("qux", "foobarbaz"));
}

test "anchors" {
    try std.testing.expect(isMatch("^foo", "foobar"));
    try std.testing.expect(!isMatch("^foo", "barfoo"));
    try std.testing.expect(isMatch("bar$", "foobar"));
    try std.testing.expect(!isMatch("bar$", "barfoo"));
    try std.testing.expect(isMatch("^foobar$", "foobar"));
    try std.testing.expect(!isMatch("^foobar$", "foobarbaz"));
}

test "dot and star" {
    try std.testing.expect(isMatch("f.o", "foo"));
    try std.testing.expect(isMatch("fo*", "f"));
    try std.testing.expect(isMatch("fo*", "foooo"));
    try std.testing.expect(isMatch("^.*$", ""));
    try std.testing.expect(isMatch("^.*$", "anything"));
}

test "plus and question mark" {
    try std.testing.expect(!isMatch("^fo+$", "f"));
    try std.testing.expect(isMatch("^fo+$", "foo"));
    try std.testing.expect(isMatch("^colou?r$", "color"));
    try std.testing.expect(isMatch("^colou?r$", "colour"));
    try std.testing.expect(!isMatch("^colou?r$", "colouur"));
}

test "character classes" {
    try std.testing.expect(isMatch("[abc]", "xbz"));
    try std.testing.expect(!isMatch("[abc]", "xyz"));
    try std.testing.expect(isMatch("^[a-z]+$", "hello"));
    try std.testing.expect(!isMatch("^[a-z]+$", "Hello"));
    try std.testing.expect(isMatch("^[^0-9]+$", "abc"));
    try std.testing.expect(!isMatch("^[^0-9]+$", "abc1"));
}

test "alternation" {
    try std.testing.expect(isMatch("foo|bar", "somebar"));
    try std.testing.expect(isMatch("^(foo)|(bar)$", "(bar)"));
    try std.testing.expect(!isMatch("foo|bar", "baz"));
}

test "escape" {
    try std.testing.expect(isMatch("a\\.b", "a.b"));
    try std.testing.expect(!isMatch("a\\.b", "axb"));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
