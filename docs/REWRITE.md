# Porting `org.lichess.compression` from Scala to Flix

This document describes the Flix rewrite of the lichess chess clock and move
compression library: what was rewritten, what Flix forced the design to look like,
how the result is called from Scala and Java, and — in detail, and honestly — what
has actually been proven about it.

It is written for an engineer who knows Scala and does not know Flix.

The library's whole purpose is that its output is a storage format. A port is
useless unless it is **byte-for-byte identical** to the original, so most of what
follows is about fidelity, and the verification section is deliberately specific
about which claims are backed by an executed test and which are not.

---

## 1. What was rewritten

The whole library. 1579 lines of Scala became 5493 lines of Flix.

### Main sources

| Scala (`src/main/scala/`) | LOC | Flix (`flix/src/`) | LOC |
|---|---:|---|---:|
| `BitOps.scala` | 113 | `BitOps.flix` | 496 |
| `clock/Encoder.scala` | 40 | `ClockEncoder.flix` | 251 |
| `clock/EndTimeEstimator.scala` | 13 | `EndTimeEstimator.flix` | 47 |
| `clock/LinearEstimator.scala` | 29 | `LinearEstimator.flix` | 70 |
| `clock/LowBitTruncator.scala` | 23 | `LowBitTruncator.flix` | 117 |
| `game/Bitboard.scala` | 119 | `Bitboard.flix` | 562 |
| `game/Board.scala` | 334 | `Board.flix` | 905 |
| `game/Encoder.scala` | 159 | `GameEncoder.flix` | 626 |
| `game/Huffman.scala` | 291 | `Huffman.flix` | 461 |
| `game/Magic.scala` | 138 | `Magic.flix` | 178 |
| `game/model.scala` | 35 | `Role.flix` + `Square.flix` | 110 + 85 |
| `game/MoveList.scala` | 87 | `MoveList.flix` | 342 |
| `game/Move.scala` | 82 | `Move.flix` | 373 |
| `game/ZobristHash.scala` | 116 | `ZobristHash.flix` | 421 |
| — | — | `Bits.flix` *(new)* | 79 |
| — | — | `Api.flix` *(new)* | 370 |
| **total** | **1579** | | **5493** |

Two files have no Scala counterpart. `Bits.flix` exists because Flix has no infix
bitwise operators (§2.1). `Api.flix` is the JVM export surface (§3).

Three renames were forced rather than chosen:

- `clock/Encoder.scala` → **`ClockEncoder`**, and `game/Encoder.scala` →
  **`GameEncoder`**. Flix compiles the project as a single unit with a flat global
  module namespace; there are no packages, so two modules called `Encoder` collide.
- `game/model.scala` split into `Role.flix` (which holds both `Role` and `Piece`)
  and `Square.flix`, because Flix wants one top-level type per companion module.

The 3.3× line growth is not ceremony. It is roughly: doc comments recording *why*
each construct differs from the Scala (a large fraction), `while` loops rewritten
as named tail-recursive functions (§2.3), and bitwise expressions that were infix
operators becoming nested function calls (§2.1).

### Tests

| Scala (`src/test/scala/`) | LOC | Flix (`flix/test/`) | LOC |
|---|---:|---|---:|
| `ClockHistoryTest.scala` | 67 | `TestClock.flix` | 220 |
| `HuffmanPgnTest.scala` | 425 | `TestHuffman.flix` + `TestGameEncoder.flix` | 333 + 703 |
| `PerftTest.scala` | 69023 | `TestBoard.flix` + `TestBoardPerft.flix` | 1694 + 168 |
| — | — | `TestBitOps.flix` *(new)* | 455 |
| — | — | `TestBitboard.flix` *(new)* | 1068 |
| — | — | `PerftSweep.flix` + `TestPerftSweep.flix` *(new)* | 298 + 47 |
| **total** | **69515** | | **4986** |

`PerftSweep.flix` is a driver rather than a test module — it is the depth-4 sweep's
entry point, run from `scripts/perft-sweep.sh`. Its corpus,
`flix/test/data/perft-corpus.csv`, is 6838 rows of generated data extracted from
`PerftTest.scala` by `tools/extract-perft-corpus.py`; see §4.3.

126 `@Test` functions in total: 94 in `flix/test/`, and 32 more in `src/` as
`Test*Self` modules written by the porters of those files. The `src/` placement is
not ideal but is also not the problem it looks like — Flix has no test scope, so
moving them to `test/` would not keep them out of the jar either (§5.4).

> Earlier revisions of this document said 127 / 95 / 32, and that was a miscount.
> `grep -rn '@Test' flix/src flix/test` returned 127 hits, but **two of them are
> inside doc comments** — `test/TestBoardPerft.flix:12` and
> `test/TestBoard.flix:1342` — not annotations. The real pre-`PerftSweep` figure
> was 125, which is exactly the 121 passed + 4 skipped that `flix test` reported.
> Adding `TestPerftSweep.testCorpusDepth2` (§4.3) makes it 126 = 122 + 4. Count it
> with `grep -rn '@Test' flix/src flix/test | grep -vE ':\s*///' | wc -l`.

`PerftTest.scala` is 69023 lines of generated position data. The Flix side does not
transcribe all of it; see §4.3 for exactly how much is covered and what that leaves
unproven.

### New Scala/Java code

| File | LOC | Purpose |
|---|---:|---|
| `flix-bridge/…/FlixCodec.java` | 162 | typed interface, named package |
| `flix-bridge/…/LichessFlixCodec.java` | 154 | implementation, **unnamed** package |
| `scala-api/…/flix/Flix.scala` | 34 | process-wide `lazy val`s |
| `scala-api/…/flix/clock/Encoder.scala` | 34 | clock facade |
| `scala-api/…/flix/game/Encoder.scala` | 134 | game facade + `DecodeResult` + 13-field `Board` |
| `scala-api/README.md` | 107 | consumer documentation |
| `scala-api-dropin/…/{clock,game}/Encoder.scala` | 14 + 106 | original-FQN facade; `game` is an adapter, not an alias (§5.2) |
| `scala-api-dropin/…/game/Board.scala` | 103 | package-level `Board`, so lila's `Board as JavaBoard` import resolves |
| `scala-api-dropin/…/game/LilaSourceCompatWitness.scala` | 51 | compiles lila's exact import and field reads — the drop-in's only test |
| `difftest/…/DifferentialTest.scala` | 309 | Scala-vs-Flix byte equality, incl. all 13 `Board` fields |
| `difftest/…/SanFuzzTest.scala` | 224 | SAN matcher vs `java.util.regex` |
| `difftest/…/ConcurrencyTest.scala` | 137 | thread-safety |
| `difftest/…/ExceptionParityTest.scala` | 223 | failure-path parity (§5.1) |
| `difftest/…/PerftCorpusTest.scala` | 227 | the Scala half of the perft sweep (§4.3) |
| `tools/extract-perft-corpus.py` | 166 | `PerftTest.scala` → `perft-corpus.csv` |
| `scripts/perft-sweep.sh` | 131 | depth-4 sweep entry point, both implementations |
| `benchmarks/…/{Corpus,FlixGameBench,FlixClockBench,ColdStartBench,SetupPlacementBench}.scala` | 657 | the Flix-vs-Scala JMH suite (§5.7) |

---

## 2. How it was rewritten — the design Flix forced

### 2.1 There are no infix bitwise operators, so there is a `Bits` module

This library is bit manipulation almost end to end, and Scala writes it with
`<<`, `>>`, `>>>`, `&`, `|`, `^`, `~`. Flix has none of these as operators. The
stdlib equivalents exist but are verbose and, critically, `logicalRightShift` takes
a **named** argument:

```flix
Int32.logicalRightShift(dist = n, x)
```

Every one of them is wrapped once, in `Bits.flix`, with a short name and a doc
comment naming the Java operator it stands for:

```flix
pub def ushr(x: Int32, n: Int32): Int32 = Int32.logicalRightShift(dist = n, x)
pub def bandL(x: Int64, y: Int64): Int64 = Int64.bitwiseAnd(x, y)
```

This is not sugar. It is the port's main defence against the single highest-risk
class of bug: **arithmetic (`>>`) versus logical (`>>>`) right shift.** With
`Bits.shr` and `Bits.ushr` as distinct names, every shift site can be diffed
against the Scala by eye, and the `L` suffix keeps Int32 and Int64 width from being
confused at the same time.

The cost is that expressions invert. Scala's

```scala
(1L << a) | (1L << b) | (slide(a) & slide(b))
```

becomes

```flix
Bits.borL(Bits.borL(Bits.bit(a), Bits.bit(b)), Bits.bandL(slideA, slideB))
```

which is uglier but has one compensating virtue: Scala's precedence rule that `&`
binds tighter than `|` is now explicit rather than remembered. That rule is
load-bearing in `Bitboard`'s ray table and in `Board.sliderBlockers`, and it is the
kind of thing a hand port silently gets wrong.

One trap deserves a specific mention. `Int32.abs` is **not** `Math.abs`:
[api.flix.dev/Int32.html](https://api.flix.dev/Int32.html) specifies "If the
absolute value exceeds maxValue(), -1 is returned", where Java wraps
`Math.abs(Integer.MIN_VALUE)` back to `Integer.MIN_VALUE`. `Move.set` compares
`Math.abs(from - to) == 16`, so Java semantics are required. `Bits.absInt` is the
hand-written wrapping version and the stdlib function must not be substituted for
it.

### 2.2 There is no global mutable state and no memoization — hence `Tables`

This is the deepest structural change in the port.

The Scala `object Bitboard` holds nine `val` arrays filled by a static
initializer, the largest being the magic-bitboard attack table at **88772
entries**. `object Move` holds a 6×64 piece-square table; `object ZobristHash`
holds 781 Polyglot keys; `object Huffman` holds a 256-entry code table and its
decoding tree. In Scala these are free: `object` initialisation runs once, and
every use site just names them.

Flix has no `object`, no static initializer, no global mutable state, and no
memoization annotation. A zero-argument `def` returning a table is **recomputed on
every call**. Writing `Bitboard.attacks()` inside move generation would therefore
rebuild 88772 entries per lookup.

The resolution is that all precomputed data is built once into an explicit value
and **threaded as a parameter**:

```flix
let t = Tables.mk();                       // ~100 ms, once per process
Bitboard.rookAttacks(t, square, occupied)  // every lookup takes it first
```

Two decisions inside that are worth spelling out, because the obvious versions are
both wrong.

**`Tables` is an immutable region-free value, not a region-allocated struct.** The
first implementation made it `struct Tables[r: Region]` holding
`Array[Int64, r]`. That typechecks, but every single lookup then carries the region
effect `\ r`, which propagates into `Board`, `MoveList`, `GameEncoder` and finally
forces the export layer to hold a `Tables[Static]` at `\ IO`. It was rewritten to
hold `Vector`s: the mutation needed to *fill* the tables is confined to a
`region rc { … }` inside `mk`, whose effect is discharged at the block boundary,
and every lookup afterwards is a pure `Vector.get`. `Tables.mk(): Tables` is
therefore **pure**, and no region effect leaks anywhere. This mirrors the Scala,
where the arrays are `val` and written only by the initializer — the mutability was
always construction-only.

This also had to be a single-case `enum`, not a `struct`: doc.flix.dev states that
"Every struct must have a region type parameter and it must be the last in the type
parameter list", so a struct cannot be region-free at all.

**The static data is bundled two levels deep, not one.** There are four
independent tables — `Tables` (attacks), `Psqt` (piece-square), the Polyglot
`Vector[Int32]`, and `Huffman.HuffmanTable`. They are constructible separately and
then bundled by `GameTables.mk()`, rather than merged into one `Tables` value.
Merging was considered and rejected on a structural constraint: `Psqt` is declared
in `Move.flix`, and `Move.flix` already depends on `Tables` (its `MoveCtx` holds
one), so merging would make `Bitboard.flix` and `Move.flix` mutually dependent. It
would also force a consumer that only wants move generation to build a Huffman tree
it never reads.

The obligation this creates for callers is real and is the port's main operational
hazard: **build the tables once and cache them.** Because `GameTables.mk()` is
pure, the type system will not warn you if you call it in a loop. The Scala facade
discharges this with a `lazy val`.

### 2.3 Regions and effects replace ad-hoc mutation

Flix tracks effects in the type system, and mutable memory lives in a *region*
whose lifetime is a lexical block. `region rc { … }` runs a computation with access
to `rc` and discharges its effect at the block boundary, so a function that mutates
internally can still be pure from the outside.

That maps onto this library unusually well, because most of its mutation is
scratch space:

- `GameEncoder.encode` allocates its `Board`, its `MoveList` and its `BitWriter`
  in a local region and lets only a `Vector[Int8]` escape. It is therefore
  **pure**, despite being a mutable-move-generation algorithm inside.
- `GameEncoder.decode` cannot be pure — its result *contains* the final `Board`,
  which is region-allocated — so it takes the caller's region and is `\ r`.
- The original's `ThreadLocal[MoveList]` simply disappears. It existed because the
  scratch move list was shared mutable state; here it is allocated per call inside
  a region, which is thread-local by construction. This is a genuine improvement,
  and §4.4 records the test that confirms it.

Every `while` loop in the original became a named tail-recursive local `def`. This
is not merely idiom: several loops depend on visit order (`while (bb != 0) { …;
bb &= bb - 1 }` visits squares in ascending order, and move push order is
observable through `MoveList`), and a named recursive function with the bitboard as
an accumulator makes that order explicit and local rather than implicit in mutation.

For the same reason the port avoids `List.map`/`Array.tabulate` in effectful
positions: Flix does not document a left-to-right evaluation order for them, and
several sequences here depend on it.

`Static` — the region that outlives everything — is used in exactly one file,
`Api.flix`, and only because values handed to Java must outlive the call. Nothing
in the library proper touches it.

### 2.4 ADTs replace `null`

The Scala uses `null` in four places. Flix has no `null`, and each became an
explicit type:

| Scala | Flix |
|---|---|
| `Board.roleAt` returns `null` for an empty square | `Option[Role]` |
| `Move.promotion: Role \| null` | `Option[Role]` |
| `Encoder.encode` returns `null` for unencodable SAN | `Option[Vector[Int8]]` |
| `DecodeResult.lastUci: String \| null` | `Option[String]` |

This is the one place where the port is *safer* than the original rather than
merely equivalent, and it costs nothing at runtime. Where an internal caller has
already established that a square is occupied, a private `roleAtOrBug` unwraps with
`bug!` — the analogue of the `NullPointerException` the Scala would have raised.

Note that at the JVM boundary the `null`s come **back**: the facade's public
signatures return `null` exactly where the original does, so callers do not have to
change. §3.2 explains how a genuine Java `null` is produced from Flix.

Two more ADT choices worth recording:

- `Move` is an immutable single-case enum, and the original's **object pooling was
  dropped**. Scala's `MoveList` recycles 256 preallocated `Move` objects and
  `swapRemove` swaps references. Nothing in the library observes `Move` identity —
  the encoder compares fields — so the pooling is unobservable, and immutable moves
  make the one place a `Move` outlives its slot (`decode` holds a move across
  `board.play`) unconditionally sound rather than accidentally sound.
- `DecodeResult` is a `pub enum DecodeResult[r: Region]`. An enum, not a struct,
  because an enum's cases destructure in any module while a struct's fields do not
  (§2.5) — an enum is the escape hatch for returning region-allocated data out of a
  function.

### 2.5 The struct/module naming rule, and why it shapes the file layout

doc.flix.dev/structs.html states two rules that together dictate much of this port's
structure:

> "A struct is declared inside a module of the same name — its companion."
>
> "The fields of a struct are only visible from within its companion module."

The second is stronger than it first appears, and it is about *resolution*, not
just visibility: `b->field` only resolves inside the module named after the struct.
`mod Bitboard` cannot write `t->attacks` for a `Tables` value at all — not even
with a qualified name. Every cross-module read needs an explicit accessor function
defined in the companion.

The consequences are visible throughout:

- `BitOps.flix` is four modules — `BitOps`, `BitReader`, `BitWriter`,
  `IntArrayList` — that communicate only through functions, because each struct
  needs its own companion.
- The entire 20-plus-helper move generator lives inside `mod Board`, because it all
  touches board fields. Nothing outside `mod Board` can reach board state.
- `Square.aligned` **could not stay in `Square`**. It needs the `RAYS` table, which
  lives with the other tables, and Flix additionally forbids reopening a module
  (a second `mod Square` block is `[E5410] Duplicate module`), so `Square` cannot be
  extended from another file. It is `Bitboard.aligned(t, a, b, c)`.

### 2.6 Smaller forced changes

These are individually minor but each one silently changes behaviour if missed.

**No overloading.** Flix has no overloading, so every Scala overload pair got
distinct names: `BitOps.writeSigned` / `writeSignedAll`,
`LowBitTruncator.truncate` / `truncateCenti`, `LinearEstimator.encode` /
`encodeRange`.

**Reserved words.** `from`, `discard` and `run` are keywords. `Move.from`/`Move.to`
are therefore `Move.fromSq`/`Move.toSq` (`to` is *not* reserved, but the pair reads
better renamed together), and `Board.discard` is `Board.discardAt`.

**`def` names must start lowercase.** Scala's `val A1 = 0` cannot be `def A1()`;
the `Square` constants are `Square.a1()`, `Square.h8()` and so on, with parentheses
at every call site. Enum *case* names may be uppercase, but `Role` uses CamelCase
(`Role.Pawn`) to match the stdlib.

**Integer literals are range-checked at parse time against the signed maximum.**
`0xffffffff`, `0x8100000000000081i64` and even `-0x10` are all rejected with
"Malformed int literal … value out of bounds" — the unary minus in front of a hex
literal is *always* rejected regardless of magnitude. Java masks with the top bit
set had to be written as signed decimal with the hex in a trailing comment:

```flix
-9151314442816847743i64 /* 0x8100000000000081 */
```

This affects the `Board` castling-rights default, several `Bitboard` masks, and
every position constant in the perft tests. Because a mistranscription here is
invisible by inspection, all such tables — `Magic`, `Huffman`, `ZobristHash`, the
piece-square table, the perft positions — were **generated by script from the Scala
source and then mechanically compared back**, rather than typed.

**`java.nio.ByteBuffer` is gone.** `BitReader` holds an `Array[Int8, r]` plus a
`mut pos`, and `bb.getInt()` is assembled by hand from four sequential `let`
bindings so that the big-endian read order is pinned in the source rather than
inherited from a library.

**No regex group API.** `GameEncoder`'s SAN matcher is a hand-written backtracking
transcription of
`([NBKRQ])?([a-h])?([1-8])?x?([a-h][1-8])(?:=([NBRQK]))?[\+#]?` reproducing
`java.util.regex` semantics: leftmost start position wins, greedy `?` groups are
tried present-first, and alternatives are abandoned right-to-left. This is the one
component that reimplements a *library* rather than the project's own code, and
§4.2 describes the test built specifically to attack it.

---

## 3. Calling it from Scala and Java

### 3.1 The `@Export` surface

Flix compiles an `@Export`ed `pub def` to a `public static final` method on a class
named after its module. `Api.flix` is that surface: **22 functions**
(`grep -c '^    @Export' flix/src/Api.flix`). Five are the codec itself and
seventeen read fields off the opaque `DecodeResult` handle — eleven of those
seventeen were added to close §5.2.

An exported signature may only mention primitives and `java.lang.Object`. Arrays,
`String`, enums, structs, `Option` and tuples are not exportable. So everything
non-scalar crosses as `Object` and is `unchecked_cast` back on entry. Usefully,
`Array[Int8, Static]` *is* a Java `byte[]`, `Array[Int32, Static]` an `int[]`,
`Array[String, Static]` a `java.lang.String[]`, and Flix `String` is
`java.lang.String` — so nothing is copied at the boundary.

```
newTables(int) -> Object            // opaque GameTables handle
clockEncode(Object centis, int startTime) -> Object    // int[]  -> byte[]
clockDecode(Object bytes,  int startTime) -> Object    // byte[] -> int[]
gameEncode(Object tables, Object pgnMoves) -> Object   // String[] -> byte[] or null
gameDecode(Object tables, Object input, int plies) -> Object  // opaque DecodeResult

// the 17 DecodeResult accessors
resultPgnMoves / resultPositionHashes / resultLastUci   -> Object
resultHalfMoveClock -> int
resultTurn -> boolean
resultPawns / resultKnights / resultBishops / resultRooks / resultQueens /
  resultKings / resultWhite / resultBlack / resultOccupied /
  resultCastlingRights                                  -> long
resultEpSquare / resultIncrementalHash                  -> int
```

The last eleven are the `Board` fields added in §5.2. `resultWhite` and
`resultBlack` call the Flix `Board.whitePieces`/`Board.blackPieces` — `white` and
`black` are not available as Flix identifiers there — which is the only place the
export names and the Flix names differ.

**Why the API takes an opaque handle.** Two reasons, and they are different.
`newTables` returns a handle because Flix has no memoization (§2.2): the ~100 ms of
tables cannot hide behind a zero-argument function, so the caller must hold them
and pass them back. `gameDecode` returns a handle because `DecodeResult` is not an
exportable type — it contains a `Board`, arrays and an `Option` — so it stays on
the Flix side and seventeen accessor functions read fields off it, one scalar or
array at a time. That per-field marshalling is the direct cost of the handle
design, and it is inside the decode measurement in §5.7.

Three details that are easy to get wrong:

- **There are no zero-argument exports** (`Unit` is not an exportable parameter
  type), which is why `newTables` takes an ignored `int`.
- **A pure export must not declare `\ IO`** — Flix rejects the unused effect.
  `newTables` and `resultHalfMoveClock` are pure; the rest touch `Static` and are
  `\ IO`.
- **`unchecked_cast` cannot box a primitive.** `unchecked_cast(n as Object)` on an
  `Int32` typechecks and then throws `dev.flix.runtime.CastError` at run time, so
  scalar results are returned as `Int32`/`Int64`/`Bool` directly.

### 3.2 Producing a real Java `null`

The original returns `null` from `game.Encoder.encode` for unencodable SAN, and
`DecodeResult.lastUci` is `null` at zero plies. Flix has no null literal, but a
genuine one is obtainable:

```flix
def nullObject(): Object \ IO =
    let holder: Array[Object, Static] = Array.empty(Static, 1);
    Array.get(0, holder)
```

`Array.empty` compiles to `new Object[1]`, whose single slot is null. This is what
lets the facade keep the original's signatures instead of inventing a sentinel that
every caller would have to know about.

### 3.3 The default-package hazard, and how the facade contains it

**This is the single most important thing to know before putting the Flix jar on a
classpath.**

Flix 0.75.1 emits *everything* into the unnamed (default) package — not just your
code but its entire standard library. A clean-build jar contains **363** top-level
classes with no package, including `Object`, `String`, `Array`, `List`, `Map`,
`Set`, `Option`, `Iterator` and `Assert`. Worse, Flix emits a same-named
*directory* beside every module class: `Api.class` **and**
`Api/Def$gameEncode.class`.

(Earlier notes in this repository put that figure at 145 and named `Probe` and
`Main` among the shadowing classes. Both were measured on a stale incremental build
— see §5.4. `Probe` and `Main` are *not* in a clean-build jar; they were leftovers
from scratch files compiled during development. The hazard is real and the count is
larger than 145, but those two specific names are not part of it.)

Two distinct failures follow, and conflating them leads to the wrong fix:

- **Java** sources in the unnamed package resolve bare `String` to *Flix's*
  `String`. A `main(String[] args)` written that way compiles and then fails to
  launch, because the JVM wants `main([Ljava/lang/String;)V`. The shadowing is not
  limited to `java.lang` names: any user class in the unnamed package can be
  captured too.
- **Scala** sources in *any* package lose those names in **term** position:
  `Array("e4")` fails with `package Array does not take parameters`, because the
  same-named package outranks `scala.Array`'s companion. Type positions such as
  `Array[Byte]` still work, so the breakage is partial and confusing.

That second point also means **a Scala facade cannot call `Api` at all**, however
it spells its types. Two independent rules block it: no named-package source may
reference the unnamed package (JLS 7.5 — Scala reports `Not found: FlixBridge`),
and Flix's `Api/` directory makes Scala resolve `Api` to a package, so even
`_root_.Api.newTables` fails with `value newTables is not a member of Api`.

Shading does not help. Relocating the classes preserves the class/package name
collision that makes them unreachable in the first place.

What actually works is **containment by classpath scoping**, in a four-layer chain:

```
Scala caller
  → org.lichess.compression.flix.{clock,game}.Encoder   (scala-api, Scala)
  → org.lichess.compression.flix.FlixCodec              (flix-bridge, Java, named package)
  → LichessFlixCodec                                    (flix-bridge, Java, UNNAMED package)
  → Api                                                 (flix.jar, UNNAMED package)
```

`LichessFlixCodec` is the only source file in the repository allowed to name `Api`.
It is Java (Scala cannot reach the unnamed package in either direction), it lives
in the unnamed package (nothing else can), and it writes every JDK type as
`java.lang.X` in full because bare `String` there means Flix's `String`. It is
loaded once by `Class.forName`; every call after that is a plain
`invokeinterface`, with no per-call reflection.

`build.sbt` enforces the containment: `flix-bridge` is the only project with the
Flix jar on a compile classpath, and it is Java-only. A `hideFlixJar` setting
filters `flix.jar` out of every Scala `dependencyClasspath` (sbt propagates a
dependency's `unmanagedJars` down `dependsOn` edges, so isolating the bridge is
necessary but not sufficient) and adds it back only to runtime classpaths.

### 3.4 Using it

Two artifacts and one jar:

| artifact | compile | runtime |
|---|---|---|
| `compression-flix-api` | yes | yes |
| `compression-flix-bridge` | transitive | yes |
| `flix/artifact/flix.jar` | **no** | **yes** |

```scala
import org.lichess.compression.flix.clock.Encoder as Clock
import org.lichess.compression.flix.game.Encoder as Game

val bytes   = Clock.encode(Array(17980, 17960, 17800), startTime = 18000)
val encoded = Game.encode("e4 e5 Nf3 Nc6".split(" "))
val decoded = Game.decode(encoded, plies = 4)
```

For an existing caller that should not change its imports at all,
`compression-flix-api-dropin` re-exports the same two objects under their
*original* fully qualified names. It must be used **instead of** `compression`,
never alongside it: the names collide and whichever jar comes first on the
classpath silently wins. (That is also why `difftest` depends on `scala-api` and
not on the drop-in — it needs both implementations loadable at once.)

Building:

```
sbt scalaApi/compile   # runs `flix build-jar` first if any .flix is newer
sbt difftest/test      # the byte-for-byte differential suite
sbt flixReleaseJar     # a copy of the jar with the @Test classes stripped
```

The jar is named after the *directory* (`flix/` → `flix.jar`), not after `name` in
`flix.toml`.

---

## 4. Verification — what is actually proven

Everything in this section was executed as part of writing this document, on this
machine, and the numbers are the real output.

### 4.1 The toolchain is clean

From a wiped `flix/build` and `flix/artifact`:

```
flix check      exit 0
flix build      exit 0
flix build-jar  exit 0   → artifact/flix.jar, 2.0 MB, 1744 class entries
flix test       Passed: 122, Failed: 0. Skipped: 4. Elapsed: 13.7s
```

(121 before `TestPerftSweep.testCorpusDepth2` was added in §4.3; the four skips
are unchanged.)

> **A jar figure is only meaningful next to the exact command that produced it, and
> the 3.0 MB / 2485 entries this section used to quote is not reproducible.** The
> row above is `rm -rf flix/build flix/artifact && flix build-jar` in one step,
> nothing before it: **1744 class entries, 2.0 MB**, of which 710 are `Test*`. The
> reason the old figure cannot be reproduced is that Flix names generated closures
> with a fresh counter on every compilation
> (`PerftSweep/Clo$main$445803.class`) and `flix/build/` is **never pruned**, so
> each additional pass *appends* rather than replaces. From the same sources:
> `rm -rf` → `flix build` → `flix test` → `flix build-jar` gave 3658 entries /
> 4.7 MB, and the working tree as left by four parallel agents had reached 23 MB.
> Two independent clean measurements of the current sources gave 1733 and 1744
> entries — the 11-entry difference is the eleven `Board` accessors added in §5.2.
> `build.sbt`'s comment on `flixReleaseJar` and `PORTING-NOTES.md` now carry the
> same figures and the same caveat.

The 4 skipped tests are deliberate and documented in place: perft runs too
expensive for a normal test cycle (start depth 6 = 119060324 nodes ≈ 15 s;
kiwipete depth 5 = 193690690; position 5 depth 5 = 89941194; position 6 depth 5 =
164075551). Each carries its expected count so it can be un-skipped when move
generation changes. **These are the only skipped tests, and there are no `FIXME`,
`TODO`, `XXX` or `HACK` markers anywhere in `flix/src` or `flix/test`** — verified
by grep; the only `@Skip` hits are those four plus a mention in the notes.

### 4.2 The port is byte-identical to the Scala, tested against the Scala

This is the claim that matters, and it is tested the only way that really settles
it: both implementations on one classpath, in one JVM, over the same inputs.
`sbt difftest/test` — **25 examples, 0 failures** (it was 17 before waves 1 and 2
added the exception-parity suite, the perft corpus and the full-`Board` check):

```
[diff] clock encode                          13 / 13    matched
[diff] clock decode                          13 / 13    matched
[diff] clock encode+decode (fuzz)          2000 / 2000  matched
[diff] clock encode purity                   13 / 13    matched
[diff] game encode                          119 / 119   matched
[diff] game decode (all ply counts)        6108 / 6108  matched
[diff] game decode board (13 fields)       6108 / 6108  matched
[diff] game decode (v1 corpus)              114 / 114   matched
[diff] game decode (zero stream)              1 / 1     matched
[diff] game encode (rejections)               3 / 3     matched
[exn]  failure parity (fixed cases)           5 / 5     matched
[exn]  assert non-parity (both Error)         1 / 1     matched
[exn]  failure parity (fuzz)               1000 / 1000  matched
[san]  random alphabet strings            20000 / 20000 matched   (encoded a move:   461)
[san]  enumerated shapes                 103680 / 103680 matched  (encoded a move:   168)
[san]  leading/trailing junk               1890 / 1890  matched   (encoded a move:   204)
[san]  mutated real tokens                 4050 / 4050  matched   (encoded a move:   204)
[san]  redundant disambiguation            9605 / 9605  matched   (encoded a move:  9588)
[perft] depth4 first 200 vs PerftTest       200 / 200   matched
[perft] scala depth2 rows=6838 nodes=4689446 checksum=-6849308306848708094
```

Points worth drawing out:

- **`game decode (all ply counts)`** decodes every one of the 114 `HuffmanPgnTest`
  fixtures at *every* ply count from 0 to full length, comparing `pgnMoves`,
  `halfMoveClock`, `positionHashes`, `lastUci`, `castlingRights` and `turn` at each
  — 6108 comparisons. Decoding a prefix is a distinct operation, not a substring of
  the full decode. **`game decode board (13 fields)`** repeats that sweep over
  every public field of the decoded `Board` — see §5.2.
- **`v1 corpus`** decodes the historical base64 golden data captured before the
  port, proving the Flix reader accepts the on-disk format and not merely its own
  writer's output.
- **The SAN fuzz** was added specifically because three earlier review passes
  flagged the hand-written matcher (§2.6) as "verified on real games but not
  proven". 139225 comparisons against `java.util.regex` via the original: random
  strings over the pattern's alphabet, an exhaustive enumeration of all 103680
  shapes the pattern can take, tokens buried in leading and trailing junk (which a
  matcher that only tried offset 0 would fail), and single-character mutations of
  real tokens.
- The counts in parentheses are the test's **discriminating power**, reported
  deliberately. A token that names no legal move returns `null` from both sides, so
  a difference in capture groups 1–5 would be invisible. The
  `redundant disambiguation` case exists to fix that: it rebuilds each ply of 30
  real games with redundant-but-satisfied file/rank disambiguators, a redundant
  `x`, and a trailing `+`, so **9588 of its 9605 cases genuinely encode a move**
  and therefore exercise every capture group on a real legal position.

The differential has been shown to have teeth: a prior run deliberately perturbed
the facade (`startTime + 8`, `halfMoveClock + 1`) and flipped 12/13 clock encodes
and all 6108 game decodes to MISMATCHED.

### 4.3 Perft — and exactly how much of it is in the repo

Perft (counting the leaves of the legal-move tree) is the only test that
meaningfully validates a move generator: one wrong bit anywhere in attack
generation, pin detection, check evasion, castling, en passant or promotion changes
the number.

`PerftTest.scala` holds 6838 generated `gentest-` positions across `batch0`..
`batch17`, plus a hand-picked `trickyBatch` — **6854** assertions in total. (An
earlier revision said 6855, from `grep -c 'assertEqual(' src/test/scala/PerftTest.scala`.
That grep's 6855th hit is the *definition*, `private def assertEqual` at
`PerftTest.scala:22`. There are 6854 real assertions: 16 in `trickyBatch` and 6838
`gentest-` blocks, one per position, all at depth 4.)

**The sweep is now reproduced, and reproducible.** One command, from the
repository root:

```
bash scripts/perft-sweep.sh            # the Flix port
bash scripts/perft-sweep.sh --scala    # the original Scala
```

Measured on this machine (16-core, Flix 0.75.1, JVM 25), both runs from the same
committed corpus file:

```
[perft] flix  depth4 rows=6838 nodes=4135458706 checksum=8459721354967636746 mismatches=0
[perft] scala depth4 rows=6838 nodes=4135458706 checksum=8459721354967636746 mismatches=0
```

That is 4 135 458 706 nodes each, 0 mismatches against the corpus's own expected
counts, and **the same checksum** — see below for what the checksum covers.

Wall clock, each run alone on the box (16 cores; both drivers are single-threaded):

| | sweep proper | end to end |
|---|---:|---:|
| Flix (`perft-sweep.sh`) | **79 s** | 104 s (incl. `flix build-jar`) |
| Scala (`perft-sweep.sh --scala`) | **160.5 s** | 176 s (incl. sbt start + compile) |

**The Flix sweep is 2.03× faster than the Scala one** over identical work and an
identical move-order-sensitive checksum.

Before the optimisation campaign of §5.8 this table read **494 s against 161 s**,
i.e. 3.07× the other way. Both figures were measured on this machine with this
script; the Scala row reproduced its 161 s at 160.5 s in the same session as the
79 s, which is the control that says the Flix change is the code and not the box.
An earlier pass reported 497 s and 162 s for the pre-campaign figures — agreement
to within 1%.

Both scripts print their own sweep-proper figure (`[perft] … wall … s`), so this is
re-measurable rather than quoted. The **3.1x gap is a real signal and not an
artefact of the harness**: the two drivers are deliberately identical in shape — a
fresh `MoveList` per node, `copy()` + `play()` per child, the same fold order — and
they visit exactly the same 4.1e9 nodes. It is the first end-to-end performance
comparison of the port that exists; §5.5 (the benchmarks project) is where a
controlled measurement belongs, and this number should be read as "there is
something worth measuring", not as a benchmark result.

#### How it is wired

| piece | what it does |
|---|---|
| `tools/extract-perft-corpus.py` | parses the 6838 `// gentest-N` blocks out of the 69023-line `PerftTest.scala` into a flat CSV |
| `flix/test/data/perft-corpus.csv` | the corpus, committed: 6838 rows, 920 KB, sha256 `b5ef6c8c…ba7b0c` |
| `flix/test/PerftSweep.flix` | the Flix driver, `mod PerftSweep` with a mod-scoped `main` |
| `flix/test/TestPerftSweep.flix` | the cheap tier: all 6838 positions at depth 2, inside `flix test` |
| `difftest/…/PerftCorpusTest.scala` | the Scala driver, same corpus, same checksum |
| `scripts/perft-sweep.sh` | the depth-4 entry point for both |
| `.github/workflows/perft-sweep.yml` | weekly + on-demand CI for the depth-4 pair |

The extractor is self-checking: it exits non-zero unless it parsed exactly 6838
blocks numbered 1..6838 with no gaps **and** their expected node counts sum to
4 135 458 706. That last assertion is independent of how the script chooses to
spell a bitboard, so it catches a mangled field that a row count would not.
Regeneration is idempotent:

```
$ python3 tools/extract-perft-corpus.py src/test/scala/PerftTest.scala > /tmp/c.csv
rows=6838
sha256=b5ef6c8c2583312e234eecc60ab6ea1eb46cd47a996d39c6c34d003a99ba7b0c
nodes=4135458706
$ diff /tmp/c.csv flix/test/data/perft-corpus.csv && echo identical
identical
```

Bitboards are stored as **signed decimals**, not the hex the Scala source uses,
because Flix rejects an `Int64` hex literal with the top bit set and
`Int64.fromString` has no radix form (see `PORTING-NOTES.md` §2.6). Signed decimal
is also exactly what `java.lang.Long.parseLong` reads, so the two drivers agree on
the file by construction rather than by convention.

#### The checksum, and why node counts alone are not enough

Two move generators can agree on every leaf count while emitting moves in a
different order or with different `score`s — and move order is load-bearing in this
library, because `Encoder` selects a move by its **rank in the ordered list**. A
reordering would leave every perft number untouched and silently change the
compressed bytes. So both drivers also fold every generated move into one running
64-bit value:

```
k = (from << 48) | (to << 40) | (score & 0xffffffff)    // per move, in generation order
h = ((h << 5) + h) ^ k
h = ((h << 5) + h) ^ n                                  // once per node, after the move loop
```

`h` starts at 0 for the whole run and threads through every node of every row in
corpus order, so it is sensitive to move order, move contents, node order and row
order at once. The two implementations printing the same number is the actual
result; the literal constants asserted in the two test files are only a tripwire
against both sides drifting together.

#### What runs on every `flix test`

- **All 6838 corpus positions at depth 2** — `TestPerftSweep.testCorpusDepth2`,
  4 689 446 nodes, checksum `-6849308306848708094`, **0.6 s**. Every position is
  visited and the checksum covers every move generated at plies 1 and 2 of every
  one of them. `PerftCorpusTest` asserts the identical triple on the Scala side.
- **An 87-position subset at depth 4** — `TestBoard.gentestA()..gentestD()`,
  **60 568 155** nodes. The subset was chosen by feature, not at random: every
  position with a legal en passant at the root, the one double check, every
  checkmate and stalemate, every position with two or more pinned pieces, one
  position per distinct `castlingRights` value (all sixteen), the largest node
  count in the file, and a deterministic every-683rd sample. Expected values are
  transcribed from the Scala data and from chessprogramming.org, never read off the
  Flix implementation.
- **The six standard "tricky" positions** to depths 4–6.

> The subset is **87** positions and **60 568 155** nodes, not the "88 positions,
> roughly 100M nodes" this document used to claim. Method: count the distinct
> `("gentest-N",` entries inside `gentestA()..gentestD()` and sum the depth-4
> expected values in them — 22 + 22 + 22 + 21 = 87, and the four part headers at
> `TestBoard.flix:173/377/581/785` already say 22/22/22/21. Only the file header at
> `TestBoard.flix:20` said 88. Note that
> `grep -o 'gentest-[0-9]*' flix/test/TestBoard.flix | sort -u | wc -l` returns 88
> and is misleading: `[0-9]*` matches zero digits, so the literal `gentest-N` in
> the doc comment at `TestBoard.flix:16` counts as an 88th "id".

#### The Scala-side driver was never actually lost

The claim that the sweep had been run "via a generated throwaway driver that was
not kept" was half right — the *Flix* driver was gone, but the Scala one is still
in the tree. `src/test/scala/HuffmanPgnTest.scala:165-186` holds
`PerftTest.batch0()..batch16()` inside a `/* */` block, with `trickyBatch()` and
`batch17()` left live. It is commented out **deliberately** — enabling it would add
minutes to every `sbt test` — and it is left that way. `PerftCorpusTest` and
`scripts/perft-sweep.sh --scala` are the opt-in path instead, and they check more
than the commented block would: the block only asserts node counts, and only inside
`PerftTest` itself.

#### In CI

Before this round **nothing in the Flix port ran in CI at all**:
`.github/workflows/test.yml` ran only `sbt test` and `sbt benchmarks/compile`, and
`lazy val root` has no `.aggregate`, so `sbt test` reached only the original Scala
tests. `flix test` and `sbt difftest/test` were developer-machine-only, which is
the same class of defect as the unreproducible sweep.

- **`test.yml`** now installs the Flix 0.75.1 compiler (cached, and exposed as an
  executable named `flix` on `PATH`, because `build.sbt`'s `flixJar` task shells
  out to literally `flix build-jar`) *before* the sbt steps, then runs `flix test`
  and `sbt difftest/test` alongside the existing steps. That puts the depth-2 pass
  over all 6838 positions, on both implementations, on every push.
- **`perft-sweep.yml`** is a separate `workflow_dispatch` + weekly job that
  regenerates the corpus from `PerftTest.scala` and `diff`s it against the
  committed file, then runs the depth-4 sweep on both implementations. It is not on
  every push because the pair takes about eleven minutes.

`flix/build/` is deliberately not cached in either workflow: `flix build-jar`
packages whatever is in it and never prunes it (see §4.1).

### 4.4 Thread safety — newly tested

The facade documents the codecs as safe to call from any number of threads with no
per-thread state, on the reasoning in §2.3. That claim had never been executed, and
it is not free — the original keeps a `ThreadLocal[MoveList]` precisely because its
scratch buffer is shared, and the two shared values behind the facade are reached
through `lazy val`s that many threads hit at once on a cold JVM.

`difftest/…/ConcurrencyTest.scala` now covers it: 3 examples, 0 failures. It races
the *first* call so the `lazy val`s initialise under contention, then runs encode
and decode concurrently across `max(4, availableProcessors)` threads on distinct
inputs, comparing every result against the single-threaded Scala answer — so a torn
read of the shared tables surfaces as a wrong answer, not merely as a crash.

This is a probabilistic test, as all concurrency tests are; it demonstrates the
absence of an obvious race, not the absence of all races. The structural argument
in §2.3 is the real basis for the claim, and the test corroborates it.

### 4.5 Static-data integrity

Every hand-transcribable constant table was compared mechanically against the Scala
source rather than by eye, by scripts that parse both files:

| table | entries | result |
|---|---:|---|
| `Magic` rook/bishop mask, factor, offset | 384 | all match |
| `ZobristHash` Polyglot keys | 781 | all match, all within 24 bits |
| `Huffman` code table | 256 | all match; Kraft sum exactly 1.0, no code a prefix of another, longest 31 bits |
| `Psqt` piece-square table | 384 | all match, including the deliberate 21/−31/11 asymmetries |
| `Bitboard` leaper/ray/between/magic tables | — | checksummed against the compiled Scala over all 4096 square pairs and 96000 magic lookups |

The Huffman result also confirms that dropping the original's
`assert(bits <= 32)` in `buildTree` is sound: the code is a complete prefix code, so
recursion always reaches a leaf by depth 31.

### 4.6 What is *not* verified

Stated plainly, because the rest of this section is a list of green results:

- **~~The full 6838-position perft sweep.~~** No longer on this list. It was here
  as "claimed by an earlier pass, not reproduced here, not in the repo". It has now
  been run on both implementations from a committed corpus, agreeing on
  4 135 458 706 nodes and on a move-level checksum, and is re-runnable with
  `bash scripts/perft-sweep.sh` — see §4.3. What remains unproven about it is only
  the depth: the corpus records depth-4 expectations, so nothing here says anything
  about behaviour deeper than four plies from those roots.
- **Perft coverage of the *codec*, as opposed to the move generator.** The sweep
  proves move generation and `play`; it does not touch Huffman coding, the clock
  encoder or the bit reader. §4.2 is what covers those.
- **~~Error-path fidelity.~~** No longer on this list either. It was here as "the
  differential compares outputs, not thrown exceptions, and does not fuzz corrupt
  bit streams". `ExceptionParityTest` now does both: five fixed cases plus a seeded
  1000-input fuzz over random byte streams and ply counts from −5 to 39, asserting
  the exception *class name and message* agree on every input, and asserting equal
  decoded values on the 210 inputs that do not throw. See §5.1. What remains
  unproven is the same thing fuzzing always leaves unproven — 1005 failure paths is
  evidence, not a proof of equivalence — plus one *deliberate* non-parity, the
  `Bitboard.msb` assert, which the test pins rather than hides.
- **The SAN matcher for arbitrary strings.** 139225 fuzzed comparisons is strong
  evidence, not a proof of equivalence.
- **Unused public API.** `MoveList.push`, `MoveList.pretty`, `MoveList.toList`
  (which has no Scala counterpart at all), `Move.compare`, `Board.pieceMap` and
  `Board.roleAt` are kept for parity with the original classes but are exercised by
  no test and no code path. They were verified by reading against the Scala source
  only.
- **~~Performance.~~** No longer on this list. `benchmarks/` now measures both
  implementations in one JVM: the port is ~5× slower on the game codec, ~3-4× on
  the clock codec, and allocates 10-90× more. §5.7, and `benchmarks/results.md`
  for the tables. What remains unverified about it is the *baseline*: the
  pre-existing Scala-only numbers in `results.md` do not reproduce on this machine,
  and never recorded which JVM produced them, so nothing here says how either
  implementation compares to a historical measurement.

---

## 5. Known gaps and follow-up work

### 5.1 Invalid input fails differently — **closed**

**Status: fixed, and the two claims this section used to make were both wrong.**
It said the divergence mattered "only to a caller that catches by type", and that
fixing it "needs an error effect and would change `decode`'s signature". Neither
survives contact with the compiler.

**It was not a matter of taste.** `bug!` is not a Flix-flavoured
`IllegalArgumentException`. `Prelude.flix:158-166` shows what it expands to:

```flix
pub def bug!(m: String): a = unsafe IO {
    System.err.println("*".repeat(80));
    ...
    ?panic
}
```

`?panic` throws `dev.flix.runtime.HoleError$`, which extends
`dev.flix.runtime.FlixError$`, which extends **`java.lang.Error`**. A caller
written against the original catches `IllegalArgumentException` — `catch (Exception
e)` in Java, `case e: Exception` in Scala — and an `Error` goes straight past that.
The corrupt-stream branch a caller had written and tested therefore did not run,
and the exception unwound its whole stack instead. That is a behavioural
regression, not a cosmetic one. On the way out it also prints a six-line
`** BUG:` banner to stderr, which is not something a codec should do to a caller's
logs on bad input.

**It did not need an error effect.** `unsafe IO { throw new X(...) }` is the Flix
standard library's own idiom for raising a Java exception from a function that is
not `IO`; `Prelude.flix:176-178` uses exactly that shape for `indexOutOfBounds!`.
It changes no signature. `MoveList.get` and `MoveList.selectRank` still declare
`\ r`, `BitReader.getUnsigned` still declares `\ r`, and `Api.gameDecode` still
declares `\ IO` because it always did. The whole fix is three source edits:

| site | was | now |
|---|---|---|
| `MoveList.get` | `bug!` → `HoleError$` | `IllegalArgumentException("requirement failed")` |
| `MoveList.selectRank` | `bug!` → `HoleError$` | `IllegalArgumentException("requirement failed")` |
| `BitReader.getUnsigned` | bare `Array.get` → `ArrayIndexOutOfBoundsException` | explicit bound → `BufferUnderflowException` |
| `Api.gameDecode` | negative `plies` → `ArrayIndexOutOfBoundsException` | `NegativeArraySizeException(plies)` |

The bound in `getUnsigned` costs a length load and a compare per input byte and
nothing else: `Array.length` is `%%ARRAY_LENGTH%%` (`Array.flix:144`), i.e. pure
and one `arraylength` instruction, so the declared effect is unchanged. Its cost
was measured directly, by rebuilding `flix.jar` from a copy of the tree with the
guard removed and running `FlixGameBench.flixDecode` both ways under identical
settings:

| band | with the guard | without | delta |
|---|---:|---:|---:|
| short  | 1019.787 ± 7.152 us | 1006.787 ± 5.654 us | +1.3% |
| median | 1942.715 ± 34.346 us | 1915.844 ± 7.799 us | +1.4% |
| long   | 3740.299 ± 31.365 us | 3762.464 ± 11.336 us | **−0.6%** |

The longest band goes the *other* way, so the effect is not distinguishable from
run-to-run variation; at most it is ~1.5% of a decode that is already 5× the
original's. Exception parity is not paid for in throughput.

**Evidence.** `difftest/src/test/scala/ExceptionParityTest.scala` is the test: five
fixed cases (four failures plus a negative control that must *not* throw), the
documented non-parity below, and a seeded 1000-input fuzz that compares
`getClass.getName` and `getMessage` on both sides. It catches `Throwable`, not
`Exception` — catching `Exception` would have missed the very defect it is testing,
and `NonFatal` matches a plain `Error` so it is useless as a discriminator. It
currently reports

```
[exn] failure parity (fixed cases)           5 / 5     matched
[exn] fuzz: typeMismatch=0 bothThrew=790 valueEqual=210 valueDiff=0
[exn] failure parity (fuzz)               1000 / 1000  matched
```

— 790 of the 1000 inputs abort, now with identical exception type *and* message on
both sides where before the fix they differed, and the other 210 decode to equal
values, so the suite cannot be satisfied by simply making everything throw.
`flix test` is unaffected: 122 passed / 0 failed / 4 skipped.

Two divergences were missing from this section's old list:

- **Negative `plies`.** The original hits `Array.ofDim[String](plies)`
  (`game/Encoder.scala:79`) and raises `NegativeArraySizeException`; the port
  reached an array bound instead. Now guarded at the JVM boundary in `Api.flix`.
- **The encode-path `Bitboard.msb` assert.** `Bitboard.lsb`/`msb` on an empty
  bitboard: the original's `assert(b != 0)` throws `java.lang.AssertionError`, the
  port throws `HoleError$`. **Deliberately not closed.** Both are
  `java.lang.Error`, so the catchability argument that justifies the edits above
  does not apply; Scala's `assert` is elidable with `-Xdisable-assertions`, so
  pinning its type would codify a build flag rather than a contract; and
  `Bitboard.lsb` is the hottest function in the port (§5.7), which makes it the one
  place a parity edit could cost throughput. `ExceptionParityTest` asserts the
  property a caller can actually observe — both sides throw, and both throw
  something `catch (Exception e)` misses.

Two smaller items from the old list stand, both unreachable and neither affecting
an encoded byte. `BitOps.bitMask(32)` returns 0 where Scala's `BitMasks(32)` threw
(the maximum width anywhere in the library is mechanically confirmed to be 31).
`Huffman.write` outside 0..255 goes through `Vector.get(i, v)`, which is the
**unchecked** intrinsic `%%VECTOR_GET%%` (`Vector.flix:229`) and raises a plain
`java.lang.ArrayIndexOutOfBoundsException` — the same class the original raises,
not, as this section used to imply, some distinct "`Vector.get` exception". (The
*checked* `Vector.get(t, i): a \ OutOfBounds` at `Vector.flix:25` is a different
function that the port does not use.)

### 5.2 `DecodeResult.board` — **closed**

**Status: fixed.** `DecodeResult.board` used to be a two-field
`Board(castlingRights: Long, turn: Boolean)`. It now carries **all thirteen public
fields of the original `Board`**: the nine bitboards, `turn`, `epSquare`,
`castlingRights` and `incrementalHash`.

The Flix `Board` still cannot cross the export boundary — an `@Export` may mention
only primitives and `java.lang.Object` — so the thirteen come across one scalar at
a time through thirteen `result*` accessors in `Api.flix`, and the Scala facade
reassembles them into an immutable snapshot. That is the "cheap fix, each three
lines" this section used to recommend, carried out.

Two of the thirteen are not observable anywhere else and are why this is worth
having: `epSquare` is the only piece of position state the nine bitboards do not
determine, and `incrementalHash` is the *full* Zobrist hash where
`DecodeResult.positionHashes` keeps only its top three bytes.

The proof is `difftest`'s "expose the full decoded Board identically" example,
which compares all thirteen fields against the original's `Board` field by field
over 6108 decodes, plus a guard that the two field extractors are in step so a
reordering cannot make it compare `pawns` against `knights`.

The drop-in artifact needed more than the facade did. lila writes

```scala
import org.lichess.compression.game.{ Encoder, Board as JavaBoard }
```

and `Board as JavaBoard` binds a **package-level** type, which no type member of
`object Encoder` can satisfy however many fields it has — the compiler says
`value Board is not a member of org.lichess.compression.game`. So
`scala-api-dropin` now declares a real package-level `Board`, and
`LilaSourceCompatWitness.scala` compiles lila's exact import and field reads so
that `sbt scalaApiDropin/compile` is the check rather than a paragraph.

What is still absent, on purpose: the original `Board`'s **methods**. `roleAt`,
`whiteAt`, `pieceMap`, `us`, `them` and `byColor` are pure functions of the nine
bitboards and are cheaper to recompute than to marshal; `copy`, `play`,
`legalMoves`, `isCheck`, `zobristHash` and `hasLegalEnPassant` are the move
generator, and exposing them would mean marshalling `Move`, `Role` and `MoveList`
too. This artifact is a codec.

### 5.3 `Bitboard.squareSet` iteration order

Returns Flix's *ordered* `Set[Int32]`; Scala builds a mutable `HashSet` and calls
`.toSet`, so iteration order differs.

An earlier revision of this section justified that as harmless by saying
"`grep -rn squareSet src/main/scala/` finds no caller — it is dead code in the
original". **That is false**: the grep was scoped to `src/main/scala/` only, and
`squareSet` has two live callers in the test sources —
`src/test/scala/HuffmanPgnTest.scala:42` and `:45`:

```scala
Bitboard.squareSet(d1.board.castlingRights) must_== Set(0, 7, 56, 63)
Bitboard.squareSet(d2.board.castlingRights) must_== Set(0, 7, 56)
```

The practical conclusion survives, but for a different reason. Both call sites
compare the result against an **unordered `Set` literal**, and `Set` equality does
not look at iteration order, so the difference is genuinely unobservable at those
two sites. It is not dead code; it is live code whose only uses happen not to
depend on the property that differs. Any future order-sensitive use — iterating it,
printing it, folding over it — would still diverge.

### 5.4 Test classes ship in the jar, and `flix/build/` accumulates

Flix has no test scope. `flix build-jar` compiles every `.flix` file in the
project, so the `@Test` modules from **both** `src/` and `test/` are emitted into
the artifact — **710 of 1744 class entries** on a clean build. Moving the in-`src/`
self-test modules to `test/` would *not* change this; an earlier recommendation to
do so on those grounds was mistaken.

`sbt flixReleaseJar` now strips them, producing `artifact/flix-release.jar` at
**0.8 MB from 2.0 MB**. It is a separate task rather than a change to `flixJar`,
because `difftest` should keep running against exactly the bytes the developer
built. Re-verified for this revision by copying `flix-release.jar` over
`flix.jar` and re-running: the stripped jar passes the full differential suite,
25 examples / 0 failures, so nothing outside the `Test` modules depends on them.

Separately, and worth knowing before quoting any jar size: **`flix/build/`
accumulates stale classes across incremental builds and is never pruned.** The
tree as left by development produced an 18.5 MB / 13762-entry jar and the tree as
left by this round's four parallel agents reached 23 MB; after
`rm -rf flix/build flix/artifact` the identical sources produced 2.0 MB / 1744
entries. All of them pass the differential, so this is dead weight rather than a
correctness problem — but earlier notes and review reports quoting 12 MB, 19 MB
and "3.0 MB / 2485 entries" were all measuring builds with history behind them.
A release build must start clean. See the caveat in §4.1.

### 5.5 The benchmarks project — **closed**

**Status: done.** `benchmarks/` now `dependsOn(root, scalaApi)` and measures both
implementations side by side. The headline numbers are in §5.7 and the tables are
in `benchmarks/results.md`. What follows is what this section used to advise, with
one item corrected because it does not work.

**`hideFlixJar` — right, and more necessary here than anywhere else.** A JMH
project is the worst possible victim of the default-package hazard of §3.3, because
`@BenchmarkMode(Array(Mode.AverageTime))` is not a style choice: an annotation
argument of array type has to be spelled that way, and it appears in every
benchmark class. Verified as a negative control by deleting the line and running
`sbt benchmarks/clean benchmarks/compile`:

```
[error] -- [E050] Type Error: .../BitOpsTest.scala:10:15
[error] 10 |@BenchmarkMode(Array(Mode.AverageTime))
[error]    |               ^^^^^
[error]    |               package Array does not take parameters
```

in seven files, plus `package List does not take parameters` on `Corpus`'s fixture
list. The hazard is at least self-detecting: it fails the build loudly rather than
miscompiling.

**"a runtime `unmanagedJars` entry, exactly as `difftest` does" — WRONG.** That is
the one piece of advice here that does not work, and it fails silently in the sense
that the build succeeds and every Flix benchmark then dies in `@Setup` with a
`ClassNotFoundException`. sbt-jmh 0.4.7 defines the whole `Jmh` configuration in
terms of `Compile`:

```scala
Jmh / dependencyClasspath := (Compile / dependencyClasspath).value
```

It never reads `Runtime` at all. Verified with
`sbt 'print benchmarks/Jmh/dependencyClasspath'` against
`sbt 'print benchmarks/Compile/dependencyClasspath'` on the unmodified build: the
two lists were element for element identical. The line that works is

```scala
Jmh / dependencyClasspath += Attributed.blank(flixJar.value)
```

which puts the jar exactly where the forked benchmark JVM looks and, because it is
not `Compile`, leaves the compile classpath clean. The two `print` commands are the
regression test for it: `Compile` must contain zero `flix.jar` entries and `Jmh`
exactly one.

**"put table construction in `@Setup`" — right, and now with a number.** The A/B
is in the repository as `SetupPlacementBench.scala`, two classes differing by one
line, run with
`sbt 'benchmarks/Jmh/run -f 10 -wi 0 -i 1 -bm ss .*SetupPlacement.*'`:

```
SetupPlacementTablesInsideBench.encode    ss   10  140.346 ± 5.907  ms/op
SetupPlacementTablesForcedBench.encode    ss   10   42.892 ± 2.869  ms/op
```

**About 97 ms moved out of the score by placement alone** — the measured score
more than triples if the line is missing. Because the facade's `Flix.tables` is
`private[flix]`, the only way to force it is one throwaway call through the public
API — `FlixEncoder.encode(Array("e4"))` — and that line in `FlixGameBench.setup` is
load-bearing rather than dead code.

> **This row is the one benchmark in this document that did not reproduce.** An
> earlier revision reported `209.095 ± 10.340` against `46.730 ± 2.169`, i.e.
> "~162 ms". Re-running the identical committed command twice for this revision
> gave `140.346 / 42.892` and `143.438 / 42.413` — internally consistent to ±2%,
> and disagreeing with the published `inside` figure by a third. The `forced` side
> reproduces fine; it is the *unforced* side, a single shot of one-time table
> construction in a cold JVM, that is machine-state sensitive. **The conclusion is
> unaffected** — placement is worth roughly 100 ms and more than a 3× difference in
> the reported score — but quote the range, not a single number, and re-run the
> command rather than citing either figure.

`ColdStartFlixBench` measures the same one-time cost honestly, from the other side,
in a JVM that has never run the codec: 107.598 ± 1.912 ms against Scala's
67.409 ± 2.226 ms (independently re-measured for this revision at 109.406 ± 4.236
and 67.344 ± 1.530 — this one does reproduce).

**"region allocation is the interesting variable, which is why the depth-4 sweep
takes minutes" — WRONG, and the attribution was wrong too.** The sweep takes
minutes because it is 4 135 458 706 nodes. Measured on this box, each run alone:
**494 s in Flix against 161 s in Scala** for identical work — see §4.3, which is
where those two numbers are produced by a committed script.

> Both halves of that sentence have since been overtaken. §5.8's campaign took the
> Flix sweep to **79 s** against the same 160.5 s of Scala, i.e. 2.03× *faster*,
> and it did so by attacking the calling convention and the data representation —
> never region allocation, which this paragraph was already right to dismiss.
> §4.3 carries the current figures.

> An earlier revision of this section said "8m39s against 5m10s". Neither figure is
> reproducible here and the second is not even close: the Scala sweep is 161 s, not
> 310 s. Those numbers came from a review pass in which the two sweeps were run
> *concurrently*, contending for the same box, and they were transcribed into this
> section without being re-run. They have been replaced by §4.3's, which were
> measured twice, alone, and agree to within 1%. The ratio the section argues from
> goes **up**, from 1.7× to 3.1×.

The three region-shaped hypotheses were isolated and measured on the full sweep,
and they are not where the time goes:

| hypothesis | share of the full sweep |
|---|---:|
| region opened per child | 0.7% |
| `Board` struct allocated per node | 0.8% |
| `MoveList` allocated per node | 6.1% |

> **These three percentages are NOT reproducible from this repository, and were not
> reproduced for this revision.** No committed benchmark produces them; they come
> from a profiling pass whose harness was not kept. That is the same failure mode
> the perft claim in §4.6 used to have, so it is flagged here rather than left to
> the fine print. Re-measure before quoting any of them. What *is* verified is the
> conclusion they support — that the port is several times slower — and that is
> verified independently, by §4.3's sweep and §5.7's JMH tables.

The real attribution, from the same profiling pass and under the same caveat, is
the parts of Flix that are not visible in the source at all. The **mechanisms**
below were each confirmed against the Flix 0.75.1 standard-library source for this
revision; only the percentages attached to them are unreproduced:

- **The calling convention.** Flix boxes through `Value$` and drives calls through
  a `Thunk$`/`Suspension$` trampoline; that accounted for 52% of allocation samples
  against 1.4% for the `Board`. There is no *compiler flag* for it (see
  PORTING-NOTES: `flix --help`'s `--X` options are compiler diagnostics only — no
  `-O`, no inliner threshold, no way to turn the trampoline off).

  > **"There is no source-level lever for it" — WRONG, and this was the campaign's
  > single most valuable correction.** There are two, and together they are most of
  > §5.8's win. A call to a *different* def in **tail position** is compiled to a
  > heap continuation dispatched through a megamorphic `invokeinterface`; a trailing
  > `; ()` moves it out of tail position and it becomes a bare `invokestatic`, which
  > was worth **2.1× on the clock codec** on its own. And `@Inline` on a small def
  > deletes both its `Value$` box and its trampoline entry outright. The trampoline
  > cannot be turned off globally, but it can be kept out of every hot path, and
  > that is what took this port past the original. PORTING-NOTES has both mechanisms
  > with the disassembly.
- **`Int64.numberOfTrailingZeros`.** 14% of execution samples. Mechanism
  re-verified at `Int64.flix:265`: it delegates to `lowestOneBitPosition` (`:206`),
  which delegates to `oneBitPositionHelper` (`:215`) — a **linear scan that tests
  one bit at a time** via `getBit`. Java's is a single `TZCNT`. `Bitboard.lsb` is
  the hottest function in the port and this is why. *(Confirmed by §5.8: replacing
  it was the largest single win of the campaign, worth roughly 1.25× on the game
  codec by itself.)*
- **`Int64.logicalRightShift`.** Mechanism re-verified at `Int64.flix:138`: the
  signature really is `logicalRightShift(dist: {dist = Int32}, x: Int64)` — the
  shift distance arrives as a **record**, on a function called once per ray step.

These are language-runtime costs, not design costs, which is the distinction §5.7
turns on. That distinction does not depend on the unreproduced percentages: the
mechanisms are in the standard library where anyone can read them, and §5.7's JMH
tables measure their aggregate effect without attributing it.

### 5.6 Build aggregation

The root project has no `.aggregate(...)`, so a bare `sbt compile` does not build
the new subprojects (it did not aggregate `benchmarks` either). Build them
explicitly: `sbt scalaApi/compile`, `sbt scalaApiDropin/compile`,
`sbt difftest/test`. This was left alone deliberately rather than risk changing
what `sbt publish` emits for root.

Also note the `flixJar` staleness guard compares `.flix` file timestamps against
the jar; it does not notice changes to `flix.toml` or to Flix's own dependencies.
Delete the jar to force a full rebuild.

### 5.7 Measured cost of the port

> **Superseded by §5.8.** This section records the port *as first written*, before
> the optimisation campaign. Its figures are the starting point that §5.8 measures
> against, not the current state: game encode is now **faster** than the original
> and the worst remaining row is 1.35x rather than 5.3x. The section is kept intact
> because §5.8's before/after columns are meaningless without it, and because its
> analysis of *where* the cost came from is what the campaign then acted on.

The first measurement of the Flix port against the original. Full tables, commands,
toolchain and caveats are in `benchmarks/results.md`; this is the summary.

Both implementations are measured **in the same JVM, in the same run, on the same
inputs**, with a byte-equality `require` in `@Setup` so that a fork which returns a
wrong answer dies rather than publishing a fast number.

| operation | Flix / Scala, wall time | Flix / Scala, bytes allocated | after §5.8 |
|---|---:|---:|---:|
| game encode | **4.9-5.3×** | **24.6-26.4×** | **0.82-0.88×** / **0.34-0.47×** |
| game decode | **4.6-5.3×** | **83.7-90.0×** | 1.02-1.11× / 2.30-3.11× |
| clock encode | **4.2-4.3×** | 10.1× | 1.27-1.35× / 1.28-1.53× |
| clock decode | **2.7-3.9×** | 26.0× | 1.15-1.31× / 1.45-3.33× |
| first encode in a cold JVM | 107.598 ms vs 67.409 ms (**1.60×**, +40 ms) | 1 318 099 B vs 41 085 B | 76.2 ms vs 68.6 ms (1.11×) |

The ratios are flat across three length bands, so this is a constant factor on the
per-ply work rather than an overhead that amortises over longer games.

`gc.alloc.rate.norm` is the co-primary axis, not a footnote. It is reproducible to
the byte — most rows carry an error of ±0.001 B/op — where wall time is not, and it
is the sharper result: **the port allocates one to two orders of magnitude more than
the original to produce the identical bytes.** §5.5 attributes the bulk of that to
the Flix calling convention rather than to anything visible in the port's source.

The facade is not the cost. A `flixEncodeRawBridge` control that bypasses the
facade's two per-call `lazy val` reads differs from the facade path by −0.5% to
+1.5%, with an inconsistent sign and inside the error bars, and allocates
11 284 655 B/op against the facade's 11 263 140. The 5× is the port.

**Machine and toolchain**: 16 logical CPUs, 62 GB, Linux 7.1.5; JDK 25.0.3 (Oracle
GraalVM `25.0.3+9-LTS-jvmci-b01`, Graal JIT); JMH 1.37 with compiler blackholes in
use for every run; `-Xms4g -Xmx4g -XX:+AlwaysPreTouch`; two forks, five warmup and
five measured iterations of 2 s. Load average 2-4 throughout — **not an idle
machine**, and said here rather than omitted.

**The sanity gate did not pass, and that is worth knowing.** Re-running the
pre-existing Scala-only benchmarks with their historical settings does *not*
reproduce the numbers at the top of `benchmarks/results.md`: the differences go in
both directions and reach ±50%. Today's numbers are internally very reproducible
(two independent sweeps 25 minutes apart agree to under 1%, error bars ~0.3%), and
the JIT alone moves individual scores by up to 2× — Temurin 25.0.3 gives
`OverallEncodingTest.testEncode` at 230.803 ns/op where GraalVM 25.0.3 gives
117.703. Neither reproduces the historical table, which never recorded which JVM
produced it. The old rows are therefore not a usable baseline. The Flix-versus-Scala
ratios are unaffected, because both halves of every ratio were produced minutes
apart in one JVM under one JIT and one blackhole mode.

**Honesty caveats.**

- **This is not a language benchmark.** Both halves run on the same JVM, JIT and
  GC. What is measured is the *shape the port was forced into*: regions instead of
  a `ThreadLocal` scratch buffer, immutable structures instead of in-place
  mutation, a `Tables` value threaded through every call instead of static fields —
  plus the Flix runtime's own calling convention.
- **The facade is inside the measurement.** A decode is followed by seventeen
  separate `result*` accessor calls (thirteen board fields after §5.2, plus four
  result fields). The raw-bridge control bounds the wrapper's cost on the *encode*
  path at nothing measurable; there is no equivalent control on the decode path, so
  the accessor cost is included there but not separated out.
- **Correctness is equal.** The differential suite asserts byte-for-byte agreement,
  and each Flix benchmark re-asserts it in `@Setup`. So the slowdown buys nothing:
  it is a **cost with no correctness benefit attached**, and should be reported as
  a cost rather than dressed up as a trade-off. What the port buys is elsewhere —
  no `ThreadLocal`, no shared mutable state, and a compiler that enforces both.

### 5.8 The optimisation campaign — what was applied, what it bought, what was reverted

**This section used to list three optimisations as "measured and deliberately not
applied". They have now been applied, along with a dozen more.** The numbers below
are from `benchmarks/run-optimised/`, produced by
`bash scripts/run-benchmarks.sh` and derived from JMH's own JSON by
`python3 scripts/compare-benchmarks.py benchmarks/run-hw benchmarks/run-optimised`.
Unlike the estimates this section used to carry, every figure here is reproducible
from the repository.

#### The result

| axis | before | after |
|---|---:|---:|
| game encode, three bands | 5.08-5.30x slower | **0.82-0.88x — faster than Scala** |
| game encode allocation | 24.6-26.9x | **0.34-0.47x — below Scala** |
| perft depth-4, 4 135 458 706 nodes | 494 s vs 161 s (3.07x slower) | **79 s vs 160.5 s — 2.03x faster** |
| game decode | 4.72-5.38x slower | 1.02-1.11x slower |
| clock encode | 4.24-4.43x slower | 1.27-1.35x slower |
| clock decode | 2.75-3.98x slower | 1.15-1.31x slower |
| game decode allocation | 78.9-94.9x | 2.30-3.11x |
| cold start | 172.3 ms vs 69.1 ms | 76.2 ms vs 68.6 ms |

**The target was to beat the Scala original. Game encode and move generation beat
it; game decode and both clock directions do not.** Nine of the twelve throughput
rows are still on the slow side of parity; the three that are not are game encode.
Full tables, caveats and the machine-did-not-move control are in
`benchmarks/results.md`.

Every change was gated on `sbt difftest/test` — **emitted bytes**, not node counts —
and on `flix test`. Both were re-run after every individual change and again at the
end: 25 examples / 0 failures, and 122 passed / 0 failed / 4 skipped.

#### What was applied

Ordered by measured effect, largest first.

**1. `Bitboard.lsb`/`msb` call `java.lang.Long.numberOfTrailingZeros` /
`numberOfLeadingZeros`.** This is item (a) below, and the six-mask rewrite it
proposed turned out to be unnecessary: Flix treats every method on
`java.lang.Long` as **pure**, so the JVM intrinsic can be called directly with no
`unsafe` block, no effect and no signature change. It is literally the call
`src/main/scala/game/Bitboard.scala:100` makes, so the two implementations are now
identical by construction. Measured alone: game encode 5.42/5.30/5.05x ->
4.30/3.89/3.59x. The single largest win of the campaign.

**2. The tail-call thunk removed from ~20 hot defs.** Flix compiles a call to a
*different* def in tail position into a heap continuation which the caller's
trampoline dispatches through a megamorphic `invokeinterface Thunk$.invoke()`.
A trailing `; ()` on a `Unit`-returning def moves the call out of tail position
and it becomes a plain `invokestatic`. This is the least intuitive item in the
campaign and the second largest: clock encode 3.96/4.03/4.26x -> 1.32/1.30/1.22x.
It is load-bearing in six files, documented at length above `Board.put`, and it
looks exactly like dead code — see PORTING-NOTES.

**3. `Tables` became a `struct`; `Move` and `Psqt` became a packed `Int64` and a
`type alias`.** A single-case enum destructure materialises **every** field
regardless of `_` wildcards and appends a dead `MatchError$` branch, so one read of
the 15-field `Tables` enum cost 264 bytecodes. As a struct it is a `getfield`.
`Move` packed into an `Int64` (item (c) below) made `MoveList.buffer` a bare
`long[]` and deleted the last per-move heap object. Together: game encode
2.17/2.08/2.30x -> 1.32/1.30/1.31x.

**4. The SAN matcher rewritten flat and allocation-free.** Six mutually recursive
defs returning `Option[(Option[Char], ..., Char, Char, Option[Char])]` became one
self-recursive loop over `(start position, 4-bit subset mask)` returning the six
capture groups packed into an `Int64`. This is where game encode passed Scala:
0.99/1.00/1.07x -> 0.82/0.86/0.93x, and encode allocation fell to below the
original's. It is the one change with real fidelity risk, and it is checked by a
three-way fuzz against a transcription of the old matcher **and against
`java.util.regex` running the Scala original's own pattern** over 679 045 inputs,
plus the committed `SanFuzzTest`.

**5. `Bits.ushr`/`ushrL` made branchless.** The standard library's formula branches
on the sign of the operand, and the JVM has no `>>>` for a conditionally signed
value, so the branch survives into machine code — inside the magic-bitboard lookup,
where the operand is a hash and the branch mispredicts about half the time. The
replacement is `(x >> n) & ~((-1 << (63 - n)) << 1)`, checked against the previous
body and against `java.lang.Long.divideUnsigned` over millions of comparisons. It
took `Board.attacksToOcc` from 430 to 306 bytecodes and `Board.isSafe` from 475 to
323, both crossing under HotSpot's 325-byte `FreqInlineSize`.

**6. ~124 `@Inline` annotations, and the boxing conversions.** Flix has no
primitive narrowing operation at all, so its conversions box through `java.lang`:
`Int64.truncateToInt32` is `Long.valueOf(x).intValue()`, `Int8.toInt32` is
`Byte.valueOf(b).intValue()`, `Int32.truncateToInt8` is
`Integer.valueOf(x).byteValue()`. The first two have pure `java.lang` replacements
(`Long.hashCode` on a masked value, `Byte.toUnsignedInt`); the third does not, but
its argument can be forced into `Integer`'s cache so the `valueOf` never allocates.
Also: `String.startsWith(prefix = ...)` and `Int32.logicalRightShift(dist = ...)`
take **records**, which are a heap allocation plus a string-keyed lookup per call.

#### What was tried, measured, and reverted

These are recorded because the reasoning behind each was sound and someone will
otherwise re-derive it. Both are documented at their sites in the source.

**Splitting `BitReader.readBits` / `BitWriter.writeBits` into fast and slow paths.**
Both sit near HotSpot's 325-byte inlining threshold, so shrinking them looks
obviously right. The first attempt made the clock codec **2.1x slower**, because
the extracted call landed in tail position and became a heap continuation — which
is the first hard number anyone has put on mechanism 2 above. With the thunk fixed
the regression disappeared but the split still bought nothing: clock decode median
regressed 10% with tight error bars. Reverted in full.

**Short-circuiting `Board.isAttacked`.** Three call sites only test `!= 0`, and by
distributivity the five attack terms can be evaluated cheapest-first and abandoned
at the first hit — genuinely less work than the Scala original, which always
evaluates all five. It measured as nothing, and forty lines restating
`attacksToOcc` in a reference implementation is not worth an unmeasurable gain.

**`@Inline` on the fifteen `Tables` accessors, while `Tables` was still an enum.**
This is the hazard item (b) warns about, and it fired exactly as advertised:
`flix check` clean, `flix build-jar` dead with
`MethodTooLargeException: TestBitboard/Clo$testBetweenRaysAligned$462392.applyFrame`
— a *test* file, not the file that was annotated. The root cause was not the
annotation but the enum: inlining a 264-bytecode accessor body makes call sites
bigger, not smaller. After change 3 the same fifteen annotations build clean.

#### The three original items, adjudicated

**(a) Six-mask branchless `ntz` — superseded, do not do it.** `java.lang.Long
.numberOfTrailingZeros` is one token, is a `TZCNT` intrinsic rather than six masks,
is pure in Flix, and is the same call the original makes. The estimated −19.8% was
in the right direction and for the right reason; the proposed patch was simply the
wrong way to get it.

**(b) `@Inline` on short leaf defs — applied, and the caveat was real.** The
estimate of 1.35-1.4x was in the right range for the annotation sweep considered
alone. The caveat about the 64 KB limit is the one piece of advice in this section
that cost an afternoon exactly as predicted, and the missing half of it is that the
limit is reached because the *inlined body* is large — so shrink the data
representation first and the annotation becomes safe.

**(c) Pack `Move` into a single `Int64` — applied, and the fidelity warning was
the right warning.** `score` is kept in the **low 32 bits** so that `Bits.toInt`
recovers the identical signed value `Move.lessThan` compared before, with no
assumption about the score's range. That is what makes the ordering — and hence the
Huffman symbol written to the stream — provably unchanged. It was gated on
`difftest`, never on perft, exactly as this section said it must be, and it passed
on the first attempt.

#### What is still open

- **Game decode, 1.02-1.11x.** `GameEncoder.san` runs once per decoded ply and is
  the largest remaining thing on that path. Decode allocation is 2.3-3.1x.
- **Both clock directions, 1.15-1.35x — and the measurement is not trustworthy.**
  At 36-183 ns/op a fixed per-invocation cost is a meaningful share of the ratio.
  Three rounds have now said this and none has fixed it. Re-measure with `-bm ss`
  or a 100x coarser workload *before* optimising further.
- **`Move.mk` is ~960 bytecodes** and `@Inline` on it pushes its callers over the
  JIT's budget. Deleting `MoveCtx` and threading its five members would shrink it.
---

## 6. Summary

The port is complete: every function in the 1579 lines of Scala has a Flix
counterpart, nothing was stubbed, and there are no `FIXME`/`TODO` markers or
disabled tests other than four deliberately `@Skip`ped long-running perft cases
that carry their expected counts.

Fidelity is established by running both implementations in one JVM over the same
inputs: 14492 direct comparisons across the clock and game codecs — including every
one of the 114 real-game fixtures at every ply count, all thirteen `Board` fields
at each, and the historical on-disk corpus — plus 139225 fuzzed comparisons of the
SAN matcher against `java.util.regex` and 1005 of the failure paths, all matching.
Move generation is checked separately against 6838 positions to depth 4 on both
implementations, agreeing on 4 135 458 706 nodes *and* on a move-order-sensitive
checksum. 122 in-tree Flix tests pass, whose expected values are Scala reference
output rather than the port's own.

**The four gaps this document used to list are closed, and each was re-verified
independently before this revision was written**, by re-running the committed
command rather than by trusting the report that closed it:

| gap | closed by | the command that proves it | re-verified result |
|---|---|---|---|
| **G1 perft** | a committed corpus + two drivers | `bash scripts/perft-sweep.sh` / `--scala` | both: 6838 rows, 4 135 458 706 nodes, checksum `8459721354967636746`, 0 mismatches (§4.3) |
| **G2 exceptions** | three `flix/src` edits, no signature change | `sbt 'difftest/testOnly *ExceptionParityTest'` | 3 examples / 0 failures; **2 failures against the reverted sources**, so the test has teeth (§5.1) |
| **G3 board** | 11 new `@Export`s + a package-level drop-in `Board` | `sbt difftest/test`, `sbt scalaApiDropin/compile` | `game decode board (13 fields) 6108 / 6108`; **0 / 6108 when one accessor is deliberately mis-wired** (§5.2) |
| **G4 benchmarks** | `benchmarks/` now `dependsOn(root, scalaApi)` | `sbt 'benchmarks/Jmh/run … org.lichess.compression.benchmark.*'` | game and clock tables reproduce within a few percent; cold start 109.4 / 67.3 ms (§5.7) |

What replaced them was a measurement rather than an unknown, and it was not
flattering: the port as first written was about 5× slower than the original on the
game codec and allocated 10-90× more, for byte-identical output (§5.7).

**§5.8 is the optimisation campaign that followed, and it changed that answer
without changing a single emitted byte.** Where it stands now:

- **Game encode is faster than the Scala original** on all three length bands —
  0.82× / 0.84× / 0.88× of its time — and allocates **less** than it does,
  0.34-0.47×.
- **The end-to-end perft sweep is 2.03× faster**: 79 s against 160.5 s for the same
  4 135 458 706 nodes and the same move-order-sensitive checksum.
- **Game decode and both clock directions are still slower**: 1.02-1.11× on decode,
  1.15-1.35× on the clock. Allocation outside game encode is still 1.28-3.33×.
- Cold start went 172.3 ms → 76.2 ms against Scala's unchanged ~69 ms.

So the honest summary is that **nine of the twelve throughput rows are still on the
slow side of parity, and three — all of them game encode — have crossed it** — an
implementation that was uniformly 3-5× behind is now ahead on one direction of one
codec and on move generation, and within a few percent to a third on the rest.
"Five times faster than it was" and "faster than Scala" are different claims, and
only the first holds everywhere. What the port buys remains the same: no shared mutable
state, and a compiler that enforces it.

**Three numbers in this document did not reproduce and are flagged in place rather
than quietly kept.** §5.5's profiling percentages (0.7% / 0.8% / 6.1%, 52%, 14%)
come from a pass whose harness was never committed, and no command in this
repository produces them; the *mechanisms* they attribute to were re-verified
against the Flix standard-library source, only the percentages were not. §5.5's
`SetupPlacementBench` A/B reproduced its conclusion but not its number — "~162 ms"
became ~97 and ~101 ms on two re-runs. And an earlier revision of §5.5 claimed the
sweep was "8m39s against 5m10s", which is simply wrong for the Scala side.

§5.8's two old estimates — −19.8% for a hand-written `ntz` and 1.35-1.4× for the
`@Inline` sweep — have now been **adjudicated by measurement rather than merely
flagged**: the first was superseded (the JVM intrinsic is callable directly and is
better than the proposed patch), the second was applied and its stated hazard fired
exactly as written. §4.3's 494 s / 161 s have likewise been superseded by 79 s /
160.5 s from the same committed script. Being able to say which claims failed to
reproduce, and then closing them out, is the point of the rounds that produced this
revision.

The gaps that remain are smaller and named where they belong: the perft corpus
records depth-4 expectations and says nothing deeper (§4.6); `Bitboard.squareSet`
iteration order still differs, unobservably at both call sites (§5.3); test classes
still ship in the unstripped jar (§5.4); the `Bitboard.lsb`/`msb` assert is a
deliberate, tested, documented exception-type non-parity (§5.1); and the historical
Scala-only benchmark numbers do not reproduce and never recorded which JVM produced
them (§5.7) — superseded for future comparisons by the fully recorded sweep in
`benchmarks/results.md`, reproducible via `bash scripts/run-benchmarks.sh`.

For the design, the three things worth carrying away are that **precomputed tables
must be built once and threaded explicitly** because Flix has no memoization and
the type system will not warn you, that **the Flix jar must never touch a Scala
compile classpath** because its standard library occupies the default package, and
that **regions turn a mutable move generator into a pure function** — which is what
let the original's `ThreadLocal` disappear.
