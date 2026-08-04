///
/// Square arithmetic on the 0..63 little-endian rank-file board.
///
/// Port of `object Square` in `src/main/scala/game/model.scala`. Every function
/// here is a pure `Int32` computation; the Scala originals are one-liners over
/// Java `int`, so the bit operations go through `Bits` to keep exactly the
/// Java semantics (`>>>` logical, `^`/`&` on 32-bit wrapping ints).
///
/// `Square.aligned(a, b, c) = Bitboard.contains(Bitboard.RAYS(a)(b), c)` is
/// deliberately NOT here: it needs the `RAYS` table, so it lives with `Bitboard`.
///
mod Square {

    /// Square a1 (index 0).
    pub def a1(): Int32 = 0

    /// Square c1 (index 2).
    pub def c1(): Int32 = 2

    /// Square d1 (index 3).
    pub def d1(): Int32 = 3

    /// Square f1 (index 5).
    pub def f1(): Int32 = 5

    /// Square g1 (index 6).
    pub def g1(): Int32 = 6

    /// Square h1 (index 7).
    pub def h1(): Int32 = 7

    /// Square a8 (index 56).
    pub def a8(): Int32 = 56

    /// Square h8 (index 63).
    pub def h8(): Int32 = 63

    ///
    /// The square at `file` (0..7) and `rank` (0..7).
    ///
    /// Scala: `def square(file: Int, rank: Int): Int = file ^ (rank << 3)`.
    /// Note it is `^`, not `|` — identical for in-range inputs, but kept exact.
    ///
    pub def square(file: Int32, rank: Int32): Int32 =
        Bits.bxor(file, Bits.shl(rank, 3))

    ///
    /// The file of `sq`, in `0..7`.
    ///
    /// Scala: `square & 7`.
    ///
    pub def file(sq: Int32): Int32 = Bits.band(sq, 7)

    ///
    /// The rank of `sq`, in `0..7`.
    ///
    /// Scala: `square >>> 3` — the logical shift, so it is `Bits.ushr`.
    ///
    pub def rank(sq: Int32): Int32 = Bits.ushr(sq, 3)

    ///
    /// `sq` flipped vertically (rank r becomes rank 7 - r).
    ///
    /// Scala: `square ^ 0x38`.
    ///
    pub def mirror(sq: Int32): Int32 = Bits.bxor(sq, 0x38)

    ///
    /// The square with the file of `a` and the rank of `b`.
    ///
    pub def combine(a: Int32, b: Int32): Int32 = square(file(a), rank(b))

    ///
    /// Chebyshev (king-move) distance between `a` and `b`.
    ///
    /// Scala: `Math.max(Math.abs(file(a) - file(b)), Math.abs(rank(a) - rank(b)))`.
    /// `abs` is spelled out rather than taken from the stdlib so that the
    /// two's-complement behaviour is Java's `Math.abs`, not a saturating variant.
    ///
    pub def distance(a: Int32, b: Int32): Int32 = {
        let df = Bits.absInt(file(a) - file(b));
        let dr = Bits.absInt(rank(a) - rank(b));
        if (df > dr) df else dr
    }
}
