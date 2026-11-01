import std;
import json;

namespace gooseneck;

// ---------------------------------------------------------------------------
// The context.
//
// Rendering reads one data model, stdlib json's: a document is a pool of
// json::Node in document order, each with a key, a value, and links to its
// first child and next sibling. A JSON context is json::parse's document as
// it is. A typed context is turned into the same kind of document below,
// node by node, with only the fields the template uses.

// The field names engine's paths use, as slices of engine.text, for the
// conversions below.
fn name_slices(engine: const Engine&, names: const u8[:][>..]&) {
    var i: i64 = 0;
    while i < engine.names.len {
        let s = engine.names[i];
        names.push(engine.text[s.start..s.start + s.len]);
        i += 1;
    }
}

// Whether names holds name. The set is small, one entry per distinct
// segment in the template, so a scan is enough.
fn wanted(names: const u8[:][>..]&, name: const u8[:]) -> bool {
    var i: i64 = 0;
    while i < names.len {
        if names[i] == name { return true; }
        i += 1;
    }
    return false;
}

// Appends a node with no links yet and returns its index.
fn push_node(doc: json::Node[>..]&, key: const u8[:], val: json::Value) -> i64 {
    doc.push(json::Node { next: null, first: null, key: key, val: val });
    return doc.len - 1;
}

// The children of a container node being built: the container's index, and
// its last child so far (NONE while it has none).
struct Children { parent: i64, last: i64 }

// No children yet for the container at parent.
fn children_of(parent: i64) -> Children {
    return Children { parent: parent, last: NONE };
}

// Links child after the last of children, or as the container's first.
fn append_child(doc: json::Node[>..]&, children: Children&, child: i64) {
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
fn doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const u8[:], rank: i32) -> i64 {
    return push_node(doc, key, json::Value.Str { s: value });
}

fn doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const u8[>..]&, rank: i32) -> i64 {
    return push_node(doc, key, json::Value.Str { s: value });
}

fn doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: i64, rank: i32) -> i64 {
    return push_node(doc, key, json::Value.Int { v: value });
}

fn doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: f64, rank: i32) -> i64 {
    return push_node(doc, key, json::Value.Num { v: value });
}

fn doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: f32, rank: i32) -> i64 {
    return push_node(doc, key, json::Value.Num { v: value });
}

fn doc_value(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: bool, rank: i32) -> i64 {
    return push_node(doc, key, json::Value.Bool { v: value });
}

// A slice becomes an array of its elements, converted the same way.
fn doc_value<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const C[:], rank: i32) -> i64 {
    return doc_list(doc, names, key, value);
}

// A struct becomes an object of the fields the template uses.
fn doc_value<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const C&, rank: i64) -> i64 {
    return doc_struct(doc, names, key, value);
}

// An optional is null when empty, else its value converted as a field of
// that type would be.
fn doc_value<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: C?, rank: f64) -> i64 {
    guard value else { return push_node(doc, key, json::Value.Null); }
    let inner_rank: i32 = 0;
    return doc_value(doc, names, key, value, inner_rank);
}

// An array node, then each element's node and subtree, linked in order.
// Elements have no key and are never filtered; the fields of an element
// that is a struct are.
recursive fn doc_list<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], items: const C[:]) -> i64 {
    let index = push_node(doc, key, json::Value.Arr { count: items.len });
    var children = children_of(index);
    let rank: i32 = 0;
    for &item in items {
        append_child(doc, children, doc_value(doc, names, "", item, rank));
    }
    return index;
}

// An object node, then a node and subtree for each field the template uses,
// linked in declaration order. Unused fields get no node, and their subtrees
// are never visited at run time; const for still checks the conversion of
// every field type, so the specializations are one per type reachable from
// the root.
recursive fn doc_struct<C>(doc: json::Node[>..]&, names: const u8[:][>..]&, key: const u8[:], value: const C&) -> i64 {
    let index = push_node(doc, key, json::Value.Obj { count: 0 });
    var children = children_of(index);
    var count: i64 = 0;
    let rank: i32 = 0;
    const for <N, A> in fields<C> {
        if wanted(names, N) {
            append_child(doc, children, doc_value(doc, names, N, value.A, rank));
            count += 1;
        }
    }
    doc[index].val = json::Value.Obj { count: count };
    return index;
}
