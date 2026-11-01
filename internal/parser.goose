import std;
import json;

namespace gooseneck;

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
// the parser's list of names. tag_start is where its opening tag starts in
// the template, for the error when it is never closed.
struct OpenBlock { opener: i64, last: i64, in_inverse: bool, chained: bool, names: Range, tag_start: i64 }

// The top level, or a block that {{#helper}} opened at tag_start,
// declaring names.
fn open_block(opener: i64, names: Range, tag_start: i64) -> OpenBlock {
    return OpenBlock { opener: opener, last: NONE, in_inverse: false, chained: false, names: names, tag_start: tag_start };
}

// The position in open of the block that started the innermost chain:
// {{#if a}} for {{#if a}}...{{else if b}}...{{else each c}}. The innermost
// block itself when nothing is chained onto it.
fn chain_start(open: const OpenBlock[>..<]&) -> i64 {
    var at = open.len - 1;
    while open[at].chained { at -= 1; }
    return at;
}

// The block that new nodes go into: the last one opened.
fn innermost(open: OpenBlock[>..<]&) -> OpenBlock& {
    return open[open.len - 1];
}

// Whether the innermost open block was opened by {{#helper ...}}, so a
// closing tag such as {{/with}} only closes the block its opener started.
// For a chain, {{#if a}}...{{else with b}}...{{/if}}, that is the block
// that started it. False at the top level, where no block is open.
fn innermost_is(source: const u8[:], nodes: const Node[>..]&, open: const OpenBlock[>..<]&, helper: const u8[:]) -> bool {
    let opener = open[chain_start(open)].opener;
    guard opener != NONE else { return false; }
    return span_text(source, nodes[opener].value) == helper;
}

// Pushes node and links it into the innermost open block. Returns its index.
fn add(nodes: Node[>..]&, roots: i64[>..]&, open: OpenBlock[>..<]&, node: Node) -> i64 {
    let index = nodes.len;
    nodes.push(node);
    let inner .= innermost(open);
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
fn node(kind: NodeKind, start: i64, end: i64, escaped: bool) -> Node {
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
        param_ref: no_param_ref(),
        helper_first: false,
    };
}

// The calls of a tag are parsed from its TagTokens (see lex_tag). A call
// is words: the helper name, then its arguments. A word ends at the next
// token that has whitespace before it, except inside parentheses, so
// (helper a b) is one word. Each argument word is a subexpression, a
// literal, a path, or key=value with one of those as the value.

// The text from the start of tokens[from] to the end of tokens[to - 1].
fn tokens_text(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64) -> const u8[:] {
    return source[tokens[from].start..tokens[to - 1].end];
}

// Where the helper name of a call that starts at tokens[at] ends: at the
// next token with whitespace before it, whatever it is, or at stop.
fn name_end(tokens: const TagToken[>..<]&, at: i64, stop: i64) -> i64 {
    guard at < stop else { return stop; }
    var i = at + 1;
    while i < stop && !tokens[i].spaced { i += 1; }
    return i;
}

// Where the argument word that starts at tokens[at] ends: at the next
// token with whitespace before it outside parentheses, or at stop.
fn word_end(tokens: const TagToken[>..<]&, at: i64, stop: i64) -> i64 {
    var depth: i64 = 0;
    var i = at;
    while i < stop {
        let token = tokens[i];
        if i > at && depth == 0 && token.spaced { break; }
        if token.kind == TagTokenKind.LParen { depth += 1; }
        if token.kind == TagTokenKind.RParen && depth > 0 { depth -= 1; }
        i += 1;
    }
    return i;
}

// The index of the ')' that closes the '(' at tokens[open], or stop when
// none does.
fn closing_paren(tokens: const TagToken[>..<]&, open: i64, stop: i64) -> i64 {
    var depth: i64 = 0;
    var i = open;
    while i < stop {
        let kind = tokens[i].kind;
        if kind == TagTokenKind.LParen { depth += 1; }
        if kind == TagTokenKind.RParen {
            depth -= 1;
            if depth == 0 { return i; }
        }
        i += 1;
    }
    return stop;
}

// Ends the compile at the argument word tokens[from..to] when it does not
// close: a quote that never closes, a ')' that closes nothing or a '('
// that never closes. The error shows the text from the word to call_end,
// the end of the call.
fn check_word(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64, call_end: i64) {
    let at = tokens[from].start;
    let rest = source[at..call_end];
    var depth: i64 = 0;
    var i = from;
    while i < to {
        let kind = tokens[i].kind;
        guard kind != TagTokenKind.UnclosedString else { error_at(source, at, str("unclosed string: ", rest)); }
        if kind == TagTokenKind.LParen { depth += 1; }
        if kind == TagTokenKind.RParen {
            guard depth > 0 else { error_at(source, at, str("unexpected ): ", rest)); }
            depth -= 1;
        }
        i += 1;
    }
    guard depth == 0 else { error_at(source, at, str("unclosed subexpression: ", rest)); }
}

// How many argument words tokens[at..stop] holds, each checked to close.
fn count_args(source: const u8[:], tokens: const TagToken[>..<]&, at: i64, stop: i64, call_end: i64) -> i64 {
    var count: i64 = 0;
    var word = at;
    while word < stop {
        let end = word_end(tokens, word, stop);
        check_word(source, tokens, word, end, call_end);
        count += 1;
        word = end;
    }
    return count;
}

// Takes count slots at the end of args, Null until the parser fills them.
fn reserve_args(args: Arg[>..]&, count: i64) {
    var taken: i64 = 0;
    while taken < count {
        args.push(Arg { key: Span { start: 0, len: 0 }, value: ArgValue.Null });
        taken += 1;
    }
}

// The index of the '=' of a hash argument word tokens[from..to],
// key=value, or NONE when the word is positional. A quoted string or a
// subexpression is never a key.
fn hash_equals(tokens: const TagToken[>..<]&, from: i64, to: i64) -> i64 {
    var i = from;
    while i < to {
        let kind = tokens[i].kind;
        if kind == TagTokenKind.Equals { return i; }
        if kind == TagTokenKind.String || kind == TagTokenKind.LParen { return NONE; }
        i += 1;
    }
    return NONE;
}

// The helper name of the call in tokens[at..stop] must be there and read
// as a path would. call is the call's text, at byte call_at, which the
// missing name error shows.
fn check_helper_name(source: const u8[:], tokens: const TagToken[>..<]&, at: i64, stop: i64, call: const u8[:], call_at: i64) {
    let end = name_end(tokens, at, stop);
    guard end > at else { error_at(source, call_at, str("missing helper name: ", call)); }
    let why = path_error(source, tokens, at, end);
    guard why.len == 0 else { error_at(source, tokens[at].start, str(why, ": ", tokens_text(source, tokens, at, end))); }
}

// A literal word, one token: a quoted string (its text between the
// quotes), a number, true / false or null / undefined.
fn literal(source: const u8[:], token: TagToken) -> ArgValue {
    let text = token_text(source, token);
    match token.kind {
        String => { return ArgValue.String { text: Span { start: token.start + 1, len: text.len - 2 } }; },
        Bool => { return ArgValue.Bool { v: text == "true" }; },
        Number => {
            let number = json::scan_number(text, 0);
            if number.is_int { return ArgValue.Int { v: number.int }; }
            return ArgValue.Number { v: number.value };
        },
        _ => { return ArgValue.Null; },
    }
}

// Whether a token, as a whole word, is a literal.
fn is_literal(kind: TagTokenKind) -> bool {
    return kind == TagTokenKind.String || kind == TagTokenKind.Number || kind == TagTokenKind.Bool || kind == TagTokenKind.Null;
}

// Reads the argument word tokens[from..to]: a subexpression, a literal,
// or else a path, validated as any other. A subexpression's own arguments
// go onto args. from is past the '=' of a hash argument, which an empty
// value leaves alone.
recursive fn arg_value(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64, args: Arg[>..]&) -> ArgValue {
    guard to > from else { error_at(source, tokens[from - 1].start, "missing argument value"); }
    let first = tokens[from];
    let text = tokens_text(source, tokens, from, to);
    if first.kind == TagTokenKind.LParen {
        let close = closing_paren(tokens, from, to);
        guard close == to - 1 else { error_at(source, first.start, str("text after subexpression: ", text)); }
        let name, params, hash = parse_call(source, tokens, from + 1, close, tokens[close].start, args);
        check_helper_name(source, tokens, from + 1, close, text, first.start);
        return ArgValue.Call { name: name, params: params, hash: hash };
    }
    if first.kind == TagTokenKind.String {
        guard to - from == 1 else { error_at(source, first.start, str("unclosed string: ", text)); }
    }
    if to - from == 1 && is_literal(first.kind) { return literal(source, first); }
    let why = path_error(source, tokens, from, to);
    guard why.len == 0 else { error_at(source, first.start, str(why, ": ", text)); }
    return ArgValue.Path { path: Span { start: first.start, len: text.len }, param_ref: no_param_ref() };
}

// Parses the helper call in tokens[at..stop] into the helper name, the
// params and the hash. It is the body of a block tag after its '#', of a
// mustache with arguments, or of a subexpression inside its parentheses;
// call_end is where its text ends in source.
// A call's arguments sit in one run of args, params first, which its two
// Ranges view; a subexpression among them puts its own run after that one.
// So the run is taken, Null, as soon as the arguments are counted, and each
// slot is filled as its argument is read.
recursive fn parse_call(source: const u8[:], tokens: const TagToken[>..<]&, at: i64, stop: i64, call_end: i64, args: Arg[>..]&) -> Span, Range, Range {
    let name_end = name_end(tokens, at, stop);
    let helper = if name_end > at {
        Span { start: tokens[at].start, len: tokens[name_end - 1].end - tokens[at].start }
    } else {
        Span { start: call_end, len: 0 }
    };
    var params = Range { first: args.len, count: 0 };
    var hash = Range { first: args.len, count: 0 };
    reserve_args(args, count_args(source, tokens, name_end, stop, call_end));
    var word = name_end;
    while word < stop {
        let end = word_end(tokens, word, stop);
        let slot = params.first + params.count + hash.count;
        let key_start = tokens[word].start;
        let equals = hash_equals(tokens, word, end);
        if equals != NONE {
            let value = arg_value(source, tokens, equals + 1, end, args);
            args[slot] = Arg { key: Span { start: key_start, len: tokens[equals].start - key_start }, value: value };
            hash.count += 1;
        } else {
            guard hash.count == 0 else { error_at(source, key_start, str("positional argument after hash arguments: ", tokens_text(source, tokens, word, end))); }
            let value = arg_value(source, tokens, word, end, args);
            args[slot] = Arg { key: Span { start: key_start, len: 0 }, value: value };
            params.count += 1;
        }
        word = end;
    }
    hash.first = params.first + params.count;
    return helper, params, hash;
}

// Whether arg is the literal true or false.
fn is_bool_literal(arg: Arg) -> bool {
    match arg.value {
        Bool => { return true; },
        _ => { return false; },
    }
}

// Whether helper is one of the built-in blocks: with, each, if, unless.
fn is_built_in_block(helper: const u8[:]) -> bool {
    return helper == "with" || helper == "each" || helper == "if" || helper == "unless";
}

// Checks a block's call, in the tag at byte tag_start, against what its
// helper takes: with and each exactly one param and no hash; if and unless
// exactly one param and at most includeZero=true or false. Any other helper
// is a user block helper, which takes anything; whether it is registered is
// the render's to check, since the block helpers are given to the render
// (see unknown_block_error).
fn check_call(source: const u8[:], tag_start: i64, helper: const u8[:], params: Range, hash: Range, args: const Arg[>..]&) {
    if helper == "with" || helper == "each" {
        guard params.count == 1 else { error_at(source, tag_start, str("#", helper, " takes exactly one argument")); }
        guard hash.count == 0 else { error_at(source, tag_start, str("#", helper, " takes no hash arguments")); }
    }
    if helper == "if" || helper == "unless" {
        guard params.count == 1 else { error_at(source, tag_start, str("#", helper, " takes exactly one argument")); }
        for i in hash.count {
            let arg = arg_at(args, hash, i);
            let key = span_text(source, arg.key);
            guard key == "includeZero" else { error_at(source, arg.key.start, str("#", helper, ": unknown hash argument ", key)); }
            guard is_bool_literal(arg) else { error_at(source, arg.key.start, str("#", helper, ": includeZero must be true or false")); }
        }
    }
}

// ---------------------------------------------------------------------------
// Block parameters: {{#each items as |item i|}}.
//
// A path whose first segment names a block parameter, item.name, is tied to
// the block that declares it when it is parsed: the innermost enclosing
// block, in its body, that declares that name (see ParamRef). Nothing about
// it is looked up by name when rendering.

// The index of the "as" of a block's trailing as |a b|, NONE when it has
// none (see mark_block_params).
fn as_index(tokens: const TagToken[>..<]&) -> i64 {
    var i = tokens.len - 1;
    while i >= 0 && tokens[i].kind != TagTokenKind.As { i -= 1; }
    return i;
}

// Whether a word of as |...|, tokens[from..to], can name a block
// parameter: one plain name, no dots.
fn is_param_name(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64) -> bool {
    guard to - from == 1 && is_segment(tokens[from]) else { return false; }
    return source[tokens[from].start] != '[';
}

// Reads the names of as |a b|, whose "as" is tokens[as_at], onto names.
// tag_end is where the tag's text ends. Returns their run; a name that is
// not one, "invalid block parameter name: a.b", ends the compile.
fn parse_param_names(source: const u8[:], tokens: const TagToken[>..<]&, as_at: i64, tag_end: i64, names: Span[>..]&) -> Range {
    var run = Range { first: names.len, count: 0 };
    let last = tokens.len - 1;
    var word = as_at + 2;
    while word < last {
        let end = name_end(tokens, word, last);
        guard is_param_name(source, tokens, word, end) else {
            error_at(source, tokens[word].start, str("invalid block parameter name: ", tokens_text(source, tokens, word, end)));
        }
        names.push(Span { start: tokens[word].start, len: tokens[word].end - tokens[word].start });
        run.count += 1;
        word = end;
    }
    let as_start = tokens[as_at].start;
    guard run.count > 0 else { error_at(source, as_start, str("missing block parameter names: ", source[as_start..tag_end])); }
    return run;
}

// The position of name among the names of run, or NONE.
fn slot_of(source: const u8[:], names: const Span[>..]&, run: Range, name: const u8[:]) -> i64 {
    for i in run.count {
        if span_text(source, names[run.first + i]) == name { return i; }
    }
    return NONE;
}

// The block parameter path starts with, as seen from inside the open
// blocks. A path that starts with ../, ./ or this, or a data variable, is
// never one, as in handlebars.js. A block walking its inverse has no
// parameters there.
fn param_ref(source: const u8[:], path: const u8[:], open: const OpenBlock[>..<]&, names: const Span[>..]&) -> ParamRef {
    let taken, climbs = navigation_step(path);
    guard taken == 0 && !starts_with(path, "@") else { return no_param_ref(); }
    let first, rest = split_segment(path);
    let head = segment_name(first);
    var up: i64 = 0;
    var at = open.len - 1;
    while at > 0 {
        let candidate = open[at];
        if candidate.names.count > 0 && !candidate.in_inverse {
            let slot = slot_of(source, names, candidate.names, head);
            if slot != NONE { return ParamRef { up: up, slot: slot }; }
            up += 1;
        }
        at -= 1;
    }
    return no_param_ref();
}

// Ties every path among args[from..] to its block parameter, if any: the
// arguments of the call just parsed, its subexpressions' included.
fn bind_arg_paths(source: const u8[:], args: Arg[>..]&, from: i64, open: const OpenBlock[>..<]&, names: const Span[>..]&) {
    var i = from;
    while i < args.len {
        match args[i].value {
            Path p => {
                let param_ref = param_ref(source, span_text(source, p.path), open, names);
                args[i].value = ArgValue.Path { path: p.path, param_ref: param_ref };
            },
            _ => {},
        }
        i += 1;
    }
}

// The helpers whose blocks take block parameters: each, with, and the
// user's block helpers. if and unless walk no new context to name.
fn takes_block_params(helper: const u8[:]) -> bool {
    return helper != "if" && helper != "unless";
}

// Parses the block call in tokens, the lexed body of a block tag that
// spans tag_start to tag_end ("with person" for {{#with person}}), checks
// it, and adds its Block node to the innermost open block. Returns the
// node's index and the run of block parameter names it declares.
fn parse_block(source: const u8[:], tokens: const TagToken[>..<]&, tag_start: i64, tag_end: i64, nodes: Node[>..]&, roots: i64[>..]&, open: OpenBlock[>..<]&, args: Arg[>..]&, names: Span[>..]&) -> i64, Range {
    let as_at = as_index(tokens);
    let call_stop = if as_at == NONE { tokens.len } else { as_at };
    let call_end = if as_at == NONE { tag_end } else { tokens[as_at].start };
    let mark = args.len;
    var declared = Range { first: names.len, count: 0 };
    let helper, params, hash = parse_call(source, tokens, 0, call_stop, call_end, args);
    let name = span_text(source, helper);
    check_call(source, tag_start, name, params, hash, args);
    bind_arg_paths(source, args, mark, open, names);
    if as_at != NONE {
        guard takes_block_params(name) else { error_at(source, tokens[as_at].start, str("#", name, " takes no block parameters")); }
        declared = parse_param_names(source, tokens, as_at, tag_end, names);
    }
    var node = node(NodeKind.Block, helper.start, helper.start + helper.len, false);
    node.params = params;
    node.hash = hash;
    node.block_params = declared.count;
    return add(nodes, roots, open, node), declared;
}

// Whether a mustache whose lexed body is tokens holds a helper call with
// arguments, {{helper args}}, rather than a path: whether any token past
// the first has whitespace before it.
fn is_call(tokens: const TagToken[>..<]&) -> bool {
    var i: i64 = 1;
    while i < tokens.len {
        if tokens[i].spaced { return true; }
        i += 1;
    }
    return false;
}

// Whether the mustache {{path}}, lexed into tokens, may call a helper
// instead: when path is one name, plain or bracketed ({{[name]}} calls
// the helper name), as handlebars.js decides. ./name,
// this.name, ../name, dotted paths, data variables and block parameters
// are always paths.
fn may_be_helper(source: const u8[:], tokens: const TagToken[>..<]&, param_ref: ParamRef) -> bool {
    guard param_ref.up == NONE && tokens.len == 1 && is_segment(tokens[0]) else { return false; }
    let name = token_text(source, tokens[0]);
    return name != "this";
}

// Turns tokens into nodes, roots and args. Text becomes a Text node, unless
// whitespace control emptied it; comments are dropped. {{#helper args}}
// adds a Block node with its arguments and opens its block; {{/helper}}
// closes the innermost block, which helper must have opened, and {{else}}
// starts its inverse. A block still open at the end is an error. A {{...}} or
// {{{...}}} with arguments, {{helper args}}, is a Call node; any other is a
// field lookup, already trimmed. escaped says whether what either writes is
// HTML-escaped. The first error ends the compile.
fn parse(source: const u8[:], tokens: const Token[:], nodes: Node[>..]&, roots: i64[>..]&, args: Arg[>..]&) {
    let open: OpenBlock[>..<] = [];
    let names: Span[>..] = [];
    // The lexed body of the tag at hand, reused from tag to tag.
    let tag_tokens: TagToken[>..<] = [];
    open.push(open_block(NONE, Range { first: 0, count: 0 }, 0));
    for token in tokens {
        match token.token_type {
            Comment => {},
            RawOpen => {
                lex_tag(source, token.start, token.end, tag_tokens);
                let opener, declared = parse_block(source, tag_tokens, token.outer_start, token.end, nodes, roots, open, args, names);
                open.push(open_block(opener, declared, token.outer_start));
            },
            RawClose => {
                let helper = source[token.start..token.end];
                guard innermost_is(source, nodes, open, helper) else { error_at(source, token.outer_start, str("unexpected /", helper)); }
                open.resize(chain_start(open));
            },
            Text => {
                if token.end > token.start {
                    add(nodes, roots, open, node(NodeKind.Text, token.start, token.end, false));
                }
            },
            Expression => {
                let word = source[token.start..token.end];
                if token.tag == TagKind.Else {
                    let inner .= innermost(open);
                    guard inner.opener != NONE && !inner.in_inverse else { error_at(source, token.outer_start, "unexpected else"); }
                    inner.in_inverse = true;
                    inner.last = NONE;
                } else if token.tag == TagKind.ElseChain {
                    // {{else helper args}}: the inverse holds one block,
                    // helper, which takes the rest up to the closing tag.
                    let inner .= innermost(open);
                    guard inner.opener != NONE && !inner.in_inverse else { error_at(source, token.outer_start, "unexpected else"); }
                    inner.in_inverse = true;
                    inner.last = NONE;
                    lex_tag(source, token.start + 4, token.end, tag_tokens);
                    let opener, declared = parse_block(source, tag_tokens, token.outer_start, token.end, nodes, roots, open, args, names);
                    var chained = open_block(opener, declared, token.outer_start);
                    chained.chained = true;
                    open.push(chained);
                } else if token.tag == TagKind.Close {
                    let helper = trim(word[1..]);
                    guard innermost_is(source, nodes, open, helper) else { error_at(source, token.outer_start, str("unexpected /", helper)); }
                    open.resize(chain_start(open));
                } else if token.tag == TagKind.Open {
                    lex_tag(source, token.start + 1, token.end, tag_tokens);
                    let opener, declared = parse_block(source, tag_tokens, token.outer_start, token.end, nodes, roots, open, args, names);
                    open.push(open_block(opener, declared, token.outer_start));
                } else {
                    // A mustache, {{helper args}} or {{path}}. {{^...}} is
                    // read as one too, and fails as a path.
                    lex_tag(source, token.start, token.end, tag_tokens);
                    if is_call(tag_tokens) {
                        let mark = args.len;
                        let helper, params, hash = parse_call(source, tag_tokens, 0, tag_tokens.len, token.end, args);
                        check_helper_name(source, tag_tokens, 0, tag_tokens.len, word, token.outer_start);
                        bind_arg_paths(source, args, mark, open, names);
                        var node = node(NodeKind.Call, helper.start, helper.start + helper.len, token.escaped);
                        node.params = params;
                        node.hash = hash;
                        add(nodes, roots, open, node);
                    } else {
                        let why = path_error(source, tag_tokens, 0, tag_tokens.len);
                        guard why.len == 0 else { error_at(source, token.outer_start, str(why, if word.len > 0 { ": " } else { "" }, word)); }
                        var node = node(NodeKind.Expression, token.start, token.end, token.escaped);
                        node.param_ref = param_ref(source, word, open, names);
                        node.helper_first = may_be_helper(source, tag_tokens, node.param_ref);
                        add(nodes, roots, open, node);
                    }
                }
            },
        }
    }
    let unclosed = open[chain_start(open)];
    guard unclosed.opener == NONE else { error_at(source, unclosed.tag_start, str("unclosed #", span_text(source, nodes[unclosed.opener].value))); }
}

// Whether names, spans of text, holds name.
fn has_name(names: const Span[:], text: const u8[:], name: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < names.len {
        let s = names[i];
        if text[s.start..s.start + s.len] == name { return true; }
        i += 1;
    }
    return false;
}

// Adds the field names of the path at span: its dotted segments after the
// leading ../ and ./ navigation, or after @root.
fn add_path_names(names: Span[>..]&, text: const u8[:], span: Span) {
    let path = text[span.start..span.start + span.len];
    guard !is_data_path(path) else { return; }
    let rooted, after_root = root_parts(path);
    let body = if rooted { after_root } else { strip_navigation(path) };
    var at = span.start + path.len - body.len;
    let end = span.start + span.len;
    while at < end {
        let segment, rest = split_segment(text[at..end]);
        let name = segment_name(segment);
        let name_at = if bracketed(segment) { at + 1 } else { at };
        if name.len > 0 && segment != ".." && !has_name(names, text, name) {
            names.push(Span { start: name_at, len: name.len });
        }
        at = end - rest.len;
    }
}

// Adds the key of a lookup call, (lookup target "key"), when it is a
// string literal: it names a field as a path would. A key that is a path
// or a subexpression is known only when rendering, and names nothing.
fn add_lookup_key_name(names: Span[>..]&, text: const u8[:], args: const Arg[>..]&, helper: Span, params: Range) {
    guard span_text(text, helper) == "lookup" && params.count == 2 else { return; }
    match arg_at(args, params, 1).value {
        String key => {
            if !has_name(names, text, span_text(text, key.text)) { names.push(key.text); }
        },
        _ => {},
    }
}

// An Engine that only carries error.
fn failed(error: const u8[:]) -> Engine {
    return Engine { nodes: [], roots: [], args: [], names: [], text: [], error: error };
}

// Tokenizes, parses and validates template, and returns the Engine for it.
// prefix starts the error text, if any.
fn compile(template: const u8[:], prefix: const u8[:]) -> Engine {
    let nodes: Node[>..] = [];
    let roots: i64[>..] = [];
    let args: Arg[>..] = [];
    let err = parse_template(template, nodes, roots, args);
    guard err.len == 0 else { return failed(str(prefix, err)); }

    // The paths are those of the expressions and those among the
    // arguments, which hold every call's, subexpressions included. A
    // lookup's literal key names a field too.
    let names: Span[>..] = [];
    for node in nodes {
        match node.kind {
            Expression => { add_path_names(names, template, node.value); },
            Call => { add_lookup_key_name(names, template, args, node.value, node.params); },
            _ => {},
        }
    }
    for arg in args {
        match arg.value {
            Path p => { add_path_names(names, template, p.path); },
            Call c => { add_lookup_key_name(names, template, args, c.name, c.params); },
            _ => {},
        }
    }
    return Engine { nodes: nodes, roots: roots, args: args, names: names, text: template, error: "" };
}

// Tokenizes and parses template into nodes, roots and args. Returns the
// compile error, or nothing when the template compiles. The tokenizer and
// the parser stop at their first error with error_at, which returns it
// here from however deep they found it.
fn parse_template(template: const u8[:], nodes: Node[>..]&, roots: i64[>..]&, args: Arg[>..]&) -> u8[>..] {
    parse(template, tokenize(template), nodes, roots, args);
    return [];
}

// Ends the compile with the error why, found at byte at of source, as
// "line:column: why", both counted from 1: 3:5: unexpected /each.
fn error_at(source: const u8[:], at: i64, why: const u8[:]) {
    var line: i64 = 1;
    var column: i64 = 1;
    for i in at {
        if source[i] == '\n' { line += 1; column = 1; } else { column += 1; }
    }
    return str(line, ":", column, ": ", why) from parse_template;
}
