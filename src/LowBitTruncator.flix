///
/// Port of `org.lichess.compression.clock.LowBitTruncator`.
///
/// Clock times are stored in centiseconds, but the low three bits carry almost no
/// information for the estimators, so they are sheared off before prediction and
/// written out separately as raw 3-bit digits.
///
/// Fidelity notes:
///   * `>> 3` is arithmetic in Java. Centis are non-negative in practice, but the
///     arithmetic shift is preserved rather than "cleaned up" to a logical one.
///   * `writeDigits` tests the *untruncated* value against `CENTI_CUTOFF`, whereas
///     `decode` tests the *re-expanded* value (`trunced(i) << 3`). Those are not the
///     same predicate — `x >> 3 << 3` loses the low bits — but the asymmetry is
///     exactly what the original does and it is what makes the stream self-
///     synchronising, so it is reproduced verbatim.
///   * When the cutoff test fails, the encoder writes nothing and the decoder
///     substitutes the literal `3`. Do not turn that into a symmetric round-trip.
///
mod LowBitTruncator {

    ///
    /// Below this many centiseconds (10 s) the low three bits are transmitted
    /// verbatim; at or above it they are discarded and reconstructed as `3`.
    ///
    def centiCutoff(): Int32 = 1000

    ///
    /// Shifts every element of `centis` right by three bits, in place.
    ///
    pub def truncate(centis: Array[Int32, r]): Unit \ r =
        truncateFrom(centis, 0)

    def truncateFrom(centis: Array[Int32, r], i: Int32): Unit \ r =
        if (i < Array.length(centis)) {
            Array.put(Bits.shr(Array.get(i, centis), 3), i, centis);
            truncateFrom(centis, i + 1)
        } else
            ()

    ///
    /// Scalar counterpart of `truncate`, used for the start time.
    ///
    /// Flix has no overloading, so the Scala `truncate(centi: Int)` overload is
    /// renamed rather than merged with the array version.
    ///
    pub def truncateCenti(centi: Int32): Int32 = Bits.shr(centi, 3)

    ///
    /// Writes the three low bits of each clock value that is under the cutoff, plus
    /// the three low bits of the final value unconditionally.
    ///
    /// Takes the *original*, untruncated `centis` — the caller truncates a copy.
    ///
    /// This is `LowBitTruncator.writeDigits(centis, writer)` from the Scala original,
    /// and is the only public entry point, matching the Scala surface.
    ///
    /// The bit sink used to be injected as a `(data, numBits)` callback, which was a
    /// leftover of the port order — `LowBitTruncator` was written before `BitOps`
    /// existed. It cost, per encode, three heap allocations and four dispatches for
    /// what is semantically one 3-bit write: the effect-polymorphic parameter forced
    /// Flix to materialise a resumable `Frame$` closure for the final call (which is
    /// in tail position, so it was not defunctionalised the way the loop's was),
    /// `getUniqueThreadClosure()` copied it, and `applyFrame` then allocated a
    /// `BitWriter/Def$writeBits` thunk of its own. The sequence, count and order of
    /// `writeBits` calls here is exactly what the callback form produced.
    pub def writeDigits(centis: Array[Int32, r1], w: BitWriter[r2]): Unit \ (r1 + r2) =
        let maxIdx = Array.length(centis) - 1;
        writeDigitsFrom(centis, w, 0, maxIdx);
        BitWriter.writeBits(Array.get(maxIdx, centis), 3, w);
        ()   // keeps `writeBits` out of tail position; see the note in `mod Board`

    def writeDigitsFrom(centis: Array[Int32, r1], w: BitWriter[r2], i: Int32, maxIdx: Int32): Unit \ (r1 + r2) =
        if (i < maxIdx) {
            let centi = Array.get(i, centis);
            if (centi < centiCutoff())
                BitWriter.writeBits(centi, 3, w)
            else
                ();
            writeDigitsFrom(centis, w, i + 1, maxIdx)
        } else
            ()

    ///
    /// Re-expands truncated values in place, reading back the three low bits that
    /// `writeDigits` emitted and substituting `3` where it emitted nothing.
    ///
    /// This is `LowBitTruncator.decode(trunced, reader)` from the Scala original,
    /// and is the only public entry point, matching the Scala surface.
    ///
    pub def decode(trunced: Array[Int32, r1], rd: BitReader[r2]): Unit \ (r1 + r2) =
        decodeWith(trunced, numReqBits -> BitReader.readBits(numReqBits, rd))

    ///
    /// `decode` with the bit source supplied as a `numReqBits -> Int32` callback.
    ///
    /// It is only invoked on the branches where the original calls `reader.readBits`,
    /// so the number and order of reads is unchanged.
    ///
    /// THIS SIDE KEEPS THE CALLBACK AND THAT IS A MEASURED DECISION. The symmetric
    /// change was made to `writeDigits` above and won there (clock encode
    /// 1.364/1.319/1.262x -> 1.294/1.257/1.198x); the same change here LOST, and by
    /// more than it won on encode: clock decode 1.148/1.174/1.286x -> 1.233/1.298/1.214x,
    /// i.e. +5.5 ns on the short band and +11 ns on the median against error bars of
    /// 2-3 ns. Flix already defunctionalises this side — the `readBits` calls are not
    /// in tail position, so no `Frame$` closure is materialised the way `writeDigits`'
    /// final call materialised one — so there was no allocation to win back, and
    /// calling `BitReader.readBits` directly from `decodeFrom` evidently costs
    /// HotSpot an inlining decision it was previously making. Do not "finish the job"
    /// here without re-measuring.
    ///
    def decodeWith(trunced: Array[Int32, r], readBits: Int32 -> Int32 \ ef): Unit \ r + ef =
        let maxIdx = Array.length(trunced) - 1;
        decodeFrom(trunced, readBits, 0, maxIdx);
        let last = Bits.shl(Array.get(maxIdx, trunced), 3);
        let bits = readBits(3);
        Array.put(Bits.bor(last, bits), maxIdx, trunced)

    def decodeFrom(trunced: Array[Int32, r], readBits: Int32 -> Int32 \ ef, i: Int32, maxIdx: Int32): Unit \ r + ef =
        if (i < maxIdx) {
            let rounded = Bits.shl(Array.get(i, trunced), 3);
            let low = if (rounded < centiCutoff()) readBits(3) else 3;
            Array.put(Bits.bor(rounded, low), i, trunced);
            decodeFrom(trunced, readBits, i + 1, maxIdx)
        } else
            ()
}
