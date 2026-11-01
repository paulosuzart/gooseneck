// Rendering: walks an Engine's nodes over the context document, resolves
// paths and helper arguments, calls the user's helpers and block helpers,
// and writes values, HTML-escaped where the template asks.

import std;
import math;
import json;

namespace gooseneck;

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
// registry is what the user's helpers register on, with the current
// helper call, which views them.
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
    registry: Registry,
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
// parameter that is no node, an each's @key, finds nothing. @root starts
// from the first frame, the context the render began with.
fn lookup(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> const json::Node? {
    guard !is_data_path(path) else { return null; }
    var rest = path;
    var frame = rc.stack.len - 1;
    let rooted, after_root = root_parts(path);
    if rooted {
        frame = 0;
        rest = after_root;
    } else if param_ref.up != NONE {
        guard param_ref.slot == 0 else { return null; }
        frame = rc.params[rc.params.len - 1 - param_ref.up].frame;
        rest = _after_first_segment(path);
    }
    loop {
        let taken, climbs = navigation_step(rest);
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
fn param_key(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> json::Value {
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
fn format_float(out: u8[>..]&, v: f64) {
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
fn write_value(value: json::Value, escaped: bool, rc: RenderContext&) {
    match value {
        Str t => {
            if escaped { append_html_escaped(rc.out, t.s); } else { rc.out.append(t.s); }
        },
        Int i => { format(rc.out, i.v); },
        Num f => { format_float(rc.out, f.v); },
        Bool b => {
            if b.v { rc.out.append("true"); } else { rc.out.append("false"); }
        },
        Null, Arr, Obj => {},
    }
}

// The value of a data variable: @index, @key, @first or @last of the
// innermost {{#each}}, or of an enclosing one for each ../ (@../index).
// Null when there is no such each.
fn data_value(path: const u8[:], rc: RenderContext&) -> json::Value {
    let depth, name = data_parts(path);
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
fn path_value(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> json::Value {
    if is_data_path(path) { return data_value(path, rc); }
    if param_ref.up != NONE && param_ref.slot != 0 { return param_key(path, param_ref, rc); }
    let node = lookup(path, param_ref, rc);
    guard node else { return json::Value.Null; }
    return node.val;
}

// Writes the value path resolves to, if any.
fn eval_expression(path: const u8[:], param_ref: ParamRef, escaped: bool, rc: RenderContext&) {
    write_value(path_value(path, param_ref, rc), escaped, rc);
}

// The param at position i of a Block node.
fn param(rc: RenderContext&, node: const Node&, i: i64) -> Arg {
    return arg_at(rc.engine.args, node.params, i);
}

// Whether a Block node's hash sets key to the literal true. Compile time
// made sure such a key holds a bool.
fn hash_flag(rc: RenderContext&, node: const Node&, key: const u8[:]) -> bool {
    for i in node.hash.count {
        let arg = arg_at(rc.engine.args, node.hash, i);
        if span_text(rc.engine.text, arg.key) == key {
            match arg.value {
                Bool b => { return b.v; },
                _ => {},
            }
        }
    }
    return false;
}

// The value of a helper argument: a path's context value (Null when it
// finds nothing), a literal's own, a subexpression's result.
recursive fn resolve<F>(arg: Arg, rc: RenderContext&) -> json::Value {
    match arg.value {
        Path p => { return path_value(span_text(rc.engine.text, p.path), p.param_ref, rc); },
        Call c => { return call_value(c.name, c.params, c.hash, rc, F); },
        Int n => { return json::Value.Int { v: n.v }; },
        Number n => { return json::Value.Num { v: n.v }; },
        Bool b => { return json::Value.Bool { v: b.v }; },
        String t => { return json::Value.Str { s: span_text(rc.engine.text, t.text) }; },
        Null => { return json::Value.Null; },
    }
}

// Pushes the resolved values of the arguments in range, keyed as they are.
recursive fn push_resolved<F>(range: Range, rc: RenderContext&) {
    for i in range.count {
        let arg = arg_at(rc.engine.args, range, i);
        let value = resolve(arg, rc, F);
        rc.resolved.push(Resolved { key: span_text(rc.engine.text, arg.key), value: value });
    }
}

// Calls the helper name of F with params and hash resolved, innermost
// subexpressions first, and returns its value: Null when F does not answer.
// The arguments are popped once the helper has run.
recursive fn call_helper<F>(name: Span, params: Range, hash: Range, rc: RenderContext&) -> json::Value {
    let mark = rc.resolved.len;
    push_resolved(params, rc, F);
    push_resolved(hash, rc, F);
    start_call(rc, name, Range { first: mark, count: params.count }, Range { first: mark + params.count, count: hash.count });
    F(&rc.registry);
    rc.resolved.resize(mark);
    return rc.registry.call.value;
}

// Readies rc.registry.call for a call to the helper name with params and
// hash: unanswered, with a Null value.
fn start_call(rc: RenderContext&, name: Span, params: Range, hash: Range) {
    rc.registry.call.name = span_text(rc.engine.text, name);
    rc.registry.call.params = params;
    rc.registry.call.hash = hash;
    rc.registry.call.value = json::Value.Null;
    rc.registry.call.answered = false;
}

// Calls the helper name of F with no arguments, for a bare {{name}}, and
// returns whether F answered, with its value in rc.registry.call.value.
// lookup without arguments answers Null.
fn bare_helper<F>(name: Span, rc: RenderContext&) -> bool {
    let none = Range { first: rc.resolved.len, count: 0 };
    start_call(rc, name, none, none);
    guard !is_lookup(rc, name) else { return true; }
    F(&rc.registry);
    return rc.registry.call.answered;
}

// Whether a call is to the built-in lookup.
fn is_lookup(rc: RenderContext&, name: Span) -> bool {
    return span_text(rc.engine.text, name) == "lookup";
}

// The value of a call: lookup's node's value (Null when it finds nothing),
// or else what the user's helpers give.
recursive fn call_value<F>(name: Span, params: Range, hash: Range, rc: RenderContext&) -> json::Value {
    guard is_lookup(rc, name) else { return call_helper(name, params, hash, rc, F); }
    let found = lookup_node(params, rc, F);
    guard found else { return json::Value.Null; }
    return found.val;
}

// Walks the chain at index, if there is one: a block's body or inverse.
recursive fn evaluate_chain<F, G>(index: i64, rc: RenderContext&) {
    if index != NONE { evaluate_node(index, rc, F, G); }
}

// Makes the block parameters of node, if it declares any, readable in its
// body: the context pushed at frame, and key. The caller pops them, back to
// rc.params.len before the call.
fn push_params(node: const Node&, frame: i64, key: json::Value, rc: RenderContext&) {
    if node.block_params > 0 { rc.params.push(ParamFrame { frame: frame, key: key }); }
}

// Walks body for a user block helper's call of B: node's body or inverse
// on the context body describes. That context is pushed as a frame unless
// it is the block's own; an element also gets its Loop. The body, not the
// inverse, also gets the block parameters. Returns false, walking nothing,
// when the context is not there: a param past the last, one that finds no
// node, an element past the end.
recursive fn walk_body<F, G>(node: const Node&, body: Body, rc: RenderContext&) -> bool {
    let chain = if body.inverse { node.inverse } else { node.body };
    let frame_mark = rc.stack.len;
    let loop_mark = rc.loops.len;
    let params_mark = rc.params.len;
    match body.context {
        This => {
            if !body.inverse { push_params(node, frame_mark - 1, json::Value.Null, rc); }
        },
        Param => {
            guard body.param >= 0 && body.param < node.params.count else { return false; }
            let found = resolve_node(param(rc, node, body.param), rc, F);
            guard found else { return false; }
            rc.stack.push(found);
            if !body.inverse { push_params(node, frame_mark, json::Value.Null, rc); }
        },
        Element => {
            guard body.param >= 0 && body.param < node.params.count else { return false; }
            let found = resolve_node(param(rc, node, body.param), rc, F);
            guard found else { return false; }
            let item = element_at(found, body.index);
            guard item else { return false; }
            let key = item_key(item, body.index, is_object(found));
            rc.loops.push(Loop { index: body.index, count: item_count(found), key: key });
            rc.stack.push(item);
            if !body.inverse { push_params(node, frame_mark, key, rc); }
        },
    }
    evaluate_chain(chain, rc, F, G);
    rc.params.resize(params_mark);
    rc.loops.resize(loop_mark);
    rc.stack.resize(frame_mark);
    return true;
}

// Runs a user block helper: resolves its arguments, then hands G a copy of
// rc.registry filled in for the call (the body's own calls reuse
// rc.registry) and body, the B of the description under Block helpers in
// gooseneck.goose. The arguments are popped once G returns.
recursive fn eval_user_block<F, G>(node: const Node&, rc: RenderContext&) {
    fn body(part: Body) -> bool {
        return walk_body(node, part, rc, F, G);
    }
    let mark = rc.resolved.len;
    push_resolved(node.params, rc, F);
    push_resolved(node.hash, rc, F);
    var reg = rc.registry;
    reg.call.name = span_text(rc.engine.text, node.value);
    reg.call.params = Range { first: mark, count: node.params.count };
    reg.call.hash = Range { first: mark + node.params.count, count: node.hash.count };
    reg.call.answered = false;
    G(&reg, body);
    rc.resolved.resize(mark);
}

// Runs a Block node's helper: a built-in one, or else a user block helper,
// which _unknown_block_error found registered before the render began.
recursive fn eval_block<F, G>(node: const Node&, rc: RenderContext&) {
    let helper = span_text(rc.engine.text, node.value);
    if helper == "with" {
        eval_with(node, rc, F, G);
    } else if helper == "if" {
        eval_if(node, rc, false, F, G);
    } else if helper == "unless" {
        eval_if(node, rc, true, F, G);
    } else if helper == "each" {
        eval_each(node, rc, F, G);
    } else {
        eval_user_block(node, rc, F, G);
    }
}

// Walks the chain starting at engine node index on the top frame. Text is
// copied. An expression looks its path up there; a call writes its
// helper's result. A block runs its helper, which may walk its body (with
// and each on a pushed frame, if on this one) or its inverse; the nodes
// after the block stay on the frame that reached it. Its only type parameter is the helpers: one
// specialization for every context.
recursive fn evaluate_node<F, G>(index: i64, rc: RenderContext&) {
    let node = rc.engine.nodes[index];
    let value = span_text(rc.engine.text, node.value);
    match node.kind {
        Text => { rc.out.append(value); },
        Expression => {
            if node.helper_first {
                if bare_helper(node.value, rc, F) {
                    write_value(rc.registry.call.value, node.escaped, rc);
                } else {
                    eval_expression(value, node.param_ref, node.escaped, rc);
                }
            } else {
                eval_expression(value, node.param_ref, node.escaped, rc);
            }
        },
        Call => {
            let result = call_value(node.value, node.params, node.hash, rc, F);
            write_value(result, node.escaped, rc);
        },
        Block => { eval_block(node, rc, F, G); },
    }
    if node.next != NONE { evaluate_node(node.next, rc, F, G); }
}

// Walks each root of engine over doc, with the document's root, node 0, as
// the first frame. Each root is its own chain; the parser links next only
// inside a block.
fn evaluate<F, G>(engine: const Engine&, doc: const json::Node[>..]&, out: u8[>..]&) {
    let stack: const json::Node&[>..<] = [];
    stack.push(doc[0]);
    let loops: Loop[>..<] = [];
    let params: ParamFrame[>..<] = [];
    let resolved: Resolved[>..<] = [];
    let text: u8[>..] = [];
    let none = Range { first: 0, count: 0 };
    let call = HelperContext { resolved: resolved, params: none, hash: none, text: text, out: out };
    let registry = Registry { call: call };
    let rc = RenderContext { out: out, stack: stack, engine: engine, loops: loops, params: params, resolved: resolved, registry: registry };
    var index: i64 = 0;
    while index < engine.roots.len {
        evaluate_node(engine.roots[index], rc, F, G);
        index += 1;
    }
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

fn append_html_escaped(out: u8[>..]&, text: const u8[:]) {
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
