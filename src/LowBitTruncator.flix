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
    pub def writeDigits(centis: Array[Int32, r1], w: BitWriter[r2]): Unit \ (r1 + r2) =
        writeDigitsWith(centis, (data, numBits) -> BitWriter.writeBits(data, numBits, w))

    ///
    /// `writeDigits` with the bit sink supplied as a `(data, numBits)` callback.
    ///
    /// This indirection is a leftover of the port order: `LowBitTruncator` was written
    /// before `BitOps` existed, so the sink had to be injected. It is kept because the
    /// control flow can be exercised without a real `BitWriter`, but it is now
    /// module-private — the sequence and order of `writeBits` calls is identical
    /// either way, so `writeDigits` above is the entry point callers want.
    ///
    def writeDigitsWith(centis: Array[Int32, r], writeBits: (Int32, Int32) -> Unit \ ef): Unit \ r + ef =
        let maxIdx = Array.length(centis) - 1;
        writeDigitsFrom(centis, writeBits, 0, maxIdx);
        writeBits(Array.get(maxIdx, centis), 3)

    def writeDigitsFrom(centis: Array[Int32, r], writeBits: (Int32, Int32) -> Unit \ ef, i: Int32, maxIdx: Int32): Unit \ r + ef =
        if (i < maxIdx) {
            let centi = Array.get(i, centis);
            if (centi < centiCutoff())
                writeBits(centi, 3)
            else
                ();
            writeDigitsFrom(centis, writeBits, i + 1, maxIdx)
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
    /// Module-private, for the same reason as `writeDigitsWith` above. It is only
    /// invoked on the branches where the original calls `reader.readBits`, so the
    /// number and order of reads is unchanged.
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
