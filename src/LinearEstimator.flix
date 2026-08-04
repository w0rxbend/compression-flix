///
/// Port of `org.lichess.compression.clock.LinearEstimator`.
///
/// A divide-and-conquer predictor over the clock series. Given the known values
/// at the two ends of a range, the midpoint is predicted as their average and
/// replaced by its residual; the two halves are then processed recursively.
///
/// Fidelity notes:
///   * The recursion is seeded with `startIdx = -1`, i.e. a *virtual* element one
///     slot before the array holding `startTime`. `(startIdx + endIdx) >> 1` is
///     therefore an arithmetic shift of a possibly-negative sum, and it must stay
///     arithmetic: for `startIdx = -1, endIdx = 0` the midpoint is
///     `(-1) >> 1 == -1 == startIdx`, which is what terminates the recursion.
///     A logical shift would yield `2147483647` and blow up.
///   * `(start + end) >> 1` is likewise an arithmetic shift of a wrapping 32-bit
///     sum, so negative residuals average the same way Java averages them.
///   * `encode` reads the midpoint *before* overwriting it and recurses on the
///     original value; `decode` writes first and recurses on the restored value.
///     The two orders are mirror images and must not be "tidied up".
///
mod LinearEstimator {

    ///
    /// Replaces each interior element of `dest` by its residual against the linear
    /// prediction from its neighbours, in place.
    ///
    /// `dest` must be non-empty; the last element is the seed for the right end and
    /// is left untouched by this pass.
    ///
    pub def encode(dest: Array[Int32, r], startTime: Int32): Unit \ r =
        let maxIdx = Array.length(dest) - 1;
        // Trailing `()`: see the note in `mod Board`.
        encodeRange(dest, -1, startTime, maxIdx, Array.get(maxIdx, dest));
        ()

    ///
    /// Inverse of `encode`: turns residuals back into absolute values, in place.
    ///
    pub def decode(dest: Array[Int32, r], startTime: Int32): Unit \ r =
        let maxIdx = Array.length(dest) - 1;
        decodeRange(dest, -1, startTime, maxIdx, Array.get(maxIdx, dest));
        ()

    ///
    /// `midIdx == startIdx` is the recursion's base case: it means the range has no
    /// interior element left. Note `startIdx` may be `-1`, so the shift is arithmetic.
    ///
    def encodeRange(dest: Array[Int32, r], startIdx: Int32, start: Int32, endIdx: Int32, end: Int32): Unit \ r =
        let midIdx = Bits.shr(startIdx + endIdx, 1);
        if (startIdx != midIdx) {
            let mid = Array.get(midIdx, dest);
            Array.put(mid - Bits.shr(start + end, 1), midIdx, dest);

            encodeRange(dest, startIdx, start, midIdx, mid);
            encodeRange(dest, midIdx, mid, endIdx, end)
        } else
            ()

    ///
    /// Mirror of `encodeRange`: the midpoint is restored *before* the sub-ranges are
    /// visited, because the halves are predicted from the restored value.
    ///
    def decodeRange(dest: Array[Int32, r], startIdx: Int32, start: Int32, endIdx: Int32, end: Int32): Unit \ r =
        let midIdx = Bits.shr(startIdx + endIdx, 1);
        if (startIdx != midIdx) {
            Array.put(Array.get(midIdx, dest) + Bits.shr(start + end, 1), midIdx, dest);
            let mid = Array.get(midIdx, dest);

            decodeRange(dest, startIdx, start, midIdx, mid);
            decodeRange(dest, midIdx, mid, endIdx, end)
        } else
            ()
}
