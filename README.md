# compression-flix

Chess clock and move compression for lichess.org, rewritten in
[Flix](https://flix.dev/).

This is a port of **[lichess-org/compression](https://github.com/lichess-org/compression)**
— the original Scala implementation, which remains the reference. The port
produces **byte-for-byte identical output**, which is the only useful standard
for a library whose output is a storage format: a change in a single bit would
invalidate every game and clock history already on disk.

## Attribution

| | |
|---|---|
| Original implementation | <https://github.com/lichess-org/compression> (Scala, by lichess.org) |
| This port | Flix 0.75.1, same algorithms, same output |
| Full port repository | <https://github.com/w0rxbend/compression> — keeps both implementations side by side, and is where the differential tests, perft sweep and benchmarks live |
| Licence | GNU AGPL v3 or later, inherited from the original — see [LICENSE](LICENSE) |

The original library carries this note, which is worth repeating because it
explains why the Scala being ported does not look like idiomatic Scala:

> This library was migrated from the Java language to the Scala language. Only
> the language syntax changed to Scala; the design and paradigms of the Java
> program were kept.

The Flix port did not inherit that constraint and is written as Flix, within the
limits described in [docs/REWRITE.md](docs/REWRITE.md).

## What is here

```
flix.toml, src/, test/     the Flix implementation (17 modules) and its tests
scala-api/                 Scala facade — org.lichess.compression.flix.*
scala-api-dropin/          the same API under the ORIGINAL package names
flix-bridge/               Java shim that loads the Flix jar
smoke/                     runnable end-to-end check, not published
docs/                      the port write-up, Flix notes, and benchmarks
```

## Using it from Scala

Two artifacts, depending on how much you want to change:

```scala
// Namespaced — explicit that you are calling the Flix port.
import org.lichess.compression.flix.clock.Encoder
import org.lichess.compression.flix.game.Encoder as GameEncoder
```

```scala
// Drop-in — the ORIGINAL package names, so existing callers do not change.
// Do not put this on a classpath that also has the original library.
import org.lichess.compression.clock.Encoder
import org.lichess.compression.game.{ Encoder, Board as JavaBoard }
```

The drop-in artifact is compile-checked against lila's actual import shape by
`LilaSourceCompatWitness`, so the guarantee is enforced by the build rather than
asserted in a comment.

```scala
val centis  = Array(30000, 29000, 28500, 27000)
val encoded = Encoder.encode(centis, startTime = 30000)   // 7 bytes
val decoded = Encoder.decode(encoded, startTime = 30000)  // 30003, 29003, 28499, 27000

val moves   = Array("e4", "e5", "Nf3", "Nc6", "Bb5")
val bytes   = GameEncoder.encode(moves)                   // 2 bytes
GameEncoder.decode(bytes, moves.length).pgnMoves          // e4 e5 Nf3 Nc6 Bb5
```

The clock codec is **deliberately lossy** — `LowBitTruncator` drops the low three
bits and, at or above 1000 centis, does not store them at all — which is why
30000 decodes as 30003. The original behaves identically; this was checked
directly, not assumed.

## Building

Needs the [Flix compiler](https://github.com/flix/flix/releases) 0.75.1 on `PATH`
and a JDK 21 or newer.

```bash
flix test                  # the Flix suite: 122 tests
flix build-jar             # -> artifact/<clone-directory-name>.jar
sbt scalaApi/compile       # the Scala facade (runs flix build-jar for you)
sbt smoke/runMain smoke    # end-to-end check through the facade
sbt flixReleaseJar         # publishable jar with the @Test classes stripped
```

Note `flix build-jar` names its output after the **enclosing directory**, not
after `name` in `flix.toml`. The build discovers the jar rather than assuming a
name, so a clone into any directory works.

### The one thing to know before depending on this

Flix emits its entire standard library into the **default package**, including
classes literally named `Object`, `String`, `Map` and `Array`. Any Scala or Java
source compiled with the raw Flix jar on its classpath will resolve unqualified
`String` to *Flix's* class, not `java.lang.String`. The symptom is baffling: a
`main(String[] args)` compiled that way silently becomes `main([LString;)V` and
the JVM refuses to start it.

The build handles this by keeping the jar off every Scala compile classpath and
adding it back at runtime only. **Depend on `scala-api`, never on the raw Flix
jar.**

## How it performs

The port started at a uniform ~5x slower than the original. After an optimisation
campaign gated on byte-identical output, it is **ahead on game encode and on move
generation, and still behind on everything else**:

| | before | after |
|---|---|---|
| game encode | 5.08-5.30x slower | **0.818-0.877x — faster** |
| game encode allocation | 24.6-26.9x more | **0.336-0.468x — less** |
| perft depth-4, 4.1e9 nodes | 494 s vs 161 s | **79 s vs 160.5 s — 2.03x faster** |
| game decode | 4.72-5.38x slower | 1.017-1.109x slower |
| clock encode | 4.24-4.43x slower | 1.266-1.349x slower |
| clock decode | 2.75-3.98x slower | 1.149-1.307x slower |
| cold start | 172 ms vs 69 ms | 76.2 ms vs 68.6 ms |

It does **not** beat the original outright. The Scala side was never given an
equivalent optimisation pass, so the defensible claim is "faster than the
reference implementation it copies, on some paths" — not that Flix is faster
than Scala.

Most of the gain was not algorithmic. Flix's `Int64.numberOfTrailingZeros` is a
recursive per-bit scan that compiles to a heap continuation, where
`java.lang.Long`'s is a pure call and a JIT intrinsic. Beyond that it was the
calling convention rather than the data structures: a body in tail position
allocates a continuation object, a single-case enum destructure emits every field
plus a dead `MatchError` block, and named-argument stdlib functions allocate a
record. [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) records each mechanism with
the bytecode that demonstrates it — useful to anyone writing a Flix hot loop.

Full tables, methodology, hardware and per-row caveats:
[docs/BENCHMARKS.md](docs/BENCHMARKS.md).

## How it is verified

- **122 Flix tests** (`flix test`), whose expected values are output from the
  Scala original rather than from the port itself.
- **Perft**: 6,838 positions to depth 4, agreeing with the Scala implementation
  on 4,135,458,706 nodes *and* on a checksum over every generated move in
  generation order — which catches a reordering that node counts alone would
  hide. The corpus ships in `test/data/perft-corpus.csv`; the depth-2 replay runs
  as part of `flix test`.
- **Differential tests** against the original: byte equality on both codecs, all
  thirteen `Board` fields, and exception-type parity. These need the Scala
  implementation present, so they live in the
  [full repository](https://github.com/w0rxbend/compression).

## Documentation

- [docs/REWRITE.md](docs/REWRITE.md) — what was rewritten and how, the design
  decisions Flix forced, the interop surface, and an honest account of what is
  verified versus what is not.
- [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) — Flix 0.75.1 behaviour
  established by compiling, including several points where the official
  documentation is wrong or oversimplified. Useful for anyone else porting
  imperative code to Flix.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) — the performance comparison.
