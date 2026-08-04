package org.lichess.compression.flix

/** Process-wide state for the Flix-backed codecs.
  *
  * There are exactly two things that must be created once and shared, and both are
  * here rather than in the two `Encoder` objects so that neither can accidentally
  * be rebuilt:
  *
  *   - `codec`, the bridge into the unnamed-package Flix classes. Loading it costs
  *     one `Class.forName`; every call through it afterwards is a plain interface
  *     dispatch.
  *   - `tables`, the game codec's precomputed data — 88772 attack entries, the
  *     piece-square table, the Polyglot Zobrist keys and the Huffman tree. Building
  *     it takes ~100 ms and allocates a few hundred kilobytes.
  *
  * Flix has no memoization and no global mutable state: a zero-argument Flix `def`
  * returning the tables would rebuild them on every single call. The caching
  * obligation therefore lands here, and `lazy val` discharges it — Scala's
  * initialisation is thread-safe, so concurrent first calls block rather than
  * racing to build two copies.
  *
  * Both values are immutable once built and every Flix entry point behind them is
  * pure with respect to them, so the codecs are safe to call from any number of
  * threads. This is a real improvement on the original, whose `MoveList` had to be
  * a `ThreadLocal`; the Flix port allocates its scratch move list per call inside a
  * region.
  */
private[flix] object Flix:

  /** The bridge to the Flix `Api` class. Loaded once, on first use. */
  lazy val codec: FlixCodec = FlixCodec.load()

  /** The game codec's static tables. Built once, on first use. Opaque. */
  lazy val tables: java.lang.Object = codec.newTables()
