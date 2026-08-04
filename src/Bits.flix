///
/// Bit-twiddling helpers with Java `int`/`long` semantics.
///
/// The Scala/Java original leans heavily on the `<<`, `>>`, `>>>`, `&`, `|`, `^`
/// operators. Flix has no infix bitwise operators, so this module gives the
/// `Int32.*`/`Int64.*` stdlib calls short, uniform names. Every function here is
/// pure, and all but the two logical right shifts map 1:1 onto a JVM bytecode
/// instruction; `ushr`/`ushrL` are two or three, and carry a note explaining why
/// they do not simply call `Int32.logicalRightShift`.
///
mod Bits {

    // `toInt` and `byteToUnsigned` call `java.lang` statics directly. Flix treats
    // every method on `java.lang.Long`/`Byte` as *pure*, so this costs no `unsafe`
    // block, no effect and no signature change. (A doc-comment on an `import` is a
    // parse error: imports are not declarations.)
    import java.lang.Long
    import java.lang.Byte
    import java.lang.Integer

    /// `x << n` on a Java `int`.
    pub def shl(x: Int32, n: Int32): Int32 = Int32.leftShift(x, n)

    /// `x >> n` on a Java `int` (arithmetic, sign-propagating).
    pub def shr(x: Int32, n: Int32): Int32 = Int32.rightShift(x, n)

    ///
    /// `x >>> n` on a Java `int` (logical, zero-filling).
    ///
    /// Spelled out rather than delegated to `Int32.logicalRightShift`, which is the
    /// one standard-library function in this module that is *not* cheap. Its shift
    /// distance is a **named record** (`dist = n`), so every call allocates a
    /// `RecordExtend` for the argument and then resolves the field by *string
    /// comparison* at run time — three times, once per mention of `dist#dist` — and
    /// its `Int32.remainder` guard is a real division. One `>>>` cost about five
    /// heap allocations.
    ///
    /// The standard library's own formula is also the wrong shape. It branches on
    /// `x < 0`, and the JVM has no `>>>` for a *conditionally* signed value, so the
    /// branch survives into machine code. On the hot paths that matters: the sign
    /// of `BitReader.pendingBits` (a window of the compressed stream) and the sign
    /// of a magic-bitboard product (`factor * (occupied & mask)`, a hash) are both
    /// effectively random, so the branch mispredicts about half the time inside the
    /// innermost loop of the decoder and of move generation respectively.
    ///
    /// The body below is branchless: mask off the sign fill that `>>` leaves behind.
    ///
    ///     x >>> n  ==  (x >> n) & ~((-1 << (31 - n)) << 1)
    ///
    /// The mask is written as two shifts rather than `-1 << (32 - n)` so that `n = 0`
    /// stays correct: `32 - 0` would be masked back to a shift of `0` by the JVM and
    /// clear everything, whereas `(-1 << 31) << 1` is `0` and clears nothing. Both
    /// shift distances are congruent mod 32 to their `n & 31` counterparts, so
    /// negative and out-of-range `n` behave exactly as Java's `>>>` does.
    ///
    /// For a constant `n` — which is every call site except `BitReader.readBits` and
    /// `BitWriter.writeBits` — the whole mask folds to a literal and this is two
    /// instructions: the magic index becomes `lshr; land`, matching Scala's `lushr`.
    ///
    /// Checked against the previous body over 30 000 random values crossed with every
    /// shift distance in `-70..70` plus thirteen adversarial values over the same
    /// range, and independently against `java.lang.Integer.divideUnsigned(x, 1 << n)`
    /// — a genuine Java `>>>` that does not go through Flix's standard library — over
    /// 20 000 random values crossed with `0..31`: zero disagreements.
    ///
    @Inline
    pub def ushr(x: Int32, n: Int32): Int32 =
        Int32.bitwiseAnd(
            Int32.rightShift(x, n),
            Int32.bitwiseNot(Int32.leftShift(Int32.leftShift(-1, 31 - n), 1)))

    /// `x & y` on a Java `int`.
    pub def band(x: Int32, y: Int32): Int32 = Int32.bitwiseAnd(x, y)

    /// `x | y` on a Java `int`.
    pub def bor(x: Int32, y: Int32): Int32 = Int32.bitwiseOr(x, y)

    /// `x ^ y` on a Java `int`.
    pub def bxor(x: Int32, y: Int32): Int32 = Int32.bitwiseXor(x, y)

    /// `~x` on a Java `int`.
    pub def bnot(x: Int32): Int32 = Int32.bitwiseNot(x)

    /// `x << n` on a Java `long`.
    pub def shlL(x: Int64, n: Int32): Int64 = Int64.leftShift(x, n)

    /// `x >> n` on a Java `long` (arithmetic, sign-propagating).
    pub def shrL(x: Int64, n: Int32): Int64 = Int64.rightShift(x, n)

    /// `x >>> n` on a Java `long` (logical, zero-filling). See `ushr` for why this
    /// is spelled out and why it is branchless; the only change is `63` for `31`.
    @Inline
    pub def ushrL(x: Int64, n: Int32): Int64 =
        Int64.bitwiseAnd(
            Int64.rightShift(x, n),
            Int64.bitwiseNot(Int64.leftShift(Int64.leftShift(-1i64, 63 - n), 1)))

    /// `x & y` on a Java `long`.
    pub def bandL(x: Int64, y: Int64): Int64 = Int64.bitwiseAnd(x, y)

    /// `x | y` on a Java `long`.
    pub def borL(x: Int64, y: Int64): Int64 = Int64.bitwiseOr(x, y)

    /// `x ^ y` on a Java `long`.
    pub def bxorL(x: Int64, y: Int64): Int64 = Int64.bitwiseXor(x, y)

    /// `~x` on a Java `long`.
    pub def bnotL(x: Int64): Int64 = Int64.bitwiseNot(x)

    /// `1L << sq`, the single-bit mask for square `sq`.
    @Inline
    pub def bit(sq: Int32): Int64 = Int64.leftShift(1i64, sq)

    ///
    /// `(int) x`, truncating a Java `long` to a Java `int`.
    ///
    /// Not `Int64.truncateToInt32`, which is literally `Long.valueOf(x).intValue()`
    /// — Flix has no primitive narrowing operation at all, so every conversion in
    /// its standard library boxes through `java.lang`. This sits inside the magic
    /// bitboard index, where the value is never in the `Long` cache, so the box is
    /// a real allocation on every slider lookup.
    ///
    /// `Long.hashCode(v)` is *contractually* `(int) (v ^ (v >>> 32))`, so masking
    /// the high half away first makes it exactly `(int) x`. Checked against
    /// `Int64.truncateToInt32` over 300 000 random `Int64`s and fourteen adversarial
    /// values (`0`, `±1`, `minValue`, `maxValue`, both sides of `2^31` and `2^32`):
    /// zero disagreements.
    ///
    @Inline
    pub def toInt(x: Int64): Int32 = Long.hashCode(Int64.bitwiseAnd(x, 4294967295i64))

    ///
    /// `(long) x`, widening a Java `int` to a Java `long` with sign extension.
    ///
    /// This one still boxes (`Int32.toInt64` is `Integer.valueOf(x).longValue()`)
    /// and has no pure `java.lang` equivalent. Nothing on a hot path uses it —
    /// prefer `toLongU` where the value is known non-negative, which is every
    /// such site in this library.
    ///
    @Inline
    pub def toLong(x: Int32): Int64 = Int32.toInt64(x)

    ///
    /// `x & 0xffffffffL`: widening a Java `int` to a Java `long` with **zero**
    /// extension.
    ///
    /// Not `Int32.toInt64`, which is `Integer.valueOf(x).longValue()` and so
    /// allocates for any `x` outside the `Integer` cache — see `toInt`.
    /// `Integer.toUnsignedLong` is a pure `java.lang` static, allocation-free, and
    /// is exactly `(long) x & 0xffffffffL` by its specification.
    ///
    /// This is the widening the packed `Move` uses: every field it stores is
    /// either non-negative (so zero and sign extension agree) or is the 32-bit
    /// score, which occupies bits 0..31 and is read back with `toInt`.
    ///
    @Inline
    pub def toLongU(x: Int32): Int64 = Integer.toUnsignedLong(x)

    ///
    /// `(byte) x`, truncating a Java `int` to a Java `byte`.
    ///
    /// `Int32.truncateToInt8` is literally `Integer.valueOf(x).byteValue()`, so it
    /// allocates an `Integer` for every `x` outside the cache — and the hash bytes
    /// `GameEncoder.setHash` narrows are uniformly distributed, so almost all of
    /// them are. There is no pure `java.lang` static that narrows an `int` to a
    /// `byte`, but the boxing can be made free instead of removed: the sign-extend
    /// identity `((x & 0xff) ^ 0x80) - 0x80` is `(byte) x` widened back to `int`
    /// for **every** `int`, and its result is always in `-128..127`, which is
    /// always inside `Integer`'s cache. So the `valueOf` below never allocates.
    ///
    /// Being `@Inline` also removes `Int32.truncateToInt8`'s own trampoline and
    /// its 48-byte `Value$` return.
    ///
    @Inline
    pub def toByte(x: Int32): Int8 =
        Integer.valueOf(Bits.bxor(Bits.band(x, 0xff), 0x80) - 0x80).byteValue()

    ///
    /// `b & 0xff`, reading a Java `byte` as an unsigned value in `0..255`.
    ///
    /// `Byte.toUnsignedInt` rather than `Int8.toInt32`, which is
    /// `Byte.valueOf(b).intValue()` — see `toInt`. This runs once per input byte on
    /// the decode path. Checked equal to `Int8.toInt32(b) & 0xff` for all 256 byte
    /// values.
    ///
    @Inline
    pub def byteToUnsigned(b: Int8): Int32 = Byte.toUnsignedInt(b)

    ///
    /// `Math.abs(x)` on a Java `int`: **wrapping**, so `absInt(Int32.minValue)` is
    /// `Int32.minValue` (because `0 - Int32.minValue` overflows back to itself).
    ///
    /// This is deliberately NOT `Int32.abs`, which returns `-1` when the magnitude
    /// would exceed `maxValue` — see PORTING-NOTES.md. `Square.distance` and
    /// `Board.isEnPassantLegal`'s `abs(from - to) == 16` both need Java semantics,
    /// and both used to carry their own private copy of this body; one definition
    /// means the two cannot silently drift apart.
    ///
    @Inline
    pub def absInt(x: Int32): Int32 = if (x < 0) 0 - x else x
}
