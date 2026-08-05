# Flix porting notes (verified against Flix 0.75.1)

Every claim below was established by compiling and running real code against the
Flix 0.75.1 toolchain on this machine, not from memory. Treat it as ground truth
and do not re-litigate it; if you find something here that is wrong, fix the note
and say so in your report.

## Toolchain

- `flix` 0.75.1, JVM 25 (GraalVM). Project root is `flix/`.
- `flix check` — typecheck. `flix build` — compile. `flix test` — run `@Test` defs.
- `flix build-jar` — emits `flix/artifact/flix.jar`. The name comes from the
  **project directory** (`flix/`), *not* from `name = "compression"` in
  `flix.toml`; there is no output-path flag. This note previously said
  `artifact/compression.jar`, which is wrong — `build.sbt`'s `flixJar` task has
  always consumed `flix/artifact/flix.jar` and does so successfully. Corrected
  after re-running `flix build-jar` and listing `flix/artifact/`.
- Layout: `flix.toml` at root, sources in `src/*.flix`, tests in `test/*.flix`.
  All `.flix` files in both directories compile as ONE unit; there is no
  per-file compilation. A broken file anywhere breaks the whole build.

## Language facts that bite

### No infix bitwise operators
`>>`, `>>>`, `&`, `|`, `^`, `~` do not exist. `>>>` is not defined at all.
Use the `Bits` module in `src/Bits.flix` (already written and compiling):

| Java              | Flix (`Bits`)      |
|-------------------|--------------------|
| `x << n`          | `Bits.shl(x, n)`   |
| `x >> n`          | `Bits.shr(x, n)`   |
| `x >>> n`         | `Bits.ushr(x, n)`  |
| `x & y`           | `Bits.band(x, y)`  |
| `x \| y`          | `Bits.bor(x, y)`   |
| `x ^ y`           | `Bits.bxor(x, y)`  |
| `~x`              | `Bits.bnot(x)`     |
| same on `long`    | `shlL/shrL/ushrL/bandL/borL/bxorL/bnotL` |
| `1L << sq`        | `Bits.bit(sq)`     |
| `(int) longVal`   | `Bits.toInt(x)`    |
| `(long) intVal`   | `Bits.toLong(x)`   |
| `(byte) intVal`   | `Bits.toByte(x)`   |
| `b & 0xff`        | `Bits.byteToUnsigned(b)` |
| `(char) intVal`   | `Int32.truncateToChar(x)` |
| `(int) charVal`   | `Char.toBmpCodePoint(c)` |

`Int32.logicalRightShift` / `Int64.logicalRightShift` take a *named* argument:
`Int32.logicalRightShift(dist = n, x)`. `Bits` already wraps this.

`Char.fromInt32` / `Char.toInt32` / `Char.ordinal` / `Char.fromOrdinal` do **not**
exist (confirmed against <https://api.flix.dev/Char.html>, which lists
`toBmpCodePoint` as the only Char->Int32 conversion). Java's `(sq + 'a')` idiom in
`Move.uci` and `Encoder.san` is therefore
`Int32.truncateToChar(Square.file(sq) + Char.toBmpCodePoint('a'))`.

### `Int32.abs` is NOT Java's `Math.abs`
`Int32.abs` and `Int64.abs` return **-1** when the magnitude would exceed
`maxValue`, i.e. `Int32.abs(Int32.minValue()) == -1`, whereas Java's
`Math.abs(Integer.MIN_VALUE)` wraps to `Integer.MIN_VALUE`. Verified by running:

```flix
Int32.abs(Int32.minValue())  // -1        (Java: -2147483648)
Int64.abs(Int64.minValue())  // -1
Int32.abs(-5)                // 5
```

Anywhere the port must reproduce Java `int` arithmetic exactly, hand-roll it —
`if (x < 0) 0 - x else x` wraps like Java, because `0 - Int32.minValue` overflows
back to `Int32.minValue`.

There is exactly **one** such definition in the port: `Bits.absInt`. It used to be
duplicated as a private `absInt` in both `Square.flix` (for `Square.distance`) and
`Board.flix` (for `abs(from - to) == 16` in the en-passant test); integration
collapsed them into `Bits.absInt` so the two copies cannot drift apart. Do not
"simplify" it to `Int32.abs` — that is a different function.

### Integer division by zero returns 0 — it does **not** throw

This is the sharpest numeric divergence found, and it is a *silent wrong answer*
rather than a differently-typed abort. Verified by compiling and running a probe
against Flix 0.75.1:

```flix
let a = 7;    let z = 0;
a / z                      // 0   (Java/Scala: ArithmeticException "/ by zero")
Int32.remainder(a, z)      // 0   (Java/Scala: ArithmeticException)
7i64 / 0i64                // 0   (Java/Scala: ArithmeticException)
Int64.remainder(7i64, 0i64)// 0
```

A port of Java or Scala code that relies on a division by zero to fail loudly —
a guard, a validity check, a "this cannot happen" — will instead compute with a
zero and carry it forward. Nothing in the type system flags it.

**It is unreachable in this port**, and that was checked rather than assumed:
stripping `//` and `///` comments from all seventeen modules in `flix/src` leaves
zero occurrences of `/`, `rem`, `remainder`, `%`, `Int32.div` or `Int64.div` as
operators (the only surviving hits are `/* ... */` block comments beside the
signed-decimal bitboard literals in `Board.flix`). The same scan over
`src/main/scala/` also finds none — the original is pure shifts, masks and adds.
So the divergence exists but this library never touches it. Re-run that scan
before adding arithmetic to any module here.

### Reserved words
`and`, `or`, `xor`, `not`, `run`, `discard`, `from`, `def`, `mod`, `new`, `region`
are keywords and cannot be used as identifiers. This already forced
`Bits.band`/`bor`/`bxor`/`bnot`.
Watch for `run` — a natural name for perft/driver helpers.
**`discard` is also reserved** (`Hint: 'discard' is a keyword`, verified by compile
failure), which forced `Board.discard` -> `Board.discardAt`.
**`from` is also reserved.** `pub def from(x: Int32): Int32 = x + 1` fails with
`Parse Error [E6405] Expected at least one <Ident>` followed by
`Parse Error [E6629] ... Hint: 'from' is a keyword` (verified by compile failure,
then success after renaming). `to` is **not** reserved. This is why the Scala
`Move.from`/`Move.to` fields are `Move.fromSq`/`Move.toSq` throughout the port.

### Doc-comments are illegal on struct fields
A `///` comment inside a `struct` body is `Parse Error [E6289] Misplaced
doc-comment(s)`, and the parser then fails to recover (`Expected '}' before <name>`).
Only declarations take doc-comments; document a struct's fields in the doc-comment
of the struct itself. Verified by compile failure on `struct Board`.

### Literals
`0i8`, `0i16`, `0`, `0i64` for `Int8`/`Int16`/`Int32`/`Int64`. An unsuffixed
integer literal is `Int32`. Long masks must be written `0xffL`-style as
`0xffi64`. Negative long: `-1i64`.

**A hex `Int64` literal with the high bit set is rejected** — `0x8100000000000081i64`
is a `Malformed int literal ... value out of bounds` error, even though Java accepts
`0x8100000000000081L`. Flix parses the digits as a magnitude and checks it against
`Int64.maxValue`, so any constant `>= 2^63` must be written as its signed decimal
with the hex in a comment:
`-9151314442816847743i64 /* 0x8100000000000081 */`. This bites hard on Zobrist keys
and on any table of 64-bit masks; `Magic.flix` happens to be all-positive and is fine.

**A unary minus in front of a hex literal is *always* rejected**, whatever the
magnitude: `-0x10`, `-0x10i64` and `-0x1000000000000i64` (2^48, comfortably in
range) all fail with `Malformed int literal`. Write the negative in decimal
(`-16`, `-1i64`) or compute it — `0i64 - 0x1000000000000i64` compiles fine.
Verified by compile failure/success, not from memory.

### Structs and mutable state
Flix has `struct`, declared with an explicit region parameter:

```flix
mod Buf {
    pub struct Buf[r: Region] {
        data: Array[Int64, r],
        mut counter: Int32
    }

    pub def mk(rc: Region[r]): Buf[r] \ r =
        new Buf @ rc { data = Array.repeat(rc, 1024, 0i64), counter = 0 }

    pub def at(t: Buf[r], i: Int32): Int64 \ r = Array.get(i, t->data)
}
```

- Field read/write uses `->`: `t->data`, `t->counter = 5`.
- **A struct must live in a module of the same name.** Declaring
  `struct Buf` inside `mod Foo` makes field access fail to resolve
  (`Undefined struct field ... on struct 'Foo'`). This is verified, not folklore.
  Follow the stdlib convention: `mod MutSet { pub struct MutSet[...] }`.
- The rule is stronger than "declare it there": **`t->field` only resolves inside
  the module named after the struct.** Another module cannot write `t->data` for a
  `Buf[r]`, whatever it imports. So every read and write of a struct's fields —
  including the whole builder — must live in that struct's own module, which then
  exports accessor functions. `src/BitOps.flix` is laid out this way
  (`mod BitWriter` owns `struct BitWriter` and every `w->` in the program).
- This constraint used to be a reason to prefer a single-case `enum` for read-only
  data: enum cases are `pub` and can be destructured anywhere, so the type does
  not drag its whole API into one module. **On a hot path that trade is wrong** —
  a single-case enum destructure materialises *every* field on every read, so a
  wide one costs an order of magnitude more than a struct field load. See
  "A single-case `enum` destructure materialises every field" below. Keep the enum
  for cold, narrow data; use a struct for anything wide or hot.
- Fields are immutable unless declared `mut`.
- Mutation of an `Array[a, r]` or a `mut` field carries the region effect `\ r`.
- Reading a non-`mut` field is **pure**, even though the struct is region-allocated.
  A `Vector[Int64]` field is therefore a free constant lookup: `\ r` appears only
  because of the `Array.get` behind it. Flix will reject `\ r` on a signature whose
  body never touches the region (`Unused effect: 'r'`).
  (doc.flix.dev says flatly "Each operation has an effect in the region of the
  struct"; that is a simplification. Re-verified by compiling: a `def` reading a
  non-`mut` field with no declared effect is accepted, and reading a `mut` field
  without `\ r` is not.)

### Prefer immutable `Vector` tables over region `Array` tables

For data that is *written once during construction and only read afterwards* —
which is every precomputed table in this port — do **not** keep it in a region
`Array`. Build it in a local `region rc { ... }`, snapshot it with
`Array.toVector`, and store the `Vector`. The region effect is discharged at the
`region` boundary, so the builder is **pure** and every lookup is **pure**:

```flix
pub enum Tables { case Tables(Vector[Int64], /* ... */) }
mod Tables {
    pub def mk(): Tables = region rc {         // pure!
        let attacks = Array.repeat(rc, 88772, 0i64);
        fill(attacks);                          // \ rc, discharged below
        Tables.Tables(Array.toVector(attacks))
    }
}
```

`src/Bitboard.flix` is built this way. The payoff is large: no `\ r` propagates
into `Board`, `MoveList` or the game encoder, no `Tables[Static]` handle and no
`\ IO` at the `@Export` layer, and no region type parameter to unify with the
`Board`'s own region.

Measured on this machine, 10^8 dependent lookups into an 88772-entry table:

| shape                                   | time    |
|-----------------------------------------|---------|
| `Vector.get` (pure)                      | 428 ms |
| `Array.get` in a region                  | 460 ms |
| struct field holding a `Vector`          | ~= Array |
| single-case enum field holding a `Vector` | ~= struct |
| **extensible record** field (`t#attacks`) | **1470 ms** |

So: `Vector` is not slower than `Array`, and **Flix records are ~3x slower than
structs/enums for field access** — do not use a record as a hot-path table
container, however much nicer the named fields read.

The table above measures a *one-field* container, where enum and struct tie. They
do **not** tie once the container is wide: see "A single-case `enum` destructure
materialises every field" below, which is why `Tables` in this port is a struct.

A `struct` always needs a region type parameter (doc.flix.dev: "Every struct must
have a region type parameter and it must be the last in the type parameter list").
That does **not** force a region-free table to be an enum, and an earlier revision
of this note was wrong to say it did. Build the struct in a local region and cast
the result to `Static`:

```flix
pub struct Tables[r: Region] { attacks: Vector[Int64], /* ... */ }
mod Tables {
    pub def mk(): Tables[Static] = region rc {        // still pure!
        let attacks = Array.repeat(rc, 88772, 0i64);
        fill(attacks);
        let t = new Tables @ rc { attacks = Array.toVector(attacks) };
        unchecked_cast(t as Tables[Static])
    }
}
```

Reading a non-`mut` field is pure, so `mk()` and every accessor keep the exact
signatures the enum version had — no `\ IO`, no region parameter, no effect leaking
into callers. The cast exposes nothing, because the struct has no `mut` field and
never escapes as a mutable thing, and a Flix region frees nothing — a region handle
is an ordinary GC-rooted object, so the value stays valid after `rc` goes out of
scope. `src/Bitboard.flix` is built exactly this way.

### Modules cannot be reopened
`mod Square { ... }` may appear **once in the whole program**. A second block, in
the same file or another one, is `Name Error [E5410] Duplicate module`. There is no
way to add a function to a module owned by someone else's file, so a function that
logically belongs to `Square` but needs a dependency `Square.flix` cannot see has
to be renamed and rehoused. That is why Scala's `Square.aligned(a, b, c)` is
`Bitboard.aligned(t, a, b, c)` in the port: it needs the `RAYS` table.

### `flix check` does not catch the JVM 64 KB method limit

`flix check` is a typecheck only. Code generation can still fail, and the failure
mode you will actually hit is

```
org.objectweb.asm.MethodTooLargeException: Method too large:
  TestBoard/Clo$testHasLegalEnPassant$414588.applyFrame (...)
```

emitted by `flix build` / `flix test` *after* a completely clean `flix check`.
Verified on a `@Test` body that was nothing but eleven statements of the shape
`Assert.assertTrue(has(somePosition()))`. A `@Test` def has effect `Assert`, so
Flix compiles the body into a resumable continuation frame (`applyFrame`), and
that representation blows past 64 KB far sooner than the source suggests —
eleven effectful statements was enough. `@DontInline` on the called helper did
**not** help; the cost is in the frame, not in inlining.

The fix that works is to stop writing the cases as statements and make them
data: put the cases in a `List` and fold over them with a single assertion at
the end.

```flix
def check(cases: List[(String, Pos, Bool)]): Unit \ Assert = {
    let failures = List.filterMap(c -> {
        let (name, p, expected) = c;
        if (f(p) == expected) None else Some("${name}: expected ${expected}")
    }, cases);
    Assert.assertEq(expected = (Nil: List[String]), failures)
}
```

That is one effect operation instead of N, it keeps the method small no matter
how many cases there are, and it reports *every* failure rather than stopping at
the first. `test/TestBoard.flix` and `test/TestBitboard.flix` are written this
way for exactly this reason. Note that a run of `Assert.assertEq` calls on
*pure* arguments is fine at 25-30 statements (`TestBitboard.testLeaperTables`);
the limit is reached quickly, but not immediately.

### A pure expression in statement position is an error
`Redundancy Error [E8956] Useless expression: It is pure and its result is
discarded.` This makes the direct translation of a Scala `assert(...)` illegal,
because `bug!` is pure. Fold the check into a value instead:

```flix
let checked = if (bad) bug!("...") else value;
Array.put(checked, idx, arr)
```

`bug!("msg")` itself works, is pure, and unifies with any type.

### Regions
`region rc { ... }` scopes mutable state; the effect is discharged at the block
boundary so the block can be pure. `Static` is the global-lifetime region, used
for data that must outlive any block — but touching it costs `\ IO`.

Reach for `Static` only when a *mutable* structure genuinely has to outlive every
`region` block. Read-only precomputed data is not that case: snapshot it to
`Vector` inside a local region instead (see above). The only `Static` in this port
should be whatever the `@Export` layer must hand to Java as a live `Object`
handle, and even that is unnecessary for `Tables`, which is region-free.

### No global mutable state, no memoization
There is no `@Memoize`. A top-level `def` is recomputed on every call, so the
precomputed tables (`Bitboard.ATTACKS` is 88772 longs, plus `BETWEEN`/`RAYS`
64x64) **cannot** be a zero-arg `def` that callers hit per lookup — that would
rebuild them per call. The design is: build the tables once into an immutable,
region-free `Tables` value (see "Prefer immutable `Vector` tables" above) and
thread that value through every function that needs it. The Scala-facing layer
builds it once and caches it in a `lazy val`.

Note that `Tables.mk()` is *pure*, so nothing in the type system stops you from
calling it in a loop. It costs ~65-100 ms. Call it once, per process.

### The static-data layout, and why it is two levels and not one

There are four independent precomputed values in the port:

| value                    | built by                | lives in       |
|--------------------------|-------------------------|----------------|
| `Tables` (attacks, rays) | `Tables.mk()`           | `Bitboard.flix`|
| `Psqt`                   | `Psqt.mk()`             | `Move.flix`    |
| Polyglot keys            | `ZobristHash.polyglot()`| `ZobristHash.flix` |
| `Huffman.HuffmanTable`   | `Huffman.mkTable()`     | `Huffman.flix` |

They are bundled by `GameTables.mk()` (in `GameEncoder.flix`) into a single
region-free `GameTables` value that the caller builds once and threads. That is
the "one static-data value" the earlier phases kept asking for.

Integration considered collapsing all four *into* `Tables` itself and rejected it,
for a concrete reason rather than taste: **`Psqt` is declared in `Move.flix`, and
`Move.flix` already depends on `Tables`** (its `MoveCtx` holds one). Folding `Psqt`
into `Tables` would make `Bitboard.flix` and `Move.flix` mutually dependent. It
would also force every consumer that only wants move generation — including
`TestBitboard` — to build the Huffman tree and the piece-square table it never
reads. Two levels (four independent pieces, one bundle) keeps the layering acyclic
and the pieces independently constructible; `GameTables` is the single thing an
application holds.

Verified: no table is rebuilt on a hot path. `Tables.mk`, `Psqt.mk`,
`ZobristHash.polyglot` and `Huffman.mkTable` are each called only from
`GameTables.mk` and from test setup — never inside `encode`, `decode`, `play` or
move generation.

Available annotations: `@Test`, `@Export`, `@Lazy`, `@Skip`, `@Inline`,
`@DontInline`, `@Parallel`, `@ParallelWhenPure`, `@Deprecated`, `@Experimental`,
`@Terminates`, `@TailRecursive`. There is no `@Memoize` and no `@Export` on
zero-arg functions.

### Tests
```flix
@Test
pub def testFoo(): Unit \ Assert =
    Assert.assertEq(expected = 2147483647, Int32.logicalRightShift(dist = 1, -2))
```
- A `@Test` def takes **no parameters** and must return `Unit`, with effect
  `Assert`, `IO`, or both. Returning `Bool` is rejected.
- The assertion API is `Assert.assertEq(expected = ..., actual)`,
  `Assert.assertTrue`, `Assert.assertFalse`, `Assert.assertSome`, `Assert.fail`,
  etc. There is no bare `Assert.eq`.
- `expected` is a *named* argument; the actual value is positional.

### `flix build-jar` ships your tests — from `src/` *and* `test/`

Verified by building `artifact/flix.jar` and listing it: the jar contains
`TestBitboard.class` and `TestBoardPerft.class` (which live in `test/`) alongside
`TestBitOpsSelf.class`, `TestClockEncoderSelf.class`, `TestGameEncoderSelf.class`,
`TestHuffmanSelf.class` and `TestZobristHashSelf.class` (which live in `src/`).
All seven were re-confirmed present in a clean-build jar, which carries **710**
`Test`-matching entries out of 1744 once the generated closure and continuation
classes are counted. (An earlier revision said 1167 of 2485; see the jar-size
caveat two sections below — that count came from a build with history behind it.)

So **putting a `@Test` module in `test/` does not keep it out of the artifact.**
`src/` vs `test/` is an organisational distinction only; there is no `provided`/
`test` scope the way sbt or Maven has one. Earlier review passes recommended
relocating the in-`src/` self-test modules "so they do not compile into the
shipped jar" — that reasoning is wrong, and the modules were therefore left where
their authors put them. If a release jar must be test-free, strip the `Test*`
classes at packaging time (or shade), which is the same step the default-package
hazard below already forces.

That strip is now wired up: `sbt flixReleaseJar` copies `artifact/flix.jar` to
`artifact/flix-release.jar` and deletes the `Test*` entries. On a clean build that
is **710 of 1744 class entries**, taking the jar from **2.0 MB to 0.8 MB**. The
full differential suite was re-run against the stripped jar (copied over
`flix.jar` so `difftest` actually loads it) and still passes at 25 examples / 0
failures, so nothing outside the `Test` modules depends on them.

### `flix/build/` accumulates stale classes — clean it before measuring or releasing

`flix build-jar` packages whatever is sitting in `flix/build/`, and that directory
is **not** pruned when a module is renamed or deleted. During this port the
directory was built repeatedly by many agents: the resulting jar was 18.5 MB with
13762 class entries at one point and 23 MB after the four gap-closing agents. After
`rm -rf flix/build flix/artifact` the very same sources produced a **2.0 MB jar
with 1744 entries**.

It is not only deleted modules. Flix names generated closures with a **fresh
counter on every compilation** (`PerftSweep/Clo$main$445803.class`), so even an
unchanged source file contributes a new set of closure classes on each pass and
the old ones stay. Measured on identical sources: one `flix build-jar` from clean
gives 1744 entries / 2.0 MB, whereas `rm -rf` → `flix build` → `flix test` →
`flix build-jar` gives 3658 entries / 4.7 MB.

All of these jars pass the full differential suite, so this is dead weight rather
than a correctness hazard, but it means:

* jar sizes quoted from an incremental build are meaningless — earlier notes in
  this file and in the review reports cite 12 MB, 19 MB and "3.0 MB / 2485
  entries", and all were measuring builds with history behind them;
* two clean measurements of the *same* sources can still differ slightly (1733 vs
  1744 entries across this round) as the export surface changes;
* a release build must start from a clean `flix/build/`.

## Java / Scala interop — verified working

`@Export` compiles a `pub def` to a `public static final` method on a class named
after its enclosing module, in the **default package**:

```flix
mod Api {
    import java.lang.Object

    @Export
    pub def newTables(_ignored: Int32): Object \ IO =
        unchecked_cast(Tables.mk() as Object)

    @Export
    pub def encode(handle: Object, input: Object): Object \ IO =
        let t: Tables = unchecked_cast(handle as Tables);
        let arr: Array[Int32, Static] = unchecked_cast(input as Array[Int32, Static]);
        ...
        unchecked_cast(out as Object)
}
```

produces `public final class Api { public static final java.lang.Object encode(java.lang.Object, java.lang.Object); }`.

Hard constraints, all verified:

1. **Exported signatures may only use** `Bool`, `Char`, `Int8`, `Int16`, `Int32`,
   `Int64`, `Float32`, `Float64`, and `java.lang.Object`. Arrays, structs,
   `String`, `Option`, and tuples are **not** exportable. Pass them as `Object`
   and `unchecked_cast` on both sides.
2. **No zero-argument exports.** `Unit` is not an exportable parameter type, so
   every exported function needs at least one real parameter. Add an ignored
   `Int32` if there is nothing natural to pass.
3. Java types are written bare (`Object`, not `##java.lang.Object`) and need an
   `import java.lang.Object` inside the module.
4. `Array[Int8, Static]` round-trips to a Java `byte[]`, `Array[Int32, Static]`
   to `int[]`. Cast with `unchecked_cast(x as Array[Int32, Static])`.

### The default-package hazard — this must be documented for users

Flix emits **all** of its classes into the default (unnamed) package, including
classes literally named `Object`, `String`, `Map`, `Array`, `List`, `Set`,
`Option`, `Iterator`, `Chain` and `Assert`. A clean-build jar for this project has
**363** such top-level classes. Flix also emits a same-named *directory* beside
every module class (`Api.class` **and** `Api/Def$gameEncode.class`), which matters
as much as the class names do.

Two *different* failures follow — conflating them leads to the wrong fix:

* **Java** source in the unnamed package resolves bare `String` to Flix's `String`.
  A `main(String[] args)` compiled that way becomes `main([LString;)V` and the JVM
  refuses to start it.
* **Scala** source in *any* package loses those names in **term** position:
  `Array("e4")` fails with `package Array does not take parameters`, because the
  same-named package outranks `scala.Array`'s companion. Type positions
  (`Array[Byte]`) are unaffected, so the breakage is partial and confusing.

The second failure also means **a Scala facade cannot reach `Api` at all**, however
it spells its types: no named-package source may reference the unnamed package
(Scala says `Not found: …`), and the `Api/` directory makes Scala resolve `Api` to
a package, so even `_root_.Api.newTables` fails with `value newTables is not a
member of Api`.

**Shading does not help** — relocating preserves the class/package name collision
that makes the class unnameable. What works is containment by classpath scoping:
keep the jar off every Scala compile classpath and give it exactly one Java-only
consumer in the unnamed package, which writes every JDK type as `java.lang.X`.

Two measurement caveats, both learned the hard way:

* Earlier revisions of this file said "~19 others" and a review report said 145,
  naming `Probe` and `Main` among them. Those were measured on stale incremental
  builds; `Probe` and `Main` are **not** in a clean-build jar (they came from
  scratch files compiled during development). Clean the build before counting.

### Throwing a Java exception from Flix — and why `bug!` is not one

`bug!` is **not** a Flix-flavoured `IllegalArgumentException`. From
`Prelude.flix:158-166` it expands to `unsafe IO { ...six stderr lines...; ?panic }`,
and `?panic` throws `dev.flix.runtime.HoleError$`. Verified with `javap` against a
built `flix.jar`:

```
public final class dev.flix.runtime.HoleError$ extends dev.flix.runtime.FlixError$
public abstract class dev.flix.runtime.FlixError$ extends java.lang.Error
```

So `bug!` throws a **`java.lang.Error`**, which `catch (Exception e)` — and Scala's
`case e: Exception` — does not catch. If your port replaces a Scala `require` with
`bug!`, a caller's error branch silently stops running. It also prints a six-line
`** BUG:` banner to stderr first, which is not something a library should do.

The idiom for raising a real Java exception is the standard library's own
(`Prelude.flix:176-178`, `indexOutOfBounds!`):

```flix
unsafe IO { throw new IllegalArgumentException("requirement failed") }
```

Four facts about it, all verified by compiling:

- **It changes no signature.** `unsafe IO { ... }` discharges the `IO` effect at
  the expression, so a `def f(...): T \ r` that throws this way still declares
  `\ r`. This is why "adding an error effect would change `decode`'s signature" is
  not a reason to leave the exception types diverging.
- **A qualified name inside `new` is a parse error.** Write
  `import java.nio.BufferUnderflowException` at the top of the module and then
  `new BufferUnderflowException()`. `new java.nio.BufferUnderflowException()` does
  not parse.
- **A bounds guard is free of effects.** `Array.length` is the intrinsic
  `%%ARRAY_LENGTH%%` (`Array.flix:144`) and is **pure** — one `arraylength`
  instruction — so `if (i >= Array.length(a)) unsafe IO { throw ... } else ...`
  adds a compare, not an effect.
- **There is no `throws` clause on the generated method.** `javap` on the exported
  `Api` shows
  `public static final java.lang.Object gameDecode(java.lang.Object, java.lang.Object, int)`
  with no `throws`. Unchecked exceptions are unaffected, but a **checked**
  exception thrown out of Flix is uncatchable from Java by declaration: javac
  rejects `catch (SomeCheckedException e)` as "never thrown in the corresponding
  try block". Throw unchecked exceptions across this boundary.

Related, when reading the standard library: `Vector.get` is overloaded on argument
order and the two have different contracts. `Vector.get(t, i): a \ OutOfBounds`
(`Vector.flix:25`) is checked; `Vector.get(i, v): a` (`Vector.flix:229`) is the
**unchecked** intrinsic `%%VECTOR_GET%%` and raises a plain
`java.lang.ArrayIndexOutOfBoundsException`, exactly as a Java array access would.

## Working end-to-end example

This is implemented, not speculative. `flix/src/Api.flix` is the `@Export` layer
(11 functions), and the chain that reaches it is:

```
Scala caller
  → org.lichess.compression.flix.{clock,game}.Encoder   (scala-api/, Scala)
  → org.lichess.compression.flix.FlixCodec              (flix-bridge/, Java, named package)
  → LichessFlixCodec                                    (flix-bridge/, Java, UNNAMED package)
  → Api                                                 (flix.jar, UNNAMED package)
```

`LichessFlixCodec` is loaded once via `Class.forName`; every call after that is a
plain `invokeinterface`. `build.sbt` filters `flix.jar` out of every Scala
`dependencyClasspath` (`hideFlixJar`) and adds it back only at runtime.
`sbt difftest/test` exercises the whole chain against the original Scala
implementation in the same JVM.

A genuine Java `null` is producible from Flix, which is what lets the facade keep
the original's null-returning signatures: `Array.empty(Static, 1)` compiles to
`new Object[1]`, so `Array.get(0, holder)` is a real null.

## Perft corpus and sweep

Everything here was established while building `flix/test/PerftSweep.flix`,
`flix/test/TestPerftSweep.flix` and `scripts/perft-sweep.sh`. It is the Flix
mechanics only; what the sweep *proves* is in `REWRITE.md` §4.3.

### There is no test filter, and `@Skip` cannot be un-skipped from the CLI

`flix --help` lists the complete option set for 0.75.1 and there is nothing that
selects a subset of `@Test` defs — no `--test`, no name pattern, no tag. `flix
test` runs every `@Test` in the project, and a `@Skip`ped test can only be enabled
by editing the source. **Do not design a "gated expensive test"**: the gate cannot
be opened by whoever needs it. An expensive tier has to be a separate entry point
(here, `PerftSweep.main` behind `scripts/perft-sweep.sh`) reached by
`flix run`/`java -jar`, not a `@Test`.

### `--entrypoint` is mandatory for a mod-scoped `main`, and a bare `flix run` silently does nothing

```
flix run --entrypoint PerftSweep.main            # runs it
flix run --entrypoint PerftSweep.main -- a b     # arguments need a bare `--`
flix run                                         # exits 0, prints nothing, runs nothing
```

That last line is the trap: with a mod-scoped `main` and no top-level `main`, a
bare `flix run` is a **silent no-op that exits 0**. Nothing warns you.

### Mod-scoped vs top-level `main` changes what `flix build-jar` produces

- `mod PerftSweep { pub def main() ... }` — a bare `flix build-jar` produces
  exactly the artifact it produced before the module existed: manifest
  `Main-Class: Main`, and **no `Main.class` entry** (which is already true of this
  repository's jar). `build.sbt`'s `flixJar` task and `difftest` are therefore
  completely unaffected by adding one.
- A **top-level** `pub def main()` DOES emit a `Main.class`, changing what
  `java -jar flix/artifact/flix.jar` does.

So: put an executable entry point in a `mod`, always.

`flix build-jar` also always writes `flix/artifact/<project-directory>.jar`, i.e.
`flix/artifact/flix.jar`, with no way to redirect it. `flix build-jar --entrypoint
…` therefore *overwrites the library jar* with one that carries a `Main.class`.
`scripts/perft-sweep.sh` copies it to `artifact/perft-sweep.jar` and then deletes
`artifact/flix.jar` so the next `sbt difftest/test` rebuilds a clean library jar.
`flix/artifact/` is gitignored, so there is no VCS consequence either way.

### `--entrypoint` POISONS `flix/build/`, and deleting the jar is not enough

This one cost real time and is not in any documentation. `--entrypoint` does not
only affect the jar; it emits **`flix/build/class/Main.class`**. And `flix/build/`
is never pruned — `flix build-jar` packages whatever is sitting in it (see
"`flix/build/` accumulates stale classes" above). So after a single
`flix build-jar --entrypoint …`, *every later bare* `flix build-jar` — which is to
say every `sbt difftest/test`, every `sbt benchmarks/*`, every CI run in that
working tree — emits a "library" jar containing `Main.class`. The manifest already
says `Main-Class: Main`, so `java -jar flix/artifact/flix.jar` silently stops being
a no-op and starts running your entry point.

Measured in this repository:

| build/ state | bare `flix build-jar` output |
|---|---|
| clean (`rm -rf build artifact`) | 1733 class entries, 1.9 MB, **no** `Main.class` |
| after one `--entrypoint` build | contains `Main.class` (866 bytes) |
| after `rm -f build/class/Main.class` | **no** `Main.class` again |

Hence `scripts/perft-sweep.sh` deletes `build/class/Main.class` as well as
`artifact/flix.jar`. A mod-scoped `main` is still the right choice — it keeps the
*sources* from changing the default artifact — but it does not protect you from the
build directory.

Related and worth knowing when you read jar sizes: rebuilding the **same,
unchanged** sources appends new classes rather than replacing them, because Flix
names generated closures with a fresh counter each compilation
(`PerftSweep/Clo$main$445803.class` and friends). A clean build here gives 1733
class entries; the same sources built a second time on top gave 3761. Any jar-size
or entry-count figure that did not start from `rm -rf flix/build flix/artifact` is
meaningless.

### Effects belong on the `@Test` signature; `@DefaultHandler` discharges them

A `@Test` is an entry point, and Flix discharges an effect at an entry point if the
effect's module carries a `@DefaultHandler`. So this works:

```flix
@Test
pub def testCorpusDepth2(): Unit \ Assert + IO + Fs.FileRead.FileRead = ...
```

and this does **not** — declaring only `Assert + IO` and then calling
`Fs.FileRead.readLines` gives, verbatim:

```
-- Type Error [E6216] ------------------------------------------ test/TestE.flix

>> Unexpected effect 'FileRead' in function declared as {'{Assert, IO}'}.
```

(and, amusingly, an accompanying `E6217 Unused effect: 'IO'`, because once the
`FileRead` call is rejected nothing in the body uses `IO`). The effect named
depends on which one you reached for — `Sys.Env.getVar` reports `'Env'`, and so on
— but the code is always E6216.

Do **not** wrap the body in `Fs.FileRead.runWithIO(...)`; the default handler
already does it, and the wrapper only obscures the signature.

The effects with a `@DefaultHandler`, all used by `PerftSweep`:

| operation | effect to declare |
|---|---|
| `Fs.FileRead.readLines` / `read` / `readBytes` | `Fs.FileRead.FileRead` |
| `Sys.Env.getVar` / `getArgs` / `getProp` | `Sys.Env.Env` |
| `Sys.Exit.exit` | `Sys.Exit.Exit` |

**Use `Fs.FileRead` directly, not `Fs.ReadLines`.** `Fs.ReadLines` has no
`@DefaultHandler`, so it cannot be discharged at a `@Test` at all.
`Fs.FileRead.readLines(path)` returns `Result[IoError, List[String]]` — it does not
throw, and a missing file comes back as `Result.Err`. A driver that shrugs that off
yields **zero rows and a green test that checked nothing**, so assert the row count
before asserting anything computed from the rows.

### Numeric conversions and literals used here

- `Int64.toInt32` does **not** exist. It is `Int64.tryToInt32: Int64 -> Option[Int32]`.
- `Int64.fromString` and `Int32.fromString` return `Option`, and there is no radix
  form — decimal only. Combined with §2.6 (Flix rejects an `Int64` hex literal with
  the top bit set) this means **every bitboard in a data file must be a signed
  decimal**. `java.lang.Long.parseLong` reads the identical text, which is what
  lets the Scala and Flix drivers share one corpus file.
- No infix bitwise operators, as above: the checksum mixer is spelled with
  `Bits.shlL` / `Bits.borL` / `Bits.bandL` / `Bits.bxorL`.

### The test runner: cwd, ordering and buffering

- During `flix test` the working directory is the **Flix project root** (`flix/`),
  verified by printing `user.dir` from inside a `@Test`. Hence the corpus path
  `test/data/perft-corpus.csv`.
- Tests run in **name order**, and no two tests' output interleaves — observed
  across every run of the 126-test suite while adding this. (That is consistent
  with a single-threaded runner but does not prove one; do not rely on tests
  sharing process state either way.)
- It **buffers a test's stdout until the test completes**, then prints it attached
  to the test's line — e.g.
  `TEST TestPerftSweep.testCorpusDepth2[perft] flix depth2 rows=…`, with the
  test's own output run together with the runner's banner. Progress output from
  inside a long `@Test` is therefore useless: it all appears at the end anyway.
  `PerftSweep.sweep` takes a `progress` flag for exactly this reason — `main` sets
  it, the `@Test` does not.

## Benchmarking a Flix port from JMH

Everything here was established while wiring `benchmarks/` to measure the port
against the original. The results are in `benchmarks/results.md`; this is the
mechanism.

### The sbt wiring, in full

```scala
lazy val benchmarks = (project in file("benchmarks"))
  .settings(
    ...,
    hideFlixJar,                                                  // compile: OFF
    Jmh / dependencyClasspath += Attributed.blank(flixJar.value)  // run: ON
  )
  .dependsOn(root, scalaApi)
  .enablePlugins(JmhPlugin)
```

Three things about it are not obvious.

- **`hideFlixJar` is mandatory, and a JMH project is the worst case for it.**
  `@BenchmarkMode(Array(Mode.AverageTime))` is the required JMH idiom — an
  annotation argument of array type has to be written that way — and it is exactly
  what the default-package hazard breaks. Delete the line and every benchmark file
  fails with `package Array does not take parameters`. At least it fails loudly.
- **The run classpath hook is `Jmh / dependencyClasspath`, not
  `Runtime / unmanagedJars`.** sbt-jmh 0.4.7 sets
  `Jmh / dependencyClasspath := (Compile / dependencyClasspath).value` and never
  reads `Runtime`. Verified by `print`: on the unmodified build the `Jmh` and
  `Compile` classpaths were element-for-element identical. A `Runtime` entry is
  invisible to `Jmh / run`, and the symptom is a `ClassNotFoundException` for
  `LichessFlixCodec` inside `@Setup`, not a build failure.
- **Regression test for both directions**, cheap enough to run every time:

  ```
  sbt 'print benchmarks/Compile/dependencyClasspath' | grep -c 'flix\.jar'   # 0
  sbt 'print benchmarks/Jmh/dependencyClasspath'     | grep -c 'flix\.jar'   # 1
  ```

- **`@Param` on a Scala `var` works.** JMH 1.37's generated harness sets it with
  `getDeclaredField(...)` + `setAccessible(true)`, not with a field write, so
  Scala's private backing field is not a problem.

### Static tables must be forced out of the measured region

Flix has no memoization and no global mutable state, so precomputed tables are
built by whoever calls first. If that is a measured invocation, you are timing
table construction. Measured on this port with `Mode.SingleShotTime`, two classes
differing by exactly one line in `@Setup` (`benchmarks/.../SetupPlacementBench.scala`),
over three runs of the identical command:

| run | tables built inside the timed region | tables forced in `@Setup(Level.Trial)` |
|---|---:|---:|
| 1 | 209.095 ± 10.340 ms/op | 46.730 ± 2.169 ms/op |
| 2 | 140.346 ±  5.907 ms/op | 42.892 ± 2.869 ms/op |
| 3 | 143.438 ±  5.365 ms/op | 42.413 ± 2.470 ms/op |

**Roughly 100 ms moved out of the score by placement alone**, and the reported
score more than triples without it. Note the spread on the unforced side: it is a
single shot of one-time construction in a cold JVM, so it is the most
machine-state-sensitive figure in this file. The *forced* side is stable. Quote the
effect, not a number, and re-run the A/B on the machine you care about.

If the cache lives in a Scala `lazy val` that is `private[...]`, the only way to
force it is one throwaway call through the public API. Write a comment saying so;
it looks exactly like dead code.

Do not then pretend that ~100 ms does not exist. Measure it in a separate
`Mode.SingleShotTime` benchmark with `@Warmup(iterations = 0)`,
`@Measurement(iterations = 1)` and many `@Fork`s — and put each implementation in
its **own class**, because a fork that touches both measures neither: whichever
runs second finds the JVM warm and the tables built.

### Timing pure Flix code with `nanoTime` reports ~0 ms

A pure `let`-bound call is **not evaluated at its binding site**. Bracketing it
with two `System.nanoTime` calls therefore reports a few microseconds for work that
takes seconds. Reproduced independently twice while trying to time the perft sweep
from inside Flix.

Force it with a real data dependency the effect system cannot reorder — consume the
value inside the timed region, or make the timed region `IO` and print/accumulate
the result before reading the second clock.

### There are no optimisation flags

`flix --help`'s experimental `--X` set is, in full:

```
--Xbenchmark-code-size  --Xbenchmark-incremental  --Xbenchmark-phases
--Xbenchmark-frontend   --Xbenchmark-throughput   --Xlib <nix|min|all>
--Xno-deprecated        --Xprint-phases           --Xsummary
--Xsubeffecting <value>
```

Every one of those is a **compiler** diagnostic — the `--Xbenchmark-*` family
benchmarks the *compiler*, not your program. There is no `-O`, no inliner
threshold and no way to disable the `Thunk$`/`Suspension$` trampoline.

**Every tuning lever is source-level**, and the next section is the list of them.
That is not as limiting as it sounds: applying them to this port turned a codec
that was 5x slower than its Scala original into one that is faster.

### Two forks is not enough for the REFERENCE side, and the failure flatters you

A Flix-versus-reference benchmark publishes a ratio, so the reference is the
denominator of every number you report — and it is the side nobody watches, because
it is not the code being changed.

On the final verification run of this port, `FlixGameBench.scalaDecode` (short band)
came in at 231.758 ± **70.786** µs against a previous run's 186.793. The per-fork raw
data says exactly what happened:

```
scalaDecode short   fork 0 [187.7, 187.1, 187.5, 187.1, 187.4]
                    fork 1 [278.7, 277.8, 274.7, 275.2, 274.4]
```

Fork 0 reproduces; fork 1 picked up a compilation plan ~48% slower and held it, flat,
for all five iterations. The Flix rows in the same JVM were tight. At `-f 2` that one
fork moves the *published* ratio from 0.796x to **0.647x** — a 0.15x improvement that
does not exist, in the direction that makes the port look good. At `-f 6` it averages
out and the control drifts by 1.4%.

Three rules follow. **Check the reference side's drift against the previous run before
believing any ratio**, and treat a material move as invalidating the comparison rather
than as background noise. **Read `rawData` per fork, not just the score and error bar**
— a bimodal fork pair produces a large `scoreError` that looks like ordinary variance
and is not. And **raise `-f` until the control reproduces**: for this suite that is
`-f 6` on the game benchmarks, where `-f 2` suffices for the clock ones. Allocation is
the opposite case and is worth knowing as a contrast: `gc.alloc.rate.norm` on the
reference side reproduced **to the byte** across three separate runs on this machine,
which makes it the most sensitive available check that the fixtures and the JVM really
are the same.

## Making Flix fast — mechanisms verified in bytecode

Everything in this part was established by compiling a probe and reading `javap`
output, and every claim was then applied to this port and measured with JMH.

The campaign it comes from took a port that was **uniformly 2.7-5.4x slower than
the Scala original** to one that beats it on **ten of the twelve throughput rows**
— game encode 0.774/0.827/0.915x, game decode 0.796/0.858/0.953x, clock decode
0.775/0.786/0.768x — with cold start at 0.555x and the depth-4 perft sweep at 80 s
against Scala's 161.3 s, all without changing an emitted byte. The two throughput
rows it does **not** win are clock encode (1.17-1.27x), and that row plus the clock
encode allocation rows are a property of Flix's `@Export` boundary rather than open
work; see "Every `@Export`ed def costs 64 bytes a call". Final verified figures are
in `benchmarks/results.md`; `REWRITE.md` §5.8-5.9 is the narrative.

Read this before optimising anything. Most of the items below are invisible in the
source and none of them is in the language documentation.

### `java.lang` statics on the boxed primitives are PURE — this is the escape hatch

A method on `java.lang.{Boolean, Byte, Character, Double, Float, Integer, Long,
Number, Short}` can be called from a pure `def`: no `unsafe` block, no `IO` effect,
no signature change. The compiler enforces this rather than merely permitting it —
wrapping such a call in `unsafe IO` is a **compile error**:

```
-- Redundancy Error [E7623] --
>> Redundant unsafe block, the expression is pure.
   pub def ntzUnsafe(x: Int64): Int32 = unsafe IO { Long.numberOfTrailingZeros(x) }
Explanation: The block unsafely removes the 'IO' effect, but the body expression is pure.
```

That matters because **Flix's own numeric standard library is often much slower
than the `java.lang` method of the same name**, and swapping in the Java one costs
nothing structurally. Verified by disassembling both forms of the same def:

```flix
pub def ntz(x: Int64): Int32 = Long.numberOfTrailingZeros(x)   // java.lang
pub def ntzStd(x: Int64): Int32 = Int64.numberOfTrailingZeros(x)  // Flix stdlib
```

```
ntz     ->  lload_0
            invokestatic java/lang/Long.numberOfTrailingZeros:(J)I   <- the intrinsic

ntzStd  ->  new           Int64/Def$numberOfTrailingZeros           <- a heap continuation
            dup; invokespecial <init>; putfield arg0; areturn        <- handed to the trampoline
```

`Int64.numberOfTrailingZeros` delegates to `lowestOneBitPosition` and then to
`oneBitPositionHelper`, which is a **recursive scan testing one bit at a time**,
each step a shift plus a `remainder`, through `Int64.getBit` — whose `pos` argument
is a named record, so each iteration also allocates. Java's is one `TZCNT`. In a
bitboard port `lsb` runs once per set bit of every bitboard iterated in move
generation, so this one substitution was the single largest win in this repository.

The replacements this port uses, all verified equivalent by exhaustive or
multi-million-input probes before being applied:

| Flix standard library | what it actually compiles to | pure `java.lang` replacement |
|---|---|---|
| `Int64.numberOfTrailingZeros` | recursive per-bit scan | `Long.numberOfTrailingZeros` (TZCNT) |
| `Int64.numberOfLeadingZeros` | recursive per-bit scan | `Long.numberOfLeadingZeros` (LZCNT) |
| `Int64.truncateToInt32(x)` | `Long.valueOf(x).intValue()` — allocates | `Long.hashCode(x & 0xffffffffL)` |
| `Int8.toInt32(b)` | `Byte.valueOf(b).intValue()` | `Byte.toUnsignedInt(b)` |
| `Int32.toInt64(x)` | `Integer.valueOf(x).longValue()` | `Integer.toUnsignedLong(x)` (zero-extending) |
| `Char.toBmpCodePoint(c)` | `Short.valueOf(..).intValue()`, masked | `Character.hashCode(c)`, i.e. `(int) c` |
| `Int32.truncateToInt8(x)` | `Integer.valueOf(x).byteValue()` | none exists — see below |

**Flix has no primitive narrowing or widening operation at all**; every numeric
conversion in its standard library round-trips through a `java.lang` box. Outside
the small-integer caches that is a real allocation per conversion.

`Int32.truncateToInt8` is the one with no pure Java static. It can still be made
free rather than removed, by forcing the argument into `Integer`'s cache — the
sign-extend identity `((x & 0xff) ^ 0x80) - 0x80` equals `(byte) x` widened back
for every `int` and always lands in `-128..127`:

```flix
pub def toByte(x: Int32): Int8 =
    Integer.valueOf(Bits.bxor(Bits.band(x, 0xff), 0x80) - 0x80).byteValue()
```

### A call to a *different* def in tail position becomes a heap allocation

This is the least obvious item here and it was worth **2.1x on one of this port's
two codecs** when it was accidentally reintroduced.

Flix compiles a call to another def in tail position into a heap continuation which
the caller's trampoline then dispatches through `invokeinterface Thunk$.invoke()` —
megamorphic, because thousands of classes in a jar implement `Thunk$`. Moving the
same call out of tail position compiles it to a plain `invokestatic`. Verified on
two defs whose bodies are otherwise identical:

```flix
pub def tailCall(x: Int32, a: Array[Int32, r]): Unit \ r = sink(x, a)
pub def notTailCall(x: Int32, a: Array[Int32, r]): Unit \ r = { sink(x, a); () }
```

```
tailCall     ->  new Tail/Def$sink; dup; invokespecial <init>
                 putfield arg0; putfield arg1; areturn      <- allocates, returns a thunk

notTailCall  ->  iload_0; aload_1; checkcast [I
                 invokestatic Tail/Def$sink.staticApply     <- direct call, no allocation
```

Three ways to take a call out of tail position:

* a trailing `; ()` on a `Unit`-returning def — the identity on a `Unit` expression;
* `@Inline` on a def whose body is a single delegation, so the *caller* issues the
  `invokestatic` and the thunk never exists;
* for a **non-`Unit`** return, where `; ()` does not typecheck, bind the result and
  then bind something derived from it before returning it:

  ```flix
  let out  = BitWriter.toArray(writer);
  let _len = Array.length(out);   // dead, but it is what moves the call
  out
  ```

  Verified in `ClockEncoder.encode`: with the two lets the method ends
  `new Value$ / putfield o / areturn`, without them it ends
  `new BitWriter/Def$toArray$NNNNNN / areturn`.

`let r = f(x); r` does **not** work — a `let` of a tail call is still a tail call.
The second binding is what makes the difference, which is exactly why it looks like
dead code and must be commented.

**Do this only to bounded delegations** (a wrapper calling a loop, one extra JVM
frame). Never to a self- or mutually recursive loop: the thunk is what makes those
stack-safe. Self-recursive tail calls are unaffected anyway — Flix compiles those
to `goto`.

### MUTUAL recursion is the shape that cannot be fixed by annotation — fuse it

The rule above has a corollary that is worth its own heading, because it is worth
**45 ms of this port's cold start** and it is invisible in the source.

*Self* tail recursion compiles to `goto`. A tail call to a *different* def compiles
to a heap continuation. Two functions that tail-call **each other** are therefore in
the worst case: every alternation allocates, and neither `@Inline` (silently ignored
on recursion, and unsound here anyway) nor the `; ()` idiom (which would break
stack-safety) can help. The only fix is to *fuse the two loops into one
self-recursive def* carrying the union of their loop variables.

This port's `Bitboard.slidingAttacks` was the textbook case — the Scala original
nests `attackLoop` over the deltas and `deltaLoop` walking one delta, and they call
each other:

```
Bitboard/Def$attackLoop  ->  new Bitboard/Def$deltaLoop     (before every areturn)
Bitboard/Def$deltaLoop   ->  new Bitboard/Def$attackLoop    (on both exit paths)
```

At ~9 alternations per call and ~121 000 calls during table construction that is
roughly a million allocations and a million megamorphic `Thunk$.invoke()` dispatches,
all executed *interpreted* because they happen before the JIT has warmed. Fusing them
into one `slidingLoop(square, occupied, deltas, deltaIndex, sq, acc)` — restarting at
`square` exactly where `attackLoop` did — compiles to a `goto` loop with **zero**
`new` instructions, and took cold start from 76.2 ms to 37.0 ms against Scala's
unchanged 68.7 ms.

When you transcribe a Scala pair of mutually recursive inner loops, fuse them at
transcription time. The visiting order is preserved by carrying both indices.

A trailing `()` looks exactly like dead code and an eager cleanup will delete it.
Comment every site. This port documents the rule once, above `Board.put`, and
points at it from the other five files.

### An effect-polymorphic function parameter costs a closure only in tail position

A parameter of type `(Int32, Int32) -> Unit \ ef` is usually free: Flix
defunctionalises the call site and emits a direct call. It stops being free where the
call is in **tail** position, because there the compiler must materialise the lambda
as a resumable continuation — a `Clo` class extending `Clo2$…` and implementing
`Frame$`, with a `pc` field and a `copy()` method. Invoking that costs, per call, the
closure, the copy `getUniqueThreadClosure()` makes of it, and a `Def$` thunk that its
`applyFrame` allocates and returns, plus two `Thunk$.invoke()` dispatches.

`LowBitTruncator` had exactly this shape on both sides. The write side's final
`writeBits(...)` was in tail position, so it paid all of the above for one 3-bit
write; inlining the callback away and calling `BitWriter.writeBits` directly was
worth **clock encode 1.364/1.319/1.262x -> 1.294/1.257/1.198x**.

The read side's `readBits` calls were *not* in tail position, so Flix was already
defunctionalising them and there was nothing to win. Making it direct anyway — the
symmetric, obviously-tidier change — **lost**: clock decode 1.148/1.174/1.286x ->
1.233/1.298/1.214x, +5.5 ns on a 64 ns operation. It was reverted and the callback is
still there with a comment saying why.

So: look for the pattern, but only where the callback call is in tail position, and
measure the other sites rather than assuming symmetry.

### A single-case `enum` destructure materialises every field

`let Wide.Wide(_, _, c, _, _) = w` does **not** load only `c`. Verified on a
five-field single-case enum against a five-field struct, both reading one field,
both `@DontInline` to force the worst case:

| | bytecode |
|---|---|
| 5-field single-case **enum**, four fields wildcarded | 76 lines: an ordinal check, **all five** `checkcast`+`getfield` pairs, and a provably dead `new MatchError$` / `new ReifiedSourceLocation$` / `athrow` block |
| the same five fields as a **struct** | one `getfield`, one `checkcast` |

In this port that was the difference between a 264-bytecode table read and a
12-bytecode one, on a function called several times per generated move. It also
compounds: an accessor whose *inlined body* is 264 bytecodes makes every call site
bigger, so `@Inline` on it is a pessimisation and can blow the JVM's 64 KB method
limit — which is exactly what happened here, and why the "shrink the representation
first" order matters.

So: for read-only data that is wide or hot, use a `struct` (built in a local region
and cast to `Static`, as shown earlier) or a `type alias` over the underlying
representation. Keep single-case enums for cold or narrow data.

The same reasoning killed two more shapes in this port: a seven-field `Move` enum
became `type alias Move = Int64` with the fields packed into one word, and a
one-field `Psqt` enum became `type alias Psqt = Vector[Int32]`.

### `@Inline` is unconditional, and only `flix build-jar` can gate it

* `@Inline` has **no size budget**. Flix inlines what you annotate, however large.
* It is silently ignored on self-recursive defs.
* `@Inline` and `@DontInline` are the only annotations that reach code generation;
  `@TailRecursive`, `@Terminates`, `@Parallel`, `@Lazy` do not affect the emitted
  bytecode in 0.75.1.
* **Gate every `@Inline` batch on `flix build-jar`, never on `flix check`.** `check`
  does no code generation, so it cannot see `MethodTooLargeException` — and when
  that fires it names a *test* file's continuation frame rather than the file you
  annotated. See "`flix check` does not catch the JVM 64 KB method limit".
* Flix's **automatic** inliner is site-dependent in a way worth knowing: in this
  port `Bitboard.ranks` was compiled as a real call while the structurally identical
  `Bitboard.files` was inlined. If you want a family inlined, annotate the whole
  family rather than the members that happen to need it.

#### The JIT you are tuning against is Graal, not C2 — earlier rounds got this wrong

Three of this port's four reverted optimisations were argued from HotSpot's
`FreqInlineSize` of 325 bytecodes. **That flag is never consulted on the benchmark
JVM.** Verified on this machine:

```
$ java -XX:+PrintFlagsFinal -version | grep -E 'UseJVMCICompiler|FreqInlineSize|MaxInlineSize'
     bool UseJVMCICompiler   = true  {JVMCI product} {default}
     intx FreqInlineSize     = 325   {C2 pd product}
     intx MaxInlineSize      = 35    {C2 product}
```

`benchmarks/results.md` has always recorded that the harness runs with the inherited
`-XX:+EnableJVMCIProduct`, so the top tier is Graal and the C2 flags govern nothing
the benchmarks measure. The figures actually in force, from
`java -XX:+JVMCIPrintProperties -version`:

| property | value |
|---|---|
| `jdk.graal.MaximumInliningSize` | 300 |
| `jdk.graal.TrivialInliningSize` | 10 |
| `jdk.graal.MaximumRecursiveInlining` | 5 |
| `jdk.graal.PartialEscapeAnalysis` | true |
| `jdk.graal.MaximumEscapeAnalysisArrayLength` | 128 |

Two consequences. The budget to aim at is **300**, not 325. And the diagnostic is
`-Djdk.graal.TraceInlining=true`, which prints a per-callsite decision tree with
reasons; `-XX:+PrintInlining` reports C1/C2 decisions and says nothing at all about
the tier-4 compilations that matter here.

The correction has teeth. `BitWriter.writeBits` sat at 407 bytecodes for three
rounds, of which **83 were `Thunk$`/`Suspension$`/`UnhandledEffectError$` boilerplate
from one call to another Flix def** (`IntArrayList.copyOf`). Round 5 replaced that
callee with `java.util.Arrays.copyOf` — a `java.*` static compiles to a bare
`invokestatic` and carries none of that — and bound `l->index` once instead of five
times, which took `writeBits` to **274 bytecodes as a leaf**, under Graal's budget
for the first time. Measured: clock encode 46.7/82.0/142.3 -> 46.3/80.9/138.9 ns,
i.e. 1.300/1.288/1.200x -> 1.276/1.254/1.183x. Small, but it is the first thing in
five attempts at that def to move at all.

**Crossing the budget is necessary for the JIT to inline, not sufficient for the
change to pay, and it is worth being blunt about this because the bytecode argument
is seductive.** Round 4 removed `@Inline` from `IntArrayList.add`, which took
`writeBits` from 407 to 235 — comfortably inlinable, exactly as predicted, and it
LOST: clock encode 1.319/1.255/1.194x -> 1.255/1.393/1.337x, a small win on the
8-reading band and a large loss on the 16- and 30-reading ones, where the buffer
grows and the now-real call to `add` is paid once per 32 bits written. Reverted.

#### `@Inline` deletes a call, and with it the 48-byte `Value$` — but only a *value*-returning def has one to delete

This is the sharpest single lever found in the whole campaign, and its **sign depends
on the return type**, which is not obvious from the source.

Every value-returning Flix def ends `new dev/flix/runtime/Value$ … putfield i32 …
areturn`, and `Value$` is a universal box with `b/c/i8/i16/i32/i64/f32/f64/o` fields —
34 bytes of fields plus a 12-byte header, **48 bytes**, allocated per call unless the
JIT inlines *and* scalarises it. A `Unit`-returning def instead returns the free
`Value$.UNIT` static, and a `Bool`-returning one returns `Value$.TRUE`/`FALSE`, also
statics. Each call site additionally emits ~50 bytecodes of trampoline: an
`instanceof Thunk$` loop, a `Suspension$` test, a provably dead
`UnhandledEffectError$`/`ReifiedSourceLocation$` block, then `checkcast Value$` and a
`getfield`.

`@Inline` on such a def removes the call *at the Flix level* — no `Def$` class is even
emitted — so the trampoline and the box both disappear, and **none of that depends on
a JIT threshold going your way**. That is what makes it different in kind from
splitting a def to fit an inlining budget.

Applied to `BitReader.readBits` (`Int32`-returning, 17/33/66 calls per clock decode,
and hundreds per game decode) it was worth, in one change:

| row | before | after |
|---|---|---|
| clock decode short | 58.96 ns (1.072x) | 44.12 ns (**0.793x**) |
| clock decode median | 104.73 ns (1.048x) | 73.12 ns (**0.781x**) |
| clock decode long | 222.54 ns (1.248x) | 150.30 ns (**0.814x**) |
| clock decode alloc | 200 / 232 / 720 B/op | 120 / 152 / 240 B/op |

The same annotation on `BitWriter.writeBits` — same module, same shape, same call
counts, the obviously symmetric change — **lost**, and lost in both of the two forms
it was built in:

| variant | clock encode (ns) |
|---|---|
| baseline | 46.34 / 82.02 / 141.86 |
| `@Inline`, flush arm outlined, `writeUnsigned`'s two sites unified | 47.25 / 86.83 / 149.22 |
| `@Inline`, both arms in the body, unified sites, `add` growth via `Arrays.copyOf` so the pasted body is a call-free leaf | 47.39 / 85.80 / 150.16 |

The two variants agree, which rules out the outlined-flush call as the cause and
leaves the annotation itself. **The difference is the box.** `readBits` returns
`Int32`, so inlining it deletes a 48-byte allocation per call; `writeBits` returns
`Unit`, so there was never a box to win, only an `invokestatic`, and pasting a
400-bytecode body into every write site costs more than that is worth.

So the rule is: `@Inline` a hot **value**-returning def to delete its `Value$`. Do not
assume the `Unit`-returning twin behaves the same way — here it went the other way,
by 5%.

A corollary for the straddle/rare arm: outline it *and* make it self-tail-recursive
with an accumulator, so Flix compiles it to `goto` rather than paying a call and a box
per level. `readBits`' straddle arm recursed inside
`Bits.bor(Bits.shl(res, needed), readBits(needed, rd))` — not tail position — which is
where the clock decode long band's +504 B/op allocation cliff came from.

### A `java.*` static is a bare `invokestatic`; a call to another Flix def is not

Worth its own heading because it is the escape hatch that finally shrank
`BitWriter.writeBits`, and because it is invisible in the source: the two look
identical.

A call to another Flix def emits, **at the call site**, `invokestatic …staticApply`
returning a `Result$`, then `dup / instanceof Thunk$ / invokeinterface
Thunk$.invoke() / goto`, then an `instanceof Suspension$` test, then a provably dead
`new UnhandledEffectError$ / new ReifiedSourceLocation$ / athrow` block, then
`checkcast Value$` and a `getfield`. In `writeBits` that boilerplate was 83 of 407
bytecodes — 20% of the method — for one call to `IntArrayList.copyOf`.

A call to a `java.*` static carries none of it:

```flix
l->data = unchecked_cast(Arrays.copyOf(l->data, newLen) as Array[Int32, r] \ r)
```

compiles to `invokestatic java/util/Arrays.copyOf:([II)[I` and nothing else. This is
why round 4's "outline just the growth branch into a `grow` def" only got `writeBits`
from 407 to 351 — the outlined call brought the same boilerplate to the new site —
and why replacing the callee with the JDK's own method got it to 274.

Three hand-rolled loops in this port were replaceable this way and one still is:
`IntArrayList`'s growth (done — and `Arrays.copyOf` is literally what the Scala
original calls), `IntArrayList.toArray`, and `GameEncoder.sliceBytes`. Note that
`Array.copy` already lowers to `java.util.Arrays.copyOfRange`, so it is fine as is,
whereas `Array.repeat(rc, n, zero)` is `newarray` **plus** a redundant
`java.util.Arrays.fill` of a region the JVM has already zeroed.

### `unsafe IO { … }` makes the expression PURE, so an unused Java call is deleted

A silent-wrong-answer trap, found the hard way, and the reason this port still
assembles its output bytes by hand instead of through `java.nio.ByteBuffer`.

`ByteBuffer.putInt` is not one of the `java.lang` statics Flix treats as pure, so it
needs an `unsafe IO { … }` block. That block *removes* the effect — that is its whole
purpose — and what is left is a pure expression whose result nobody reads. Flix
deletes it.

```flix
let bb = unsafe IO { ByteBuffer.wrap(out) };
let _bb = unsafe IO { bb.putInt(v) };     // silently discarded
```

`flix check` is clean, `flix build-jar` succeeds, and the writes simply do not happen:
42 of this port's 122 tests failed with every whole-word byte zero and only the
hand-written ragged tail present. (Binding the result is not enough; and *not* binding
it is a hard error, `Redundancy Error [E8956] Useless expression`, which is at least
loud.)

So: `unsafe IO` is for a Java call whose **value** you use. For a Java call you want
for its **side effect**, you need a genuinely `\ IO` seam, not an `unsafe` block — or
you keep doing it in Flix. Anything that consumes the result only to defeat the
dead-code eliminator is one refactor away from firing again, in a codec where the
failure mode is wrong bytes rather than an exception.

### Every `@Export`ed def costs 64 bytes a call — unless it returns `Bool`

`Api.resultKnights(result)` looks like a field read. It compiles to: `new
Api/Def$resultKnights`, `dup`, `<init>`, `putfield arg0`, an `instanceof Thunk$` /
`invokeinterface Thunk$.invoke()` trampoline loop, a `Suspension$` test, `checkcast
Value$`, `getfield i64`, `lreturn`. Measured over a 200 000-call loop on one fixed
handle — the case most favourable to escape analysis, and escape analysis still fails
because `Thunk$.invoke()` is megamorphic across the thousands of `Thunk$`
implementations in the jar — that is a 16-byte `Def$` closure plus a 48-byte `Value$`,
**64 bytes per accessor call**.

`Bool` is the exception, and it is the whole fix: `Value$.TRUE` and `Value$.FALSE` are
public static finals, so a `Bool`-returning export skips the box and costs 16 bytes.
(`Unit` would be tidier and is not available: it is not an exportable return type,
Entry Point Error E1396.)

The Scala facade here read a decoded game through seventeen such accessors — 1,040
bytes per `decode`, against a decode that legitimately allocates about 58 bytes per
ply. Replacing them, for the facade only, with **one** `Bool`-returning export that
fills a caller-supplied `long[14]` and `Object[3]` moved game decode allocation
1.848/1.225/0.898x -> 1.527/1.058/0.813x, on every band, for no change in time. The
seventeen stay: they are documented API and they are the readable way to read one
field.

The boundary is also the **whole** of the clock codec's allocation gap, and that is
worth stating as a closed result rather than an open target. On the 8-reading band the
Scala original allocates 136 B/op, which is exactly `int[8]` (48) + `int[10]` (56) +
`byte[11]` (32) — its `Writer`, its `IntArrayList` and its `HeapByteBuffer` are all
scalarised. The Flix port allocates those same three arrays and nothing else. The flat
**+72 B/op on every band** is the 24-byte `Api/Def$` closure plus one 48-byte `Value$`,
and the `Def$` in particular cannot be removed: it flows through the `Thunk$.invoke()`
trampoline loop phi, where partial escape analysis cannot follow it. `@Inline` on the
codec does not reach it (see the `ThreadMXBean` section above), and a `Bool`-returning
`clockEncodeInto` makes it worse — 32 B for the `Fn3` `Def$` plus a caller-allocated
24-byte `Object[1]` against the 24 B that would be left. Record such a row as a property
of the mechanism, not as work outstanding.

If an export must hand back an `Int32` that will be widened, use
`Integer.toUnsignedLong` and narrow with a cast on the far side. The sign-extending
widening is indistinguishable for a square index or a ply count and silently wrong for
a Zobrist hash, whose top bit is live.

### Named-argument standard-library functions allocate a record per call

`Int32.logicalRightShift(dist: {dist = Int32}, x: Int32)` takes its shift distance
as a **record**, and `String.startsWith(prefix: {prefix = String}, s: String)` takes
its prefix the same way. Each call allocates a `RecordExtend`, then resolves the
field by **string comparison** at run time, once per mention of `dist#dist` in the
body. One `>>>` through the standard library cost about five heap allocations.

Write the body out instead. `x >>> n` is `(x >> n) & ~((-1 << (31 - n)) << 1)` for
`Int32` (63 for `Int64`), which is also **branchless** where the standard library's
own formula branches on the sign of `x` — the JVM has no `>>>` for a conditionally
signed value, so that branch survives into machine code. Inside a magic-bitboard
lookup the operand is a hash, so it mispredicts about half the time.

Audit for other named-argument stdlib calls on hot paths while you are there.

That branchless `ushr` is still **five operations where Java's `>>>` is one**, so it
is worth knowing when an arithmetic `shr` is provably equivalent and can replace it:

* when the operand is **non-negative** — `>>` and `>>>` agree at every distance;
* when the result is immediately **masked to `k` low bits and `k + distance <= 32`**
  — the two shifts differ only in bits `32 - distance` upwards, which the mask
  discards. This is the case in `BitReader.readBits`' fast arm, where after the
  update `distance + numReqBits == numRemainingBits <= 32` by construction.

The second one is worth 3-9% of clock decode here and about 1% of game decode
(checked over 1.58 million (x, distance, width) combinations before it was applied).
The *first* one is available in `BitWriter.writeBits` on the same reasoning and was
measured there too — and it **lost**, moving clock encode median from 81.2 to 88.1 ns
while the other two bands did not move. Both are recorded at their sites. The lesson
is the one above: on this codebase a strictly-cheaper instruction sequence can still
lose by moving an inlining decision, so measure per site rather than sweeping.

### String interpolation is a chain of `String.concat`

`"${a}${b}${c}"` compiles to successive `java.lang.String.concat` calls, and a
`Char` inside an interpolation goes through `Character.toString`, allocating a
one-character `String`. For anything per-iteration, build with `StringBuilder` and
use `appendCodePoint` for characters — `append` would route through `ToString` and
allocate the very `String` you are trying to avoid.

### Reading bytecode: clean the build directory first

`flix/build/` is never pruned and Flix names generated closure classes with a fresh
counter on every compilation, so an incremental build leaves several generations of
`Def$foo$NNNNNN.class` side by side. `javap` one of the stale ones and you will draw
a confident, wrong conclusion. Always `rm -rf flix/build flix/artifact` before
measuring bytecode sizes. (See "`flix/build/` accumulates stale classes".)

Note also that `unzip -l jar | tail -1` reports the **uncompressed** total, not the
file size — 3.3 MB uncompressed for this port's 1.87 MB jar. Do not read a jar-size
regression into it.

### `Array.repeat` is a trampolined call, `Array.empty` is seven bytecodes — but the substitution is site-dependent

`Array.repeat(rc, n, zero)` emits, at the **call site**, `invokestatic
Array/Def$repeat$NNN.staticApply` plus the ~55-bytecode `Thunk$` / `Suspension$` /
`UnhandledEffectError$` / `ReifiedSourceLocation$` trampoline, a `checkcast Value$` and
a `getfield`; the callee is `newarray` + `java.util.Arrays.fill` + a 48-byte `Value$`.
`Array.empty(rc, n)` inlines to seven bytecodes — `iconst_0; iload; newarray; dup_x1;
swap; invokestatic Arrays.fill` — with no call, no trampoline and no box. For any
element type whose `Reflect.default()` is the value `repeat` was filling with
(`Int8`/`Int32`/`Int64`/`Char` -> zero) the two are interchangeable wherever every slot
is written before it is read, or where unwritten slots are provably never read.

It is worth real rows. `BitOps.readSignedArray` alone took clock decode allocation on
the 30-reading band from 240 to 208 B/op against Scala's 216 — **flipping the row** —
and the same substitution in `BitWriter.toArray` and `IntArrayList.mk` took game encode
median allocation from 61,833 to 35,481 B/op.

**It is not a sweep.** The same change at `GameEncoder.decode`'s `output` and `sanBuf`,
where it is equally safe (`Array.ofDim[String](plies)` in the Scala original is
null-filled, and `sanBuf` is only ever read back over `[0, n)`), measured *worse*: game
decode allocation 53,753 -> 54,340 (short) and 69,046 -> 69,760 (median) B/op. Convert
one site at a time and measure it. And note the separate, independently verified result
that the redundant `Arrays.fill` itself costs nothing — Graal eliminates it (`new
int[10]` 4.004 ns vs `new int[10]` + `Arrays.fill(x,0)` 3.988 ns over 200 M ops). What
you are removing is the call and the box, not the fill.

### A `ThreadMXBean` probe and a JMH allocation row can disagree — and the JMH row is the one that counts

Two independent researchers measured `@Inline` on `ClockEncoder.encode` removing a
48-byte `Value$`, deterministically, 3/3 runs. It was reproduced a third time here with
`com.sun.management.ThreadMXBean.getCurrentThreadAllocatedBytes` over the *real* Scala
facade, at 200 000 calls a band: Flix-minus-Scala goes 176 -> 128 B/op on all three
bands, identical to the byte. The annotation demonstrably does what it says — a clean
`rm -rf build artifact && flix build-jar` emits **no `ClockEncoder/` class directory at
all**, and the body reappears inside `Api/Def$clockEncode.staticApply`.

JMH's `gc.alloc.rate.norm` for the same operation moved by **exactly zero**: 208/248/328
B/op before and after. The same thing happened to a structurally different change aimed
at the same object (splitting the writer half of `encode` into its own def), which a
standalone probe put at -48/-56/0 B/op and JMH put at 0/0/0.

Both instruments are correct and they are measuring different compiled shapes. A probe
loop and a JMH `@Benchmark` loop give Graal different inlining budgets and different
profile pollution, so an object that survives in one is scalarised in the other. Draw
two rules from it: **profile the shape you are scored on**, and **a deterministic
allocation delta in a hand-written probe is a hypothesis about the benchmark, not a
result for it**. Verify against `-prof gc` before believing a row will move.

### A `Bool` return costs nothing — use it to hand back a value the caller was recomputing

A `Bool`-returning Flix def ends `getstatic dev/flix/runtime/Value$.TRUE` / `getstatic
dev/flix/runtime/Value$.FALSE` / `areturn`. Those are public static finals, so it
allocates nothing — exactly like the `Unit` return's `Value$.UNIT`, and unlike every
other return type, which builds a 48-byte `Value$`. Widening a hot `Unit`-returning def
to `Bool` is therefore free at every call site, including the ones that `discard` it.

`Board.legalMoves` is the case that matters here. It computes
`checkers = attacksTo(king, !turn)` and threw it away; `GameEncoder.decodeLoop` then
called `isCheck()`, which recomputes that same expression on a board `legalMoves` did
not mutate — 1.00 redundant call per ply, 17.8-23.4% of all `attacksTo` calls and 12.0%
of every magic-bitboard lookup a decoded ply performs. Returning the flag deleted it
along with a trampolined `Def$isCheck` and a trampolined `Def$attacksToOcc` per ply, and
moved game decode from 356.6/728.3 to 348.2/697.2 µs on the median and long bands.

This change had been proposed once before and declined on the grounds that a non-`Unit`
`legalMoves` would box on every call. It does not. If you are about to reject a change
because of what a Flix return type is assumed to cost, `javap` it first.

### A decoder's contract is its symbols, so its algorithm is not pinned — an encoder's is

Worth stating explicitly in a byte-fidelity port, because it is the one place where a
genuinely different algorithm is admissible. The encoder writes the bytes, so every
tie-break, every push order and every comparison in it is load-bearing. The decoder only
has to produce the same *symbols*; how it gets there is free.

`MoveList.selectRank` is the example. The original quickselects with a Lomuto partition,
which resolves ties by position, so for a long time it looked pinned. But `Move.score`
packs five bit-disjoint fields, which makes scores **injective within one legal move
list** — checked at 0 duplicates over 206 604 lists / 5 072 212 moves in an exhaustive
depth-4 walk — so the `(rank+1)`-th largest is unique and *any* correct selection
returns the same `Move`. That unpinned a hybrid: one pass keeping the best four in four
scalars for `targetRank < 4` (about half of all plies), quickselect above it. Game decode
went 169.6/385.9/753.6 -> 151.7/356.6/728.3 µs with allocation unchanged.

Two things make the argument safe rather than plausible, and both are worth reproducing
for any similar change: the permutation the old algorithm left behind had to be shown
unobservable (here the only post-selection reads are an order-independent OR-reduction
and a size test, and the next ply clears the list), and the def had to have no caller on
the encode side (`selectRank` has exactly one caller in the repository, in `decodeLoop`).
The depth-4 perft checksum is the gate that catches a mistake in either.

### An `@Inline`d body upstream of a closure is not free to change size

`Board.sliderBlockers` is `@Inline`d into `Board.legalMoves`, whose tail is
`MoveList.retain(moves, m -> isSafe(b, king, m, blockers))` — a closure over three
values. Replacing two magic-table lookups inside `sliderBlockers` with two 64-entry
table reads is strictly less work, is provably the same value (asserted exhaustively
over all 64 squares against both the magic path and the generator), and left the
move-order-sensitive depth-4 perft checksum bit-identical. It still had to be reverted:
on the long game-encode band that closure stopped being scalarised, and allocation went
104,241 -> 140,581 B/op with encode time 581.9 -> 601.2 µs.

Nothing about the change was wrong. What was wrong was measuring only the axis it
targeted. **An `@Inline`d def that sits upstream of a closure-allocating call is part of
that call's inlining budget**, so any edit to it — including one that makes it smaller —
can flip a scalarisation decision. Measure `gc.alloc.rate.norm` as well as time, and
measure it with `-f 3`: this particular row is **bimodal within one build**, its
per-iteration values clustering at 96 490 and ~137 000 B/op, so a single fork cannot be
read as a point estimate.

### Standard-library primitives that are much slower than their Java namesakes

Summarised here because it is the trap most likely to be hit by someone who has not
read the rest of this section. **Read the standard-library source before assuming a
Flix function maps to a JVM intrinsic.**

- `Int64.numberOfTrailingZeros` / `numberOfLeadingZeros` → a recursive per-bit scan.
  Java's are single-instruction intrinsics. In a bitboard port this is the hottest
  function you have.
- `Int64.logicalRightShift(dist: {dist = Int32}, x: Int64)` — the shift distance is
  a record, on a function called once per ray step.
- Every numeric conversion (`truncateTo*`, `to*`) boxes through `java.lang`.

## Validation protocol for parallel work

All `.flix` files compile as one unit, so you cannot run `flix check` in
`flix/` while other agents have half-finished files there. Instead:

1. `mkdir -p "$SCRATCH/<your-name>" && cp flix/flix.toml "$SCRATCH/<your-name>/"`
2. `mkdir -p "$SCRATCH/<your-name>/src"` and copy in `flix/src/Bits.flix` plus
   whichever already-completed dependency files you were told you may rely on.
3. Write your own file(s) there and iterate with `flix check` until clean.
4. Only when clean, copy your finished file(s) into `flix/src/` (or `flix/test/`).

Never edit a file that is not yours. Never delete another agent's file.
