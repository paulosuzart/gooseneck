import std;

namespace gooseneck;

// ---------------------------------------------------------------------------
// Paths: https://handlebarsjs.com/guide/expressions.html

const INVALID_SEGMENT = "Invalid characted in segment";
const KEYWORD_IN_PATH = "true, false, null, or undefined allowed only at the beginning of the path";
const UNKNOWN_DATA = "Unknown data variable: only @root, and @index, @key, @first and @last after any ../";

const INVALID_IDENTIFIER_CHARS: u8[27] = ['!', '"', '#', '%', '&','\'', '(', ')', '*', 
                                          '+', ',', '.', '/', ';', '<', '=', '>', '@', 
                                          '[', '\\', ']', '^', '`', '{', '|', '}', '~'];

// The navigation step at the start of path: how many bytes it takes, and
// whether it climbs to the parent frame. ../ and .. climb; ./, ., this,
// this. and this/ stay on the current frame. Zero bytes when path starts
// with a field name instead.
fn navigation_step(path: const u8[:]) -> i64, bool {
    if starts_with(path, "../") { return 3, true; }
    if path == ".." { return 2, true; }
    if starts_with(path, "./") { return 2, false; }
    if path == "." { return 1, false; }
    if starts_with(path, "this.") || starts_with(path, "this/") { return 5, false; }
    if path == "this" { return 4, false; }
    return 0, false;
}

// Drops the leading navigation steps (see navigation_step). What remains
// is the field path the identifier check sees. ../name is parent then
// name, not a name that contains '/'.
fn strip_navigation(path: const u8[:]) -> const u8[:] {
    var rest = path;
    loop {
        let taken, climbs = navigation_step(rest);
        if taken == 0 { break; }
        rest = rest[taken..];
    }
    return rest;
}

// The data variables {{#each}} sets, written @index, @key, @first, @last.
const DATA_NAMES = ["index", "key", "first", "last"];

// Splits a path that starts at the context the render began with, @root
// or @root.name..., into true and the path after "@root.": "" for @root,
// "a.b" for @root.a.b. Any other path: false and "".
fn root_parts(path: const u8[:]) -> bool, const u8[:] {
    guard starts_with(path, "@root") else { return false, ""; }
    let rest = path[5..];
    if rest.len == 0 { return true, rest; }
    guard starts_with(rest, ".") else { return false, ""; }
    return true, rest[1..];
}

// Splits a data path, @ then any number of ../ then a name, into how many
// enclosing each blocks it climbs and the name: @../index is 1 and
// "index". Not a data path: -1 and "".
fn data_parts(path: const u8[:]) -> i64, const u8[:] {
    guard starts_with(path, "@") else { return -1, ""; }
    var rest = path[1..];
    var depth: i64 = 0;
    while starts_with(rest, "../") {
        rest = rest[3..];
        depth += 1;
    }
    return depth, rest;
}

// Whether path is a data variable: @, any number of ../, and one of
// DATA_NAMES.
fn is_data_path(path: const u8[:]) -> bool {
    let depth, name = data_parts(path);
    guard depth >= 0 else { return false; }
    for known in DATA_NAMES {
        if name == known { return true; }
    }
    return false;
}

// Whether a token can be one segment of a path: a name, or a word the lexer
// read as a literal (a path may start with true: true.name).
fn is_segment(token: TagToken) -> bool {
    let kind = token.kind;
    return kind == TagTokenKind.Ident || kind == TagTokenKind.Number || kind == TagTokenKind.Bool || kind == TagTokenKind.Null;
}

// Whether a segment's text is one of the literal words.
fn is_keyword(text: const u8[:]) -> bool {
    return text == "true" || text == "false" || text == "null" || text == "undefined";
}

// Whether tokens[i] is a navigation step: .., . or this.
fn is_navigation(source: const u8[:], tokens: const TagToken[>..<]&, i: i64) -> bool {
    let token = tokens[i];
    if token.kind == TagTokenKind.DotDot || token.kind == TagTokenKind.Dot { return true; }
    return token.kind == TagTokenKind.Ident && token_text(source, token) == "this";
}

// Where the field segments of the path tokens[from..to] start: past its
// leading navigation, ../, ./, this. or this/, any number of them, and a
// last .., . or this.
fn skip_navigation(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64) -> i64 {
    var i = from;
    while i < to && is_navigation(source, tokens, i) {
        i += 1;
        let separated = i < to && (tokens[i].kind == TagTokenKind.Slash || tokens[i].kind == TagTokenKind.Sep);
        guard separated else { break; }
        i += 1;
    }
    return i;
}

// What is wrong with the path tokens[from..to], or "" when nothing is: it
// must be a data variable (@, any ../, a data name), @root and name
// segments after it, or navigation then name segments joined by '.'. A
// literal word is a segment only first.
fn path_error(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64) -> const u8[:] {
    guard to > from else { return "Has 0 length"; }
    if tokens[from].kind == TagTokenKind.Data {
        let text = source[tokens[from].start..tokens[to - 1].end];
        if is_data_path(text) { return ""; }
        let rooted, rest = root_parts(text);
        guard rooted else { return UNKNOWN_DATA; }
        // @ and root, then '.' and the segments.
        guard to > from + 2 else { return ""; }
        guard to > from + 3 else { return INVALID_SEGMENT; }
        return segments_error(source, tokens, from + 3, to);
    }
    return segments_error(source, tokens, skip_navigation(source, tokens, from, to), to);
}

// What is wrong with name segments joined by '.', tokens[body..to], or ""
// when nothing is: a literal word is a segment only first, and the path
// neither ends in a '.' nor has two in a row.
fn segments_error(source: const u8[:], tokens: const TagToken[>..<]&, body: i64, to: i64) -> const u8[:] {
    var i = body;
    while i < to {
        let later = i > body;
        if later && is_segment(tokens[i]) && is_keyword(token_text(source, tokens[i])) { return KEYWORD_IN_PATH; }
        i += 1;
    }
    i = body;
    while i < to {
        let wants_segment = (i - body) % 2 == 0;
        let fits = if wants_segment { is_segment(tokens[i]) } else { tokens[i].kind == TagTokenKind.Sep };
        guard fits else { return INVALID_SEGMENT; }
        i += 1;
    }
    let ends_in_sep = to > body && (to - body) % 2 == 0;
    guard !ends_in_sep else { return INVALID_SEGMENT; }
    return "";
}

// Checks a path on its own: whether it is valid, and if not, why (see
// path_error).
fn validate_path(path: const u8[:]) -> bool, u8[:] {
    let tokens: TagToken[>..<] = [];
    lex_tag(path, 0, path.len, tokens);
    let why = path_error(path, tokens, 0, tokens.len);
    return why.len == 0, why;
}
