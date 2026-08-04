///
/// Bitboards: square sets as `Int64`, plus the precomputed attack tables.
///
/// Port of `src/main/scala/game/Bitboard.scala`.
///
/// # Why there is a `Tables` parameter
///
/// The Scala original keeps its tables in `object Bitboard` and fills them from a
/// static initializer: `RANKS`, `FILES`, `KNIGHT_ATTACKS`, `KING_ATTACKS`,
/// `WHITE_PAWN_ATTACKS`, `BLACK_PAWN_ATTACKS`, `BETWEEN`, `RAYS` and the 88772-entry
/// magic-bitboard `ATTACKS` table. Flix has no static initializers, no global
/// mutable state and no `@Memoize`, so a zero-argument `def` would rebuild all
/// 88772 entries on every single lookup.
///
/// The tables therefore live in a `Tables` value, built exactly once and threaded
/// explicitly:
///
/// ```flix
/// let t = Tables.mk();                         // build once, ~100 ms
/// Bitboard.rookAttacks(t, square, occupied)    // lookups take `t` first
/// ```
///
/// # `Tables` is immutable, region-free and pure
///
/// The Scala tables are `val` arrays written once by the static initializer and
/// only ever read afterwards. So `Tables` holds `Vector`s, not region-allocated
/// `Array`s: the mutation needed to *fill* them is confined to a `region rc { ... }`
/// inside `mk`, whose effect is discharged at the block boundary, and every lookup
/// is a `Vector.get` and therefore **pure**.
///
/// Concretely that means:
///
///   * `Tables.mk(): Tables` is pure — no region argument, no `\ IO`, no `Static`.
///   * `Bitboard.rookAttacks`, `between`, `rays`, `aligned` and the rest are pure,
///     so no region effect leaks into `Board`, `MoveList` or the game encoder, and
///     the `@Export` layer needs no `Tables[Static]` handle.
///   * `Tables` carries no region type parameter, so it does not have to unify with
///     (or be threaded alongside) the region of a `Board`.
///
/// This mirrors `Huffman.HuffmanTable`, which is also pure region-free data; the
/// two can be bundled into one "static tables" value at integration time.
///
/// `Vector.get` is not slower than `Array.get` here — measured at 428 ms vs 460 ms
/// for 10^8 dependent lookups into an 88772-entry table on this machine — and it
/// avoids the region effect entirely. (Flix *records* were measured 3.2x slower
/// than either, so the named-field record shape was rejected.)
///
/// # The API, at a glance
///
/// Everything is pure. Table-free:
/// ```
/// Bitboard.all(): Int64                      // Scala `Bitboard.ALL`
/// Bitboard.rankMask(i: Int32): Int64         // Scala `Bitboard.RANKS(i)`
/// Bitboard.fileMask(i: Int32): Int64         // Scala `Bitboard.FILES(i)`
/// Bitboard.lsb(b: Int64): Int32
/// Bitboard.msb(b: Int64): Int32
/// Bitboard.moreThanOne(b: Int64): Bool
/// Bitboard.contains(b: Int64, sq: Int32): Bool
/// Bitboard.squareSet(b: Int64): Set[Int32]
/// Bitboard.slidingAttacks(square: Int32, occupied: Int64, deltas: Vector[Int32]): Int64
/// ```
///
/// Table-taking:
/// ```
/// Bitboard.knightAttacks(t, square)
/// Bitboard.kingAttacks(t, square)
/// Bitboard.pawnAttacks(t, white, square)
/// Bitboard.bishopAttacks(t, square, occupied)
/// Bitboard.rookAttacks(t, square, occupied)
/// Bitboard.queenAttacks(t, square, occupied)
/// Bitboard.between(t, a, b)                  // Scala `BETWEEN(a)(b)`
/// Bitboard.rays(t, a, b)                     // Scala `RAYS(a)(b)`
/// Bitboard.ranks(t, i) / Bitboard.files(t, i)
/// Bitboard.aligned(t, a, b, c)               // Scala's `Square.aligned`; see below
/// ```
///
/// Scala's `Square.aligned` is spelled `Bitboard.aligned` here. It needs `RAYS`,
/// and Flix forbids reopening a module ("A module may have only one declaration
/// site in the program. Reopening a module — either across files or as multiple
/// sibling blocks — is not allowed", verified by compile failure), so `mod Square`
/// has exactly one declaration site (`src/Square.flix`) and cannot be extended from
/// this file.
///
/// # Notes on fidelity
///
///   * `RANKS`/`FILES` are kept in `Tables` because the Scala object has them, but
///     `Bitboard.rankMask`/`fileMask` recompute the identical value with one shift
///     and need no table; prefer them where threading `t` would be noise.
///   * `BETWEEN` and `RAYS` are 64x64 in Scala; here they are single flat vectors of
///     4096 indexed `a * 64 + b`, which is the same data with one fewer indirection.
///   * Every bit operation goes through `Bits`, so the semantics are Java's:
///     wrapping 64-bit multiply in the magic index, logical `>>>`, arithmetic `>>`.
///   * `Tables` also snapshots the six `Magic` vectors. `Magic.rookMask()` and
///     friends are plain `def`s returning a `Vector#{...}` literal, so they rebuild
///     64 elements on every call; a magic lookup must not pay that.
///
/// Verified against the compiled Scala original: every leaper table entry, the
/// `BETWEEN`/`RAYS` checksums over all 4096 pairs, magic rook/bishop/queen attacks
/// over 500 pseudorandom occupancies x 64 squares, `slidingAttacks` over 200
/// occupancies x 64 squares x 3 delta sets, `Square.aligned` over all 64^3 triples,
/// and `lsb`/`msb`/`moreThanOne`/`squareSet` over 500 values — all identical.
///

///
/// The precomputed bitboard tables: immutable, region-free, built once by
/// `Tables.mk()`.
///
/// The fields are positional and in this order; sizes mirror the Scala arrays.
/// Nothing outside `mod Tables` should destructure this — use the accessors.
///
/// ```
///   0  ranks             8      Scala `RANKS`
///   1  files             8      Scala `FILES`
///   2  knightAttacks     64     Scala `KNIGHT_ATTACKS`
///   3  kingAttacks       64     Scala `KING_ATTACKS`
///   4  whitePawnAttacks  64     Scala `WHITE_PAWN_ATTACKS`
///   5  blackPawnAttacks  64     Scala `BLACK_PAWN_ATTACKS`
///   6  between           4096   Scala `BETWEEN`,  flattened `a * 64 + b`
///   7  rays              4096   Scala `RAYS`,     flattened `a * 64 + b`
///   8  attacks           88772  Scala `ATTACKS`
///   9  rookMask          64     Scala `Magic.ROOK(i).mask`
///   10 rookFactor        64     Scala `Magic.ROOK(i).factor`
///   11 rookOffset        64     Scala `Magic.ROOK(i).offset`
///   12 bishopMask        64     Scala `Magic.BISHOP(i).mask`
///   13 bishopFactor      64     Scala `Magic.BISHOP(i).factor`
///   14 bishopOffset      64     Scala `Magic.BISHOP(i).offset`
/// ```
///
pub enum Tables {
    case Tables(
        Vector[Int64],  // 0  ranks
        Vector[Int64],  // 1  files
        Vector[Int64],  // 2  knightAttacks
        Vector[Int64],  // 3  kingAttacks
        Vector[Int64],  // 4  whitePawnAttacks
        Vector[Int64],  // 5  blackPawnAttacks
        Vector[Int64],  // 6  between
        Vector[Int64],  // 7  rays
        Vector[Int64],  // 8  attacks
        Vector[Int64],  // 9  rookMask
        Vector[Int64],  // 10 rookFactor
        Vector[Int32],  // 11 rookOffset
        Vector[Int64],  // 12 bishopMask
        Vector[Int64],  // 13 bishopFactor
        Vector[Int32]   // 14 bishopOffset
    )
}

mod Tables {

    ///
    /// Builds every table. This is the port of the Scala static initializer: the
    /// `for i <- 0 until 64` loop that fills the leaper tables and runs
    /// `initMagics`, followed by the `BETWEEN`/`RAYS` double loop.
    ///
    /// Pure: the arrays it fills live in a local region whose effect is discharged
    /// at the `region` boundary, and the result is a snapshot of immutable vectors.
    ///
    /// Call this **once** and thread the result. It does on the order of ten million
    /// `slidingAttacks` steps and takes roughly 100 ms; a `def` in Flix is not
    /// memoized, so calling it per move would be a catastrophic performance bug.
    /// Purity means the compiler will not warn you about that — hold the value.
    ///
    pub def mk(): Tables = region rc {
        let ranks            = Array.repeat(rc, 8, 0i64);
        let files            = Array.repeat(rc, 8, 0i64);
        let knightAttacks    = Array.repeat(rc, 64, 0i64);
        let kingAttacks      = Array.repeat(rc, 64, 0i64);
        let whitePawnAttacks = Array.repeat(rc, 64, 0i64);
        let blackPawnAttacks = Array.repeat(rc, 64, 0i64);
        let between          = Array.repeat(rc, 64 * 64, 0i64);
        let rays             = Array.repeat(rc, 64 * 64, 0i64);
        let attacks          = Array.repeat(rc, 88772, 0i64);

        // Snapshotted once: `Magic.rookMask()` and friends rebuild a 64-element
        // `Vector` literal on every call.
        let rookMask     = Magic.rookMask();
        let rookFactor   = Magic.rookFactor();
        let rookOffset   = Magic.rookOffset();
        let bishopMask   = Magic.bishopMask();
        let bishopFactor = Magic.bishopFactor();
        let bishopOffset = Magic.bishopOffset();

        initRankFile(ranks, files, 0);
        initLeapersAndMagics(knightAttacks, kingAttacks, whitePawnAttacks, blackPawnAttacks, attacks,
                             rookMask, rookFactor, rookOffset, bishopMask, bishopFactor, bishopOffset, 0);
        initBetweenRays(between, rays, 0, 0);

        Tables.Tables(
            Array.toVector(ranks),
            Array.toVector(files),
            Array.toVector(knightAttacks),
            Array.toVector(kingAttacks),
            Array.toVector(whitePawnAttacks),
            Array.toVector(blackPawnAttacks),
            Array.toVector(between),
            Array.toVector(rays),
            Array.toVector(attacks),
            rookMask, rookFactor, rookOffset,
            bishopMask, bishopFactor, bishopOffset)
    }

    /// `RANKS(i) = 0xffL << (i * 8)` and `FILES(i) = 0x0101010101010101L << i`.
    def initRankFile(ranks: Array[Int64, r], files: Array[Int64, r], i: Int32): Unit \ r =
        if (i >= 8) ()
        else {
            Array.put(Bitboard.rankMask(i), i, ranks);
            Array.put(Bitboard.fileMask(i), i, files);
            initRankFile(ranks, files, i + 1)
        }

    ///
    /// The Scala `for i <- 0 until 64` loop: the four leaper tables plus the rook
    /// and bishop magic tables, in that order.
    ///
    def initLeapersAndMagics(knightAttacks: Array[Int64, r], kingAttacks: Array[Int64, r],
                             whitePawnAttacks: Array[Int64, r], blackPawnAttacks: Array[Int64, r],
                             attacks: Array[Int64, r],
                             rookMask: Vector[Int64], rookFactor: Vector[Int64], rookOffset: Vector[Int32],
                             bishopMask: Vector[Int64], bishopFactor: Vector[Int64], bishopOffset: Vector[Int32],
                             i: Int32): Unit \ r =
        if (i >= 64) ()
        else {
            Array.put(Bitboard.slidingAttacks(i, Bitboard.all(), Bitboard.knightDeltas()), i, knightAttacks);
            Array.put(Bitboard.slidingAttacks(i, Bitboard.all(), Bitboard.kingDeltas()), i, kingAttacks);
            Array.put(Bitboard.slidingAttacks(i, Bitboard.all(), Bitboard.whitePawnDeltas()), i, whitePawnAttacks);
            Array.put(Bitboard.slidingAttacks(i, Bitboard.all(), Bitboard.blackPawnDeltas()), i, blackPawnAttacks);
            initMagics(attacks, i, Vector.get(i, rookMask), Vector.get(i, rookFactor),
                       Vector.get(i, rookOffset), 12, Bitboard.rookDeltas());
            initMagics(attacks, i, Vector.get(i, bishopMask), Vector.get(i, bishopFactor),
                       Vector.get(i, bishopOffset), 9, Bitboard.bishopDeltas());
            initLeapersAndMagics(knightAttacks, kingAttacks, whitePawnAttacks, blackPawnAttacks, attacks,
                                 rookMask, rookFactor, rookOffset, bishopMask, bishopFactor, bishopOffset, i + 1)
        }

    ///
    /// Fills the slice of `ATTACKS` owned by `square`'s magic entry, walking every
    /// subset of `mask` with the carry-rippler trick, starting at the empty subset.
    ///
    def initMagics(attacks: Array[Int64, r], square: Int32, mask: Int64, factor: Int64, offset: Int32,
                   shift: Int32, deltas: Vector[Int32]): Unit \ r =
        updateAttacks(attacks, square, mask, factor, offset, shift, deltas, 0i64)

    ///
    /// The `@tailrec def updateAttacks` of the Scala source, including its
    /// consistency assertion: a slot is either untouched or already holds exactly
    /// the attack set we are about to write.
    ///
    def updateAttacks(attacks: Array[Int64, r], square: Int32, mask: Int64, factor: Int64, offset: Int32,
                      shift: Int32, deltas: Vector[Int32], subset: Int64): Unit \ r = {
        let attack = Bitboard.slidingAttacks(square, subset, deltas);
        let idx = Bits.toInt(Bits.ushrL(factor * subset, 64 - shift)) + offset;
        let existing = Array.get(idx, attacks);
        // Scala: `assert(ATTACKS(idx) == 0 || ATTACKS(idx) == attack)`. Written as a
        // value rather than a statement because a discarded pure expression is a
        // compile error in Flix.
        let checked =
            if (existing != 0i64 and existing != attack)
                bug!("Tables.initMagics: inconsistent magic attack table")
            else
                attack;
        Array.put(checked, idx, attacks);
        let nextSubset = Bits.bandL(subset - mask, mask);
        if (nextSubset != 0i64)
            updateAttacks(attacks, square, mask, factor, offset, shift, deltas, nextSubset)
        else
            ()
    }

    ///
    /// The Scala `for a <- 0 until 64; b <- 0 until 64` loop filling `BETWEEN` and
    /// `RAYS`. Flattened to `a * 64 + b`.
    ///
    /// Scala's `&` binds tighter than `|`, so the `RAYS` expression is
    /// `(1L << a) | (1L << b) | (slide(a) & slide(b))`; that grouping is explicit here.
    ///
    def initBetweenRays(between: Array[Int64, r], rays: Array[Int64, r], a: Int32, b: Int32): Unit \ r =
        if (a >= 64) ()
        else if (b >= 64) initBetweenRays(between, rays, a + 1, 0)
        else {
            let rook = Bitboard.rookDeltas();
            let bishop = Bitboard.bishopDeltas();
            let idx = a * 64 + b;
            if (Bitboard.contains(Bitboard.slidingAttacks(a, 0i64, rook), b)) {
                Array.put(
                    Bits.bandL(
                        Bitboard.slidingAttacks(a, Bits.bit(b), rook),
                        Bitboard.slidingAttacks(b, Bits.bit(a), rook)),
                    idx, between);
                Array.put(
                    Bits.borL(
                        Bits.borL(Bits.bit(a), Bits.bit(b)),
                        Bits.bandL(
                            Bitboard.slidingAttacks(a, 0i64, rook),
                            Bitboard.slidingAttacks(b, 0i64, rook))),
                    idx, rays)
            } else if (Bitboard.contains(Bitboard.slidingAttacks(a, 0i64, bishop), b)) {
                Array.put(
                    Bits.bandL(
                        Bitboard.slidingAttacks(a, Bits.bit(b), bishop),
                        Bitboard.slidingAttacks(b, Bits.bit(a), bishop)),
                    idx, between);
                Array.put(
                    Bits.borL(
                        Bits.borL(Bits.bit(a), Bits.bit(b)),
                        Bits.bandL(
                            Bitboard.slidingAttacks(a, 0i64, bishop),
                            Bitboard.slidingAttacks(b, 0i64, bishop))),
                    idx, rays)
            } else
                ();
            initBetweenRays(between, rays, a, b + 1)
        }

    /// `Bitboard.RANKS(i)`.
    pub def ranks(t: Tables, i: Int32): Int64 =
        let Tables.Tables(v, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = t;
        Vector.get(i, v)

    /// `Bitboard.FILES(i)`.
    pub def files(t: Tables, i: Int32): Int64 =
        let Tables.Tables(_, v, _, _, _, _, _, _, _, _, _, _, _, _, _) = t;
        Vector.get(i, v)

    /// `Bitboard.KNIGHT_ATTACKS(square)`.
    pub def knightAttacks(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, v, _, _, _, _, _, _, _, _, _, _, _, _) = t;
        Vector.get(square, v)

    /// `Bitboard.KING_ATTACKS(square)`.
    pub def kingAttacks(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, v, _, _, _, _, _, _, _, _, _, _, _) = t;
        Vector.get(square, v)

    /// `Bitboard.WHITE_PAWN_ATTACKS(square)`.
    pub def whitePawnAttacks(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, _, v, _, _, _, _, _, _, _, _, _, _) = t;
        Vector.get(square, v)

    /// `Bitboard.BLACK_PAWN_ATTACKS(square)`.
    pub def blackPawnAttacks(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, v, _, _, _, _, _, _, _, _, _) = t;
        Vector.get(square, v)

    /// `Bitboard.BETWEEN(a)(b)`.
    pub def between(t: Tables, a: Int32, b: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, v, _, _, _, _, _, _, _, _) = t;
        Vector.get(a * 64 + b, v)

    /// `Bitboard.RAYS(a)(b)`.
    pub def rays(t: Tables, a: Int32, b: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, _, v, _, _, _, _, _, _, _) = t;
        Vector.get(a * 64 + b, v)

    /// `Bitboard.ATTACKS(idx)`, the raw magic-table read.
    pub def attackAt(t: Tables, idx: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, _, _, v, _, _, _, _, _, _) = t;
        Vector.get(idx, v)

    /// `Magic.ROOK(square).mask`, from the snapshot held by the tables.
    pub def rookMask(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, _, _, _, v, _, _, _, _, _) = t;
        Vector.get(square, v)

    /// `Magic.ROOK(square).factor`.
    pub def rookFactor(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, _, _, _, _, v, _, _, _, _) = t;
        Vector.get(square, v)

    /// `Magic.ROOK(square).offset`.
    pub def rookOffset(t: Tables, square: Int32): Int32 =
        let Tables.Tables(_, _, _, _, _, _, _, _, _, _, _, v, _, _, _) = t;
        Vector.get(square, v)

    /// `Magic.BISHOP(square).mask`.
    pub def bishopMask(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, _, _, _, _, _, _, v, _, _) = t;
        Vector.get(square, v)

    /// `Magic.BISHOP(square).factor`.
    pub def bishopFactor(t: Tables, square: Int32): Int64 =
        let Tables.Tables(_, _, _, _, _, _, _, _, _, _, _, _, _, v, _) = t;
        Vector.get(square, v)

    /// `Magic.BISHOP(square).offset`.
    pub def bishopOffset(t: Tables, square: Int32): Int32 =
        let Tables.Tables(_, _, _, _, _, _, _, _, _, _, _, _, _, _, v) = t;
        Vector.get(square, v)
}

mod Bitboard {

    ///
    /// Every square: `-1L`. Scala `Bitboard.ALL`.
    ///
    pub def all(): Int64 = -1i64

    ///
    /// `RANKS(i) = 0xffL << (i * 8)`, table-free.
    ///
    pub def rankMask(i: Int32): Int64 = Bits.shlL(0xffi64, i * 8)

    ///
    /// `FILES(i) = 0x0101010101010101L << i`, table-free.
    ///
    pub def fileMask(i: Int32): Int64 = Bits.shlL(0x0101010101010101i64, i)

    /// Scala `KNIGHT_DELTAS`.
    pub def knightDeltas(): Vector[Int32] = Vector#{17, 15, 10, 6, -17, -15, -10, -6}

    /// Scala `BISHOP_DELTAS`.
    pub def bishopDeltas(): Vector[Int32] = Vector#{7, -7, 9, -9}

    /// Scala `ROOK_DELTAS`.
    pub def rookDeltas(): Vector[Int32] = Vector#{1, -1, 8, -8}

    /// Scala `KING_DELTAS`.
    pub def kingDeltas(): Vector[Int32] = Vector#{1, 7, 8, 9, -1, -7, -8, -9}

    /// Scala `WHITE_PAWN_DELTAS`.
    pub def whitePawnDeltas(): Vector[Int32] = Vector#{7, 9}

    /// Scala `BLACK_PAWN_DELTAS`.
    pub def blackPawnDeltas(): Vector[Int32] = Vector#{-7, -9}

    ///
    /// The squares reachable from `square` by repeatedly stepping along each of
    /// `deltas`, stopping at (and including) the first occupied square and at the
    /// board edge, where "edge" means a step of Chebyshev distance greater than 2.
    ///
    /// The Scala original nests two local recursive functions, `attackLoop` over
    /// the deltas and `@tailrec deltaLoop` walking one delta; they call each other,
    /// so both are lifted to top-level helpers here.
    ///
    pub def slidingAttacks(square: Int32, occupied: Int64, deltas: Vector[Int32]): Int64 =
        attackLoop(square, occupied, deltas, 0, 0i64)

    /// `attackLoop` of the Scala `slidingAttacks`.
    def attackLoop(square: Int32, occupied: Int64, deltas: Vector[Int32],
                   deltaIndex: Int32, acc: Int64): Int64 =
        if (deltaIndex >= Vector.length(deltas)) acc
        else deltaLoop(square, occupied, deltas, deltaIndex, square, acc)

    /// `deltaLoop` of the Scala `slidingAttacks`.
    def deltaLoop(square: Int32, occupied: Int64, deltas: Vector[Int32],
                  deltaIndex: Int32, sq: Int32, tempAcc: Int64): Int64 = {
        let newSq = sq + Vector.get(deltaIndex, deltas);
        if (newSq < 0 or newSq >= 64 or Square.distance(newSq, sq) > 2)
            attackLoop(square, occupied, deltas, deltaIndex + 1, tempAcc)
        else {
            let newAcc = Bits.borL(tempAcc, Bits.bit(newSq));
            if (contains(occupied, newSq))
                attackLoop(square, occupied, deltas, deltaIndex + 1, newAcc)
            else
                deltaLoop(square, occupied, deltas, deltaIndex, newSq, newAcc)
        }
    }

    ///
    /// Bishop attacks from `square` given `occupied`, via the magic table.
    ///
    /// Scala: `ATTACKS(((magic.factor * (occupied & magic.mask)) >>> (64 - 9)).toInt + magic.offset)`.
    /// The multiply wraps mod 2^64 exactly as Java's `lmul`, and `.toInt` truncates.
    ///
    pub def bishopAttacks(t: Tables, square: Int32, occupied: Int64): Int64 = {
        let mask = Tables.bishopMask(t, square);
        let factor = Tables.bishopFactor(t, square);
        let offset = Tables.bishopOffset(t, square);
        Tables.attackAt(t, Bits.toInt(Bits.ushrL(factor * Bits.bandL(occupied, mask), 64 - 9)) + offset)
    }

    ///
    /// Rook attacks from `square` given `occupied`, via the magic table.
    ///
    pub def rookAttacks(t: Tables, square: Int32, occupied: Int64): Int64 = {
        let mask = Tables.rookMask(t, square);
        let factor = Tables.rookFactor(t, square);
        let offset = Tables.rookOffset(t, square);
        Tables.attackAt(t, Bits.toInt(Bits.ushrL(factor * Bits.bandL(occupied, mask), 64 - 12)) + offset)
    }

    ///
    /// Queen attacks: Scala uses `^`, not `|`. The two sets are disjoint, so this
    /// is the same value, but the operator is kept as written.
    ///
    pub def queenAttacks(t: Tables, square: Int32, occupied: Int64): Int64 =
        Bits.bxorL(bishopAttacks(t, square, occupied), rookAttacks(t, square, occupied))

    ///
    /// Pawn attacks from `square` for the given colour (`true` = white).
    ///
    pub def pawnAttacks(t: Tables, white: Bool, square: Int32): Int64 =
        if (white) Tables.whitePawnAttacks(t, square) else Tables.blackPawnAttacks(t, square)

    /// `Bitboard.KNIGHT_ATTACKS(square)`.
    pub def knightAttacks(t: Tables, square: Int32): Int64 = Tables.knightAttacks(t, square)

    /// `Bitboard.KING_ATTACKS(square)`.
    pub def kingAttacks(t: Tables, square: Int32): Int64 = Tables.kingAttacks(t, square)

    /// `Bitboard.BETWEEN(a)(b)`: the squares strictly between `a` and `b`, or `0`.
    pub def between(t: Tables, a: Int32, b: Int32): Int64 = Tables.between(t, a, b)

    /// `Bitboard.RAYS(a)(b)`: the whole line through `a` and `b`, or `0`.
    pub def rays(t: Tables, a: Int32, b: Int32): Int64 = Tables.rays(t, a, b)

    /// `Bitboard.RANKS(i)`, read from the table.
    pub def ranks(t: Tables, i: Int32): Int64 = Tables.ranks(t, i)

    /// `Bitboard.FILES(i)`, read from the table.
    pub def files(t: Tables, i: Int32): Int64 = Tables.files(t, i)

    ///
    /// Index of the least significant set bit. Undefined for `0`, which the Scala
    /// original guards with `assert`; the guard is kept.
    ///
    pub def lsb(b: Int64): Int32 =
        if (b == 0i64) bug!("Bitboard.lsb: empty bitboard")
        else Int64.numberOfTrailingZeros(b)

    ///
    /// Index of the most significant set bit. Undefined for `0`.
    ///
    pub def msb(b: Int64): Int32 =
        if (b == 0i64) bug!("Bitboard.msb: empty bitboard")
        else 63 - Int64.numberOfLeadingZeros(b)

    ///
    /// `true` if `b` has two or more squares set.
    ///
    pub def moreThanOne(b: Int64): Bool =
        Bits.bandL(b, b - 1i64) != 0i64

    ///
    /// `true` if `sq` is a member of `b`.
    ///
    pub def contains(b: Int64, sq: Int32): Bool =
        Bits.bandL(b, Bits.bit(sq)) != 0i64

    ///
    /// The set of squares in `b`, clearing the low bit each step exactly as the
    /// Scala `while` loop does.
    ///
    pub def squareSet(b: Int64): Set[Int32] = squareSetLoop(b, Set.empty())

    def squareSetLoop(remaining: Int64, acc: Set[Int32]): Set[Int32] =
        if (remaining == 0i64) acc
        else squareSetLoop(Bits.bandL(remaining, remaining - 1i64), Set.insert(lsb(remaining), acc))

    ///
    /// `true` if `a`, `b` and `c` are on one rank, file or diagonal.
    ///
    /// This is Scala's `Square.aligned(a, b, c) = Bitboard.contains(Bitboard.RAYS(a)(b), c)`.
    /// It lives in `Bitboard`, not `Square`, for a hard language reason: Flix forbids
    /// reopening a module, so `mod Square` may have exactly one declaration site in
    /// the whole program and that is `src/Square.flix`, which cannot see `Tables`.
    /// Call sites that would say `Square.aligned(a, b, c)` in Scala say
    /// `Bitboard.aligned(t, a, b, c)` here.
    ///
    pub def aligned(t: Tables, a: Int32, b: Int32, c: Int32): Bool =
        contains(Tables.rays(t, a, b), c)
}
