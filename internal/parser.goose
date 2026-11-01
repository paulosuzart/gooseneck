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
// the parser's list of names.
struct OpenBlock { opener: i64, last: i64, in_inverse: bool, chained: bool, names: Range }

// The top level, or a block that {{#helper}} opened, declaring names.
fn open_block(opener: i64, names: Range) -> OpenBlock {
    return OpenBlock { opener: opener, last: NONE, in_inverse: false, chained: false, names: names };
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

// A compile error found while parsing a call: its message, and the template
// text it is about, possibly empty. It is two slices rather than one built
// string because the call parser is recursive (subexpressions nest) and may
// hold no growable value across its recursive calls (spec §7.8).
// error_text joins them once parsing has stopped.
struct CallError { message: const u8[:], text: const u8[:] }

fn no_error() -> CallError {
    return CallError { message: "", text: "" };
}

fn is_ok(err: CallError) -> bool {
    return err.message.len == 0;
}

fn error_text(err: CallError) -> u8[>..] {
    return str(err.message, err.text);
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

// What keeps the argument word tokens[from..to] from closing: a quote that
// never closes, a ')' that closes nothing or a '(' that never closes.
// Its text runs from the word to call_end, the end of the call.
fn word_error(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64, call_end: i64) -> CallError {
    let rest = source[tokens[from].start..call_end];
    var depth: i64 = 0;
    var i = from;
    while i < to {
        let kind = tokens[i].kind;
        guard kind != TagTokenKind.UnclosedString else { return CallError { message: "unclosed string: ", text: rest }; }
        if kind == TagTokenKind.LParen { depth += 1; }
        if kind == TagTokenKind.RParen {
            guard depth > 0 else { return CallError { message: "unexpected ): ", text: rest }; }
            depth -= 1;
        }
        i += 1;
    }
    guard depth == 0 else { return CallError { message: "unclosed subexpression: ", text: rest }; }
    return no_error();
}

// How many argument words tokens[at..stop] holds, or the error of the
// first one that does not close.
fn count_args(source: const u8[:], tokens: const TagToken[>..<]&, at: i64, stop: i64, call_end: i64) -> i64, CallError {
    var count: i64 = 0;
    var word = at;
    while word < stop {
        let end = word_end(tokens, word, stop);
        let err = word_error(source, tokens, word, end, call_end);
        guard is_ok(err) else { return count, err; }
        count += 1;
        word = end;
    }
    return count, no_error();
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
// as a path would. call is the text the missing name error shows.
fn check_helper_name(source: const u8[:], tokens: const TagToken[>..<]&, at: i64, stop: i64, call: const u8[:]) -> CallError {
    let end = name_end(tokens, at, stop);
    guard end > at else { return CallError { message: "missing helper name: ", text: call }; }
    let why = path_error(source, tokens, at, end);
    guard why.len == 0 else { return CallError { message: why, text: "" }; }
    return no_error();
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
// go onto args.
recursive fn arg_value(source: const u8[:], tokens: const TagToken[>..<]&, from: i64, to: i64, args: Arg[>..]&) -> ArgValue, CallError {
    guard to > from else { return ArgValue.Null, CallError { message: "missing argument value", text: "" }; }
    let first = tokens[from];
    let text = tokens_text(source, tokens, from, to);
    if first.kind == TagTokenKind.LParen {
        let close = closing_paren(tokens, from, to);
        guard close == to - 1 else { return ArgValue.Null, CallError { message: "text after subexpression: ", text: text }; }
        let name, params, hash, err = parse_call(source, tokens, from + 1, close, tokens[close].start, args);
        guard is_ok(err) else { return ArgValue.Null, err; }
        let name_err = check_helper_name(source, tokens, from + 1, close, text);
        guard is_ok(name_err) else { return ArgValue.Null, name_err; }
        return ArgValue.Call { name: name, params: params, hash: hash }, no_error();
    }
    if first.kind == TagTokenKind.String {
        guard to - from == 1 else { return ArgValue.Null, CallError { message: "unclosed string: ", text: text }; }
    }
    if to - from == 1 && is_literal(first.kind) { return literal(source, first), no_error(); }
    let why = path_error(source, tokens, from, to);
    guard why.len == 0 else { return ArgValue.Null, CallError { message: why, text: "" }; }
    return ArgValue.Path { path: Span { start: first.start, len: text.len }, param_ref: no_param_ref() }, no_error();
}

// Parses the helper call in tokens[at..stop] into the helper name, the
// params and the hash. It is the body of a block tag after its '#', of a
// mustache with arguments, or of a subexpression inside its parentheses;
// call_end is where its text ends in source.
// A call's arguments sit in one run of args, params first, which its two
// Ranges view; a subexpression among them puts its own run after that one.
// So the run is taken, Null, as soon as the arguments are counted, and each
// slot is filled as its argument is read.
recursive fn parse_call(source: const u8[:], tokens: const TagToken[>..<]&, at: i64, stop: i64, call_end: i64, args: Arg[>..]&) -> Span, Range, Range, CallError {
    let name_end = name_end(tokens, at, stop);
    let helper = if name_end > at {
        Span { start: tokens[at].start, len: tokens[name_end - 1].end - tokens[at].start }
    } else {
        Span { start: call_end, len: 0 }
    };
    var params = Range { first: args.len, count: 0 };
    var hash = Range { first: args.len, count: 0 };
    let count, count_err = count_args(source, tokens, name_end, stop, call_end);
    guard is_ok(count_err) else { return helper, params, hash, count_err; }
    reserve_args(args, count);
    var word = name_end;
    while word < stop {
        let end = word_end(tokens, word, stop);
        let slot = params.first + params.count + hash.count;
        let key_start = tokens[word].start;
        let equals = hash_equals(tokens, word, end);
        if equals != NONE {
            let value, err = arg_value(source, tokens, equals + 1, end, args);
            guard is_ok(err) else { return helper, params, hash, err; }
            args[slot] = Arg { key: Span { start: key_start, len: tokens[equals].start - key_start }, value: value };
            hash.count += 1;
        } else {
            guard hash.count == 0 else { return helper, params, hash, CallError { message: "positional argument after hash arguments: ", text: tokens_text(source, tokens, word, end) }; }
            let value, err = arg_value(source, tokens, word, end, args);
            guard is_ok(err) else { return helper, params, hash, err; }
            args[slot] = Arg { key: Span { start: key_start, len: 0 }, value: value };
            params.count += 1;
        }
        word = end;
    }
    hash.first = params.first + params.count;
    return helper, params, hash, no_error();
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

// Checks a block's call against what its helper takes: with and each
// exactly one param and no hash; if and unless exactly one param and at
// most includeZero=true or false. Any other helper is a user block helper,
// which takes anything; whether it is registered is the render's to check,
// since the block helpers are given to the render (see
// unknown_block_error). Returns the error, empty when the call holds.
fn check_call(source: const u8[:], helper: const u8[:], params: Range, hash: Range, args: const Arg[>..]&) -> u8[>..] {
    if helper == "with" || helper == "each" {
        guard params.count == 1 else { return str("#", helper, " takes exactly one argument"); }
        guard hash.count == 0 else { return str("#", helper, " takes no hash arguments"); }
        return [];
    }
    if helper == "if" || helper == "unless" {
        guard params.count == 1 else { return str("#", helper, " takes exactly one argument"); }
        for i in hash.count {
            let arg = arg_at(args, hash, i);
            let key = span_text(source, arg.key);
            guard key == "includeZero" else { return str("#", helper, ": unknown hash argument ", key); }
            guard is_bool_literal(arg) else { return str("#", helper, ": includeZero must be true or false"); }
        }
        return [];
    }
    return [];
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
// tag_end is where the tag's text ends. Returns their run, or an error
// such as "invalid block parameter name: a.b".
fn parse_param_names(source: const u8[:], tokens: const TagToken[>..<]&, as_at: i64, tag_end: i64, names: Span[>..]&) -> Range, u8[>..] {
    var run = Range { first: names.len, count: 0 };
    let last = tokens.len - 1;
    var word = as_at + 2;
    while word < last {
        let end = name_end(tokens, word, last);
        guard is_param_name(source, tokens, word, end) else { return run, str("invalid block parameter name: ", tokens_text(source, tokens, word, end)); }
        names.push(Span { start: tokens[word].start, len: tokens[word].end - tokens[word].start });
        run.count += 1;
        word = end;
    }
    guard run.count > 0 else { return run, str("missing block parameter names: ", source[tokens[as_at].start..tag_end]); }
    return run, [];
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
    let dot = find(path, ".");
    let head = if dot >= 0 { path[..dot] } else { path };
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
// ends at tag_end ("with person" for {{#with person}}), checks it, and
// adds its Block node to the innermost open block. Returns the node's
// index and the run of block parameter names it declares, or an error.
fn parse_block(source: const u8[:], tokens: const TagToken[>..<]&, tag_end: i64, nodes: Node[>..]&, roots: i64[>..]&, open: OpenBlock[>..<]&, args: Arg[>..]&, names: Span[>..]&) -> i64, Range, u8[>..] {
    let as_at = as_index(tokens);
    let call_stop = if as_at == NONE { tokens.len } else { as_at };
    let call_end = if as_at == NONE { tag_end } else { tokens[as_at].start };
    let mark = args.len;
    var declared = Range { first: names.len, count: 0 };
    let helper, params, hash, err = parse_call(source, tokens, 0, call_stop, call_end, args);
    guard is_ok(err) else { return NONE, declared, error_text(err); }
    let name = span_text(source, helper);
    let call_err = check_call(source, name, params, hash, args);
    guard call_err.len == 0 else { return NONE, declared, call_err; }
    bind_arg_paths(source, args, mark, open, names);
    if as_at != NONE {
        guard takes_block_params(name) else { return NONE, declared, str("#", name, " takes no block parameters"); }
        let run, names_err = parse_param_names(source, tokens, as_at, tag_end, names);
        guard names_err.len == 0 else { return NONE, declared, names_err; }
        declared = run;
    }
    var node = node(NodeKind.Block, helper.start, helper.start + helper.len, false);
    node.params = params;
    node.hash = hash;
    node.block_params = declared.count;
    return add(nodes, roots, open, node), declared, [];
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
// instead: when path is one plain name, as handlebars.js decides. ./name,
// this.name, ../name, dotted paths, data variables and block parameters
// are always paths.
fn may_be_helper(source: const u8[:], tokens: const TagToken[>..<]&, param_ref: ParamRef) -> bool {
    guard param_ref.up == NONE && tokens.len == 1 && is_segment(tokens[0]) else { return false; }
    let name = token_text(source, tokens[0]);
    return name != "this" && name[0] != '[';
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

fn parse(source: const u8[:], tokens: const Token[:], nodes: Node[>..]&, roots: i64[>..]&, args: Arg[>..]&) -> u8[>..] {
    let open: OpenBlock[>..<] = [];
    let names: Span[>..] = [];
    // The lexed body of the tag at hand, reused from tag to tag.
    let tag_tokens: TagToken[>..<] = [];
    open.push(open_block(NONE, Range { first: 0, count: 0 }));
    for token in tokens {
        match token.token_type {
            Comment => {},
            RawOpen => {
                lex_tag(source, token.start, token.end, tag_tokens);
                let opener, declared, err = parse_block(source, tag_tokens, token.end, nodes, roots, open, args, names);
                guard err.len == 0 else { return err; }
                open.push(open_block(opener, declared));
            },
            RawClose => {
                let helper = source[token.start..token.end];
                guard innermost_is(source, nodes, open, helper) else { return str("unexpected /", helper); }
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
                    guard inner.opener != NONE && !inner.in_inverse else { return str("unexpected else"); }
                    inner.in_inverse = true;
                    inner.last = NONE;
                } else if token.tag == TagKind.ElseChain {
                    // {{else helper args}}: the inverse holds one block,
                    // helper, which takes the rest up to the closing tag.
                    let inner .= innermost(open);
                    guard inner.opener != NONE && !inner.in_inverse else { return str("unexpected else"); }
                    inner.in_inverse = true;
                    inner.last = NONE;
                    lex_tag(source, token.start + 4, token.end, tag_tokens);
                    let opener, declared, err = parse_block(source, tag_tokens, token.end, nodes, roots, open, args, names);
                    guard err.len == 0 else { return err; }
                    var chained = open_block(opener, declared);
                    chained.chained = true;
                    open.push(chained);
                } else if token.tag == TagKind.Close {
                    let helper = trim(word[1..]);
                    guard innermost_is(source, nodes, open, helper) else { return str("unexpected /", helper); }
                    open.resize(chain_start(open));
                } else if token.tag == TagKind.Open {
                    lex_tag(source, token.start + 1, token.end, tag_tokens);
                    let opener, declared, err = parse_block(source, tag_tokens, token.end, nodes, roots, open, args, names);
                    guard err.len == 0 else { return err; }
                    open.push(open_block(opener, declared));
                } else {
                    // A mustache, {{helper args}} or {{path}}. {{^...}} is
                    // read as one too, and fails as a path.
                    lex_tag(source, token.start, token.end, tag_tokens);
                    if is_call(tag_tokens) {
                        let mark = args.len;
                        let helper, params, hash, err = parse_call(source, tag_tokens, 0, tag_tokens.len, token.end, args);
                        guard is_ok(err) else { return error_text(err); }
                        let name_err = check_helper_name(source, tag_tokens, 0, tag_tokens.len, word);
                        guard is_ok(name_err) else { return error_text(name_err); }
                        bind_arg_paths(source, args, mark, open, names);
                        var node = node(NodeKind.Call, helper.start, helper.start + helper.len, token.escaped);
                        node.params = params;
                        node.hash = hash;
                        add(nodes, roots, open, node);
                    } else {
                        let why = path_error(source, tag_tokens, 0, tag_tokens.len);
                        guard why.len == 0 else { return str(why); }
                        var node = node(NodeKind.Expression, token.start, token.end, token.escaped);
                        node.param_ref = param_ref(source, word, open, names);
                        node.helper_first = may_be_helper(source, tag_tokens, node.param_ref);
                        add(nodes, roots, open, node);
                    }
                }
            },
        }
    }
    let unclosed = open[chain_start(open)].opener;
    guard unclosed == NONE else { return str("unclosed #", span_text(source, nodes[unclosed].value)); }
    return [];
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
        var stop = at;
        while stop < end && text[stop] != '.' { stop += 1; }
        let head = text[at..stop];
        if head.len > 0 && head != ".." && !has_name(names, text, head) {
            names.push(Span { start: at, len: stop - at });
        }
        at = stop + 1;
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
    let tokens, err = tokenize(template);
    guard err.len == 0 else { return failed(str(prefix, err)); }
    let nodes: Node[>..] = [];
    let roots: i64[>..] = [];
    let args: Arg[>..] = [];
    let parse_err = parse(template, tokens, nodes, roots, args);
    guard parse_err.len == 0 else { return failed(str(prefix, parse_err)); }

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
