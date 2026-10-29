import std;
import regex;
import os;
import math;
import json;

namespace gooseneck;

// ---------------------------------------------------------------------------
// Tokenizing.
//
// _tokenize is the only code that walks the template: it owns the cursor.
// _scan_tag reads one tag from a given position with a cursor of its own and
// returns where the tag ends; nothing else moves through the template. Every
// token records byte offsets into the template, never a copy. Whitespace
// control is a separate pass over the finished tokens
// (_control_whitespace): it only narrows the ranges of Text tokens.

enum TokenType {
    Text,
    Expression,
    // {{! ... }} and {{!-- ... --}}: written nowhere.
    Comment,
    // {{{{helper args}}}} and {{{{/helper}}}}: a raw block, whose content
    // is one Text token, never parsed.
    RawOpen,
    RawClose,
}

struct Token {
    token_type: TokenType,
    // Text: the bytes to write, template[start..end]. The whitespace pass
    // narrows this range, and a Text left empty writes nothing. A tag: its
    // body between the braces, without ~, trimmed.
    start: i64,
    end: i64,
    // Text: the range as tokenized, which the standalone checks read, so
    // what one tag strips never changes what another tag sees. A tag: the
    // whole tag, braces included.
    outer_start: i64,
    outer_end: i64,
    // True for {{...}}: the looked-up text is HTML-escaped when written.
    // False for {{{...}}}, for comments and for text.
    escaped: bool,
    // {{~ and ~}}: strip all whitespace, newlines included, from the end of
    // the Text before the tag / the start of the Text after it.
    strip_left: bool,
    strip_right: bool,
}

fn _text_token(start: i64, end: i64) -> Token {
    return Token {
        token_type: TokenType.Text,
        start: start, end: end, outer_start: start, outer_end: end,
        escaped: false, strip_left: false, strip_right: false,
    };
}

// Reads the tag that opens with "{{" at input[at]. The forms are {{x}},
// {{{x}}}, {{! x }} and {{!-- x --}}, each with an optional ~ just inside
// either end: {{~x~}}, {{~{x}~}}, {{~!-- x --~}}. Returns the tag's token,
// and an error, empty when the tag closes.
fn _scan_tag(input: const u8[:], at: i64) -> Token, const u8[:] {
    var p = at + 2;
    let strip_left = p < input.len && input[p] == '~';
    if strip_left { p += 1; }
    var kind = TokenType.Expression;
    var escaped = true;
    // What must come right before the closing "}}" (and its optional ~).
    var head: const u8[:] = "";
    if p < input.len && input[p] == '{' {
        escaped = false;
        head = "}";
        p += 1;
    } else if starts_with(input[p..], "!--") {
        kind = TokenType.Comment;
        escaped = false;
        head = "--";
        p += 3;
    } else if p < input.len && input[p] == '!' {
        kind = TokenType.Comment;
        escaped = false;
        p += 1;
    }
    var from = p;
    var found = find(input[from..], "}}");
    while found >= 0 {
        let close = from + found;
        let strip_right = close > p && input[close - 1] == '~';
        let body_end = if strip_right { close - 1 } else { close };
        if body_end - head.len >= p && input[body_end - head.len..body_end] == head {
            let body = input[p..body_end - head.len];
            let lead = trim_start(body);
            let start = p + body.len - lead.len;
            let end = start + trim_end(lead).len;
            return Token {
                token_type: kind,
                start: start, end: end, outer_start: at, outer_end: close + 2,
                escaped: escaped, strip_left: strip_left, strip_right: strip_right,
            }, "";
        }
        // That "}}" was not this tag's closing (e.g. inside {{!-- x }} y --}}).
        from = close + 1;
        found = find(input[from..], "}}");
    }
    return _text_token(at, at), "unclosed tag";
}

// A tag token for template[start..end], the tag being
// template[outer_start..outer_end].
fn _tag_token(kind: TokenType, start: i64, end: i64, outer_start: i64, outer_end: i64) -> Token {
    return Token {
        token_type: kind,
        start: start, end: end, outer_start: outer_start, outer_end: outer_end,
        escaped: false, strip_left: false, strip_right: false,
    };
}

// The token of the tag that opens with "{{{{" at input[at] and closes
// with "}}}}", its body trimmed: {{{{raw}}}} or {{{{/raw}}}}. Returns an
// error, empty when the tag closes.
fn _scan_raw_tag(input: const u8[:], at: i64, kind: TokenType) -> Token, const u8[:] {
    let found = find(input[at + 4..], "}}}}");
    guard found >= 0 else { return _text_token(at, at), "unclosed tag"; }
    let close = at + 4 + found;
    var start = at + 4;
    if kind == TokenType.RawClose { start += 1; }
    var end = close;
    while start < end && _is_space(input[start]) { start += 1; }
    while end > start && _is_space(input[end - 1]) { end -= 1; }
    return _tag_token(kind, start, end, at, close + 4), "";
}

// Reads the raw block that opens at input[at], {{{{helper}}}}...{{{{/helper}}}},
// onto tokens: its opening tag, its content as one Text token, and its
// closing tag. Inside, nothing is a tag: a nested {{{{x}}}} only has to be
// closed by its own {{{{/x}}}} before the block's closing tag counts, as in
// handlebars.js. Without a closing tag the content runs to the end, and
// the parser reports the block as unclosed. Returns where the block ends,
// and an error, empty when its tags close.
fn _scan_raw_block(input: const u8[:], at: i64, tokens: Token[>..]&) -> i64, const u8[:] {
    let open, err = _scan_raw_tag(input, at, TokenType.RawOpen);
    guard err.len == 0 else { return at, err; }
    tokens.push(open);
    let content = open.outer_end;
    var depth: i64 = 1;
    var p = content;
    loop {
        let found = find(input[p..], "{{{{");
        guard found >= 0 else { break; }
        let tag_at = p + found;
        let closing = tag_at + 4 < input.len && input[tag_at + 4] == '/';
        if !closing {
            depth += 1;
            p = tag_at + 4;
            continue;
        }
        let close, close_err = _scan_raw_tag(input, tag_at, TokenType.RawClose);
        guard close_err.len == 0 else { break; }
        depth -= 1;
        if depth == 0 {
            _push_text(tokens, content, tag_at);
            tokens.push(close);
            return close.outer_end, "";
        }
        p = close.outer_end;
    }
    _push_text(tokens, content, input.len);
    return input.len, "";
}

// Pushes a Text token for input[start..end] when that range holds something.
fn _push_text(tokens: Token[>..]&, start: i64, end: i64) {
    if end > start { tokens.push(_text_token(start, end)); }
}

// How many backslashes come right before input[at], back to from.
fn _backslashes_before(input: const u8[:], from: i64, at: i64) -> i64 {
    var p = at;
    while p > from && input[p - 1] == '\\' { p -= 1; }
    return at - p;
}

// Where the text of an escaped mustache, \{{...}}, that starts at
// input[at] ends: before the next "{{", and before the one or two
// backslashes that may escape that one; at the end of input otherwise.
fn _escaped_end(input: const u8[:], at: i64) -> i64 {
    let found = find(input[at + 2..], "{{");
    guard found >= 0 else { return input.len; }
    let next = at + 2 + found;
    let slashes = _backslashes_before(input, at + 2, next);
    return next - min(slashes, 2);
}

// ---------------------------------------------------------------------------
// Whitespace control: https://handlebarsjs.com/guide/expressions.html#whitespace-control
//
// Two rules, both applied by narrowing the Text tokens next to a tag:
//
// - ~ strips every whitespace byte, newlines included: {{~ from the end of
//   the Text before the tag, ~}} from the start of the Text after it.
// - A block tag ({{#...}}, {{/...}}, {{^...}}) or a comment that is alone on
//   its line, with only spaces and tabs around it, is "standalone": its line
//   is removed, the indentation before the tag and the line break after it.
//
// As in Handlebars, the standalone checks read the text as tokenized, not
// as stripped, and a neighbor that is another tag makes the line not
// standalone. The start and the end of the template count as line breaks.

fn _is_space(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12;
}

// Whether token is a tag that standalone lines apply to: a block tag,
// {{else}} or a comment.
fn _standalone_kind(input: const u8[:], token: const Token&) -> bool {
    if token.token_type == TokenType.Comment || token.token_type == TokenType.RawOpen || token.token_type == TokenType.RawClose { return true; }
    guard token.token_type == TokenType.Expression && token.end > token.start else { return false; }
    let c = input[token.start];
    return c == '#' || c == '/' || c == '^' || _is_else(input[token.start..token.end]);
}

// Whether word is an {{else}} tag: a plain one, or one that chains a block
// such as {{else if b}}.
fn _is_else(word: const u8[:]) -> bool {
    return word == "else" || _is_else_chain(word);
}

// Whether word chains a block onto an {{else}}: {{else if b}},
// {{else each items}}.
fn _is_else_chain(word: const u8[:]) -> bool {
    return word.len > 4 && starts_with(word, "else") && _is_space(word[4]);
}

// Whether only whitespace follows the last line break before tokens[i]:
// the text before it ends in whitespace that holds a '\n'. The first token
// of the template also passes when it is all whitespace, and so does
// nothing at all before the tag.
fn _prev_blank(input: const u8[:], tokens: const Token[>..]&, i: i64) -> bool {
    guard i > 0 else { return true; }
    let prev = tokens[i - 1];
    guard prev.token_type == TokenType.Text else { return false; }
    let text = input[prev.outer_start..prev.outer_end];
    var k = text.len;
    var newline = false;
    while k > 0 && _is_space(text[k - 1]) {
        if text[k - 1] == '\n' { newline = true; }
        k -= 1;
    }
    return newline || (i - 1 == 0 && k == 0);
}

// Whether only whitespace comes before the next line break after
// tokens[i]: the text after it starts with whitespace that holds a '\n'.
// The last token of the template also passes when it is all whitespace,
// and so does nothing at all after the tag.
fn _next_blank(input: const u8[:], tokens: const Token[>..]&, i: i64) -> bool {
    guard i + 1 < tokens.len else { return true; }
    let next = tokens[i + 1];
    guard next.token_type == TokenType.Text else { return false; }
    let text = input[next.outer_start..next.outer_end];
    var k: i64 = 0;
    var newline = false;
    while k < text.len && _is_space(text[k]) {
        if text[k] == '\n' { newline = true; }
        k += 1;
    }
    return newline || (i + 1 == tokens.len - 1 && k == text.len);
}

// ~ before the tag: drops all trailing whitespace.
fn _strip_end(input: const u8[:], t: Token&) {
    while t.end > t.start && _is_space(input[t.end - 1]) { t.end -= 1; }
}

// ~ after the tag: drops all leading whitespace.
fn _strip_start(input: const u8[:], t: Token&) {
    while t.start < t.end && _is_space(input[t.start]) { t.start += 1; }
}

// Standalone, before the tag: drops the line's indentation, spaces and tabs.
fn _strip_indent(input: const u8[:], t: Token&) {
    while t.end > t.start && (input[t.end - 1] == ' ' || input[t.end - 1] == '\t') { t.end -= 1; }
}

// Standalone, after the tag: drops spaces and tabs, then one "\n" or "\r\n".
fn _strip_line_end(input: const u8[:], t: Token&) {
    while t.start < t.end && (input[t.start] == ' ' || input[t.start] == '\t') { t.start += 1; }
    if t.start < t.end && input[t.start] == '\r' && t.start + 1 < t.end && input[t.start + 1] == '\n' {
        t.start += 2;
    } else if t.start < t.end && input[t.start] == '\n' {
        t.start += 1;
    }
}

// Applies ~ and standalone lines to the Text tokens around each tag. The
// _strip_* helpers narrow tokens[i - 1] and tokens[i + 1] in place; tag is a
// copy, and only read.
fn _control_whitespace(input: const u8[:], tokens: Token[>..]&) {
    var i: i64 = 0;
    while i < tokens.len {
        let tag = tokens[i];
        if tag.token_type != TokenType.Text {
            let has_prev = i > 0 && tokens[i - 1].token_type == TokenType.Text;
            let has_next = i + 1 < tokens.len && tokens[i + 1].token_type == TokenType.Text;
            if tag.strip_left && has_prev { _strip_end(input, tokens[i - 1]); }
            if tag.strip_right && has_next { _strip_start(input, tokens[i + 1]); }
            if _standalone_kind(input, tag) && _prev_blank(input, tokens, i) && _next_blank(input, tokens, i) {
                if has_prev { _strip_indent(input, tokens[i - 1]); }
                if has_next { _strip_line_end(input, tokens[i + 1]); }
            }
        }
        i += 1;
    }
}


const WORDS = regex::compile("(?:true|false|null|undefined)");

const INVALID_IDENTIFIER_CHARS: u8[27] = ['!', '"', '#', '%', '&','\'', '(', ')', '*', 
                                          '+', ',', '.', '/', ';', '<', '=', '>', '@', 
                                          '[', '\\', ']', '^', '`', '{', '|', '}', '~'];

fn keyword_past_start(path: const u8[:]) -> bool {
    regex::each_match(WORDS, path) { start, end =>
        if start != 0 { return true; }
    };
    return false;
}

// The navigation step at the start of path: how many bytes it takes, and
// whether it climbs to the parent frame. ../ and .. climb; ./, ., this,
// this. and this/ stay on the current frame. Zero bytes when path starts
// with a field name instead.
fn _navigation_step(path: const u8[:]) -> i64, bool {
    if starts_with(path, "../") { return 3, true; }
    if path == ".." { return 2, true; }
    if starts_with(path, "./") { return 2, false; }
    if path == "." { return 1, false; }
    if starts_with(path, "this.") || starts_with(path, "this/") { return 5, false; }
    if path == "this" { return 4, false; }
    return 0, false;
}

// Drops the leading navigation steps (see _navigation_step). What remains
// is the field path the identifier check sees. ../name is parent then
// name, not a name that contains '/'.
fn _strip_navigation(path: const u8[:]) -> const u8[:] {
    var rest = path;
    loop {
        let taken, climbs = _navigation_step(rest);
        if taken == 0 { break; }
        rest = rest[taken..];
    }
    return rest;
}

// The data variables {{#each}} sets, written @index, @key, @first, @last.
const DATA_NAMES = ["index", "key", "first", "last"];

// Splits a data path, @ then any number of ../ then a name, into how many
// enclosing each blocks it climbs and the name: @../index is 1 and
// "index". Not a data path: -1 and "".
fn _data_parts(path: const u8[:]) -> i64, const u8[:] {
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
fn _is_data_path(path: const u8[:]) -> bool {
    let depth, name = _data_parts(path);
    guard depth >= 0 else { return false; }
    for known in DATA_NAMES {
        if name == known { return true; }
    }
    return false;
}

// Validates path to avoid traversing invalid paths.
// The paths pass https://handlebarsjs.com/guide/expressions.html
fn _validate_path(path: const u8[:]) -> bool, u8[:] {
    guard path.len > 0 else { return false, "Has 0 length"; }
    if starts_with(path, "@") {
        guard _is_data_path(path) else { return false, "Unknown data variable: only @index, @key, @first and @last, after any ../"; }
        return true, "";
    }
    let body = _strip_navigation(path);
    if body.len == 0 || body == "." || body == ".." { return true, ""; }
    guard !keyword_past_start(body) else {
        return false, "true, false, null, or undefined allowed only at the beginning of the path";
    };
    var escape_open = false;
    var index: i64 = 0;

    let parts = split(body, '.');
    
    for part in parts {
        // part is a escaped []. Just checks it is ending with ]
        if starts_with(part, "[") {
            guard ends_with(part, "]") else { return false, "Invalid characted in segment"; }
            continue;
        }
        // not a escaped, let's check it is a valid identifier  
        var index = 0;
        while index < part.len {
            guard !INVALID_IDENTIFIER_CHARS.contains(part[index]) else { return false, "Invalid characted in segment"; }
            index += 1;
        }
    }

    return true, "";
}

// Splits a template into Text, Expression, Comment and raw block tokens,
// then applies whitespace control. An empty template returns no tokens and
// "Must not be empty". The scan's position is only ever moved here: past a byte of text,
// or to the end _scan_tag reports for a tag, so a tag jammed against the
// next one (}}{{) is still a tag. Text after the last tag is flushed.
//
// As in handlebars.js, \{{ escapes a mustache: the backslash is dropped,
// and the text from "{{" to the next mustache is written as it is. \\{{
// writes one backslash, and the mustache after it is a mustache.
fn _tokenize(input: const u8[:]) -> Token[>..], const u8[:] {
    guard input.len > 0 else { return [], "Must not be empty"; }

    let tokens: Token[>..] = [];
    var text_start: i64 = 0;
    var at: i64 = 0;
    while at + 1 < input.len {
        if input[at] == '{' && input[at + 1] == '{' {
            let slashes = _backslashes_before(input, text_start, at);
            if slashes == 1 {
                _push_text(tokens, text_start, at - 1);
                let end = _escaped_end(input, at);
                _push_text(tokens, at, end);
                at = end;
                text_start = at;
                continue;
            }
            if slashes >= 2 {
                // Drop the backslash that escaped the other.
                _push_text(tokens, text_start, at - 1);
                text_start = at;
            }
            if starts_with(input[at..], "{{{{") {
                _push_text(tokens, text_start, at);
                let end, raw_err = _scan_raw_block(input, at, tokens);
                guard raw_err.len == 0 else { return [], raw_err; }
                at = end;
                text_start = at;
                continue;
            }
            let tag, err = _scan_tag(input, at);
            guard err.len == 0 else { return [], err; }
            _push_text(tokens, text_start, at);
            tokens.push(tag);
            at = tag.outer_end;
            text_start = at;
        } else {
            at += 1;
        }
    }
    _push_text(tokens, text_start, input.len);
    _control_whitespace(input, tokens);
    return tokens, "";
}

// What {{...}} writes for these bytes. {{{...}} skips this. '&' is first
// and the value is scanned once, so a replacement is not escaped again.
// The pairs are Handlebars': & < > " ' ` =
const HTML_CHARS: u8[7] = ['&', '<', '>', '\"', '\'', '`', '='];
const HTML_ESCAPED = [
    "&amp;",
    "&lt;",
    "&gt;",
    "&quot;",
    "&#x27;",
    "&#x60;",
    "&#x3D;",
];

fn _append_html_escaped(out: u8[>..]&, text: const u8[:]) {
    var i: i64 = 0;
    while i < text.len {
        let at = position(HTML_CHARS, text[i]);
        if at >= 0 {
            out.append(HTML_ESCAPED[at]);
        } else {
            out.push(text[i]);
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Compiled templates.

// The index of no node: a link that leads nowhere, and the opener of the
// top level.
const NONE: i64 = -1;

// A range of Engine.text.
struct Span { start: i64, len: i64 }

// A run of Engine.args: the count arguments from index first on.
struct Range { first: i64, count: i64 }

// Expression is a {{path}}; Call is a {{helper args...}}, a mustache with
// arguments, whose helper is the user's (see Helpers below).
enum NodeKind { Text, Expression, Call, Block }

// One node of a compiled template. value is the text of a Text node, the
// path of an Expression, or the helper name of a Call or a Block ("with",
// "if"). The arguments of a Call or a Block are parsed once, at compile
// time, into Engine.args: params are its positional arguments, hash its
// key=value ones; both are empty for the other kinds. next, body and
// inverse are indices into Engine.nodes, NONE for none; only a Block has a
// body, and an inverse, the chain after its {{else}}.
// escaped is the {{...}} / {{{...}}} flag of an Expression or a Call.
// block_params is how many block parameters a Block declares, 2 for
// {{#each items as |item i|}}, and param_ref says whether an Expression's
// path starts with one (see ParamRef). helper_first marks an Expression
// that is a bare name, {{name}}: a helper of that name, if the helpers
// have one, wins over the field (see _may_be_helper).
struct Node {
    kind: NodeKind,
    value: Span,
    escaped: bool,
    params: Range,
    hash: Range,
    next: i64,
    body: i64,
    inverse: i64,
    block_params: i64,
    param_ref: ParamRef,
    helper_first: bool,
}

// Where the block parameter a path starts with comes from, found at
// compile time from where the path is written: up counts the blocks with
// block parameters between the path and the one that declares it (0 for
// the innermost), and slot is its position in as |...|. A path that does
// not start with one has up NONE. {{#each groups as |g|}}{{#each g.items
// as |it|}}{{g.name}} gives g.name up 1 and slot 0.
struct ParamRef { up: i64, slot: i64 }

// A path that is looked up in the context, not a block parameter.
fn _no_param_ref() -> ParamRef {
    return ParamRef { up: NONE, slot: NONE };
}

// What a helper argument is. A path is looked up when rendering. A Call is
// a subexpression, (helper args...): its helper name and its own params and
// hash, Ranges of Engine.args, so subexpressions nest. The other kinds are
// literals: an Int is a number with neither fraction nor exponent, any other
// number is a Number, and a string's text is between its quotes, unescaped.
// A path's param_ref is that of an Expression node.
enum ArgValue {
    Path { path: Span, param_ref: ParamRef },
    Call { name: Span, params: Range, hash: Range },
    Int { v: i64 },
    Number { v: f64 },
    Bool { v: bool },
    String { text: Span },
    Null,
}

// One helper argument: positional when key is empty, otherwise the hash
// argument key=value.
struct Arg { key: Span, value: ArgValue }

// The argument at position i of range, counting from 0.
fn _arg_at(args: const Arg[:], range: Range, i: i64) -> Arg {
    return args[range.first + i];
}

// A compiled template: a value that owns everything it needs, with no
// references into anything else. It can be returned, kept in a local, a
// global or a struct (an HTTP handler's state, say), passed by reference,
// and copied with copy(). It holds only what compiling produced, never
// render state: each render converts its context into a document of its own.
//
// Every field is a T[]: an array whose length is chosen at construction.
// Those are variable-class, and a struct may hold any number of them
// (spec §3.4), where it may hold only one growable T[>..]. _compile builds
// the parts in growable locals and copies them in once, the template text
// included.
//
// - nodes: the parsed template, linked by index;
// - roots: the top-level chains, each walked on the root context;
// - args: the arguments of every call, which each Call or Block, and each
//   subexpression, views as Ranges;
// - names: every field name the template's paths use; conversion skips the
//   other fields;
// - text: a copy of the template, which every node's value, the args and
//   the names view as Spans;
// - error: empty when the template compiled. render and the other entry
//   points return it instead of rendering.
struct Engine {
    nodes: Node[],
    roots: i64[],
    args: Arg[],
    names: Span[],
    text: u8[],
    error: u8[],
}

// The text a span views.
fn _span_text(text: const u8[:], span: Span) -> const u8[:] {
    return text[span.start..span.start + span.len];
}

// ---------------------------------------------------------------------------
// Parsing.
//
// The parser builds the compiled template directly: one Node per text,
// expression or block, pushed onto a growable array in template order and
// linked by index (NONE for none). A node's value is a Span of the template,
// which the Engine keeps a copy of, so nothing is copied per node.
//
// While parsing, each open block remembers the index of its last node. A new
// node goes after that node (nodes[last].next), or, in a block that is still
// empty, becomes the block's first node (nodes[opener].body, or
// nodes[opener].inverse after its {{else}}). At the top level every node is
// a root of its own.

// A block being filled: the {{#helper}} node that opened it (NONE for the
// top level), its last node so far (NONE while it is empty), whether
// {{else}} has moved it on to its inverse, and whether an {{else helper}}
// chained it onto the block before it, so that block's closing tag closes
// it too. names are the block parameters it declares, as |a b|: a run of
// the parser's list of names.
struct OpenBlock { opener: i64, last: i64, in_inverse: bool, chained: bool, names: Range }

// The top level, or a block that {{#helper}} opened, declaring names.
fn _open_block(opener: i64, names: Range) -> OpenBlock {
    return OpenBlock { opener: opener, last: NONE, in_inverse: false, chained: false, names: names };
}

// The position in open of the block that started the innermost chain:
// {{#if a}} for {{#if a}}...{{else if b}}...{{else each c}}. The innermost
// block itself when nothing is chained onto it.
fn _chain_start(open: const OpenBlock[>..<]&) -> i64 {
    var at = open.len - 1;
    while open[at].chained { at -= 1; }
    return at;
}

// The block that new nodes go into: the last one opened.
fn _innermost(open: OpenBlock[>..<]&) -> OpenBlock& {
    return open[open.len - 1];
}

// Whether the innermost open block was opened by {{#helper ...}}, so a
// closing tag such as {{/with}} only closes the block its opener started.
// For a chain, {{#if a}}...{{else with b}}...{{/if}}, that is the block
// that started it. False at the top level, where no block is open.
fn _innermost_is(source: const u8[:], nodes: const Node[>..]&, open: const OpenBlock[>..<]&, helper: const u8[:]) -> bool {
    let opener = open[_chain_start(open)].opener;
    guard opener != NONE else { return false; }
    return _span_text(source, nodes[opener].value) == helper;
}

// Pushes node and links it into the innermost open block. Returns its index.
fn _add(nodes: Node[>..]&, roots: i64[>..]&, open: OpenBlock[>..<]&, node: Node) -> i64 {
    let index = nodes.len;
    nodes.push(node);
    let inner .= _innermost(open);
    if inner.opener == NONE {
        roots.push(index);
    } else if inner.last != NONE {
        nodes[inner.last].next = index;
    } else if inner.in_inverse {
        nodes[inner.opener].inverse = index;
    } else {
        nodes[inner.opener].body = index;
    }
    inner.last = index;
    return index;
}

// A node with no links and no arguments yet.
fn _node(kind: NodeKind, start: i64, end: i64, escaped: bool) -> Node {
    let none = Range { first: 0, count: 0 };
    return Node {
        kind: kind,
        value: Span { start: start, len: end - start },
        escaped: escaped,
        params: none,
        hash: none,
        next: NONE,
        body: NONE,
        inverse: NONE,
        block_params: 0,
        param_ref: _no_param_ref(),
        helper_first: false,
    };
}

// A compile error found while parsing a call: its message, and the template
// text it is about, possibly empty. It is two slices rather than one built
// string because the call parser is recursive (subexpressions nest) and may
// hold no growable value across its recursive calls (spec §7.8).
// _error_text joins them once parsing has stopped.
struct CallError { message: const u8[:], text: const u8[:] }

fn _no_error() -> CallError {
    return CallError { message: "", text: "" };
}

fn _is_ok(err: CallError) -> bool {
    return err.message.len == 0;
}

fn _error_text(err: CallError) -> u8[>..] {
    return str(err.message, err.text);
}

// The index of the first non-whitespace byte from source[p] on, or end.
fn _skip_space(source: const u8[:], p: i64, end: i64) -> i64 {
    var at = p;
    while at < end && _is_space(source[at]) { at += 1; }
    return at;
}

// Where the argument starting at source[at] ends: at the next whitespace
// outside parentheses, or at end. A quoted string ("..." or '...') and a
// subexpression, (helper args...), are stepped over whole, spaces and all; a
// subexpression may hold strings and other subexpressions. The second result
// is the start of an error message, empty when the argument closes: a quote
// or a '(' that never closes, or a ')' that closes nothing.
fn _arg_end(source: const u8[:], at: i64, end: i64) -> i64, const u8[:] {
    var p = at;
    var depth: i64 = 0;
    while p < end && (depth > 0 || !_is_space(source[p])) {
        let c = source[p];
        if c == '"' || c == '\'' {
            p += 1;
            while p < end && source[p] != c { p += 1; }
            guard p < end else { return p, "unclosed string: "; }
        } else if c == '(' {
            depth += 1;
        } else if c == ')' {
            guard depth > 0 else { return p, "unexpected ): "; }
            depth -= 1;
        }
        p += 1;
    }
    guard depth == 0 else { return p, "unclosed subexpression: "; }
    return p, "";
}

// How many arguments source[p..end] holds, or the error of the first one
// that does not close.
fn _count_args(source: const u8[:], p: i64, end: i64) -> i64, CallError {
    var count: i64 = 0;
    var at = _skip_space(source, p, end);
    while at < end {
        let stop, why = _arg_end(source, at, end);
        guard why.len == 0 else { return count, CallError { message: why, text: source[at..end] }; }
        count += 1;
        at = _skip_space(source, stop, end);
    }
    return count, _no_error();
}

// Takes count slots at the end of args, Null until the parser fills them.
fn _reserve_args(args: Arg[>..]&, count: i64) {
    var taken: i64 = 0;
    while taken < count {
        args.push(Arg { key: Span { start: 0, len: 0 }, value: ArgValue.Null });
        taken += 1;
    }
}

// Where the key of a hash argument source[at..stop] (key=value) ends: the
// index of its '='. -1 when it is positional. A path never holds '=', and a
// quoted string or a subexpression is never a key.
fn _hash_key_end(source: const u8[:], at: i64, stop: i64) -> i64 {
    var p = at;
    while p < stop {
        let c = source[p];
        if c == '=' { return p; }
        if c == '"' || c == '\'' || c == '(' { return -1; }
        p += 1;
    }
    return -1;
}

// A helper name, that of a call (the whole call's text) or a subexpression,
// must be there and read as a path would.
fn _check_helper_name(name: const u8[:], call: const u8[:]) -> CallError {
    guard name.len > 0 else { return CallError { message: "missing helper name: ", text: call }; }
    let is_valid_path, why = _validate_path(name);
    guard is_valid_path else { return CallError { message: why, text: "" }; }
    return _no_error();
}

// Whether the trimmed body of a mustache calls a helper with arguments,
// {{helper args}}, rather than naming a path, which never holds whitespace.
fn _has_arguments(word: const u8[:]) -> bool {
    for c in word {
        if _is_space(c) { return true; }
    }
    return false;
}

// Reads one argument, source[start..stop]: a subexpression, a quoted
// string, a number, true / false, null / undefined, or else a path,
// validated as any other. A subexpression's own arguments go onto args.
recursive fn _arg_value(source: const u8[:], start: i64, stop: i64, args: Arg[>..]&) -> ArgValue, CallError {
    let text = source[start..stop];
    guard text.len > 0 else { return ArgValue.Null, CallError { message: "missing argument value", text: "" }; }
    let first = text[0];
    if first == '(' {
        guard text[text.len - 1] == ')' else { return ArgValue.Null, CallError { message: "text after subexpression: ", text: text }; }
        let name, params, hash, err = _parse_call(source, start + 1, stop - 1, args);
        guard _is_ok(err) else { return ArgValue.Null, err; }
        let name_err = _check_helper_name(_span_text(source, name), text);
        guard _is_ok(name_err) else { return ArgValue.Null, name_err; }
        return ArgValue.Call { name: name, params: params, hash: hash }, _no_error();
    }
    if first == '"' || first == '\'' {
        guard text.len >= 2 && text[text.len - 1] == first else { return ArgValue.Null, CallError { message: "unclosed string: ", text: text }; }
        return ArgValue.String { text: Span { start: start + 1, len: text.len - 2 } }, _no_error();
    }
    if text == "true" { return ArgValue.Bool { v: true }, _no_error(); }
    if text == "false" { return ArgValue.Bool { v: false }, _no_error(); }
    if text == "null" || text == "undefined" { return ArgValue.Null, _no_error(); }
    let number = json::scan_number(text, 0);
    if number.end == text.len {
        if number.is_int { return ArgValue.Int { v: number.int }, _no_error(); }
        return ArgValue.Number { v: number.value }, _no_error();
    }
    let is_valid_path, why = _validate_path(text);
    guard is_valid_path else { return ArgValue.Null, CallError { message: why, text: "" }; }
    return ArgValue.Path { path: Span { start: start, len: text.len }, param_ref: _no_param_ref() }, _no_error();
}

// Parses a helper call, source[start..end], into the helper name, the
// params and the hash. It is the body of a block tag after its '#', of a
// mustache with arguments, or of a subexpression inside its parentheses.
// A call's arguments sit in one run of args, params first, which its two
// Ranges view; a subexpression among them puts its own run after that one.
// So the run is taken, Null, as soon as the arguments are counted, and each
// slot is filled as its argument is read.
recursive fn _parse_call(source: const u8[:], start: i64, end: i64, args: Arg[>..]&) -> Span, Range, Range, CallError {
    let name_start = _skip_space(source, start, end);
    var p = name_start;
    while p < end && !_is_space(source[p]) { p += 1; }
    let helper = Span { start: name_start, len: p - name_start };
    var params = Range { first: args.len, count: 0 };
    var hash = Range { first: args.len, count: 0 };
    let count, count_err = _count_args(source, p, end);
    guard _is_ok(count_err) else { return helper, params, hash, count_err; }
    _reserve_args(args, count);
    loop {
        p = _skip_space(source, p, end);
        if p >= end { break; }
        // _count_args has seen every argument close.
        let stop, unclosed = _arg_end(source, p, end);
        let slot = params.first + params.count + hash.count;
        let key_end = _hash_key_end(source, p, stop);
        if key_end >= 0 {
            let value, err = _arg_value(source, key_end + 1, stop, args);
            guard _is_ok(err) else { return helper, params, hash, err; }
            args[slot] = Arg { key: Span { start: p, len: key_end - p }, value: value };
            hash.count += 1;
        } else {
            guard hash.count == 0 else { return helper, params, hash, CallError { message: "positional argument after hash arguments: ", text: source[p..stop] }; }
            let value, err = _arg_value(source, p, stop, args);
            guard _is_ok(err) else { return helper, params, hash, err; }
            args[slot] = Arg { key: Span { start: p, len: 0 }, value: value };
            params.count += 1;
        }
        p = stop;
    }
    hash.first = params.first + params.count;
    return helper, params, hash, _no_error();
}

// Whether arg is the literal true or false.
fn _is_bool_literal(arg: Arg) -> bool {
    match arg.value {
        Bool => { return true; },
        _ => { return false; },
    }
}

// What compiling needs to know beyond the template: the names of the
// user's block helpers, which get_engine and load_engine read from their
// registrations (see Block helpers below), as handlebars.js's
// knownHelpers. A block whose helper is neither built in nor listed is a
// compile error.
struct Config { block_helpers: (const u8[:])[] }

// Whether config lists helper as a user block helper.
fn _is_user_block(config: const Config&, helper: const u8[:]) -> bool {
    for known in config.block_helpers {
        if known == helper { return true; }
    }
    return false;
}

// Checks a block's call against what its helper takes: with and each
// exactly one param and no hash; if and unless exactly one param and at
// most includeZero=true or false. A user block helper takes anything. Any
// other helper is unknown. Returns the error, empty when the call holds.
fn _check_call(source: const u8[:], helper: const u8[:], params: Range, hash: Range, args: const Arg[>..]&, config: const Config&) -> u8[>..] {
    if helper == "with" || helper == "each" {
        guard params.count == 1 else { return str("#", helper, " takes exactly one argument"); }
        guard hash.count == 0 else { return str("#", helper, " takes no hash arguments"); }
        return [];
    }
    if helper == "if" || helper == "unless" {
        guard params.count == 1 else { return str("#", helper, " takes exactly one argument"); }
        for i in hash.count {
            let arg = _arg_at(args, hash, i);
            let key = _span_text(source, arg.key);
            guard key == "includeZero" else { return str("#", helper, ": unknown hash argument ", key); }
            guard _is_bool_literal(arg) else { return str("#", helper, ": includeZero must be true or false"); }
        }
        return [];
    }
    guard _is_user_block(config, helper) else { return str("unknown block helper #", helper); }
    return [];
}

// ---------------------------------------------------------------------------
// Block parameters: {{#each items as |item i|}}.
//
// A path whose first segment names a block parameter, item.name, is tied to
// the block that declares it when it is parsed: the innermost enclosing
// block, in its body, that declares that name (see ParamRef). Nothing about
// it is looked up by name when rendering.

// Where the block parameters of a block call source[start..stop] begin: the
// index of the "as" of a trailing as |a b|. NONE when the call has none.
fn _block_params_at(source: const u8[:], start: i64, stop: i64) -> i64 {
    var end = stop;
    while end > start && _is_space(source[end - 1]) { end -= 1; }
    guard end > start && source[end - 1] == '|' else { return NONE; }
    var bar = end - 2;
    while bar >= start && source[bar] != '|' { bar -= 1; }
    guard bar >= start else { return NONE; }
    var before = bar;
    while before > start && _is_space(source[before - 1]) { before -= 1; }
    let as_at = before - 2;
    guard as_at > start && source[as_at..before] == "as" && _is_space(source[as_at - 1]) else { return NONE; }
    return as_at;
}

// Whether name can be a block parameter: a plain identifier, no dots.
fn _is_param_name(name: const u8[:]) -> bool {
    guard name.len > 0 else { return false; }
    for c in name {
        if INVALID_IDENTIFIER_CHARS.contains(c) { return false; }
    }
    return true;
}

// Reads the names of as |a b| at source[as_at..stop] onto names. Returns
// their run, or an error such as "invalid block parameter name: a.b".
fn _parse_param_names(source: const u8[:], as_at: i64, stop: i64, names: Span[>..]&) -> Range, u8[>..] {
    var run = Range { first: names.len, count: 0 };
    var p = as_at + 2;
    while source[p] != '|' { p += 1; }
    p += 1;
    loop {
        p = _skip_space(source, p, stop);
        if source[p] == '|' { break; }
        var end = p;
        while !_is_space(source[end]) && source[end] != '|' { end += 1; }
        let name = source[p..end];
        guard _is_param_name(name) else { return run, str("invalid block parameter name: ", name); }
        names.push(Span { start: p, len: end - p });
        run.count += 1;
        p = end;
    }
    guard run.count > 0 else { return run, str("missing block parameter names: ", source[as_at..stop]); }
    return run, [];
}

// The position of name among the names of run, or NONE.
fn _slot_of(source: const u8[:], names: const Span[>..]&, run: Range, name: const u8[:]) -> i64 {
    for i in run.count {
        if _span_text(source, names[run.first + i]) == name { return i; }
    }
    return NONE;
}

// The block parameter path starts with, as seen from inside the open
// blocks. A path that starts with ../, ./ or this, or a data variable, is
// never one, as in handlebars.js. A block walking its inverse has no
// parameters there.
fn _param_ref(source: const u8[:], path: const u8[:], open: const OpenBlock[>..<]&, names: const Span[>..]&) -> ParamRef {
    let taken, climbs = _navigation_step(path);
    guard taken == 0 && !starts_with(path, "@") else { return _no_param_ref(); }
    let dot = find(path, ".");
    let head = if dot >= 0 { path[..dot] } else { path };
    var up: i64 = 0;
    var at = open.len - 1;
    while at > 0 {
        let candidate = open[at];
        if candidate.names.count > 0 && !candidate.in_inverse {
            let slot = _slot_of(source, names, candidate.names, head);
            if slot != NONE { return ParamRef { up: up, slot: slot }; }
            up += 1;
        }
        at -= 1;
    }
    return _no_param_ref();
}

// Ties every path among args[from..] to its block parameter, if any: the
// arguments of the call just parsed, its subexpressions' included.
fn _bind_arg_paths(source: const u8[:], args: Arg[>..]&, from: i64, open: const OpenBlock[>..<]&, names: const Span[>..]&) {
    var i = from;
    while i < args.len {
        match args[i].value {
            Path p => {
                let param_ref = _param_ref(source, _span_text(source, p.path), open, names);
                args[i].value = ArgValue.Path { path: p.path, param_ref: param_ref };
            },
            _ => {},
        }
        i += 1;
    }
}

// The helpers whose blocks take block parameters: each, with, and the
// user's block helpers. if and unless walk no new context to name.
fn _takes_block_params(helper: const u8[:]) -> bool {
    return helper != "if" && helper != "unless";
}

// Parses the block call in source[start..stop], "with person" for
// {{#with person}}, checks it, and adds its Block node to the innermost open
// block. Returns the node's index and the run of block parameter names it
// declares, or an error.
fn _parse_block(source: const u8[:], start: i64, stop: i64, nodes: Node[>..]&, roots: i64[>..]&, open: OpenBlock[>..<]&, args: Arg[>..]&, names: Span[>..]&, config: const Config&) -> i64, Range, u8[>..] {
    let as_at = _block_params_at(source, start, stop);
    let call_stop = if as_at == NONE { stop } else { as_at };
    let mark = args.len;
    var declared = Range { first: names.len, count: 0 };
    let helper, params, hash, err = _parse_call(source, start, call_stop, args);
    guard _is_ok(err) else { return NONE, declared, _error_text(err); }
    let name = _span_text(source, helper);
    let call_err = _check_call(source, name, params, hash, args, config);
    guard call_err.len == 0 else { return NONE, declared, call_err; }
    _bind_arg_paths(source, args, mark, open, names);
    if as_at != NONE {
        guard _takes_block_params(name) else { return NONE, declared, str("#", name, " takes no block parameters"); }
        let run, names_err = _parse_param_names(source, as_at, stop, names);
        guard names_err.len == 0 else { return NONE, declared, names_err; }
        declared = run;
    }
    var node = _node(NodeKind.Block, helper.start, helper.start + helper.len, false);
    node.params = params;
    node.hash = hash;
    node.block_params = declared.count;
    return _add(nodes, roots, open, node), declared, [];
}

// Whether the mustache {{path}} may call a helper instead: when path is
// one plain name, as handlebars.js decides. ./name, this.name, ../name,
// dotted paths, data variables and block parameters are always paths.
fn _may_be_helper(path: const u8[:], param_ref: ParamRef) -> bool {
    guard param_ref.up == NONE && path != "this" else { return false; }
    for c in path {
        if c == '.' || c == '/' || c == '@' || c == '[' { return false; }
    }
    return true;
}

// Turns tokens into nodes, roots and args. Text becomes a Text node, unless
// whitespace control emptied it; comments are dropped. {{#helper args}}
// adds a Block node with its arguments and opens its block; {{/helper}}
// closes the innermost block, which helper must have opened, and {{else}}
// starts its inverse. A block still open at the end is an error. A {{...}} or
// {{{...}}} with arguments, {{helper args}}, is a Call node; any other is a
// field lookup, already trimmed. escaped says whether what either writes is
// HTML-escaped. Returns the error text, empty
// when the parse holds.

fn _parse(source: const u8[:], tokens: const Token[:], nodes: Node[>..]&, roots: i64[>..]&, args: Arg[>..]&, config: const Config&) -> u8[>..] {
    let open: OpenBlock[>..<] = [];
    let names: Span[>..] = [];
    open.push(_open_block(NONE, Range { first: 0, count: 0 }));
    for token in tokens {
        match token.token_type {
            Comment => {},
            RawOpen => {
                let opener, declared, err = _parse_block(source, token.start, token.end, nodes, roots, open, args, names, config);
                guard err.len == 0 else { return err; }
                open.push(_open_block(opener, declared));
            },
            RawClose => {
                let helper = source[token.start..token.end];
                guard _innermost_is(source, nodes, open, helper) else { return str("unexpected /", helper); }
                open.resize(_chain_start(open));
            },
            Text => {
                if token.end > token.start {
                    _add(nodes, roots, open, _node(NodeKind.Text, token.start, token.end, false));
                }
            },
            Expression => {
                let word = source[token.start..token.end];
                if word == "else" {
                    let inner .= _innermost(open);
                    guard inner.opener != NONE && !inner.in_inverse else { return str("unexpected else"); }
                    inner.in_inverse = true;
                    inner.last = NONE;
                } else if _is_else_chain(word) {
                    // {{else helper args}}: the inverse holds one block,
                    // helper, which takes the rest up to the closing tag.
                    let inner .= _innermost(open);
                    guard inner.opener != NONE && !inner.in_inverse else { return str("unexpected else"); }
                    inner.in_inverse = true;
                    inner.last = NONE;
                    let opener, declared, err = _parse_block(source, token.start + 4, token.end, nodes, roots, open, args, names, config);
                    guard err.len == 0 else { return err; }
                    var chained = _open_block(opener, declared);
                    chained.chained = true;
                    open.push(chained);
                } else if starts_with(word, "/") {
                    let helper = trim(word[1..]);
                    guard _innermost_is(source, nodes, open, helper) else { return str("unexpected /", helper); }
                    open.resize(_chain_start(open));
                } else if starts_with(word, "#") {
                    let opener, declared, err = _parse_block(source, token.start + 1, token.end, nodes, roots, open, args, names, config);
                    guard err.len == 0 else { return err; }
                    open.push(_open_block(opener, declared));
                } else if _has_arguments(word) {
                    let mark = args.len;
                    let helper, params, hash, err = _parse_call(source, token.start, token.end, args);
                    guard _is_ok(err) else { return _error_text(err); }
                    let name_err = _check_helper_name(_span_text(source, helper), word);
                    guard _is_ok(name_err) else { return _error_text(name_err); }
                    _bind_arg_paths(source, args, mark, open, names);
                    var node = _node(NodeKind.Call, helper.start, helper.start + helper.len, token.escaped);
                    node.params = params;
                    node.hash = hash;
                    _add(nodes, roots, open, node);
                } else {
                    let is_valid_path, why = _validate_path(word);
                    guard is_valid_path else { return str(why); }
                    var node = _node(NodeKind.Expression, token.start, token.end, token.escaped);
                    node.param_ref = _param_ref(source, word, open, names);
                    node.helper_first = _may_be_helper(word, node.param_ref);
                    _add(nodes, roots, open, node);
                }
            },
        }
    }
    let unclosed = open[_chain_start(open)].opener;
    guard unclosed == NONE else { return str("unclosed #", _span_text(source, nodes[unclosed].value)); }
    return [];
}

// Whether names, spans of text, holds name.
fn _has_name(names: const Span[:], text: const u8[:], name: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < names.len {
        let s = names[i];
        if text[s.start..s.start + s.len] == name { return true; }
        i += 1;
    }
    return false;
}

// Adds the field names of the path at span: its dotted segments after the
// leading ../ and ./ navigation.
fn _add_path_names(names: Span[>..]&, text: const u8[:], span: Span) {
    let path = text[span.start..span.start + span.len];
    guard !_is_data_path(path) else { return; }
    let body = _strip_navigation(path);
    var at = span.start + path.len - body.len;
    let end = span.start + span.len;
    while at < end {
        var stop = at;
        while stop < end && text[stop] != '.' { stop += 1; }
        let head = text[at..stop];
        if head.len > 0 && head != ".." && !_has_name(names, text, head) {
            names.push(Span { start: at, len: stop - at });
        }
        at = stop + 1;
    }
}

// Adds the key of a lookup call, (lookup target "key"), when it is a
// string literal: it names a field as a path would. A key that is a path
// or a subexpression is known only when rendering, and names nothing.
fn _add_lookup_key_name(names: Span[>..]&, text: const u8[:], args: const Arg[>..]&, helper: Span, params: Range) {
    guard _span_text(text, helper) == "lookup" && params.count == 2 else { return; }
    match _arg_at(args, params, 1).value {
        String key => {
            if !_has_name(names, text, _span_text(text, key.text)) { names.push(key.text); }
        },
        _ => {},
    }
}

// An Engine that only carries error.
fn _failed(error: const u8[:]) -> Engine {
    return Engine { nodes: [], roots: [], args: [], names: [], text: [], error: error };
}

// Tokenizes, parses and validates template, and returns the Engine for it.
// prefix starts the error text, if any.
fn _compile(template: const u8[:], prefix: const u8[:], config: const Config&) -> Engine {
    let tokens, err = _tokenize(template);
    guard err.len == 0 else { return _failed(str(prefix, err)); }
    let nodes: Node[>..] = [];
    let roots: i64[>..] = [];
    let args: Arg[>..] = [];
    let parse_err = _parse(template, tokens, nodes, roots, args, config);
    guard parse_err.len == 0 else { return _failed(str(prefix, parse_err)); }

    // The paths are those of the expressions and those among the
    // arguments, which hold every call's, subexpressions included. A
    // lookup's literal key names a field too.
    let names: Span[>..] = [];
    for node in nodes {
        match node.kind {
            Expression => { _add_path_names(names, template, node.value); },
            Call => { _add_lookup_key_name(names, template, args, node.value, node.params); },
            _ => {},
        }
    }
    for arg in args {
        match arg.value {
            Path p => { _add_path_names(names, template, p.path); },
            Call c => { _add_lookup_key_name(names, template, args, c.name, c.params); },
            _ => {},
        }
    }
    return Engine { nodes: nodes, roots: roots, args: args, names: names, text: template, error: "" };
}

// Compiles template text into an Engine. On a malformed template the Engine
// carries the error, such as "unexpected /with", and renders nothing. The
// Engine copies what it needs: template may go away afterwards. A template
// with this engine opens only the built-in blocks.
fn get_engine(template: const u8[:]) -> Engine {
    return get_engine(template, _no_block_helpers);
}

// get_engine with the user's block helpers G: the blocks G registers with
// block_helper, {{#list items}} say, are the ones a template may open
// besides the built-in ones.
fn get_engine<G>(template: const u8[:]) -> Engine {
    let names: u8[>..] = [];
    _registered_blocks(names, G);
    let config = Config { block_helpers: words(names) };
    return _compile(template, "", config);
}

// Reads the template file at path and compiles it into an Engine. The
// error, if any, is "cannot read template <path>" or "<path>: <parse error>".
fn load_engine(path: const u8[:]) -> Engine {
    return load_engine(path, _no_block_helpers);
}

// load_engine with the user's block helpers G, as get_engine.
fn load_engine<G>(path: const u8[:]) -> Engine {
    let source: u8[>..] = [];
    guard read_file(path, source) else { return _failed(str("cannot read template ", path)); }
    let names: u8[>..] = [];
    _registered_blocks(names, G);
    let config = Config { block_helpers: words(names) };
    return _compile(source, str(path, ": "), config);
}

// The field names engine's paths use, as slices of engine.text, for the
// conversions below.
fn _name_slices(engine: const Engine&, names: const u8[:][>..]&) {
    var i: i64 = 0;
    while i < engine.names.len {
        let s = engine.names[i];
        names.push(engine.text[s.start..s.start + s.len]);
        i += 1;
    }
}

// Whether names holds name. The set is small, one entry per distinct
// segment in the template, so a scan is enough.
fn _wanted(names: const u8[:][>..]&, name: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < names.len {
        if names[i] == name { return true; }
        i += 1;
    }
    return false;
}
// ---------------------------------------------------------------------------
// The context.
//
// Rendering reads one data model, stdlib json's: a document is a pool of
// json::Node in document order, each with a key, a value, and links to its
// first child and next sibling. A JSON context is json::parse's document as
// it is. A typed context is turned into the same kind of document below,
// node by node, with only the fields the template uses.

// Appends a node with no links yet and returns its index.
fn _push_node(doc: json::Node[>..]&, key: const u8[:], val: json::Value) -> i64 {
    doc.push(json::Node { next: null, first: null, key: key, val: val });
    return doc.len - 1;
}

// The children of a container node being built: the container's index, and
// its last child so far (NONE while it has none).
struct Children { parent: i64, last: i64 }

// No children yet for the container at parent.
fn _children_of(parent: i64) -> Children {
    return Children { parent: parent, last: NONE };
}

// Links child after the last of children, or as the container's first.
fn _append_child(doc: json::Node[>..]&, children: Children&, child: i64) {
    if children.last == NONE {
        doc[children.parent].first .= doc[child];
    } else {
        doc[children.last].next .= doc[child];
    }
    children.last = child;
}

// Appends the node for one value, keyed key, and its subtree, and returns
// the node's index. const for instantiates a call for every field, so each
// field type needs an overload, and rank keeps them from tying. The caller
// passes an i32:
// - scalars, text and slices take the i32 itself and win;
// - a struct takes an i64, reached by widening, and wins over an optional,
//   because a struct reference would also bind a C? parameter;
// - an optional takes an f64, the last resort, which only it reaches for an
//   optional field, since an optional does not bind a C& parameter.
fn _doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const u8[:], rank: i32) -> i64 {
    return _push_node(doc, key, json::Value.Str { s: value });
}

fn _doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const u8[>..]&, rank: i32) -> i64 {
    return _push_node(doc, key, json::Value.Str { s: value });
}

fn _doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: i64, rank: i32) -> i64 {
    return _push_node(doc, key, json::Value.Int { v: value });
}

fn _doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: f64, rank: i32) -> i64 {
    return _push_node(doc, key, json::Value.Num { v: value });
}

fn _doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: f32, rank: i32) -> i64 {
    return _push_node(doc, key, json::Value.Num { v: value });
}

fn _doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: bool, rank: i32) -> i64 {
    return _push_node(doc, key, json::Value.Bool { v: value });
}

// A slice becomes an array of its elements, converted the same way.
fn _doc_value<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const C[:], rank: i32) -> i64 {
    return _doc_list(doc, names, key, value);
}

// A struct becomes an object of the fields the template uses.
fn _doc_value<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const C&, rank: i64) -> i64 {
    return _doc_struct(doc, names, key, value);
}

// An optional is null when empty, else its value converted as a field of
// that type would be.
fn _doc_value<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: C?, rank: f64) -> i64 {
    guard value else { return _push_node(doc, key, json::Value.Null); }
    let inner_rank: i32 = 0;
    return _doc_value(doc, names, key, value, inner_rank);
}

// An array node, then each element's node and subtree, linked in order.
// Elements have no key and are never filtered; the fields of an element
// that is a struct are.
recursive fn _doc_list<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], items: const C[:]) -> i64 {
    let index = _push_node(doc, key, json::Value.Arr { count: items.len });
    var children = _children_of(index);
    let rank: i32 = 0;
    for &item in items {
        _append_child(doc, children, _doc_value(doc, names, "", item, rank));
    }
    return index;
}

// An object node, then a node and subtree for each field the template uses,
// linked in declaration order. Unused fields get no node, and their subtrees
// are never visited at run time; const for still checks the conversion of
// every field type, so the specializations are one per type reachable from
// the root.
recursive fn _doc_struct<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const C&) -> i64 {
    let index = _push_node(doc, key, json::Value.Obj { count: 0 });
    var children = _children_of(index);
    var count: i64 = 0;
    let rank: i32 = 0;
    const for <N, A> in fields<C> {
        if _wanted(names, N) {
            _append_child(doc, children, _doc_value(doc, names, N, value.A, rank));
            count += 1;
        }
    }
    doc[index].val = json::Value.Obj { count: count };
    return index;
}

// ---------------------------------------------------------------------------
// Helpers.
//
// The user's helpers are one static function value (spec §7.6), passed as
// the last argument of a render function: a named function, or a block,
// which may capture the caller's locals and so carries any state the
// helpers need. It takes the call's HelperContext, as plod's handlers take
// a request's cx, and answers the call by filling it in:
//
//     fn my_helpers(cx) {
//         gooseneck::helper(cx, "loud") { gooseneck::answer(cx, loud(cx)); };
//         gooseneck::helper(cx, "count") {
//             gooseneck::answer(cx, json::Value.Int { v: gooseneck::param_count(cx) });
//         };
//     }
//     gooseneck::render_into(engine, context, out, my_helpers);
//
// or, as a block that keeps state in a local of its caller:
//
//     var calls: i64 = 0;
//     gooseneck::render_into(engine, context, out) { cx =>
//         gooseneck::helper(cx, "next") {
//             calls += 1;
//             gooseneck::answer(cx, json::Value.Int { v: calls });
//         };
//     };
//
// Its parameter is untyped, as a plod handler's cx is. The render passes
// the context with & so that a block gets it by reference rather than a
// copy, and a function that types it as HelperContext& makes that & a
// "redundant &" warning (spec §4.1); an untyped one does not.
//
// It is called for each {{helper args}} mustache and each (helper args)
// subexpression, with the helper's name and its arguments already resolved
// in cx, and for each bare {{name}} (see _may_be_helper), with no
// arguments, before name is looked up as a field. Each helper(cx, name)
// registration runs its block when the call is to name and no registration
// before it answered; the block answers with answer(cx, value), or leaves
// the call to the registrations after it. A call nobody answers leaves a
// bare {{name}} to the field.
//
// A value is a scalar: Str, Int, Num, Bool or Null. A mustache writes it
// as it would a field's value, escaped or not; {{#if}} tests its
// truthiness; it may be an argument of another call. {{#with}} and
// {{#each}} take a path or a lookup, since a scalar is never a context.
//
// lookup is built in (see _lookup_node) and wins over a user helper of the
// same name: it finds a context node, not a scalar, which no user helper
// can give. (handlebars.js lets registerHelper replace it.) A call nobody
// answers gives Null, which writes nothing and is false. (handlebars.js
// throws "Missing helper" at render time; these renders have no error to
// return once the template compiled.) The render functions without helpers
// answer nothing.
//
// A helper's text must outlive the call, since its value may be another
// call's argument: a slice of the context, of the template, or of cx.text,
// a buffer that lives until the render ends. A helper that makes new text
// appends it there and answers with the slice it appended.

// A resolved argument: the hash key, empty for a param, and the value.
struct Resolved { key: const u8[:], value: json::Value }

// One helper call, which the user's helpers read and answer, as plod's
// handlers read and answer a request's cx:
//
// - name: the helper the template calls, which helper and block_helper
//   match;
// - params and hash: the call's arguments, resolved: a path to its context
//   value (Null when it finds nothing; an object or an array as its Obj /
//   Arr count), a literal to its value, a subexpression to its helper's
//   value. Read them with param, param_count and hash_arg. They are runs
//   of resolved, a stack that each call pushes onto and pops when done;
// - text: where a helper makes new text, alive until the render ends;
// - out: the render's output, where a block helper writes its block;
// - value and answered: the answer, which answer and block_helper fill in;
// - listing: set only while an engine asks the block helpers for their
//   names (see _registered_blocks), never in a render.
//
// The render keeps one HelperContext and fills it in for each call, and a
// block helper's call gets a copy of it, since its body makes calls of its
// own. Only references are passed down the render's recursive walk, never
// stored in a struct built there (spec §7.8), so the context is made once,
// outside the walk, and the name travels in it.
struct HelperContext {
    name: const u8[:] = "",
    resolved: const Resolved[>..<]&,
    params: Range,
    hash: Range,
    text: u8[>..]&,
    out: u8[>..]&,
    value: json::Value = json::Value.Null,
    answered: bool = false,
    listing: bool = false,
}

// The resolved argument at position i of range.
fn _resolved_at(cx: const HelperContext&, range: Range, i: i64) -> Resolved {
    return cx.resolved[range.first + i];
}

// How many positional arguments the call has.
fn param_count(cx: const HelperContext&) -> i64 {
    return cx.params.count;
}

// The positional argument at i, counting from 0; Null past the last one,
// as JavaScript's undefined.
fn param(cx: const HelperContext&, i: i64) -> json::Value {
    guard i >= 0 && i < cx.params.count else { return json::Value.Null; }
    return _resolved_at(cx, cx.params, i).value;
}

// The hash argument key=..., or Null when the call has none.
fn hash_arg(cx: const HelperContext&, key: const u8[:]) -> json::Value {
    for i in cx.hash.count {
        let entry = _resolved_at(cx, cx.hash, i);
        if entry.key == key { return entry.value; }
    }
    return json::Value.Null;
}

// Answers the call cx is for with value: what the helper gives.
fn answer(cx: HelperContext&, value: json::Value) {
    cx.value = value;
    cx.answered = true;
}

// Registers the helper name: runs F, which answers the call with answer,
// when cx is a call to name that no registration before has answered.
inline fn helper<F>(cx: HelperContext&, name: const u8[:]) {
    if !cx.answered && cx.name == name { F(); }
}

// Knows no helper: what the render functions without helpers use.
fn _no_helpers(cx) {}

// ---------------------------------------------------------------------------
// Block helpers.
//
// The user's block helpers are a second static function value, passed
// after the helpers to a render function, and to get_engine or
// load_engine. It is called as
//
//     block_helpers<B>(cx: HelperContext&)
//
// for each {{#name args}}...{{/name}} that is not a built-in block, with
// the arguments resolved in cx as a helper's are. Each
// block_helper(cx, name) registration runs its block when the call is to
// name, and that answers the call. The block writes straight into cx.out,
// and calls B, the block's body, as often as it likes, each time with the
// context the body runs on:
//
//     B(this())           the context the block was written in;
//     B(param(i))         what the param at position i finds: a path or a
//                         lookup, never a literal or a helper's value;
//     B(element(i, k))    the item at position k of the array or object
//                         that param i finds, with @index, @key, @first and
//                         @last set as #each sets them;
//     B(inverse(body))    the part after {{else}}, on body's context.
//
// B returns whether it found that context (and walked the body). The block
// parameters of {{#name args as |a b|}} are, like #each's, the context the
// body runs on and the item's @key (an element's only). For example:
//
//     fn blocks<B>(cx) {
//         gooseneck::block_helper(cx, "bold") {
//             cx.out.append("<b>");
//             B(gooseneck::this());
//             cx.out.append("</b>");
//         };
//         gooseneck::block_helper(cx, "list") {
//             cx.out.append("<ul>");
//             for k in gooseneck::length(gooseneck::param(cx, 0)) {
//                 cx.out.append("<li>");
//                 B(gooseneck::element(0, k));
//                 cx.out.append("</li>");
//             }
//             cx.out.append("</ul>");
//         };
//     }
//     let engine = gooseneck::get_engine(template, blocks);
//     gooseneck::render_into(engine, context, out, my_helpers, blocks);
//
// Given to get_engine or load_engine, the function also gives the names
// of its block helpers, which a template may open: the engine calls it
// once with cx.listing set, where each block_helper adds its name instead
// of running its block. So {{#typo}} is a compile error, as with
// handlebars.js's knownHelpers, and the names cannot drift from the
// helpers.
//
// Its body runs inside the render's recursive walk, so the limits of
// spec §7.8 hold there: no growable local (a u8[>..] buffer, say) may be in
// scope where it calls B. Text it builds goes straight into cx.out, or into
// cx.text. Each B call finds its context again from the params, so
// element(i, k) walks k items: an iterator over n items costs n²/2 steps,
// which matters only for long lists.

// Which context a block helper's body runs on (see Body).
enum BodyContext { This, Param, Element }

// What a block helper asks B to walk: the body, or the inverse, on the
// context of the block (This), of its param at position param (Param), or
// of the item at position index of that param (Element). Build one with
// this, param, element and inverse.
struct Body { inverse: bool, context: BodyContext, param: i64, index: i64 }

// The body on the context the block was written in.
fn this() -> Body {
    return Body { inverse: false, context: BodyContext.This, param: 0, index: 0 };
}

// The body on what the block's param at position i finds.
fn param(i: i64) -> Body {
    return Body { inverse: false, context: BodyContext.Param, param: i, index: 0 };
}

// The body on the item at position k of the array or object that the
// block's param at position i finds, with its @index, @key, @first, @last.
fn element(i: i64, k: i64) -> Body {
    return Body { inverse: false, context: BodyContext.Element, param: i, index: k };
}

// body's inverse: the part of the block after {{else}}, on body's context.
fn inverse(body: Body) -> Body {
    var other = body;
    other.inverse = true;
    return other;
}

// How many items a resolved array or object value holds, 0 for any other
// value: what an iterator walks with element.
fn length(value: json::Value) -> i64 {
    match value {
        Arr a => { return a.count; },
        Obj o => { return o.count; },
        _ => { return 0; },
    }
}

// Appends text to out HTML-escaped, as {{value}} writes it.
fn append_escaped(out: u8[>..]&, text: const u8[:]) {
    _append_html_escaped(out, text);
}

// Registers the block helper name: when cx is a call to name that no
// registration before has answered, runs F, which writes the block into
// cx.out and calls B, and answers the call. While cx.listing, it appends
// name to cx.text, one per line, instead.
inline fn block_helper<F>(cx: HelperContext&, name: const u8[:]) {
    if cx.listing {
        cx.text.append(name);
        cx.text.push('\n');
        return;
    }
    guard !cx.answered && cx.name == name else { return; }
    F();
    cx.answered = true;
}

// The block helpers of the render functions that take none.
fn _no_block_helpers<B>(cx) {}

// Appends the names of the block helpers that G registers with
// block_helper to names, one per line: G runs once with cx.listing set,
// and with a B that walks nothing.
fn _registered_blocks<G>(names: u8[>..]&) {
    fn no_body(part: Body) -> bool { return false; }
    let resolved: Resolved[>..<] = [];
    let none = Range { first: 0, count: 0 };
    let out: u8[>..] = [];
    var cx = HelperContext { resolved: resolved, params: none, hash: none, text: names, out: out, listing: true };
    G(cx, no_body);
}

// ---------------------------------------------------------------------------
// Rendering.

// Where an {{#each}} is: the position of its current item, how many items
// there are, and the item's key, a Str for an object's member and the Int
// position for an array's element. The data variables read it.
struct Loop { index: i64, count: i64, key: json::Value }

// The block parameters of a block whose body is being walked: the frame of
// its first one (the item of an each, the target of a with), and its second
// one, the item's @key (Null for a with).
struct ParamFrame { frame: i64, key: json::Value }

// The buffer, the context stack, the engine being rendered, the loops, and
// the helper arguments. A frame is a node of the context document; the
// first is its root. loops holds one Loop per {{#each}} being walked, the
// innermost last. resolved is the stack of resolved helper arguments, and
// helper is the context of the current helper call, which views them.
// params holds one
// ParamFrame per block with block parameters whose body is being walked,
// the innermost last, which a ParamRef counts back from. All are owned by
// _evaluate, and the document by its caller, outside the walk.
struct RenderContext {
    out: u8[>..]&,
    stack: const json::Node&[>..<]&,
    engine: const Engine&,
    loops: Loop[>..<]&,
    params: ParamFrame[>..<]&,
    resolved: Resolved[>..<]&,
    helper: HelperContext,
}

// Resolves path on the stack to a node, or null. Each leading ../ (or ..)
// climbs one frame; ./, . and this stay (see _navigation_step); with
// nothing after them they are the frame itself. ../ past the first frame
// resolves to nothing, and so does a data variable, which is no node. The
// rest is looked up one dotted segment at a time with json::member; a
// segment after anything but an object finds nothing.
//
// A path that starts with a block parameter starts from that parameter's
// node instead: the item or the target of the block that declares it. A
// parameter that is no node, an each's @key, finds nothing.
fn _lookup(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> const json::Node? {
    guard !_is_data_path(path) else { return null; }
    var rest = path;
    var frame = rc.stack.len - 1;
    if param_ref.up != NONE {
        guard param_ref.slot == 0 else { return null; }
        frame = rc.params[rc.params.len - 1 - param_ref.up].frame;
        rest = _after_first_segment(path);
    }
    loop {
        let taken, climbs = _navigation_step(rest);
        if taken == 0 { break; }
        rest = rest[taken..];
        if climbs { frame -= 1; }
    }
    guard frame >= 0 else { return null; }
    var node: const json::Node? = rc.stack[frame];
    while rest.len > 0 && node {
        let dot = find(rest, ".");
        let head = if dot >= 0 { rest[..dot] } else { rest };
        node .= json::member(node, head);
        rest = if dot >= 0 { rest[dot + 1..] } else { rest[rest.len..] };
    }
    return node;
}

// path without its first dotted segment: "name" for item.name, "" for item.
fn _after_first_segment(path: const u8[:]) -> const u8[:] {
    let dot = find(path, ".");
    guard dot >= 0 else { return path[path.len..]; }
    return path[dot + 1..];
}

// The value of the second block parameter of an each, its item's @key, when
// path is that parameter alone; Null for anything else: a with has no
// second parameter, and a key has no fields.
fn _param_key(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> json::Value {
    guard param_ref.slot == 1 && find(path, ".") < 0 else { return json::Value.Null; }
    return rc.params[rc.params.len - 1 - param_ref.up].key;
}

// Writes a float the way JavaScript's String(n), and so Handlebars, does
// for the common cases: the shortest digits that read back as v, no ".0"
// on an integral value (2.0 is "2"), "-0" as "0", an exponent with its sign
// ("1e+300", "1e-7"), and NaN / Infinity / -Infinity. The digits come from
// json::format_number. Where JavaScript and it pick a different layout,
// that layout is kept: it switches to an exponent from 1e16 where
// JavaScript waits until 1e21.
fn _format_float(out: u8[>..]&, v: f64) {
    if is_nan(v) { out.append("NaN"); return; }
    if is_inf(v) {
        if v < 0.0 { out.append("-Infinity"); } else { out.append("Infinity"); }
        return;
    }
    if v == 0.0 { out.push('0'); return; }
    let digits: u8[>..] = [];
    json::format_number(digits, v);
    var end = digits.len;
    if ends_with(digits, ".0") { end -= 2; }
    var i: i64 = 0;
    while i < end {
        out.push(digits[i]);
        if (digits[i] == 'e' || digits[i] == 'E') && i + 1 < end && digits[i + 1] != '-' && digits[i + 1] != '+' {
            out.push('+');
        }
        i += 1;
    }
}

// Writes a value as a mustache does. A string follows escaped. An Int is
// decimal, a Num as _format_float, a Bool true or false. Null, arrays and
// objects write nothing: an object is a context, an array is for a future
// each.
fn _write_value(value: json::Value, escaped: bool, rc: RenderContext&) {
    match value {
        Str t => {
            if escaped { _append_html_escaped(rc.out, t.s); } else { rc.out.append(t.s); }
        },
        Int i => { format(rc.out, i.v); },
        Num f => { _format_float(rc.out, f.v); },
        Bool b => {
            if b.v { rc.out.append("true"); } else { rc.out.append("false"); }
        },
        Null, Arr, Obj => {},
    }
}

// The value of a data variable: @index, @key, @first or @last of the
// innermost {{#each}}, or of an enclosing one for each ../ (@../index).
// Null when there is no such each.
fn _data_value(path: const u8[:], rc: RenderContext&) -> json::Value {
    let depth, name = _data_parts(path);
    let level = rc.loops.len - 1 - depth;
    guard level >= 0 else { return json::Value.Null; }
    let current = rc.loops[level];
    if name == "index" { return json::Value.Int { v: current.index }; }
    if name == "key" { return current.key; }
    if name == "first" { return json::Value.Bool { v: current.index == 0 }; }
    return json::Value.Bool { v: current.index == current.count - 1 };
}

// The value path resolves to: a data variable's, a block parameter's, or
// the context value the path finds, Null when it finds nothing.
fn _path_value(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> json::Value {
    if _is_data_path(path) { return _data_value(path, rc); }
    if param_ref.up != NONE && param_ref.slot != 0 { return _param_key(path, param_ref, rc); }
    let node = _lookup(path, param_ref, rc);
    guard node else { return json::Value.Null; }
    return node.val;
}

// Writes the value path resolves to, if any.
fn _eval_expression(path: const u8[:], param_ref: ParamRef, escaped: bool, rc: RenderContext&) {
    _write_value(_path_value(path, param_ref, rc), escaped, rc);
}

// The param at position i of a Block node.
fn _param(rc: RenderContext&, node: const Node&, i: i64) -> Arg {
    return _arg_at(rc.engine.args, node.params, i);
}

// Whether a Block node's hash sets key to the literal true. Compile time
// made sure such a key holds a bool.
fn _hash_flag(rc: RenderContext&, node: const Node&, key: const u8[:]) -> bool {
    for i in node.hash.count {
        let arg = _arg_at(rc.engine.args, node.hash, i);
        if _span_text(rc.engine.text, arg.key) == key {
            match arg.value {
                Bool b => { return b.v; },
                _ => {},
            }
        }
    }
    return false;
}

// Whether a number counts as true for {{#if}}: anything but NaN and zero
// (-0 too), and zero as well under includeZero=true.
fn _number_is_truthy(v: f64, include_zero: bool) -> bool {
    if is_nan(v) { return false; }
    if v == 0.0 { return include_zero; }
    return true;
}

// Whether a value counts as true for {{#if}}, as in handlebars.js: null,
// false, "", an empty array and zero are false (zero only without
// includeZero=true); every object, the empty one included, is true.
fn _value_is_truthy(value: json::Value, include_zero: bool) -> bool {
    match value {
        Null => { return false; },
        Bool b => { return b.v; },
        Int i => { return i.v != 0 || include_zero; },
        Num f => { return _number_is_truthy(f.v, include_zero); },
        Str t => { return t.s.len > 0; },
        Arr a => { return a.count > 0; },
        Obj => { return true; },
    }
}

// The value of a helper argument: a path's context value (Null when it
// finds nothing), a literal's own, a subexpression's result.
recursive fn _resolve<F>(arg: Arg, rc: RenderContext&) -> json::Value {
    match arg.value {
        Path p => { return _path_value(_span_text(rc.engine.text, p.path), p.param_ref, rc); },
        Call c => { return _call_value(c.name, c.params, c.hash, rc, F); },
        Int n => { return json::Value.Int { v: n.v }; },
        Number n => { return json::Value.Num { v: n.v }; },
        Bool b => { return json::Value.Bool { v: b.v }; },
        String t => { return json::Value.Str { s: _span_text(rc.engine.text, t.text) }; },
        Null => { return json::Value.Null; },
    }
}

// Pushes the resolved values of the arguments in range, keyed as they are.
recursive fn _push_resolved<F>(range: Range, rc: RenderContext&) {
    for i in range.count {
        let arg = _arg_at(rc.engine.args, range, i);
        let value = _resolve(arg, rc, F);
        rc.resolved.push(Resolved { key: _span_text(rc.engine.text, arg.key), value: value });
    }
}

// Calls the helper name of F with params and hash resolved, innermost
// subexpressions first, and returns its value: Null when F does not answer.
// The arguments are popped once the helper has run.
recursive fn _call_helper<F>(name: Span, params: Range, hash: Range, rc: RenderContext&) -> json::Value {
    let mark = rc.resolved.len;
    _push_resolved(params, rc, F);
    _push_resolved(hash, rc, F);
    _start_call(rc, name, Range { first: mark, count: params.count }, Range { first: mark + params.count, count: hash.count });
    F(&rc.helper);
    rc.resolved.resize(mark);
    return rc.helper.value;
}

// Readies rc.helper for a call to the helper name with params and hash:
// unanswered, with a Null value.
fn _start_call(rc: RenderContext&, name: Span, params: Range, hash: Range) {
    rc.helper.name = _span_text(rc.engine.text, name);
    rc.helper.params = params;
    rc.helper.hash = hash;
    rc.helper.value = json::Value.Null;
    rc.helper.answered = false;
}

// Calls the helper name of F with no arguments, for a bare {{name}}, and
// returns whether F answered, with its value in rc.helper.value. lookup
// without arguments answers Null.
fn _bare_helper<F>(name: Span, rc: RenderContext&) -> bool {
    let none = Range { first: rc.resolved.len, count: 0 };
    _start_call(rc, name, none, none);
    guard !_is_lookup(rc, name) else { return true; }
    F(&rc.helper);
    return rc.helper.answered;
}

// Whether a call is to the built-in lookup.
fn _is_lookup(rc: RenderContext&, name: Span) -> bool {
    return _span_text(rc.engine.text, name) == "lookup";
}

// The value of a call: lookup's node's value (Null when it finds nothing),
// or else what the user's helpers give.
recursive fn _call_value<F>(name: Span, params: Range, hash: Range, rc: RenderContext&) -> json::Value {
    guard _is_lookup(rc, name) else { return _call_helper(name, params, hash, rc, F); }
    let found = _lookup_node(params, rc, F);
    guard found else { return json::Value.Null; }
    return found.val;
}

// The context node an argument stands for: what a path finds, or what a
// lookup call finds. null for anything else: a literal, a data variable,
// a user helper's call, whose result is a scalar, or nothing found.
recursive fn _resolve_node<F>(arg: Arg, rc: RenderContext&) -> const json::Node? {
    match arg.value {
        Path p => { return _lookup(_span_text(rc.engine.text, p.path), p.param_ref, rc); },
        Call c => {
            guard _is_lookup(rc, c.name) else { return null; }
            return _lookup_node(c.params, rc, F);
        },
        _ => { return null; },
    }
}

// {{lookup target key}}: the member of the object target named key, or
// the element of the array target at position key. target is a path or
// another lookup; key is any argument, a data variable such as @index
// included. null when the call does not have exactly those two params,
// when target finds nothing or a scalar, or when key finds no member or
// element, as handlebars.js gives undefined.
recursive fn _lookup_node<F>(params: Range, rc: RenderContext&) -> const json::Node? {
    guard params.count == 2 else { return null; }
    let target = _resolve_node(_arg_at(rc.engine.args, params, 0), rc, F);
    guard target else { return null; }
    let key = _resolve(_arg_at(rc.engine.args, params, 1), rc, F);
    match target.val {
        Obj => { return _member_by_key(target, key); },
        Arr => { return _element_at(target, _key_index(key)); },
        _ => { return null; },
    }
}

// The member of object keyed key: a string names it, and an integer
// names it in decimal ({"1": ...}). null for any other key.
fn _member_by_key(object: const json::Node&, key: json::Value) -> const json::Node? {
    match key {
        Str s => { return json::member(object, s.s); },
        Int i => {
            var member: const json::Node? = object.first;
            while member {
                if _is_decimal(member.key, i.v) { return member; }
                member .= member.next;
            }
            return null;
        },
        _ => { return null; },
    }
}

// Whether text is the decimal form of n, as JavaScript's String(n).
fn _is_decimal(text: const u8[:], n: i64) -> bool {
    let number = json::scan_number(text, 0);
    return number.end == text.len && number.is_int && number.int == n && !starts_with(text, "-0") && (text.len == 1 || text[0] != '0');
}

// The array position a key stands for: an integer, or a string holding
// one in decimal ("1"). -1 for anything else.
fn _key_index(key: json::Value) -> i64 {
    match key {
        Int i => { return i.v; },
        Str s => {
            let number = json::scan_number(s.s, 0);
            if number.end == s.s.len && number.is_int && _is_decimal(s.s, number.int) { return number.int; }
            return -1;
        },
        _ => { return -1; },
    }
}

// The element of array at index, or null when there is none.
fn _element_at(array: const json::Node&, index: i64) -> const json::Node? {
    guard index >= 0 else { return null; }
    var element: const json::Node? = array.first;
    var at: i64 = 0;
    while element && at < index {
        element .= element.next;
        at += 1;
    }
    return element;
}

// The context node a block's only param finds: a path's or a lookup's
// (see _resolve_node).
recursive fn _block_target<F>(node: const Node&, rc: RenderContext&) -> const json::Node? {
    return _resolve_node(_param(rc, node, 0), rc, F);
}

// Walks the chain at index, if there is one: a block's body or inverse.
recursive fn _evaluate_chain<F, G>(index: i64, rc: RenderContext&) {
    if index != NONE { _evaluate_node(index, rc, F, G); }
}

// Makes the block parameters of node, if it declares any, readable in its
// body: the context pushed at frame, and key. The caller pops them, back to
// rc.params.len before the call.
fn _push_params(node: const Node&, frame: i64, key: json::Value, rc: RenderContext&) {
    if node.block_params > 0 { rc.params.push(ParamFrame { frame: frame, key: key }); }
}

// {{#with path}}: when path (or a lookup) finds an object, pushes it on
// the frame the with was written in, walks the body there, and pops it.
// Anything else walks the inverse, the part after {{else}}, on the same
// frame. {{#with path as |p|}} also names the object p.
recursive fn _eval_with<F, G>(node: const Node&, rc: RenderContext&) {
    let found = _block_target(node, rc, F);
    guard found && _is_object(found) else {
        _evaluate_chain(node.inverse, rc, F, G);
        return;
    }
    let mark = rc.stack.len;
    let params_mark = rc.params.len;
    rc.stack.push(found);
    _push_params(node, mark, json::Value.Null, rc);
    _evaluate_chain(node.body, rc, F, G);
    rc.params.resize(params_mark);
    rc.stack.resize(mark);
}

// {{#if value includeZero=...}}: walks the body on the same frame when
// value is truthy, and the inverse otherwise. {{#unless ...}} is the same
// with unless set: it walks the body when value is falsy.
recursive fn _eval_if<F, G>(node: const Node&, rc: RenderContext&, unless: bool) {
    let include_zero = _hash_flag(rc, node, "includeZero");
    let value = _resolve(_param(rc, node, 0), rc, F);
    if _value_is_truthy(value, include_zero) != unless {
        _evaluate_chain(node.body, rc, F, G);
    } else {
        _evaluate_chain(node.inverse, rc, F, G);
    }
}

// Whether a context node is an object.
fn _is_object(found: const json::Node&) -> bool {
    match found.val {
        Obj => { return true; },
        _ => { return false; },
    }
}

// How many items an each can walk in a context node: an array's elements
// or an object's members. 0 for anything else.
fn _item_count(found: const json::Node&) -> i64 {
    match found.val {
        Arr a => { return a.count; },
        Obj o => { return o.count; },
        _ => { return 0; },
    }
}

// The @key of an item: an object member's key, or else the item's position.
fn _item_key(item: const json::Node&, index: i64, in_object: bool) -> json::Value {
    if in_object { return json::Value.Str { s: item.key }; }
    return json::Value.Int { v: index };
}

// {{#each path}}: walks the body once per element of the array, or member
// of the object, that path finds, in order, each pushed as the frame the
// body sees, with its Loop for the data variables. path may also be a
// lookup. Nothing to walk (an empty array or object, a scalar, a missing
// name, a literal or a user helper's subexpression) walks the inverse
// instead, on the same frame. {{#each path as |item key|}} also names the
// item and its @key.
recursive fn _eval_each<F, G>(node: const Node&, rc: RenderContext&) {
    let found = _block_target(node, rc, F);
    guard found && _item_count(found) > 0 else {
        _evaluate_chain(node.inverse, rc, F, G);
        return;
    }
    let count = _item_count(found);
    let in_object = _is_object(found);
    let mark = rc.stack.len;
    let loop_mark = rc.loops.len;
    let params_mark = rc.params.len;
    var index: i64 = 0;
    var item = found.first;
    while item {
        let key = _item_key(item, index, in_object);
        rc.loops.push(Loop { index: index, count: count, key: key });
        rc.stack.push(item);
        _push_params(node, mark, key, rc);
        _evaluate_chain(node.body, rc, F, G);
        rc.params.resize(params_mark);
        rc.stack.resize(mark);
        rc.loops.resize(loop_mark);
        item .= item.next;
        index += 1;
    }
}

// Walks body for a user block helper's call of B: node's body or inverse
// on the context body describes. That context is pushed as a frame unless
// it is the block's own; an element also gets its Loop. The body, not the
// inverse, also gets the block parameters. Returns false, walking nothing,
// when the context is not there: a param past the last, one that finds no
// node, an element past the end.
recursive fn _walk_body<F, G>(node: const Node&, body: Body, rc: RenderContext&) -> bool {
    let chain = if body.inverse { node.inverse } else { node.body };
    let frame_mark = rc.stack.len;
    let loop_mark = rc.loops.len;
    let params_mark = rc.params.len;
    match body.context {
        This => {
            if !body.inverse { _push_params(node, frame_mark - 1, json::Value.Null, rc); }
        },
        Param => {
            guard body.param >= 0 && body.param < node.params.count else { return false; }
            let found = _resolve_node(_param(rc, node, body.param), rc, F);
            guard found else { return false; }
            rc.stack.push(found);
            if !body.inverse { _push_params(node, frame_mark, json::Value.Null, rc); }
        },
        Element => {
            guard body.param >= 0 && body.param < node.params.count else { return false; }
            let found = _resolve_node(_param(rc, node, body.param), rc, F);
            guard found else { return false; }
            let item = _element_at(found, body.index);
            guard item else { return false; }
            let key = _item_key(item, body.index, _is_object(found));
            rc.loops.push(Loop { index: body.index, count: _item_count(found), key: key });
            rc.stack.push(item);
            if !body.inverse { _push_params(node, frame_mark, key, rc); }
        },
    }
    _evaluate_chain(chain, rc, F, G);
    rc.params.resize(params_mark);
    rc.loops.resize(loop_mark);
    rc.stack.resize(frame_mark);
    return true;
}

// Runs a user block helper: resolves its arguments, then hands G a copy of
// rc.helper filled in for the call (the body's own calls reuse rc.helper)
// and body, the B of the description under Block helpers. The arguments
// are popped once G returns.
recursive fn _eval_user_block<F, G>(node: const Node&, rc: RenderContext&) {
    fn body(part: Body) -> bool {
        return _walk_body(node, part, rc, F, G);
    }
    let mark = rc.resolved.len;
    _push_resolved(node.params, rc, F);
    _push_resolved(node.hash, rc, F);
    var cx = rc.helper;
    cx.name = _span_text(rc.engine.text, node.value);
    cx.params = Range { first: mark, count: node.params.count };
    cx.hash = Range { first: mark + node.params.count, count: node.hash.count };
    cx.answered = false;
    G(&cx, body);
    rc.resolved.resize(mark);
}

// Runs a Block node's helper: a built-in one, or else a user block helper,
// which _check_call found in the Config.
recursive fn _eval_block<F, G>(node: const Node&, rc: RenderContext&) {
    let helper = _span_text(rc.engine.text, node.value);
    if helper == "with" {
        _eval_with(node, rc, F, G);
    } else if helper == "if" {
        _eval_if(node, rc, false, F, G);
    } else if helper == "unless" {
        _eval_if(node, rc, true, F, G);
    } else if helper == "each" {
        _eval_each(node, rc, F, G);
    } else {
        _eval_user_block(node, rc, F, G);
    }
}

// Walks the chain starting at engine node index on the top frame. Text is
// copied. An expression looks its path up there; a call writes its
// helper's result. A block runs its helper, which may walk its body (with
// and each on a pushed frame, if on this one) or its inverse; the nodes
// after the block stay on the frame that reached it. Its only type parameter is the helpers: one
// specialization for every context.
recursive fn _evaluate_node<F, G>(index: i64, rc: RenderContext&) {
    let node = rc.engine.nodes[index];
    let value = _span_text(rc.engine.text, node.value);
    match node.kind {
        Text => { rc.out.append(value); },
        Expression => {
            if node.helper_first {
                if _bare_helper(node.value, rc, F) {
                    _write_value(rc.helper.value, node.escaped, rc);
                } else {
                    _eval_expression(value, node.param_ref, node.escaped, rc);
                }
            } else {
                _eval_expression(value, node.param_ref, node.escaped, rc);
            }
        },
        Call => {
            let result = _call_value(node.value, node.params, node.hash, rc, F);
            _write_value(result, node.escaped, rc);
        },
        Block => { _eval_block(node, rc, F, G); },
    }
    if node.next != NONE { _evaluate_node(node.next, rc, F, G); }
}

// Walks each root of engine over doc, with the document's root, node 0, as
// the first frame. Each root is its own chain; the parser links next only
// inside a block.
fn _evaluate<F, G>(engine: const Engine&, doc: const json::Node[>..]&, out: u8[>..]&) {
    let stack: const json::Node&[>..<] = [];
    stack.push(doc[0]);
    let loops: Loop[>..<] = [];
    let params: ParamFrame[>..<] = [];
    let resolved: Resolved[>..<] = [];
    let text: u8[>..] = [];
    let none = Range { first: 0, count: 0 };
    let helper = HelperContext { resolved: resolved, params: none, hash: none, text: text, out: out };
    let rc = RenderContext { out: out, stack: stack, engine: engine, loops: loops, params: params, resolved: resolved, helper: helper };
    var index: i64 = 0;
    while index < engine.roots.len {
        _evaluate_node(engine.roots[index], rc, F, G);
        index += 1;
    }
}

// Renders engine with the fields of a typed context, appending to out.
// Returns how many nodes the converted context took, which is what the
// filtered conversion saves on. An engine that carries an error writes
// nothing and returns 0; check engine.error first.
fn render_into<T>(engine: const Engine&, context: const T&, out: u8[>..]&) -> i64 {
    return render_into(engine, context, out, _no_helpers);
}

// render_into with helpers: F is the user's helpers, as described under
// Helpers above.
fn render_into<T, F>(engine: const Engine&, context: const T&, out: u8[>..]&) -> i64 {
    return render_into(engine, context, out, F, _no_block_helpers);
}

// render_into with helpers F and block helpers G, as described under
// Block helpers above.
fn render_into<T, F, G>(engine: const Engine&, context: const T&, out: u8[>..]&) -> i64 {
    guard engine.error.len == 0 else { return 0; }
    let names: const u8[:][>..] = [];
    _name_slices(engine, names);
    let doc: json::Node[>..] = [];
    _doc_struct(doc, names, "", context);
    _evaluate(engine, doc, out, F, G);
    return doc.len;
}

// Renders engine with a context parsed from JSON text, appending to out.
// Returns the error, empty when the render holds: engine.error, or
// json::parse's message, such as "json: expected ',' or '}' at byte 41".
// On an error out is left as it was.
fn render_json(engine: const Engine&, json_text: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json(engine, json_text, out, _no_helpers);
}

// render_json with helpers F.
fn render_json<F>(engine: const Engine&, json_text: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json(engine, json_text, out, F, _no_block_helpers);
}

// render_json with helpers F and block helpers G.
fn render_json<F, G>(engine: const Engine&, json_text: const u8[:], out: u8[>..]&) -> u8[>..] {
    guard engine.error.len == 0 else { return str(engine.error); }
    let doc: json::Node[>..] = [];
    let decoded: u8[>..] = [];
    let root, err = json::parse(json_text, doc, decoded);
    guard root else { return str(err); }
    _evaluate(engine, doc, out, F, G);
    return [];
}

// Renders engine with a context read from the JSON file at path. Returns
// the error, empty when the render holds: engine.error, "cannot read JSON
// <path>", or "<path>: <json error>".
fn render_json_file(engine: const Engine&, path: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json_file(engine, path, out, _no_helpers);
}

// render_json_file with helpers F.
fn render_json_file<F>(engine: const Engine&, path: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json_file(engine, path, out, F, _no_block_helpers);
}

// render_json_file with helpers F and block helpers G.
fn render_json_file<F, G>(engine: const Engine&, path: const u8[:], out: u8[>..]&) -> u8[>..] {
    guard engine.error.len == 0 else { return str(engine.error); }
    let text: u8[>..] = [];
    guard read_file(path, text) else { return str("cannot read JSON ", path); }
    let err = render_json(engine, text, out, F, G);
    guard err.len == 0 else { return str(path, ": ", err); }
    return [];
}

// Renders engine into text from the fields of context. The second result is
// the error, engine.error, empty when the render holds; with an error the
// text is empty.
fn render<T>(engine: const Engine&, context: const T&) -> u8[>..], const u8[:] {
    return render(engine, context, _no_helpers);
}

// render with helpers F.
fn render<T, F>(engine: const Engine&, context: const T&) -> u8[>..], const u8[:] {
    return render(engine, context, F, _no_block_helpers);
}

// render with helpers F and block helpers G.
fn render<T, F, G>(engine: const Engine&, context: const T&) -> u8[>..], const u8[:] {
    let out: u8[>..] = [];
    render_into(engine, context, out, F, G);
    return out, engine.error;
}
