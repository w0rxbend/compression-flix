# compression-flix-api

The Scala face of the Flix port. `org.lichess.compression.flix.clock.Encoder` and
`org.lichess.compression.flix.game.Encoder` are signature-identical to the original
`org.lichess.compression.{clock,game}.Encoder`, and produce byte-for-byte identical
output — see `difftest/` for the test that asserts it against the original
implementation running in the same JVM.

## Using it

```scala
import org.lichess.compression.flix.clock.Encoder as Clock
import org.lichess.compression.flix.game.Encoder as Game

val bytes  = Clock.encode(Array(17980, 17960, 17800), startTime = 18000)
val centis = Clock.decode(bytes, startTime = 18000)

val encoded = Game.encode("e4 e5 Nf3 Nc6".split(" "))
val decoded = Game.decode(encoded, plies = 4)
decoded.pgnMoves       // Array("e4", "e5", "Nf3", "Nc6")
decoded.halfMoveClock  // 1
decoded.lastUci        // "b8c6"
```

If you would rather not change your imports at all, depend on
`compression-flix-api-dropin` instead. It re-exports the same two objects under
their original fully qualified names. Use it *instead of* `compression`, never
alongside it: the names collide and whichever jar comes first on the classpath
silently wins.

Both objects are thread-safe and hold no per-thread state. The static tables (~100
ms to build, a few hundred KB) are built on first use and shared for the life of the
process; the original's `ThreadLocal[MoveList]` has no equivalent here because the
Flix implementation allocates its scratch move list per call inside a region.

## The one API difference

`DecodeResult.board` is an immutable **value snapshot** of the original's mutable
`Board`, not the `Board` itself. It carries **all thirteen public fields** — the
nine bitboards (`pawns`, `knights`, `bishops`, `rooks`, `queens`, `kings`, `white`,
`black`, `occupied`), plus `turn`, `epSquare`, `castlingRights` and
`incrementalHash` — so every field read a caller can write against the original
compiles unchanged. Those thirteen are asserted byte-identical against the original
over 6108 decodes by `sbt difftest/test` ("expose the full decoded Board
identically").

What is *not* there is the original `Board`'s **methods**. `roleAt`, `whiteAt`,
`pieceMap`, `us`, `them` and `byColor` are pure functions of the nine bitboards and
are cheaper to recompute on your side than to marshal; `copy`, `play`,
`legalMoves`, `isCheck`, `zobristHash` and `hasLegalEnPassant` are the move
generator, and exposing them would mean marshalling `Move`, `Role` and `MoveList`
across the boundary too. This artifact is a codec.

Because the snapshot is a `case class`, `board.pawns` reads compile but
`board.pawns = x` writes do not. The Flix `Board` itself never crosses the export
boundary — a Flix `@Export` may mention only primitives and `java.lang.Object` — so
the thirteen fields come across one scalar at a time and the facade reassembles
them.

## What a consumer must put on the classpath

Two artifacts and one jar:

| artifact                       | compile | runtime |
|--------------------------------|---------|---------|
| `compression-flix-api`         | yes     | yes     |
| `compression-flix-bridge`      | (transitive) | yes |
| `flix/artifact/flix.jar`       | **no**  | **yes** |

**Never put `flix.jar` on a compile classpath.** Flix 0.75.1 emits its entire
standard library into the unnamed package — 363 top-level classes in a clean build,
including `Object`, `String`, `Array`, `List`, `Map`, `Set`, `Option`, `Iterator`
and `Assert`, each of them accompanied by a same-named *package*. Two things go
wrong, and they are not the same thing:

- **Java** sources in the unnamed package resolve bare `String` to Flix's `String`.
  A `main(String[] args)` written that way compiles and then will not launch,
  because the JVM wants `main([Ljava/lang/String;)V`.
- **Scala** sources in any package lose those names in *term* position:
  `Array("e4")` fails with `package Array does not take parameters`, because the
  same-named package outranks `scala.Array`'s companion. Type positions such as
  `Array[Byte]` are unaffected, so the breakage is partial and confusing.

That is why this project's build filters `flix.jar` out of every Scala
`dependencyClasspath` (`hideFlixJar` in `build.sbt`) and adds it back only to
runtime classpaths. Only `flix-bridge`, which is Java-only and writes every JDK
type as `java.lang.X`, compiles against it.

No shading is needed. Shading would not have helped anyway: relocating the classes
into a package preserves the class/package name collision that makes them
unreachable from Scala in the first place.

## Building

`flix build-jar` is wired into sbt as the `flixJar` task and runs automatically when
any `flix/src/*.flix` or `flix/test/*.flix` file is newer than the jar:

```
sbt scalaApi/compile      # builds flix/artifact/flix.jar first if stale
sbt difftest/test         # the byte-for-byte differential test
```

To force a rebuild, `touch` a `.flix` source or delete `flix/artifact/flix.jar`.
The jar is named after the *directory* (`flix/` → `flix.jar`), not after `name` in
`flix.toml`.

For a release artifact:

```
rm -rf flix/build flix/artifact   # see below
sbt flixReleaseJar                # → flix/artifact/flix-release.jar
```

`flix build-jar` has no test scope, so the `@Test` modules from both `flix/src` and
`flix/test` are compiled into the ordinary jar. `flixReleaseJar` produces a copy
with them stripped — 1.1 MB rather than 3.0 MB. It is a separate task so that
`difftest` keeps running against exactly the bytes you built.

Clean first: `flix/build/` accumulates stale classes across incremental builds and
is never pruned. A tree built repeatedly during development produced an 18.5 MB jar
whose extra ~11000 class entries were dead classes from earlier revisions; the same
sources built clean produce 3.0 MB. Treat any jar much larger than that as a stale
build rather than as the real size.
