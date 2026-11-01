import std;
import os;
import json;

import internal.tokenizer;
import internal.paths;
import internal.template;
import internal.parser;
import internal.context;
import internal.registration;
import internal.builtins;
import internal.render;

namespace gooseneck;

// gooseneck's public interface: what a program calls as gooseneck::*.
// The engine's internals are in internal/, in the same namespace; Goose
// has no private declarations, so nothing there is hidden, only apart.

// A compiled template: a value that owns everything it needs, with no
// references into anything else. It can be returned, kept in a local, a
// global or a struct (an HTTP handler's state, say), passed by reference,
// and copied with copy(). It holds only what compiling produced, never
// render state: each render converts its context into a document of its own.
//
// Every field is a T[]: an array whose length is chosen at construction.
// Those are variable-class, and a struct may hold any number of them
// (spec §3.4), where it may hold only one growable T[>..]. compile builds
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

// Compiles template text into an Engine. On a malformed template the Engine
// carries the error, such as "unexpected /with", and renders nothing. The
// Engine copies what it needs: template may go away afterwards. The
// helpers and block helpers are given to the render, not here: an Engine
// cannot hold a function (spec §7.6).
fn get_engine(template: const u8[:]) -> Engine {
    return compile(template, "");
}

// Reads the template file at path and compiles it into an Engine. The
// error, if any, is "cannot read template <path>" or "<path>: <parse error>".
fn load_engine(path: const u8[:]) -> Engine {
    let source: u8[>..] = [];
    guard read_file(path, source) else { return failed(str("cannot read template ", path)); }
    return compile(source, str(path, ": "));
}

// ---------------------------------------------------------------------------
// Helpers.
//
// The user's helpers are one static function value (spec §7.6), passed as
// the last argument of a render function: a named function, or a block,
// which may capture the caller's locals and so carries any state the
// helpers need. It takes a Registry, as plod's routes take a request's cx,
// and registers each helper by name with helper(reg, name). The block of a
// registration takes the call's HelperContext and answers the call by
// filling it in:
//
//     fn my_helpers(reg) {
//         gooseneck::helper(reg, "loud") { cx => gooseneck::answer(cx, loud(cx)); };
//         gooseneck::helper(reg, "count") { cx =>
//             gooseneck::answer(cx, json::Value.Int { v: gooseneck::param_count(cx) });
//         };
//     }
//     gooseneck::render_into(engine, context, out, my_helpers);
//
// or, as a block that keeps state in a local of its caller:
//
//     var calls: i64 = 0;
//     gooseneck::render_into(engine, context, out) { reg =>
//         gooseneck::helper(reg, "next") { cx =>
//             calls += 1;
//             gooseneck::answer(cx, json::Value.Int { v: calls });
//         };
//     };
//
// Its parameter is untyped, as a plod handler's cx is. The render passes
// the registry with & so that a block gets it by reference rather than a
// copy, and a function that types it as Registry& makes that & a
// "redundant &" warning (spec §4.1); an untyped one does not.
//
// It is called for each {{helper args}} mustache and each (helper args)
// subexpression, with the helper's name and its arguments already resolved
// in the call, and for each bare {{name}} (see may_be_helper), with no
// arguments, before name is looked up as a field. The registration of name
// runs its block when the call is to name; the block answers with
// answer(cx, value), or leaves a bare {{name}} to the field.
//
// Each name is registered once. Before a render walks anything, it runs
// the helpers once on a listing Registry, where each registration gives
// its name instead of running its block, and a name registered twice is
// the render's error, duplicate helper "name", with nothing written.
// (Helpers given inline to a render are not known before it, so that is
// where the check can be; the listing costs one call of the helpers per
// render.) A name may be both a helper and a block helper: {{name}} and
// {{#name}} cannot be confused.
//
// A value is a scalar: Str, Int, Num, Bool or Null. A mustache writes it
// as it would a field's value, escaped or not; {{#if}} tests its
// truthiness; it may be an argument of another call. {{#with}} and
// {{#each}} take a path or a lookup, since a scalar is never a context.
//
// lookup is built in (see lookup_node) and wins over a user helper of the
// same name: it finds a context node, not a scalar, which no user helper
// can give. (handlebars.js lets registerHelper replace it.) A call nobody
// answers gives Null, which writes nothing and is false. (handlebars.js
// throws "Missing helper" at render time; here, which helpers a template
// calls is not checked, only how they are registered.) The render
// functions without helpers answer nothing.
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
// - value and answered: the answer, which answer and block_helper fill in.
//
// The render keeps one Registry, and in it one HelperContext that it fills
// in for each call, and a block helper's call gets a copy of it, since its
// body makes calls of its own. Only references are passed down the
// render's recursive walk, never stored in a struct built there (spec
// §7.8), so the registry is made once, outside the walk, and the name
// travels in it.
struct HelperContext {
    name: const u8[:] = "",
    resolved: const Resolved[>..<]&,
    params: Range,
    hash: Range,
    text: u8[>..]&,
    out: u8[>..]&,
    value: json::Value = json::Value.Null,
    answered: bool = false,
}

// What the user's helpers register on: the call being made, which the
// registration of call.name answers, or, while listing, where each
// registration gives its name instead (see helper_names).
struct Registry {
    call: HelperContext,
    listing: bool = false,
}

// How many positional arguments the call has.
fn param_count(cx: const HelperContext&) -> i64 {
    return cx.params.count;
}

// The positional argument at i, counting from 0; Null past the last one,
// as JavaScript's undefined.
fn param(cx: const HelperContext&, i: i64) -> json::Value {
    guard i >= 0 && i < cx.params.count else { return json::Value.Null; }
    return resolved_at(cx, cx.params, i).value;
}

// The hash argument key=..., or Null when the call has none.
fn hash_arg(cx: const HelperContext&, key: const u8[:]) -> json::Value {
    for i in cx.hash.count {
        let entry = resolved_at(cx, cx.hash, i);
        if entry.key == key { return entry.value; }
    }
    return json::Value.Null;
}

// Answers the call cx is for with value: what the helper gives.
fn answer(cx: HelperContext&, value: json::Value) {
    cx.value = value;
    cx.answered = true;
}

// Registers the helper name: when the call is to name, runs F on it, and F
// answers it with answer. While listing, gives name instead.
inline fn helper<F>(reg: Registry&, name: const u8[:]) {
    if reg.listing {
        list_name(reg, name);
    } else if reg.call.name == name {
        F(&reg.call);
    }
}

// Knows no helper: what the render functions without helpers use.
fn no_helpers(reg) {}

// ---------------------------------------------------------------------------
// Block helpers.
//
// The user's block helpers are a second static function value, passed
// after the helpers to a render function. It is called as
//
//     block_helpers<B>(reg: Registry&)
//
// for each {{#name args}}...{{/name}} that is not a built-in block, with
// the arguments resolved in the call as a helper's are. The
// block_helper(reg, name) registration runs its block on the call's
// HelperContext cx when the call is to name, and that answers the call.
// Each name is registered once, as a helper's. The block writes straight
// into cx.out, and calls B, the block's body, as often as it likes, each
// time with the context the body runs on:
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
//     fn blocks<B>(reg) {
//         gooseneck::block_helper(reg, "bold") { cx =>
//             cx.out.append("<b>");
//             B(gooseneck::this());
//             cx.out.append("</b>");
//         };
//         gooseneck::block_helper(reg, "list") { cx =>
//             cx.out.append("<ul>");
//             for k in gooseneck::length(gooseneck::param(cx, 0)) {
//                 cx.out.append("<li>");
//                 B(gooseneck::element(0, k));
//                 cx.out.append("</li>");
//             }
//             cx.out.append("</ul>");
//         };
//     }
//     let engine = gooseneck::get_engine(template);
//     gooseneck::render_into(engine, context, out, my_helpers, blocks);
//
// The function also gives the names of its block helpers: before it
// writes anything, the render calls it once on a listing Registry, where
// each block_helper gives its name instead of running its block. A name
// registered twice is the error duplicate block helper "name", and a block
// of the template that is neither built in nor registered, {{#typo}} say,
// the error unknown block helper "typo", as handlebars.js's knownHelpers
// would find it. The engine cannot check that when it compiles: it never
// sees the block helpers, since it cannot hold a function (spec §7.6).
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
    append_html_escaped(out, text);
}

// Registers the block helper name: when the call is to name, runs F on
// it, which writes the block into cx.out and calls B, and answers the
// call. While listing, gives name instead.
inline fn block_helper<F>(reg: Registry&, name: const u8[:]) {
    if reg.listing {
        list_name(reg, name);
    } else if reg.call.name == name {
        F(&reg.call);
        reg.call.answered = true;
    }
}

// The block helpers of the render functions that take none.
fn no_block_helpers<B>(reg) {}

// Renders engine with the fields of a typed context, appending to out.
// Returns how many nodes the converted context took, which is what the
// filtered conversion saves on, and the error, empty when the render
// holds: engine.error, or a helper registered twice, such as duplicate
// helper "now". On an error out is left as it was and the count is 0.
fn render_into<T>(engine: const Engine&, context: const T&, out: u8[>..]&) -> i64, u8[>..] {
    return render_into(engine, context, out, no_helpers);
}

// render_into with helpers: F is the user's helpers, as described under
// Helpers above.
fn render_into<T, F>(engine: const Engine&, context: const T&, out: u8[>..]&) -> i64, u8[>..] {
    return render_into(engine, context, out, F, no_block_helpers);
}

// render_into with helpers F and block helpers G, as described under
// Block helpers above.
fn render_into<T, F, G>(engine: const Engine&, context: const T&, out: u8[>..]&) -> i64, u8[>..] {
    guard engine.error.len == 0 else { return 0, str(engine.error); }
    let helpers_err = registration_error(engine, F, G);
    guard helpers_err.len == 0 else { return 0, helpers_err; }
    let names: const u8[:][>..] = [];
    name_slices(engine, names);
    let doc: json::Node[>..] = [];
    doc_struct(doc, names, "", context);
    evaluate(engine, doc, out, F, G);
    return doc.len, [];
}

// Renders engine with a context parsed from JSON text, appending to out.
// Returns the error, empty when the render holds: engine.error, a helper
// registered twice (see render_into), or json::parse's message, such as
// "json: expected ',' or '}' at byte 41".
// On an error out is left as it was.
fn render_json(engine: const Engine&, json_text: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json(engine, json_text, out, no_helpers);
}

// render_json with helpers F.
fn render_json<F>(engine: const Engine&, json_text: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json(engine, json_text, out, F, no_block_helpers);
}

// render_json with helpers F and block helpers G.
fn render_json<F, G>(engine: const Engine&, json_text: const u8[:], out: u8[>..]&) -> u8[>..] {
    guard engine.error.len == 0 else { return str(engine.error); }
    let helpers_err = registration_error(engine, F, G);
    guard helpers_err.len == 0 else { return helpers_err; }
    let doc: json::Node[>..] = [];
    let decoded: u8[>..] = [];
    let root, err = json::parse(json_text, doc, decoded);
    guard root else { return str(err); }
    evaluate(engine, doc, out, F, G);
    return [];
}

// Renders engine with a context read from the JSON file at path. Returns
// the error, empty when the render holds: engine.error, a helper
// registered twice, "cannot read JSON <path>", or "<path>: <json error>".
fn render_json_file(engine: const Engine&, path: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json_file(engine, path, out, no_helpers);
}

// render_json_file with helpers F.
fn render_json_file<F>(engine: const Engine&, path: const u8[:], out: u8[>..]&) -> u8[>..] {
    return render_json_file(engine, path, out, F, no_block_helpers);
}

// render_json_file with helpers F and block helpers G.
fn render_json_file<F, G>(engine: const Engine&, path: const u8[:], out: u8[>..]&) -> u8[>..] {
    guard engine.error.len == 0 else { return str(engine.error); }
    let helpers_err = registration_error(engine, F, G);
    guard helpers_err.len == 0 else { return helpers_err; }
    let text: u8[>..] = [];
    guard read_file(path, text) else { return str("cannot read JSON ", path); }
    let err = render_json(engine, text, out, F, G);
    guard err.len == 0 else { return str(path, ": ", err); }
    return [];
}

// Renders engine into text from the fields of context. The second result is
// the error, as render_into's, empty when the render holds; with an error
// the text is empty.
fn render<T>(engine: const Engine&, context: const T&) -> u8[>..], u8[>..] {
    return render(engine, context, no_helpers);
}

// render with helpers F.
fn render<T, F>(engine: const Engine&, context: const T&) -> u8[>..], u8[>..] {
    return render(engine, context, F, no_block_helpers);
}

// render with helpers F and block helpers G.
fn render<T, F, G>(engine: const Engine&, context: const T&) -> u8[>..], u8[>..] {
    let out: u8[>..] = [];
    let nodes, err = render_into(engine, context, out, F, G);
    return out, err;
}
