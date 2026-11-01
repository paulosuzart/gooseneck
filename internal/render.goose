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
// evaluate, and the document by its caller, outside the walk.
//
// The partial being walked, if any (see eval_partial): base is the frame
// it renders on, below which ../ finds nothing; its hash arguments are
// hash[hash_from..hash_end], after those of the partials it is in; depth
// counts the partial calls under way. nothing is the frame of a partial
// whose context finds nothing.
struct RenderContext {
    out: u8[>..]&,
    stack: const json::Node&[>..<]&,
    engine: const Engine&,
    loops: Loop[>..<]&,
    params: ParamFrame[>..<]&,
    resolved: Resolved[>..<]&,
    registry: Registry,
    hash: HashEntry[>..<]&,
    nothing: const json::Node&,
    base: i64 = 0,
    hash_from: i64 = 0,
    hash_end: i64 = 0,
    depth: i64 = 0,
}

// A hash argument of a partial call, {{> name key=value}}: its key, and
// its value, the context node a path or a lookup finds, or else the value.
struct HashEntry { key: const u8[:], node: const json::Node?, value: json::Value }

// Resolves path on the stack to a node, or null. Each leading ../ (or ..)
// climbs one frame; ./, . and this stay (see navigation_step); with
// nothing after them they are the frame itself. ../ past the first frame
// resolves to nothing, and so does a data variable, which is no node. The
// rest is looked up one dotted segment at a time with json::member; a
// segment after anything but an object finds nothing.
//
// A path that starts with a block parameter starts from that parameter's
// node instead: the item or the target of the block that declares it. A
// parameter that is no node, an each's @key, finds nothing. @root starts
// from the first frame, the context the render began with.
//
// Inside a partial, ../ past the partial's frame finds nothing, and on
// that frame the partial's hash arguments come before its fields (see
// eval_partial).
fn lookup(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> const json::Node? {
    guard !is_data_path(path) else { return null; }
    let frame, start = path_start(path, param_ref, rc);
    guard frame != NONE else { return null; }
    var rest = start;
    var node: const json::Node? = rc.stack[frame];
    let entry = hash_entry(frame, rest, rc);
    if entry != NONE {
        node .= rc.hash[entry].node;
        rest = after_first_segment(rest);
    }
    while rest.len > 0 && node {
        let head, after = split_segment(rest);
        node .= member_named(node, head);
        rest = after;
    }
    return node;
}

// The member of node that segment names (see names_key), or null.
fn member_named(node: const json::Node?, segment: const u8[:]) -> const json::Node? {
    guard bracketed(segment) else { return json::member(node, segment); }
    guard node else { return null; }
    match node.val {
        Obj => {},
        _ => { return null; },
    }
    var member: const json::Node? = node.first;
    while member {
        if names_key(segment, member.key) { return member; }
        member .= member.next;
    }
    return null;
}

// The frame path starts from, and the rest of path to look up from it: the
// frame its navigation reaches (@root's, a block parameter's, or the
// current frame's), and the segments after that navigation. NONE when the
// navigation climbs past the first frame, or past the partial's frame
// being walked, or path is a param that is no node, an each's @key.
fn path_start(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> i64, const u8[:] {
    var rest = path;
    var frame = rc.stack.len - 1;
    var floor = rc.base;
    let rooted, after_root = root_parts(path);
    if rooted {
        frame = 0;
        floor = 0;
        rest = after_root;
    } else if param_ref.up != NONE {
        guard param_ref.slot == 0 else { return NONE, ""; }
        frame = rc.params[rc.params.len - 1 - param_ref.up].frame;
        rest = after_first_segment(path);
    }
    loop {
        let taken, climbs = navigation_step(rest);
        if taken == 0 { break; }
        rest = rest[taken..];
        if climbs { frame -= 1; }
    }
    guard frame >= floor else { return NONE, ""; }
    return frame, rest;
}

// The hash argument of the partial being walked that the first segment of
// rest names, when rest is looked up from that partial's frame; NONE
// otherwise. The partial's own hash is searched, the latest key first.
fn hash_entry(frame: i64, rest: const u8[:], rc: RenderContext&) -> i64 {
    guard frame == rc.base && rest.len > 0 && rc.hash_end > rc.hash_from else { return NONE; }
    let head, after = split_segment(rest);
    var i = rc.hash_end - 1;
    while i >= rc.hash_from {
        if names_key(head, rc.hash[i].key) { return i; }
        i -= 1;
    }
    return NONE;
}

// path without its first segment: "name" for item.name, "" for item.
fn after_first_segment(path: const u8[:]) -> const u8[:] {
    let head, rest = split_segment(path);
    return rest;
}

// The value of the second block parameter of an each, its item's @key, when
// path is that parameter alone; Null for anything else: a with has no
// second parameter, and a key has no fields.
fn param_key(path: const u8[:], param_ref: ParamRef, rc: RenderContext&) -> json::Value {
    guard param_ref.slot == 1 && after_first_segment(path).len == 0 else { return json::Value.Null; }
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
// decimal, a Num as format_float, a Bool true or false. Null, arrays and
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
    // A partial's hash argument whose value is no node: a literal, say.
    let frame, rest = path_start(path, param_ref, rc);
    let entry = if frame != NONE && !starts_with(path, "@") { hash_entry(frame, rest, rc) } else { NONE };
    if entry != NONE && after_first_segment(rest).len == 0 && !rc.hash[entry].node { return rc.hash[entry].value; }
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

// The helper a bare {{name}} or {{[name]}} would call: name.
fn helper_name(text: const u8[:], path: Span) -> Span {
    guard bracketed(span_text(text, path)) else { return path; }
    return Span { start: path.start + 1, len: path.len - 2 };
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
// which unknown_block_error found registered before the render began.
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
                if bare_helper(helper_name(rc.engine.text, node.value), rc, F) {
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
        Partial => { eval_partial(node, rc, F, G); },
    }
    if node.next != NONE { evaluate_node(node.next, rc, F, G); }
}

// Walks the page of engine, templates[0], over doc, with the document's
// root, node 0, as the first frame. Returns the render's error, empty when
// it holds: a partial called too deep (see depth_error), which ends the
// render where it is, with out holding what was written up to there.
fn evaluate<F, G>(engine: const Engine&, doc: const json::Node[>..]&, out: u8[>..]&) -> u8[>..] {
    let stack: const json::Node&[>..<] = [];
    stack.push(doc[0]);
    let loops: Loop[>..<] = [];
    let params: ParamFrame[>..<] = [];
    let resolved: Resolved[>..<] = [];
    let text: u8[>..] = [];
    let none = Range { first: 0, count: 0 };
    let call = HelperContext { resolved: resolved, params: none, hash: none, text: text, out: out };
    let registry = Registry { call: call };
    let hash: HashEntry[>..<] = [];
    let nothing = json::Node { next: null, first: null, key: "", val: json::Value.Null };
    let rc = RenderContext { out: out, stack: stack, engine: engine, loops: loops, params: params, resolved: resolved, registry: registry, hash: hash, nothing: nothing };
    return walk(engine.templates[0], rc, F, G);
}

// Walks template's roots, each its own chain: the parser links next only
// inside a block. Returns the render's error, which a partial called too
// deep returns here (see depth_error); empty when the walk ends.
fn walk<F, G>(template: Template, rc: RenderContext&) -> u8[>..] {
    walk_template(template, rc, F, G);
    return [];
}

// Walks each root of template.
recursive fn walk_template<F, G>(template: Template, rc: RenderContext&) {
    for i in template.roots.count {
        evaluate_node(rc.engine.roots[template.roots.first + i], rc, F, G);
    }
}

// ---------------------------------------------------------------------------
// Partials.

// Whether the partial node renders on a context of its own: it has a param
// other than this, {{> name this}} being {{> name}}.
fn has_own_context(node: const Node&, rc: const RenderContext&) -> bool {
    guard node.params.count == 1 else { return false; }
    match arg_at(rc.engine.args, node.params, 0).value {
        Path p => {
            let path = span_text(rc.engine.text, p.path);
            return path != "this" && path != ".";
        },
        _ => { return true; },
    }
}

// {{> name context key=value}}: walks the partial's template on context,
// or on the frame the call is in when it has none. A context that finds
// nothing gives a frame with nothing in it. The hash arguments, and the
// context, are resolved where the call is; inside, they come before the
// context's fields. As in handlebars.js, ../ finds nothing past that
// frame, while @root, @index and the other data variables still read; the
// caller's block parameters are not seen. Called on the frame of the
// partial it is in, a partial sees that one's hash too. A partial alone on
// its line indents each line it writes (see indent_lines). More than
// engine.partial_depth calls under way at once end the render with an
// error (see depth_error).
recursive fn eval_partial<F, G>(node: const Node&, rc: RenderContext&) {
    let name = span_text(rc.engine.text, node.value);
    if rc.depth >= rc.engine.partial_depth { depth_error(rc.engine.partial_depth, name); }
    let has_context = has_own_context(node, rc);
    var context: const json::Node? = null;
    if has_context { context .= resolve_node(param(rc, node, 0), rc, F); }
    let stack_mark = rc.stack.len;
    let hash_mark = rc.hash.len;
    let base = rc.base;
    let hash_from = rc.hash_from;
    let hash_end = rc.hash_end;
    let out_mark = rc.out.len;
    push_hash(node.hash, rc, F);
    if has_context {
        if context { rc.stack.push(context); } else { rc.stack.push(rc.nothing); }
    }
    // On the frame of the partial it is in, a partial also sees that one's
    // hash, as in handlebars.js, which merges a hash into the context.
    let same_frame = !has_context && rc.stack.len - 1 == base;
    if !same_frame { rc.hash_from = hash_mark; }
    rc.base = rc.stack.len - 1;
    rc.hash_end = rc.hash.len;
    rc.depth += 1;
    walk_template(rc.engine.templates[node.partial], rc, F, G);
    rc.depth -= 1;
    rc.hash_end = hash_end;
    rc.hash_from = hash_from;
    rc.base = base;
    rc.hash.resize(hash_mark);
    rc.stack.resize(stack_mark);
    indent_lines(rc.out, out_mark, span_text(rc.engine.text, node.indent));
}

// Pushes the hash arguments in range onto rc.hash, each with the node it
// finds, or else its value.
recursive fn push_hash<F>(range: Range, rc: RenderContext&) {
    for i in range.count {
        let arg = arg_at(rc.engine.args, range, i);
        let found = resolve_node(arg, rc, F);
        let value = if found { found.val } else { resolve(arg, rc, F) };
        rc.hash.push(HashEntry { key: span_text(rc.engine.text, arg.key), node: found, value: value });
    }
}

// Ends the render with the error partial depth over 100: name.
fn depth_error(depth: i64, name: const u8[:]) {
    return str("partial depth over ", depth, ": ", name) from walk;
}

// Indents each line of out[from..] by indent, as handlebars.js does a
// standalone partial's output: every line, the first included, but not
// an empty last one.
fn indent_lines(out: u8[>..]&, from: i64, indent: const u8[:]) {
    guard indent.len > 0 && out.len > from else { return; }
    var lines: i64 = 1;
    for i in from..out.len - 1 {
        if out[i] == '\n' { lines += 1; }
    }
    let old_len = out.len;
    for i in lines * indent.len { out.push(' '); }
    // Moves each byte to its place, from the last, and writes the indent
    // in front of every line start on the way.
    var read = old_len;
    var write = out.len;
    while read > from {
        read -= 1;
        write -= 1;
        out[write] = out[read];
        if read == from || out[read - 1] == '\n' {
            write -= indent.len;
            for k in indent.len { out[write + k] = indent[k]; }
        }
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
