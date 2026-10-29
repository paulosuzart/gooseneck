// How a typed context converts to a json::Node document: floats (Num),
// bools, optionals (Null), slices (arrays), and the filtered conversion that skips
// fields no path in the template names. Each case asserts, then prints its
// name; scripts/test.sh compares that list with test/expected/values.out.
import handlebars from "../gooseneck";

struct Point { x: f64, y: f32 }

struct Pet { name: const u8[:] }

struct Profile {
    name: const u8[:],
    score: f64,
    whole: f64,
    half: f32,
    sum: f64,
    huge: f64,
    tiny: f64,
    zero: f64,
    active: bool,
    banned: bool,
    nick: const (const u8[:])?,
    alias: const (const u8[:])?,
    pet: Pet?,
    lost: Pet?,
    tags: const u8[:][:],
    scores: const i64[:],
    point: Point,
}

fn check(label: const u8[:], template: const u8[:], context: const Profile&, want: const u8[:]) {
    let out: u8[>..] = [];
    let t = gooseneck::get_engine(template);
    let err = t.error;
    gooseneck::render_into(t, context, out);
    if err.len > 0 || out != want {
        print(label);
        print("err: ", err);
        print("got:\n", out);
        print("want:\n", want);
        assert(false);
    }
    print(label);
}

// The number of json::Node the converted context takes for template.
fn check_size(label: const u8[:], template: const u8[:], context: const Profile&, want_out: const u8[:], want_size: i64) {
    let out: u8[>..] = [];
    let t = gooseneck::get_engine(template);
    let err = t.error;
    let size = gooseneck::render_into(t, context, out);
    if err.len > 0 || out != want_out || size != want_size {
        print(label);
        print("err: ", err);
        print("got: ", out, " size ", size);
        print("want: ", want_out, " size ", want_size);
        assert(false);
    }
    print(label);
}

fn main() {
    var nick: const u8[:] = "Johnny";
    var pet = Pet { name: "Rex" };
    let tags: const u8[:][2] = ["a", "b"];
    let scores: i64[3] = [1, 2, 3];
    let a = 0.1;
    let b = 0.2;
    var context = Profile {
        name: "John",
        score: 1.5,
        whole: 2.0,
        half: 0.25,
        sum: a + b,
        huge: 1e300,
        tiny: 1e-7,
        zero: -0.0,
        active: true,
        banned: false,
        nick: nick,
        alias: null,
        pet: pet,
        lost: null,
        tags: tags,
        scores: scores,
        point: Point { x: 1.5, y: -2.0 },
    };

    check("float", "{{score}}", context, "1.5");
    check("float integral", "{{whole}}", context, "2");
    check("float f32", "{{half}}", context, "0.25");
    check("float shortest", "{{sum}}", context, "0.30000000000000004");
    check("float exponent", "{{huge}} {{tiny}}", context, "1e+300 1e-7");
    check("float negative zero", "{{zero}}", context, "0");
    check("bool", "{{active}} {{banned}}", context, "true false");
    check("optional present", "a{{nick}}b", context, "aJohnnyb");
    check("optional null", "a{{alias}}b", context, "ab");
    check("with optional present", "{{#with pet}}{{name}} of {{../name}}{{/with}}", context, "Rex of John");
    check("with optional null", "{{#with lost}}HIDDEN{{/with}}after", context, "after");
    check("with float", "{{#with score}}HIDDEN{{/with}}x", context, "x");
    check("with bool", "{{#with active}}HIDDEN{{/with}}x", context, "x");
    check("with list", "{{#with tags}}HIDDEN{{/with}}x", context, "x");
    check("list writes nothing", "a{{tags}}{{scores}}b", context, "ab");
    check("struct of floats", "{{#with point}}{{x}},{{y}}{{/with}}", context, "1.5,-2");

    // Profile has 17 fields, Pet 1 and Point 2, plus 2 tags and 3 scores:
    // converted whole, the context would take 1 + 17 + 1 + 2 + 2 + 3 = 26
    // nodes. Only the fields the template names are converted.
    check_size("filtered one field", "{{name}}", context, "John", 2);
    check_size("filtered nested", "{{name}} {{point.x}}", context, "John 1.5", 4);
    check_size("filtered with", "{{#with point}}{{x}},{{y}}{{/with}}", context, "1.5,-2", 4);
    check_size("filtered list", "{{#with tags}}x{{/with}}{{scores}}", context, "", 8);
    check_size("filtered name everywhere", "{{#with pet}}{{name}}{{/with}}", context, "Rex", 4);
}
