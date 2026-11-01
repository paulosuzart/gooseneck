// The built-in helpers: lookup, and the blocks if, unless, with and each.

import std;
import math;
import json;

namespace gooseneck;

// Whether a number counts as true for {{#if}}: anything but NaN and zero
// (-0 too), and zero as well under includeZero=true.
fn number_is_truthy(v: f64, include_zero: bool) -> bool {
    if is_nan(v) { return false; }
    if v == 0.0 { return include_zero; }
    return true;
}

// Whether a value counts as true for {{#if}}, as in handlebars.js: null,
// false, "", an empty array and zero are false (zero only without
// includeZero=true); every object, the empty one included, is true.
fn value_is_truthy(value: json::Value, include_zero: bool) -> bool {
    match value {
        Null => { return false; },
        Bool b => { return b.v; },
        Int i => { return i.v != 0 || include_zero; },
        Num f => { return number_is_truthy(f.v, include_zero); },
        Str t => { return t.s.len > 0; },
        Arr a => { return a.count > 0; },
        Obj => { return true; },
    }
}

// The context node an argument stands for: what a path finds, or what a
// lookup call finds. null for anything else: a literal, a data variable,
// a user helper's call, whose result is a scalar, or nothing found.
recursive fn resolve_node<F>(arg: Arg, rc: RenderContext&) -> const json::Node? {
    match arg.value {
        Path p => { return lookup(span_text(rc.engine.text, p.path), p.param_ref, rc); },
        Call c => {
            guard is_lookup(rc, c.name) else { return null; }
            return lookup_node(c.params, rc, F);
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
recursive fn lookup_node<F>(params: Range, rc: RenderContext&) -> const json::Node? {
    guard params.count == 2 else { return null; }
    let target = resolve_node(arg_at(rc.engine.args, params, 0), rc, F);
    guard target else { return null; }
    let key = resolve(arg_at(rc.engine.args, params, 1), rc, F);
    match target.val {
        Obj => { return member_by_key(target, key); },
        Arr => { return element_at(target, key_index(key)); },
        _ => { return null; },
    }
}

// The member of object keyed key: a string names it, and an integer
// names it in decimal ({"1": ...}). null for any other key.
fn member_by_key(object: const json::Node&, key: json::Value) -> const json::Node? {
    match key {
        Str s => { return json::member(object, s.s); },
        Int i => {
            var member: const json::Node? = object.first;
            while member {
                if is_decimal(member.key, i.v) { return member; }
                member .= member.next;
            }
            return null;
        },
        _ => { return null; },
    }
}

// Whether text is the decimal form of n, as JavaScript's String(n).
fn is_decimal(text: const u8[:], n: i64) -> bool {
    let number = json::scan_number(text, 0);
    return number.end == text.len && number.is_int && number.int == n && !starts_with(text, "-0") && (text.len == 1 || text[0] != '0');
}

// The array position a key stands for: an integer, or a string holding
// one in decimal ("1"). -1 for anything else.
fn key_index(key: json::Value) -> i64 {
    match key {
        Int i => { return i.v; },
        Str s => {
            let number = json::scan_number(s.s, 0);
            if number.end == s.s.len && number.is_int && is_decimal(s.s, number.int) { return number.int; }
            return -1;
        },
        _ => { return -1; },
    }
}

// The element of array at index, or null when there is none.
fn element_at(array: const json::Node&, index: i64) -> const json::Node? {
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
recursive fn block_target<F>(node: const Node&, rc: RenderContext&) -> const json::Node? {
    return resolve_node(param(rc, node, 0), rc, F);
}

// {{#with path}}: when path (or a lookup) finds an object, pushes it on
// the frame the with was written in, walks the body there, and pops it.
// Anything else walks the inverse, the part after {{else}}, on the same
// frame. {{#with path as |p|}} also names the object p.
recursive fn eval_with<F, G>(node: const Node&, rc: RenderContext&) {
    let found = block_target(node, rc, F);
    guard found && is_object(found) else {
        evaluate_chain(node.inverse, rc, F, G);
        return;
    }
    let mark = rc.stack.len;
    let params_mark = rc.params.len;
    rc.stack.push(found);
    push_params(node, mark, json::Value.Null, rc);
    evaluate_chain(node.body, rc, F, G);
    rc.params.resize(params_mark);
    rc.stack.resize(mark);
}

// {{#if value includeZero=...}}: walks the body on the same frame when
// value is truthy, and the inverse otherwise. {{#unless ...}} is the same
// with unless set: it walks the body when value is falsy.
recursive fn eval_if<F, G>(node: const Node&, rc: RenderContext&, unless: bool) {
    let include_zero = hash_flag(rc, node, "includeZero");
    let value = resolve(param(rc, node, 0), rc, F);
    if value_is_truthy(value, include_zero) != unless {
        evaluate_chain(node.body, rc, F, G);
    } else {
        evaluate_chain(node.inverse, rc, F, G);
    }
}

// Whether a context node is an object.
fn is_object(found: const json::Node&) -> bool {
    match found.val {
        Obj => { return true; },
        _ => { return false; },
    }
}

// How many items an each can walk in a context node: an array's elements
// or an object's members. 0 for anything else.
fn item_count(found: const json::Node&) -> i64 {
    match found.val {
        Arr a => { return a.count; },
        Obj o => { return o.count; },
        _ => { return 0; },
    }
}

// The @key of an item: an object member's key, or else the item's position.
fn item_key(item: const json::Node&, index: i64, in_object: bool) -> json::Value {
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
recursive fn eval_each<F, G>(node: const Node&, rc: RenderContext&) {
    let found = block_target(node, rc, F);
    guard found && item_count(found) > 0 else {
        evaluate_chain(node.inverse, rc, F, G);
        return;
    }
    let count = item_count(found);
    let in_object = is_object(found);
    let mark = rc.stack.len;
    let loop_mark = rc.loops.len;
    let params_mark = rc.params.len;
    var index: i64 = 0;
    var item = found.first;
    while item {
        let key = item_key(item, index, in_object);
        rc.loops.push(Loop { index: index, count: count, key: key });
        rc.stack.push(item);
        push_params(node, mark, key, rc);
        evaluate_chain(node.body, rc, F, G);
        rc.params.resize(params_mark);
        rc.stack.resize(mark);
        rc.loops.resize(loop_mark);
        item .= item.next;
        index += 1;
    }
}
