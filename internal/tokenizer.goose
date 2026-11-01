import std;
import json;

namespace gooseneck;

// ---------------------------------------------------------------------------
// Tokenizing.
//
// tokenize is the only code that walks the template: it owns the cursor.
// scan_tag reads one tag from a given position with a cursor of its own and
// returns where the tag ends; nothing else moves through the template. Every
// token records byte offsets into the template, never a copy. Whitespace
// control is a separate pass over the finished tokens
// (control_whitespace): it only narrows the ranges of Text tokens.
// Inside a tag, lex_tag (see Tag contents) splits the body into tokens
// once more, and the parser reads only those.

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

// What an Expression tag is, read from the start of its body once, when the
// tag is scanned: {{#helper ...}} opens a block, {{/helper}} closes one,
// {{else}} starts an inverse and {{else helper ...}} chains a block onto
// it. {{^...}} is not supported; it is told apart only so that its line can
// be standalone, as handlebars.js's would be. Anything else is a Mustache:
// a path or a helper call.
enum TagKind { Mustache, Open, Close, Else, ElseChain, Inverse }

// The kind of a tag whose trimmed body is body (see TagKind).
fn tag_kind(body: const u8[:]) -> TagKind {
    guard body.len > 0 else { return TagKind.Mustache; }
    if body[0] == '#' { return TagKind.Open; }
    if body[0] == '/' { return TagKind.Close; }
    if body[0] == '^' { return TagKind.Inverse; }
    if body == "else" { return TagKind.Else; }
    if body.len > 4 && starts_with(body, "else") && is_space(body[4]) { return TagKind.ElseChain; }
    return TagKind.Mustache;
}

struct Token {
    token_type: TokenType,
    // An Expression's kind; Mustache for every other token.
    tag: TagKind,
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

fn text_token(start: i64, end: i64) -> Token {
    return Token {
        token_type: TokenType.Text,
        tag: TagKind.Mustache,
        start: start, end: end, outer_start: start, outer_end: end,
        escaped: false, strip_left: false, strip_right: false,
    };
}

// Reads the tag that opens with "{{" at input[at]. The forms are {{x}},
// {{{x}}}, {{! x }} and {{!-- x --}}, each with an optional ~ just inside
// either end: {{~x~}}, {{~{x}~}}, {{~!-- x --~}}. Returns the tag's token;
// a tag that never closes is the compile's error.
fn scan_tag(input: const u8[:], at: i64) -> Token {
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
            let tag = if kind == TokenType.Expression { tag_kind(input[start..end]) } else { TagKind.Mustache };
            return Token {
                token_type: kind,
                tag: tag,
                start: start, end: end, outer_start: at, outer_end: close + 2,
                escaped: escaped, strip_left: strip_left, strip_right: strip_right,
            };
        }
        // That "}}" was not this tag's closing (e.g. inside {{!-- x }} y --}}).
        from = close + 1;
        found = find(input[from..], "}}");
    }
    error_at(input, at, "unclosed tag");
}

// A tag token for template[start..end], the tag being
// template[outer_start..outer_end].
fn tag_token(kind: TokenType, start: i64, end: i64, outer_start: i64, outer_end: i64) -> Token {
    return Token {
        token_type: kind,
        tag: TagKind.Mustache,
        start: start, end: end, outer_start: outer_start, outer_end: outer_end,
        escaped: false, strip_left: false, strip_right: false,
    };
}

// The token of the tag that opens with "{{{{" at input[at] and closes
// with "}}}}", its body trimmed: {{{{raw}}}} or {{{{/raw}}}}. A tag that
// never closes is the compile's error.
fn scan_raw_tag(input: const u8[:], at: i64, kind: TokenType) -> Token {
    let found = find(input[at + 4..], "}}}}");
    guard found >= 0 else { error_at(input, at, "unclosed tag"); }
    let close = at + 4 + found;
    var start = at + 4;
    if kind == TokenType.RawClose { start += 1; }
    var end = close;
    while start < end && is_space(input[start]) { start += 1; }
    while end > start && is_space(input[end - 1]) { end -= 1; }
    return tag_token(kind, start, end, at, close + 4);
}

// Reads the raw block that opens at input[at], {{{{helper}}}}...{{{{/helper}}}},
// onto tokens: its opening tag, its content as one Text token, and its
// closing tag. Inside, nothing is a tag: a nested {{{{x}}}} only has to be
// closed by its own {{{{/x}}}} before the block's closing tag counts, as in
// handlebars.js. Without a closing tag the content runs to the end, and
// the parser reports the block as unclosed. Returns where the block ends.
fn scan_raw_block(input: const u8[:], at: i64, tokens: Token[>..]&) -> i64 {
    let open = scan_raw_tag(input, at, TokenType.RawOpen);
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
        // A closing tag that never closes ends the content, as no tag.
        guard find(input[tag_at + 4..], "}}}}") >= 0 else { break; }
        let close = scan_raw_tag(input, tag_at, TokenType.RawClose);
        depth -= 1;
        if depth == 0 {
            push_text(tokens, content, tag_at);
            tokens.push(close);
            return close.outer_end;
        }
        p = close.outer_end;
    }
    push_text(tokens, content, input.len);
    return input.len;
}

// Pushes a Text token for input[start..end] when that range holds something.
fn push_text(tokens: Token[>..]&, start: i64, end: i64) {
    if end > start { tokens.push(text_token(start, end)); }
}

// How many backslashes come right before input[at], back to from.
fn backslashes_before(input: const u8[:], from: i64, at: i64) -> i64 {
    var p = at;
    while p > from && input[p - 1] == '\\' { p -= 1; }
    return at - p;
}

// Where the text of an escaped mustache, \{{...}}, that starts at
// input[at] ends: before the next "{{", and before the one or two
// backslashes that may escape that one; at the end of input otherwise.
fn escaped_end(input: const u8[:], at: i64) -> i64 {
    let found = find(input[at + 2..], "{{");
    guard found >= 0 else { return input.len; }
    let next = at + 2 + found;
    let slashes = backslashes_before(input, at + 2, next);
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

fn is_space(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12;
}

// Whether token is a tag that standalone lines apply to: a block tag,
// {{else}}, a raw block's tag or a comment.
fn standalone_kind(token: const Token&) -> bool {
    if token.token_type == TokenType.Comment || token.token_type == TokenType.RawOpen || token.token_type == TokenType.RawClose { return true; }
    return token.token_type == TokenType.Expression && token.tag != TagKind.Mustache;
}

// Whether only whitespace follows the last line break before tokens[i]:
// the text before it ends in whitespace that holds a '\n'. The first token
// of the template also passes when it is all whitespace, and so does
// nothing at all before the tag.
fn prev_blank(input: const u8[:], tokens: const Token[>..]&, i: i64) -> bool {
    guard i > 0 else { return true; }
    let prev = tokens[i - 1];
    guard prev.token_type == TokenType.Text else { return false; }
    let text = input[prev.outer_start..prev.outer_end];
    var k = text.len;
    var newline = false;
    while k > 0 && is_space(text[k - 1]) {
        if text[k - 1] == '\n' { newline = true; }
        k -= 1;
    }
    return newline || (i - 1 == 0 && k == 0);
}

// Whether only whitespace comes before the next line break after
// tokens[i]: the text after it starts with whitespace that holds a '\n'.
// The last token of the template also passes when it is all whitespace,
// and so does nothing at all after the tag.
fn next_blank(input: const u8[:], tokens: const Token[>..]&, i: i64) -> bool {
    guard i + 1 < tokens.len else { return true; }
    let next = tokens[i + 1];
    guard next.token_type == TokenType.Text else { return false; }
    let text = input[next.outer_start..next.outer_end];
    var k: i64 = 0;
    var newline = false;
    while k < text.len && is_space(text[k]) {
        if text[k] == '\n' { newline = true; }
        k += 1;
    }
    return newline || (i + 1 == tokens.len - 1 && k == text.len);
}

// ~ before the tag: drops all trailing whitespace.
fn strip_end(input: const u8[:], t: Token&) {
    while t.end > t.start && is_space(input[t.end - 1]) { t.end -= 1; }
}

// ~ after the tag: drops all leading whitespace.
fn strip_start(input: const u8[:], t: Token&) {
    while t.start < t.end && is_space(input[t.start]) { t.start += 1; }
}

// Standalone, before the tag: drops the line's indentation, spaces and tabs.
fn strip_indent(input: const u8[:], t: Token&) {
    while t.end > t.start && (input[t.end - 1] == ' ' || input[t.end - 1] == '\t') { t.end -= 1; }
}

// Standalone, after the tag: drops spaces and tabs, then one "\n" or "\r\n".
fn strip_line_end(input: const u8[:], t: Token&) {
    while t.start < t.end && (input[t.start] == ' ' || input[t.start] == '\t') { t.start += 1; }
    if t.start < t.end && input[t.start] == '\r' && t.start + 1 < t.end && input[t.start + 1] == '\n' {
        t.start += 2;
    } else if t.start < t.end && input[t.start] == '\n' {
        t.start += 1;
    }
}

// Applies ~ and standalone lines to the Text tokens around each tag. The
// strip_* helpers narrow tokens[i - 1] and tokens[i + 1] in place; tag is a
// copy, and only read.
fn control_whitespace(input: const u8[:], tokens: Token[>..]&) {
    var i: i64 = 0;
    while i < tokens.len {
        let tag = tokens[i];
        if tag.token_type != TokenType.Text {
            let has_prev = i > 0 && tokens[i - 1].token_type == TokenType.Text;
            let has_next = i + 1 < tokens.len && tokens[i + 1].token_type == TokenType.Text;
            if tag.strip_left && has_prev { strip_end(input, tokens[i - 1]); }
            if tag.strip_right && has_next { strip_start(input, tokens[i + 1]); }
            if standalone_kind(tag) && prev_blank(input, tokens, i) && next_blank(input, tokens, i) {
                if has_prev { strip_indent(input, tokens[i - 1]); }
                if has_next { strip_line_end(input, tokens[i + 1]); }
            }
        }
        i += 1;
    }
}

// ---------------------------------------------------------------------------
// Tag contents.
//
// lex_tag splits the body of one tag, the text between its braces (and
// after a block's '#' or an {{else}}), into TagTokens: ranges of the
// template, never copies. Whitespace only separates tokens; each token
// says whether whitespace came before it, which is what splits a call
// into its words: {{helper a.b (sub x) key=1}} is the words helper, a.b,
// (sub x) and key=1. Paths are checked and calls parsed from the tokens,
// never from the text again.

enum TagTokenKind {
    // A name segment: name, this, -x, [any text].
    Ident,
    // '.' right after a name segment: a.b.
    Sep,
    // '/': ../name, ./name, this/name.
    Slash,
    // "." and ".." anywhere but right after a segment.
    Dot,
    DotDot,
    // '@', the start of a data variable.
    Data,
    // "..." or '...', quotes included, and one that never closes.
    String,
    UnclosedString,
    // Literals, only at the start of a word and only when the word ends
    // there: 1, -2.5, true, false, null, undefined. true.name is a path.
    Number,
    Bool,
    Null,
    Equals,
    LParen,
    RParen,
    // The "as" of a trailing as |a b| (see mark_block_params).
    As,
    Pipe,
    // Any other byte that cannot be in a name, such as '!'.
    Invalid,
}

struct TagToken { kind: TagTokenKind, start: i64, end: i64, spaced: bool }

// The text of a token.
fn token_text(source: const u8[:], token: TagToken) -> const u8[:] {
    return source[token.start..token.end];
}

// Whether a word ends at source[at], so a literal may end there.
fn literal_ends(source: const u8[:], at: i64, stop: i64) -> bool {
    return at == stop || is_space(source[at]) || source[at] == ')';
}

// Where the name segment that starts at source[at] ends.
fn ident_end(source: const u8[:], at: i64, stop: i64) -> i64 {
    var p = at;
    while p < stop && !is_space(source[p]) && !INVALID_IDENTIFIER_CHARS.contains(source[p]) { p += 1; }
    return p;
}

// The literal that starts a word at source[at], if one does: its kind and
// end. Ident when the word holds no literal.
fn literal_at(source: const u8[:], at: i64, stop: i64) -> TagTokenKind, i64 {
    let c = source[at];
    let digit_next = at + 1 < stop && source[at + 1] >= '0' && source[at + 1] <= '9';
    if (c >= '0' && c <= '9') || (c == '-' && digit_next) {
        let number = json::scan_number(source[..stop], at);
        if number.end > at && literal_ends(source, number.end, stop) { return TagTokenKind.Number, number.end; }
    }
    let end = ident_end(source, at, stop);
    if literal_ends(source, end, stop) {
        let word = source[at..end];
        if word == "true" || word == "false" { return TagTokenKind.Bool, end; }
        if word == "null" || word == "undefined" { return TagTokenKind.Null, end; }
    }
    return TagTokenKind.Ident, end;
}

// Where a quoted string that opens at source[at] ends, past its closing
// quote, and whether it closes before stop.
fn string_end(source: const u8[:], at: i64, stop: i64) -> i64, bool {
    var p = at + 1;
    while p < stop && source[p] != source[at] { p += 1; }
    guard p < stop else { return stop, false; }
    return p + 1, true;
}

// The kind and end of the token at source[at]. after_segment says whether
// a name segment ends right before it, word_start whether it starts a word.
fn lex_one(source: const u8[:], at: i64, stop: i64, after_segment: bool, word_start: bool) -> TagTokenKind, i64 {
    let c = source[at];
    if c == '"' || c == '\'' {
        let end, closed = string_end(source, at, stop);
        if closed { return TagTokenKind.String, end; }
        return TagTokenKind.UnclosedString, end;
    }
    if c == '(' { return TagTokenKind.LParen, at + 1; }
    if c == ')' { return TagTokenKind.RParen, at + 1; }
    if c == '=' { return TagTokenKind.Equals, at + 1; }
    if c == '|' { return TagTokenKind.Pipe, at + 1; }
    if c == '@' { return TagTokenKind.Data, at + 1; }
    if c == '/' { return TagTokenKind.Slash, at + 1; }
    if c == '.' {
        if after_segment { return TagTokenKind.Sep, at + 1; }
        if at + 1 < stop && source[at + 1] == '.' { return TagTokenKind.DotDot, at + 2; }
        return TagTokenKind.Dot, at + 1;
    }
    if c == '[' {
        let close = find(source[at..stop], "]");
        if close >= 0 { return TagTokenKind.Ident, at + close + 1; }
        return TagTokenKind.Invalid, at + 1;
    }
    if INVALID_IDENTIFIER_CHARS.contains(c) { return TagTokenKind.Invalid, at + 1; }
    if word_start { return literal_at(source, at, stop); }
    return TagTokenKind.Ident, ident_end(source, at, stop);
}

// Whether a token may start a word's literal: the first token, one after
// whitespace, or one right after '=' or '('.
fn starts_word(tokens: const TagToken[>..<]&, spaced: bool) -> bool {
    guard tokens.len > 0 && !spaced else { return true; }
    let kind = tokens[tokens.len - 1].kind;
    return kind == TagTokenKind.Equals || kind == TagTokenKind.LParen;
}

// Whether the last token is a name segment that ends right where the next
// token starts.
fn segment_before(tokens: const TagToken[>..<]&, spaced: bool) -> bool {
    guard tokens.len > 0 && !spaced else { return false; }
    let kind = tokens[tokens.len - 1].kind;
    return kind == TagTokenKind.Ident || kind == TagTokenKind.Number || kind == TagTokenKind.Bool || kind == TagTokenKind.Null;
}

// Marks the "as" of a block's trailing block parameters, as |a b|: the
// tokens end in '|', the '|' before that one comes right after an "as"
// that is a word of its own, and that word is not the first.
fn mark_block_params(source: const u8[:], tokens: TagToken[>..<]&) {
    guard tokens.len >= 3 && tokens[tokens.len - 1].kind == TagTokenKind.Pipe else { return; }
    var bar = tokens.len - 2;
    while bar >= 0 && tokens[bar].kind != TagTokenKind.Pipe { bar -= 1; }
    guard bar >= 2 else { return; }
    let as_word = tokens[bar - 1];
    guard as_word.kind == TagTokenKind.Ident && as_word.spaced && token_text(source, as_word) == "as" else { return; }
    tokens[bar - 1].kind = TagTokenKind.As;
}

// Splits source[start..stop], the body of a tag, into tokens, replacing
// what tokens held.
fn lex_tag(source: const u8[:], start: i64, stop: i64, tokens: TagToken[>..<]&) {
    tokens.clear();
    var p = start;
    var spaced = false;
    while p < stop {
        if is_space(source[p]) {
            spaced = true;
            p += 1;
            continue;
        }
        let kind, end = lex_one(source, p, stop, segment_before(tokens, spaced), starts_word(tokens, spaced));
        tokens.push(TagToken { kind: kind, start: p, end: end, spaced: spaced });
        spaced = false;
        p = end;
    }
    mark_block_params(source, tokens);
}

// Splits a template into Text, Expression, Comment and raw block tokens,
// then applies whitespace control. An empty template is the compile's
// error, "Must not be empty". The scan's position is only ever moved here: past a byte of text,
// or to the end scan_tag reports for a tag, so a tag jammed against the
// next one (}}{{) is still a tag. Text after the last tag is flushed.
//
// As in handlebars.js, \{{ escapes a mustache: the backslash is dropped,
// and the text from "{{" to the next mustache is written as it is. \\{{
// writes one backslash, and the mustache after it is a mustache.
fn tokenize(input: const u8[:]) -> Token[>..] {
    guard input.len > 0 else { error_at(input, 0, "Must not be empty"); }

    let tokens: Token[>..] = [];
    var text_start: i64 = 0;
    var at: i64 = 0;
    while at + 1 < input.len {
        if input[at] == '{' && input[at + 1] == '{' {
            let slashes = backslashes_before(input, text_start, at);
            if slashes == 1 {
                push_text(tokens, text_start, at - 1);
                let end = escaped_end(input, at);
                push_text(tokens, at, end);
                at = end;
                text_start = at;
                continue;
            }
            if slashes >= 2 {
                // Drop the backslash that escaped the other.
                push_text(tokens, text_start, at - 1);
                text_start = at;
            }
            if starts_with(input[at..], "{{{{") {
                push_text(tokens, text_start, at);
                at = scan_raw_block(input, at, tokens);
                text_start = at;
                continue;
            }
            let tag = scan_tag(input, at);
            push_text(tokens, text_start, at);
            tokens.push(tag);
            at = tag.outer_end;
            text_start = at;
        } else {
            at += 1;
        }
    }
    push_text(tokens, text_start, input.len);
    control_whitespace(input, tokens);
    return tokens;
}
