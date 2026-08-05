package org.lichess.compression.flix.clock

import org.lichess.compression.flix.Flix

/** Clock compression, backed by the Flix port.
  *
  * Signature-identical to `org.lichess.compression.clock.Encoder`: the only change
  * a caller makes is the import. Output is byte-for-byte identical — see
  * `difftest/` for the test that asserts it against the original implementation.
  *
  * `startTime` is the game's initial clock in centiseconds. It is side information:
  * it is never written to the stream, and `decode` needs the same value that
  * `encode` was given.
  *
  * `decode` is deliberately not a total inverse. Readings at or above 1000 centis
  * lose their low three bits, which come back as `3`; readings below the cutoff,
  * and the final reading whatever its size, round-trip exactly. That is the
  * original's behaviour and the port reproduces it.
  */
object Encoder:

  /** The codec handle, resolved once and held in a `final` field.
    *
    * `Flix.codec` is a `lazy val`, which Scala 3 compiles to a read of a
    * **volatile** field plus an `instanceof` and a `checkcast`. C2 cannot
    * constant-fold a volatile load — a `lazy val` may in principle still be
    * uninitialised — so every call through this facade re-read it and the receiver
    * of the `invokeinterface` below was not a JIT constant. A `private val` on an
    * `object` becomes a final instance field of a `static final MODULE$`, which C2
    * does fold, making the interface call a constant-receiver call it can inline
    * through.
    *
    * Laziness is preserved where it matters: the load still happens on first touch
    * of this object rather than at class-load of the library. The one visible
    * difference is that a missing Flix jar now surfaces as an
    * `ExceptionInInitializerError` wrapping the `IllegalStateException` rather than
    * the `IllegalStateException` itself.
    */
  private val codec = Flix.codec

  /** Compresses one side's clock readings, in centiseconds, one per move.
    *
    * The input array is not modified. An empty input encodes to an empty array.
    */
  def encode(centis: Array[Int], startTime: Int): Array[Byte] =
    codec.clockEncode(centis, startTime)

  /** Inverse of `encode`, given the same `startTime`.
    *
    * The input array is not modified. An empty input decodes to an empty array.
    */
  def decode(bytes: Array[Byte], startTime: Int): Array[Int] =
    codec.clockDecode(bytes, startTime)
