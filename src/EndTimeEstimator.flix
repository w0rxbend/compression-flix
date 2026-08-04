///
/// Port of `org.lichess.compression.clock.EndTimeEstimator`.
///
/// The last clock value in a game is far from arbitrary: it correlates with how
/// long the game ran. `endEstimate` predicts it from the start time and the move
/// count, and `encode`/`decode` subtract/add that prediction in place.
///
/// Exact Java semantics matter here:
///   * `startTime * maxIdx` is a wrapping 32-bit multiply,
///   * `>>> 5` is a *logical* shift, so a negative product becomes a large
///     positive value rather than a small negative one.
/// Both are reproduced verbatim via `Bits`.
///
mod EndTimeEstimator {

    ///
    /// `startTime - ((startTime * maxIdx) >>> 5)`.
    ///
    /// Pure; wrapping multiply and logical (zero-filling) right shift, exactly
    /// as in the Scala/Java original.
    ///
    def endEstimate(maxIdx: Int32, startTime: Int32): Int32 =
        startTime - Bits.ushr(startTime * maxIdx, 5)

    ///
    /// Subtracts the end-time estimate from the final element of `vals`, in place.
    ///
    /// The guard `maxIdx < 32` mirrors the original: beyond 31 moves the estimate
    /// is not applied at all.
    ///
    pub def encode(vals: Array[Int32, r], startTime: Int32): Unit \ r =
        let maxIdx = Array.length(vals) - 1;
        if (maxIdx < 32)
            Array.put(Array.get(maxIdx, vals) - endEstimate(maxIdx, startTime), maxIdx, vals)
        else
            ()

    ///
    /// Adds the end-time estimate back onto the final element of `vals`, in place.
    ///
    pub def decode(vals: Array[Int32, r], startTime: Int32): Unit \ r =
        let maxIdx = Array.length(vals) - 1;
        if (maxIdx < 32)
            Array.put(Array.get(maxIdx, vals) + endEstimate(maxIdx, startTime), maxIdx, vals)
        else
            ()
}
