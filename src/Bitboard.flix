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
/// # `Tables` is immutable and pure
///
/// The Scala tables are `val` arrays written once by the static initializer and
/// only ever read afterwards. So `Tables` holds `Vector`s, not region-allocated
/// `Array`s: the mutation needed to *fill* them is confined to a `region rc { ... }`
/// inside `mk`, whose effect is discharged at the block boundary, and every lookup
/// is a `Vector.get` and therefore **pure**.
///
/// Concretely that means:
///
///   * `Tables.mk(): Tables[Static]` is pure — no region argument, no `\ IO`.
///     (`Tables` is a `struct`, so it must name a region; it is built in a local
///     region and handed out as `Static`. Reading a non-`mut` struct field is
///     pure, so no effect leaks. See the note on the declaration below.)
///   * `Bitboard.rookAttacks`, `between`, `rays`, `aligned` and the rest are pure,
///     so no region effect leaks into `Board`, `MoveList` or the game encoder.
///   * `Tables[Static]` does not have to unify with the region of a `Board`:
///     `Board[r]` holds a `Tables[Static]` and the two regions are independent.
///
/// This mirrors `Huffman.HuffmanTable`, which is also pure static data; the two
/// can be bundled into one "static tables" value at integration time.
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
/// The precomputed bitboard tables: immutable, built once by `Tables.mk()`.
///
/// # Why a `struct` and not an `enum`
///
/// This was a 15-field single-case `enum` until it was measured. Flix compiles
/// `let Tables.Tables(_, .., v, ..) = t` into fifteen `checkcast`+`getfield`+
/// `astore` triples **regardless of the wildcards**, followed by a provably dead
/// `new MatchError$ / new ReifiedSourceLocation$ / athrow` block. One table read
/// cost 264 bytecodes that way. A `struct` field read is a single `getfield`, and
/// the same accessor measures 22 bytecodes — and 12 once `@Inline`d, which is the
/// same `getfield; checkcast [J; laload` shape as the Scala original's
/// `KNIGHT_ATTACKS(sq)`.
///
/// That is also what unblocks `@Inline` on the accessors. Annotating the *enum*
/// accessors made every call site 3.3x **bigger** and blew the JVM's 64 KB method
/// limit inside `test/TestBitboard.flix`; annotating the struct accessors makes
/// each call site 5.4x smaller. See the note above the accessors.
///
/// # Why `Tables[Static]` and not `Tables[r]`
///
/// A Flix `struct` must carry a region. These tables are process-wide immutable
/// data with no `mut` field, so they live in `Static` and every consumer names
/// them `Tables[Static]`. In particular `Board[r]` holds a `Tables[Static]`: the
/// two regions do not have to agree, and a `Board` in a short-lived region can
/// still read tables that outlive it.
///
/// Reading a non-`mut` struct field is **pure**, so `Tables.mk()` and every
/// accessor keep the signatures they had as an enum — no `\ IO`, no region
/// argument, no effect leaking into `Board`, `MoveList` or the encoder.
///
pub struct Tables[r: Region] {
    ranks:            Vector[Int64],   // Scala `RANKS`,              8
    files:            Vector[Int64],   // Scala `FILES`,              8
    knightAttacks:    Vector[Int64],   // Scala `KNIGHT_ATTACKS`,     64
    kingAttacks:      Vector[Int64],   // Scala `KING_ATTACKS`,       64
    whitePawnAttacks: Vector[Int64],   // Scala `WHITE_PAWN_ATTACKS`, 64
    blackPawnAttacks: Vector[Int64],   // Scala `BLACK_PAWN_ATTACKS`, 64
    between:          Vector[Int64],   // Scala `BETWEEN`,            4096, flattened `a * 64 + b`
    rays:             Vector[Int64],   // Scala `RAYS`,               4096, flattened `a * 64 + b`
    attacks:          Vector[Int64],   // Scala `ATTACKS`,            88772
    rookMask:         Vector[Int64],   // Scala `Magic.ROOK(i).mask`,     64
    rookFactor:       Vector[Int64],   // Scala `Magic.ROOK(i).factor`,   64
    rookOffset:       Vector[Int32],   // Scala `Magic.ROOK(i).offset`,   64
    bishopMask:       Vector[Int64],   // Scala `Magic.BISHOP(i).mask`,   64
    bishopFactor:     Vector[Int64],   // Scala `Magic.BISHOP(i).factor`, 64
    bishopOffset:     Vector[Int32]    // Scala `Magic.BISHOP(i).offset`, 64
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
    pub def mk(): Tables[Static] = region rc {
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

        // Built in the local region and handed out as `Static`. The struct has no
        // `mut` field and never escapes as a mutable thing, so the cast exposes
        // nothing: it is the same immutable snapshot the enum version returned.
        // (Flix regions free nothing; a region handle is an ordinary GC-rooted
        // object, so the value stays valid after `rc` goes out of scope.)
        let t = new Tables @ rc {
            ranks            = Array.toVector(ranks),
            files            = Array.toVector(files),
            knightAttacks    = Array.toVector(knightAttacks),
            kingAttacks      = Array.toVector(kingAttacks),
            whitePawnAttacks = Array.toVector(whitePawnAttacks),
            blackPawnAttacks = Array.toVector(blackPawnAttacks),
            between          = Array.toVector(between),
            rays             = Array.toVector(rays),
            attacks          = Array.toVector(attacks),
            rookMask         = rookMask,
            rookFactor       = rookFactor,
            rookOffset       = rookOffset,
            bishopMask       = bishopMask,
            bishopFactor     = bishopFactor,
            bishopOffset     = bishopOffset
        };
        unchecked_cast(t as Tables[Static])
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

    // ------------------------------------------------------------- the accessors
    //
    // These are `@Inline`, and that is only safe because `Tables` is a `struct`.
    //
    // As a 15-field `enum` the same annotation was tried and reverted: Flix
    // materialises every field of a single-case enum on every destructure, plus a
    // dead `MatchError$`/`ReifiedSourceLocation$` branch, so an *inlined* accessor
    // body was 264 bytecodes and three of them in one caller came to 819 — against
    // 248 for the same caller with no inlining at all. That is what breached the
    // JVM's 64 KB method limit inside `test/TestBitboard.flix`, which asserts one
    // table entry per statement over 4096 pairs. `flix check` does no codegen and
    // cannot see it; only `flix build-jar` can.
    //
    // A struct field read is one `getfield`. Inlined, each accessor is ~12
    // bytecodes (`getfield; checkcast [J; iload; laload`), the same shape as the
    // Scala original's `KNIGHT_ATTACKS(sq)`, so the same three-read caller is 46
    // bytecodes — 5.4x *smaller* than not inlining. Measured, not guessed.
    //
    // The second-order effect is the one that matters more: `Board.attacksToOcc`,
    // `Board.isSafe`, `Move.mk` and the `gen*` family were all far over the JIT's
    // ~300-bytecode inlining budget largely because of these destructures, so the
    // JIT could not inline them and escape analysis never got to scalarise their
    // boxed returns.

    /// `Bitboard.RANKS(i)`.
    @Inline
    pub def ranks(t: Tables[Static], i: Int32): Int64 = Vector.get(i, t->ranks)

    /// `Bitboard.FILES(i)`.
    @Inline
    pub def files(t: Tables[Static], i: Int32): Int64 = Vector.get(i, t->files)

    /// `Bitboard.KNIGHT_ATTACKS(square)`.
    @Inline
    pub def knightAttacks(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->knightAttacks)

    /// `Bitboard.KING_ATTACKS(square)`.
    @Inline
    pub def kingAttacks(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->kingAttacks)

    /// `Bitboard.WHITE_PAWN_ATTACKS(square)`.
    @Inline
    pub def whitePawnAttacks(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->whitePawnAttacks)

    /// `Bitboard.BLACK_PAWN_ATTACKS(square)`.
    @Inline
    pub def blackPawnAttacks(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->blackPawnAttacks)

    /// `Bitboard.BETWEEN(a)(b)`.
    @Inline
    pub def between(t: Tables[Static], a: Int32, b: Int32): Int64 = Vector.get(a * 64 + b, t->between)

    /// `Bitboard.RAYS(a)(b)`.
    @Inline
    pub def rays(t: Tables[Static], a: Int32, b: Int32): Int64 = Vector.get(a * 64 + b, t->rays)

    /// `Bitboard.ATTACKS(idx)`, the raw magic-table read.
    @Inline
    pub def attackAt(t: Tables[Static], idx: Int32): Int64 = Vector.get(idx, t->attacks)

    /// `Magic.ROOK(square).mask`, from the snapshot held by the tables.
    @Inline
    pub def rookMask(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->rookMask)

    /// `Magic.ROOK(square).factor`.
    @Inline
    pub def rookFactor(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->rookFactor)

    /// `Magic.ROOK(square).offset`.
    @Inline
    pub def rookOffset(t: Tables[Static], square: Int32): Int32 = Vector.get(square, t->rookOffset)

    /// `Magic.BISHOP(square).mask`.
    @Inline
    pub def bishopMask(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->bishopMask)

    /// `Magic.BISHOP(square).factor`.
    @Inline
    pub def bishopFactor(t: Tables[Static], square: Int32): Int64 = Vector.get(square, t->bishopFactor)

    /// `Magic.BISHOP(square).offset`.
    @Inline
    pub def bishopOffset(t: Tables[Static], square: Int32): Int32 = Vector.get(square, t->bishopOffset)

    ///
    /// The whole rook magic lookup.
    ///
    /// Scala: `ATTACKS(((magic.factor * (occupied & magic.mask)) >>> (64 - 12)).toInt + magic.offset)`.
    ///
    /// The `>>> (64 - 12)` is written as `>> 52` masked to twelve bits. `Bits.ushrL`
    /// would produce the same value, but Flix does not constant-fold `64 - 12`, so
    /// it would carry the subtraction and the mask construction into the bytecode of
    /// every caller this is inlined into. `(p >> 52) & 0xFFF` is the same value for
    /// every `p`: the arithmetic shift leaves bits 52..63 in the low twelve positions
    /// with sign fill above, and the mask discards the fill. Checked against the
    /// previous expression over 200 000 random `Int64`s and eighteen adversarial
    /// values, for both this and the bishop's `>> 55` masked to nine bits.
    ///
    @Inline
    pub def rookAttack(t: Tables[Static], square: Int32, occupied: Int64): Int64 =
        let index = Bits.toInt(Bits.bandL(
            Bits.shrL(Vector.get(square, t->rookFactor) * Bits.bandL(occupied, Vector.get(square, t->rookMask)), 52),
            0xFFFi64));
        Vector.get(index + Vector.get(square, t->rookOffset), t->attacks)

    ///
    /// The whole bishop magic lookup. See `rookAttack`; the only differences are
    /// the three bishop vectors and the 9-bit shift.
    ///
    @Inline
    pub def bishopAttack(t: Tables[Static], square: Int32, occupied: Int64): Int64 =
        let index = Bits.toInt(Bits.bandL(
            Bits.shrL(Vector.get(square, t->bishopFactor) * Bits.bandL(occupied, Vector.get(square, t->bishopMask)), 55),
            0x1FFi64));
        Vector.get(index + Vector.get(square, t->bishopOffset), t->attacks)
}

mod Bitboard {

    // `lsb`/`msb` call `java.lang.Long` directly — see the note on those two
    // functions. Flix treats every `java.lang.Long` static as *pure*, so this
    // import buys the JIT intrinsics without an `unsafe` block, an `IO` effect or
    // a signature change. (A doc-comment on an `import` is a parse error: imports
    // are not declarations.)
    import java.lang.Long

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
    /// the deltas and `@tailrec deltaLoop` walking one delta. They call each other,
    /// and MUTUAL recursion is the one shape Flix cannot compile to a `goto`: each
    /// step allocated a heap continuation dispatched through the megamorphic
    /// `Thunk$.invoke()`. Table construction makes ~121 000 `slidingAttacks` calls
    /// (107 648 magic subsets plus the between/rays pairs), so that was roughly a
    /// million allocations and a million megamorphic dispatches, all executed
    /// interpreted during cold start. Fusing the two loops into ONE self-recursive
    /// def — carrying both `deltaIndex` and `sq`, and restarting at `square`
    /// exactly where `attackLoop` did — makes it a `goto`.
    ///
    /// This is a cold-start change with no steady-state exposure: `slidingAttacks`
    /// is called only from `Tables.mk` (the four leaper tables, the magic subsets
    /// and the between/rays builders) and from `test/TestBitboard.flix`, never on
    /// the encode, decode or perft path.
    ///
    @Inline
    pub def slidingAttacks(square: Int32, occupied: Int64, deltas: Vector[Int32]): Int64 =
        slidingLoop(square, occupied, deltas, 0, square, 0i64)

    /// The Scala `attackLoop` and `deltaLoop` fused; see `slidingAttacks` above.
    def slidingLoop(square: Int32, occupied: Int64, deltas: Vector[Int32],
                    deltaIndex: Int32, sq: Int32, acc: Int64): Int64 =
        if (deltaIndex >= Vector.length(deltas)) acc
        else {
            let newSq = sq + Vector.get(deltaIndex, deltas);
            if (newSq < 0 or newSq >= 64 or Square.distance(newSq, sq) > 2)
                slidingLoop(square, occupied, deltas, deltaIndex + 1, square, acc)
            else {
                let newAcc = Bits.borL(acc, Bits.bit(newSq));
                if (contains(occupied, newSq))
                    slidingLoop(square, occupied, deltas, deltaIndex + 1, square, newAcc)
                else
                    slidingLoop(square, occupied, deltas, deltaIndex, newSq, newAcc)
            }
        }

    // Every wrapper from here to `aligned` is `@Inline`, as a family, and the
    // annotation is load-bearing rather than decorative.
    //
    // These are one-line forwarders into `mod Tables`, so Flix's automatic inliner
    // *sometimes* takes them — but only sometimes, and the rule is not the obvious
    // one. In the round-2 jar `between`, `rays`, `knightAttacks` and `files` were
    // inlined at every site while the structurally identical `ranks`, `kingAttacks`
    // and `pawnAttacks` were not, and `Board.attacksToOcc` inlined its five reads
    // while `Board.legalMoves` inlined none of them. Each refusal costs a 48-byte
    // `dev.flix.runtime.Value$` in the callee and a ~62-bytecode trampoline
    // (`instanceof Thunk$` loop, `instanceof Suspension$` arm, two `checkcast`s) at
    // the call site, in the innermost loop of move generation. `@Inline` is a
    // directive and always applies, so the family is annotated uniformly: that
    // removes the site-dependence, and it also means an innocuous edit to one of
    // these bodies cannot silently un-inline it.
    //
    // Round 1 tried exactly this and had to revert it: `flix build-jar` died with
    // `MethodTooLargeException` inside `test/TestBitboard.flix`. The cause was the
    // 15-field `enum` destructure, which made an inlined read 264 bytecodes; round 2
    // made `Tables` a `struct`, so a read is now ~12 (`getfield; checkcast [J;
    // laload`) — strictly *smaller* than the trampoline it replaces. Still gate on
    // `flix build-jar` and never on `flix check`, which does no codegen and cannot
    // see the 64 KB limit.

    ///
    /// Bishop attacks from `square` given `occupied`, via the magic table.
    ///
    /// Scala: `ATTACKS(((magic.factor * (occupied & magic.mask)) >>> (64 - 9)).toInt + magic.offset)`.
    /// The multiply wraps mod 2^64 exactly as Java's `lmul`, and `.toInt` truncates.
    ///
    /// The arithmetic lives in `Tables.bishopAttack`, which reads the three magic
    /// vectors and `ATTACKS` from a single destructure; see the note there.
    ///
    @Inline
    pub def bishopAttacks(t: Tables[Static], square: Int32, occupied: Int64): Int64 =
        Tables.bishopAttack(t, square, occupied)

    ///
    /// Rook attacks from `square` given `occupied`, via the magic table.
    ///
    @Inline
    pub def rookAttacks(t: Tables[Static], square: Int32, occupied: Int64): Int64 =
        Tables.rookAttack(t, square, occupied)

    ///
    /// Queen attacks: Scala uses `^`, not `|`. The two sets are disjoint, so this
    /// is the same value, but the operator is kept as written.
    ///
    @Inline
    pub def queenAttacks(t: Tables[Static], square: Int32, occupied: Int64): Int64 =
        Bits.bxorL(bishopAttacks(t, square, occupied), rookAttacks(t, square, occupied))

    ///
    /// Pawn attacks from `square` for the given colour (`true` = white).
    ///
    @Inline
    pub def pawnAttacks(t: Tables[Static], white: Bool, square: Int32): Int64 =
        if (white) Tables.whitePawnAttacks(t, square) else Tables.blackPawnAttacks(t, square)

    /// `Bitboard.KNIGHT_ATTACKS(square)`.
    @Inline
    pub def knightAttacks(t: Tables[Static], square: Int32): Int64 = Tables.knightAttacks(t, square)

    /// `Bitboard.KING_ATTACKS(square)`.
    @Inline
    pub def kingAttacks(t: Tables[Static], square: Int32): Int64 = Tables.kingAttacks(t, square)

    /// `Bitboard.BETWEEN(a)(b)`: the squares strictly between `a` and `b`, or `0`.
    @Inline
    pub def between(t: Tables[Static], a: Int32, b: Int32): Int64 = Tables.between(t, a, b)

    /// `Bitboard.RAYS(a)(b)`: the whole line through `a` and `b`, or `0`.
    @Inline
    pub def rays(t: Tables[Static], a: Int32, b: Int32): Int64 = Tables.rays(t, a, b)

    /// `Bitboard.RANKS(i)`, read from the table.
    @Inline
    pub def ranks(t: Tables[Static], i: Int32): Int64 = Tables.ranks(t, i)

    /// `Bitboard.FILES(i)`, read from the table.
    @Inline
    pub def files(t: Tables[Static], i: Int32): Int64 = Tables.files(t, i)

    ///
    /// Index of the least significant set bit. Undefined for `0`, which the Scala
    /// original guards with `assert`; the guard is kept.
    ///
    /// `java.lang.Long.numberOfTrailingZeros`, not `Int64.numberOfTrailingZeros`.
    /// The standard library's version is a *recursive per-bit scan*: it walks the
    /// word one position at a time through `Int64.getBit`, whose `pos` argument is
    /// a named record, so each iteration allocates a `RecordExtend` and looks the
    /// field up by string. `lsb` runs once per set bit of every bitboard iterated
    /// in move generation, so that cost is multiplied by everything. The Java
    /// method is a JIT intrinsic (`TZCNT`) and is the *same call the Scala original
    /// makes* — `src/main/scala/game/Bitboard.scala:100` is
    /// `java.lang.Long.numberOfTrailingZeros(b)` — so the two implementations are
    /// now identical by construction rather than merely in agreement.
    ///
    @Inline
    pub def lsb(b: Int64): Int32 =
        if (b == 0i64) bug!("Bitboard.lsb: empty bitboard")
        else Long.numberOfTrailingZeros(b)

    ///
    /// `lsb` with the empty-bitboard guard dropped: a **precondition**, not a check.
    ///
    /// `lsb` is inlined at about fifteen sites in `Board`, and each copy drags the
    /// `bug!` cold path in with it — a `ldc`, a `checkcast String`, a call to
    /// `Def$bug$exclamation` and its full trampoline, ~70 bytecodes of code that can
    /// never run, plus a redundant compare on every iteration. HotSpot's inlining
    /// heuristics count total bytecode size including blocks it will never execute,
    /// so that dead weight is what keeps `genPawnDoubles`, `genSafeKingLoop` and
    /// friends above the threshold.
    ///
    /// Use this ONLY where the caller's own loop guard has just established
    /// `b != 0` — every use in this library is the `else` arm of a literal
    /// `if (x == 0i64) ... else { let sq = Bitboard.lsbAt(x); ... }`, so the removed
    /// test is provably unreachable. Anywhere the bitboard could genuinely be empty
    /// — `Board.getKing`, and the encoder's `O-O`/`O-O-O` back-rank lookup, which
    /// `difftest`'s `ExceptionParityTest` pins — must keep `lsb`.
    ///
    @Inline
    pub def lsbAt(b: Int64): Int32 = Long.numberOfTrailingZeros(b)

    ///
    /// Index of the most significant set bit. Undefined for `0`.
    ///
    /// `java.lang.Long.numberOfLeadingZeros` for the reason given on `lsb`.
    ///
    @Inline
    pub def msb(b: Int64): Int32 =
        if (b == 0i64) bug!("Bitboard.msb: empty bitboard")
        else 63 - Long.numberOfLeadingZeros(b)

    ///
    /// `true` if `b` has two or more squares set.
    ///
    @Inline
    pub def moreThanOne(b: Int64): Bool =
        Bits.bandL(b, b - 1i64) != 0i64

    ///
    /// `true` if `sq` is a member of `b`.
    ///
    @Inline
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
    @Inline
    pub def aligned(t: Tables[Static], a: Int32, b: Int32, c: Int32): Bool =
        contains(Tables.rays(t, a, b), c)
}
