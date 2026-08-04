///
/// Bit-twiddling helpers with Java `int`/`long` semantics.
///
/// The Scala/Java original leans heavily on the `<<`, `>>`, `>>>`, `&`, `|`, `^`
/// operators. Flix has no infix bitwise operators, so this module gives the
/// `Int32.*`/`Int64.*` stdlib calls short, uniform names. Every function here is
/// pure and maps 1:1 onto a JVM bytecode instruction.
///
mod Bits {

    /// `x << n` on a Java `int`.
    pub def shl(x: Int32, n: Int32): Int32 = Int32.leftShift(x, n)

    /// `x >> n` on a Java `int` (arithmetic, sign-propagating).
    pub def shr(x: Int32, n: Int32): Int32 = Int32.rightShift(x, n)

    /// `x >>> n` on a Java `int` (logical, zero-filling).
    pub def ushr(x: Int32, n: Int32): Int32 = Int32.logicalRightShift(dist = n, x)

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

    /// `x >>> n` on a Java `long` (logical, zero-filling).
    pub def ushrL(x: Int64, n: Int32): Int64 = Int64.logicalRightShift(dist = n, x)

    /// `x & y` on a Java `long`.
    pub def bandL(x: Int64, y: Int64): Int64 = Int64.bitwiseAnd(x, y)

    /// `x | y` on a Java `long`.
    pub def borL(x: Int64, y: Int64): Int64 = Int64.bitwiseOr(x, y)

    /// `x ^ y` on a Java `long`.
    pub def bxorL(x: Int64, y: Int64): Int64 = Int64.bitwiseXor(x, y)

    /// `~x` on a Java `long`.
    pub def bnotL(x: Int64): Int64 = Int64.bitwiseNot(x)

    /// `1L << sq`, the single-bit mask for square `sq`.
    pub def bit(sq: Int32): Int64 = Int64.leftShift(1i64, sq)

    /// `(int) x`, truncating a Java `long` to a Java `int`.
    pub def toInt(x: Int64): Int32 = Int64.truncateToInt32(x)

    /// `(long) x`, widening a Java `int` to a Java `long` with sign extension.
    pub def toLong(x: Int32): Int64 = Int32.toInt64(x)

    /// `(byte) x`, truncating a Java `int` to a Java `byte`.
    pub def toByte(x: Int32): Int8 = Int32.truncateToInt8(x)

    /// `b & 0xff`, reading a Java `byte` as an unsigned value in `0..255`.
    pub def byteToUnsigned(b: Int8): Int32 = Int32.bitwiseAnd(Int8.toInt32(b), 0xff)

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
    pub def absInt(x: Int32): Int32 = if (x < 0) 0 - x else x
}
