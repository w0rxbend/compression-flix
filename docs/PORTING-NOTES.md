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
- This constraint is another reason to prefer a single-case `enum` for read-only
  data: enum cases are `pub` and can be destructured anywhere, so the type does
  not drag its whole API into one module.
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

A `struct` always needs a region type parameter (doc.flix.dev: "Every struct must
have a region type parameter and it must be the last in the type parameter list"),
so a table that needs no region at all must be a single-case `enum`, not a struct.

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
threshold and no way to disable the `Thunk$`/`Suspension$` trampoline. Every
tuning lever is source-level: `@Inline` on small leaf functions, avoiding the slow
standard-library primitives (below), and changing data representation.

### Standard-library primitives that are much slower than their Java namesakes

Read the source before assuming a stdlib function maps to a JVM intrinsic.

- `Int64.numberOfTrailingZeros` → `lowestOneBitPosition` → `oneBitPositionHelper`,
  which is a **linear scan testing one bit at a time**, each step a shift plus a
  `remainder`. Java's is one `TZCNT`. In a bitboard port this is the hottest
  function you have.
- `Int64.logicalRightShift(dist: {dist = Int32}, x: Int64)` takes its shift
  distance as a **record**.

## Validation protocol for parallel work

All `.flix` files compile as one unit, so you cannot run `flix check` in
`flix/` while other agents have half-finished files there. Instead:

1. `mkdir -p "$SCRATCH/<your-name>" && cp flix/flix.toml "$SCRATCH/<your-name>/"`
2. `mkdir -p "$SCRATCH/<your-name>/src"` and copy in `flix/src/Bits.flix` plus
   whichever already-completed dependency files you were told you may rely on.
3. Write your own file(s) there and iterate with `flix check` until clean.
4. Only when clean, copy your finished file(s) into `flix/src/` (or `flix/test/`).

Never edit a file that is not yours. Never delete another agent's file.
