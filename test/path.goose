// _validate_path: a normal path passes, a keyword only fails past the first
// byte, and a character from the invalid set fails the segment.
import handlebars from "../gooseneck";

fn check(label: const u8[:], path: const u8[:], want: bool, why_want: const u8[:]) {
    let ok, why = gooseneck::_validate_path(path);
    if ok != want || why != why_want {
        print(label);
        print("ok: ", ok, " want: ", want);
        print("why:\n", why);
        print("why want:\n", why_want);
        assert(false);
    }
    print(label);
}

fn main() {
    check("name", "name", true, "");
    check("dotted", "address.street", true, "");
    check("parent segment", "../name", true, "");
    check("current segment", "./street", true, "");
    check("parent twice", "../../name", true, "");
    check("parent then keyword", "../foo.true", false, "true, false, null, or undefined allowed only at the beginning of the path");
    check("keyword at start", "true", true, "");
    check("keyword then field", "true.name", true, "");
    check("keyword later", "foo.true", false, "true, false, null, or undefined allowed only at the beginning of the path");
    check("two keywords", "true.false", false, "true, false, null, or undefined allowed only at the beginning of the path");
    check("invalid char", "name!", false, "Invalid characted in segment");
    check("empty", "", false, "Has 0 length");
}
