///
/// Fidelity tests for `Bitboard`.
///
/// Every expected value below was produced by running the Scala original
/// (`src/main/scala/game/Bitboard.scala`, compiled with `Magic.scala` and
/// `model.scala`) and printing the tables, not by re-deriving them here. The
/// checksums fold a whole table with `s = s * 1000003 + entry` in Java `long`
/// arithmetic, so they catch a single wrong bit anywhere in the table.
///
/// The second half of the file (from `testLeaperTablesAgainstReference` on) is
/// checked against a *different* engine instead - python-chess 1.11.2 - so that the
/// tables are validated against something that was never derived from this code or
/// from the Scala it was ported from. It covers all 64 squares for the four leaper
/// tables, a spread of squares and occupancies for the magic sliders, `BETWEEN` /
/// `RAYS` for aligned, adjacent, non-aligned and degenerate square pairs, the
/// `aligned` triple predicate, and the `lsb` / `msb` / `moreThanOne` / `contains`
/// boundaries at bit 0, bit 63 and the `Int64` sign bit.
///
mod TestBitboard {

    /// Folds `f(i)` over `0 <= i < n` with `s = s * 1000003 + f(i)`.
    def fold64(f: Int32 -> Int64 \ ef, i: Int32, n: Int32, acc: Int64): Int64 \ ef =
        if (i >= n) acc else fold64(f, i + 1, n, acc * 1000003i64 + f(i))

    @Test
    pub def testRankFileMasks(): Unit \ Assert = {
        Assert.assertEq(expected = 0x00000000000000ffi64, Bitboard.rankMask(0));
        Assert.assertEq(expected = 0x00000000ff000000i64, Bitboard.rankMask(3));
        Assert.assertEq(expected = 0x0101010101010101i64, Bitboard.fileMask(0));
        Assert.assertEq(expected = 0x2020202020202020i64, Bitboard.fileMask(5))
    }

    @Test
    pub def testScalars(): Unit \ Assert = {
        Assert.assertEq(expected = -1i64, Bitboard.all());
        Assert.assertEq(expected = 0, Bitboard.lsb(1i64));
        Assert.assertEq(expected = 63, Bitboard.lsb(Bits.shlL(1i64, 63)));
        Assert.assertEq(expected = 3, Bitboard.lsb(0x0000000000000048i64));
        Assert.assertEq(expected = 63, Bitboard.msb(-1i64));
        Assert.assertEq(expected = 6, Bitboard.msb(0x0000000000000048i64));
        Assert.assertFalse(Bitboard.moreThanOne(0i64));
        Assert.assertFalse(Bitboard.moreThanOne(Bits.shlL(1i64, 40)));
        Assert.assertTrue(Bitboard.moreThanOne(0x0000000000000048i64));
        Assert.assertTrue(Bitboard.contains(0x0000000000000048i64, 3));
        Assert.assertTrue(Bitboard.contains(0x0000000000000048i64, 6));
        Assert.assertFalse(Bitboard.contains(0x0000000000000048i64, 4));
        Assert.assertEq(expected = Set#{3, 6}, Bitboard.squareSet(0x0000000000000048i64));
        Assert.assertEq(expected = Set#{}, Bitboard.squareSet(0i64));
        Assert.assertEq(expected = 64, Set.size(Bitboard.squareSet(-1i64)))
    }

    ///
    /// `slidingAttacks` on its own, before any table is involved.
    /// Rook on a1 with an empty board is the a-file plus rank 1, minus a1.
    ///
    @Test
    pub def testSlidingAttacks(): Unit \ Assert = {
        Assert.assertEq(expected = 0x01010101010101fei64,
            Bitboard.slidingAttacks(0, 0i64, Bitboard.rookDeltas()));
        Assert.assertEq(expected = -9205322385119247872i64 /* 0x8040201008040200 */,
            Bitboard.slidingAttacks(0, 0i64, Bitboard.bishopDeltas()));
        // A blocker on a4 (square 24) stops the a-file walk there.
        Assert.assertEq(expected = 0x00000000010101fei64,
            Bitboard.slidingAttacks(0, Bits.bit(24), Bitboard.rookDeltas()));
        Assert.assertEq(expected = 0x0000000000020400i64,
            Bitboard.slidingAttacks(0, Bitboard.all(), Bitboard.knightDeltas()));
        Assert.assertEq(expected = 0x0000000000000302i64,
            Bitboard.slidingAttacks(0, Bitboard.all(), Bitboard.kingDeltas()))
    }

    @Test
    pub def testLeaperTables(): Unit \ Assert = {
        let t = Tables.mk();

        Assert.assertEq(expected = 0x00000000000000ffi64, Bitboard.ranks(t, 0));
        Assert.assertEq(expected = 0x00000000ff000000i64, Bitboard.ranks(t, 3));
        Assert.assertEq(expected = 0x0101010101010101i64, Bitboard.files(t, 0));
        Assert.assertEq(expected = 0x2020202020202020i64, Bitboard.files(t, 5));

        Assert.assertEq(expected = 0x0000000000020400i64, Bitboard.knightAttacks(t, 0));
        Assert.assertEq(expected = 0x0000000000050800i64, Bitboard.knightAttacks(t, 1));
        Assert.assertEq(expected = 0x0000000000402000i64, Bitboard.knightAttacks(t, 7));
        Assert.assertEq(expected = 0x0000142200221400i64, Bitboard.knightAttacks(t, 27));
        Assert.assertEq(expected = 0x0014220022140000i64, Bitboard.knightAttacks(t, 35));
        Assert.assertEq(expected = 0x0004020000000000i64, Bitboard.knightAttacks(t, 56));
        Assert.assertEq(expected = 0x0020400000000000i64, Bitboard.knightAttacks(t, 63));

        Assert.assertEq(expected = 0x0000000000000302i64, Bitboard.kingAttacks(t, 0));
        Assert.assertEq(expected = 0x000000000000c040i64, Bitboard.kingAttacks(t, 7));
        Assert.assertEq(expected = 0x0000001c141c0000i64, Bitboard.kingAttacks(t, 27));
        Assert.assertEq(expected = 0x0203000000000000i64, Bitboard.kingAttacks(t, 56));
        Assert.assertEq(expected = 0x40c0000000000000i64, Bitboard.kingAttacks(t, 63));

        Assert.assertEq(expected = 0x0000000000000200i64, Bitboard.pawnAttacks(t, true, 0));
        Assert.assertEq(expected = 0x0000000000000000i64, Bitboard.pawnAttacks(t, false, 0));
        Assert.assertEq(expected = 0x0000000000004000i64, Bitboard.pawnAttacks(t, true, 7));
        Assert.assertEq(expected = 0x0000001400000000i64, Bitboard.pawnAttacks(t, true, 27));
        Assert.assertEq(expected = 0x0000000000140000i64, Bitboard.pawnAttacks(t, false, 27));
        Assert.assertEq(expected = 0x0000000000000000i64, Bitboard.pawnAttacks(t, true, 56));
        Assert.assertEq(expected = 0x0002000000000000i64, Bitboard.pawnAttacks(t, false, 56))
    }

    @Test
    pub def testMagicAttacksEmptyBoard(): Unit \ Assert = {
        let t = Tables.mk();

        Assert.assertEq(expected = 0x01010101010101fei64, Bitboard.rookAttacks(t, 0, 0i64));
        Assert.assertEq(expected = -9205322385119247872i64 /* 0x8040201008040200 */, Bitboard.bishopAttacks(t, 0, 0i64));
        Assert.assertEq(expected = -9132982212281170946i64 /* 0x81412111090503fe */, Bitboard.queenAttacks(t, 0, 0i64));

        Assert.assertEq(expected = 0x02020202020202fdi64, Bitboard.rookAttacks(t, 1, 0i64));
        Assert.assertEq(expected = 0x0080402010080500i64, Bitboard.bishopAttacks(t, 1, 0i64));
        Assert.assertEq(expected = 0x02824222120a07fdi64, Bitboard.queenAttacks(t, 1, 0i64));

        Assert.assertEq(expected = -9187201950435737473i64 /* 0x808080808080807f */, Bitboard.rookAttacks(t, 7, 0i64));
        Assert.assertEq(expected = 0x0102040810204000i64, Bitboard.bishopAttacks(t, 7, 0i64));

        Assert.assertEq(expected = 0x08080808f7080808i64, Bitboard.rookAttacks(t, 27, 0i64));
        Assert.assertEq(expected = -9205038694072573375i64 /* 0x8041221400142241 */, Bitboard.bishopAttacks(t, 27, 0i64));
        Assert.assertEq(expected = -8626317307358205367i64 /* 0x88492a1cf71c2a49 */, Bitboard.queenAttacks(t, 27, 0i64));

        Assert.assertEq(expected = 0x080808f708080808i64, Bitboard.rookAttacks(t, 35, 0i64));
        Assert.assertEq(expected = 0x4122140014224180i64, Bitboard.bishopAttacks(t, 35, 0i64));

        Assert.assertEq(expected = -143832609275707135i64 /* 0xfe01010101010101 */, Bitboard.rookAttacks(t, 56, 0i64));
        Assert.assertEq(expected = 0x0002040810204080i64, Bitboard.bishopAttacks(t, 56, 0i64));

        Assert.assertEq(expected = 0x7f80808080808080i64, Bitboard.rookAttacks(t, 63, 0i64));
        Assert.assertEq(expected = 0x0040201008040201i64, Bitboard.bishopAttacks(t, 63, 0i64));
        Assert.assertEq(expected = 0x7fc0a09088848281i64, Bitboard.queenAttacks(t, 63, 0i64))
    }

    ///
    /// The magic lookups with a realistic occupancy: both pawn ranks and the four
    /// corner rooks, `0x00ff00000000ff00 | 0x8100000000000081`.
    ///
    @Test
    pub def testMagicAttacksOccupied(): Unit \ Assert = {
        let t = Tables.mk();
        let occ = Bits.borL(0x00ff00000000ff00i64, -9151314442816847743i64 /* 0x8100000000000081 */);

        Assert.assertEq(expected = 0x00000000000001fei64, Bitboard.rookAttacks(t, 0, occ));
        Assert.assertEq(expected = 0x0000000000000200i64, Bitboard.bishopAttacks(t, 0, occ));
        Assert.assertEq(expected = 0x00000000000003fei64, Bitboard.queenAttacks(t, 0, occ));

        Assert.assertEq(expected = 0x00000000000008f7i64, Bitboard.rookAttacks(t, 3, occ));
        Assert.assertEq(expected = 0x0000000000001400i64, Bitboard.bishopAttacks(t, 3, occ));
        Assert.assertEq(expected = 0x0000000000001cf7i64, Bitboard.queenAttacks(t, 3, occ));

        Assert.assertEq(expected = 0x00080808f7080800i64, Bitboard.rookAttacks(t, 27, occ));
        Assert.assertEq(expected = 0x0041221400142200i64, Bitboard.bishopAttacks(t, 27, occ));
        Assert.assertEq(expected = 0x00492a1cf71c2a00i64, Bitboard.queenAttacks(t, 27, occ));

        Assert.assertEq(expected = 0x001010ef10101000i64, Bitboard.rookAttacks(t, 36, occ));
        Assert.assertEq(expected = 0x0044280028448200i64, Bitboard.bishopAttacks(t, 36, occ));
        Assert.assertEq(expected = 0x005438ef38549200i64, Bitboard.queenAttacks(t, 36, occ));

        Assert.assertEq(expected = 0x7f80000000000000i64, Bitboard.rookAttacks(t, 63, occ));
        Assert.assertEq(expected = 0x0040000000000000i64, Bitboard.bishopAttacks(t, 63, occ));
        Assert.assertEq(expected = 0x7fc0000000000000i64, Bitboard.queenAttacks(t, 63, occ))
    }

    @Test
    pub def testBetweenRaysAligned(): Unit \ Assert = {
        let t = Tables.mk();

        Assert.assertEq(expected = 0x000000000000007ei64, Bitboard.between(t, 0, 7));
        Assert.assertEq(expected = 0x00000000000000ffi64, Bitboard.rays(t, 0, 7));

        Assert.assertEq(expected = 0x0040201008040200i64, Bitboard.between(t, 0, 63));
        Assert.assertEq(expected = -9205322385119247871i64 /* 0x8040201008040201 */, Bitboard.rays(t, 0, 63));

        Assert.assertEq(expected = 0x0001010101010100i64, Bitboard.between(t, 0, 56));
        Assert.assertEq(expected = 0x0101010101010101i64, Bitboard.rays(t, 0, 56));

        Assert.assertEq(expected = 0x0000001000000000i64, Bitboard.between(t, 27, 45));
        Assert.assertEq(expected = -9205322385119247871i64 /* 0x8040201008040201 */, Bitboard.rays(t, 27, 45));

        Assert.assertEq(expected = 0x0010101010101000i64, Bitboard.between(t, 4, 60));
        Assert.assertEq(expected = 0x1010101010101010i64, Bitboard.rays(t, 4, 60));

        // Adjacent on a diagonal: nothing between, but still a full ray.
        Assert.assertEq(expected = 0x0000000000000000i64, Bitboard.between(t, 0, 9));
        Assert.assertEq(expected = -9205322385119247871i64 /* 0x8040201008040201 */, Bitboard.rays(t, 0, 9));

        Assert.assertEq(expected = 0x0000000000000400i64, Bitboard.between(t, 3, 17));
        Assert.assertEq(expected = 0x0000000001020408i64, Bitboard.rays(t, 3, 17));

        // Not on a line at all: both entries stay zero.
        Assert.assertEq(expected = 0x0000000000000000i64, Bitboard.between(t, 10, 53));
        Assert.assertEq(expected = 0x0000000000000000i64, Bitboard.rays(t, 10, 53));

        Assert.assertTrue(Bitboard.aligned(t, 0, 7, 3));
        Assert.assertFalse(Bitboard.aligned(t, 0, 7, 8));
        Assert.assertTrue(Bitboard.aligned(t, 0, 9, 54));
        Assert.assertFalse(Bitboard.aligned(t, 0, 9, 55))
    }

    ///
    /// Whole-table checksums against the Scala original.
    ///
    @Test
    pub def testTableChecksums(): Unit \ Assert = {
        let t = Tables.mk();

        Assert.assertEq(expected = 0x51bea0a31a36318ai64,
            fold64(i -> Bitboard.knightAttacks(t, i), 0, 64, 0i64));
        Assert.assertEq(expected = -7251749315222963877i64 /* 0x9b5c9c6b51f3f95b */,
            fold64(i -> Bitboard.kingAttacks(t, i), 0, 64, 0i64));
        Assert.assertEq(expected = -2571340778522039040i64 /* 0xdc50c32f7bb7ad00 */,
            fold64(i -> Bitboard.pawnAttacks(t, true, i), 0, 64, 0i64));
        Assert.assertEq(expected = 6070367008536218765i64 /* 0x543e46a1d00d4c8d */,
            fold64(i -> Bitboard.pawnAttacks(t, false, i), 0, 64, 0i64));
        Assert.assertEq(expected = 0x11aafe4ee7a14314i64,
            fold64(i -> Bitboard.between(t, i / 64, Bits.band(i, 63)), 0, 64 * 64, 0i64));
        Assert.assertEq(expected = -7365446997520471804i64 /* 0x99c8acfac4d32904 */,
            fold64(i -> Bitboard.rays(t, i / 64, Bits.band(i, 63)), 0, 64 * 64, 0i64))
    }

    ///
    /// Checksum over the magic table itself: for every square and 256 pseudo-random
    /// occupancies, `rook + 31 * bishop`.
    ///
    @Test
    pub def testMagicChecksum(): Unit \ Assert = {
        let t = Tables.mk();
        let f = i -> {
            let sq = i / 256;
            let o = Bits.band(i, 255);
            let occ = Int32.toInt64(o) * -7046029254386353131i64 /* 0x9e3779b97f4a7c15 */;
            Bitboard.rookAttacks(t, sq, occ) + 31i64 * Bitboard.bishopAttacks(t, sq, occ)
        };
        Assert.assertEq(expected = 0x420f58611bd0f1e7i64, fold64(f, 0, 64 * 256, 0i64))
    }

    // ------------------------------------------------- independent-oracle tables
    //
    // Everything below this line is checked against python-chess, not against the
    // Scala original and not against this implementation: `chess.BB_KNIGHT_ATTACKS`,
    // `chess.BB_KING_ATTACKS`, `chess.BB_PAWN_ATTACKS`, the rank/file/diagonal
    // attack tables, and `chess.BB_BETWEEN` / `chess.BB_RAYS`. Two independent
    // implementations agreeing on all 64 squares is a much stronger statement than a
    // checksum of a port against the thing it was ported from.

    /// Reports every mismatch rather than stopping at the first.
    def report(failures: List[String]): Unit \ Assert =
        Assert.assertEq(expected = (Nil: List[String]), failures)

    ///
    /// The four leaper tables, for all 64 squares, against python-chess.
    /// Each row is `(square, knight, king, whitePawn, blackPawn)`.
    ///
    @Test
    pub def testLeaperTablesAgainstReference(): Unit \ Assert = {
        let t = Tables.mk();
        report(List.filterMap(row -> {
            let (sq, _, _, _, _) = row;
            let got = (sq, Bitboard.knightAttacks(t, sq), Bitboard.kingAttacks(t, sq),
                       Bitboard.pawnAttacks(t, true, sq), Bitboard.pawnAttacks(t, false, sq));
            if (got == row) None else Some("leapers on square ${sq}: expected ${row}, got ${got}")
        }, leaperReference()))
    }

    def leaperReference(): List[(Int32, Int64, Int64, Int64, Int64)] = List#{
        ( 0, 0x0000000000020400i64,
             0x0000000000000302i64,
             0x0000000000000200i64,
             0i64),
        ( 1, 0x0000000000050800i64,
             0x0000000000000705i64,
             0x0000000000000500i64,
             0i64),
        ( 2, 0x00000000000a1100i64,
             0x0000000000000e0ai64,
             0x0000000000000a00i64,
             0i64),
        ( 3, 0x0000000000142200i64,
             0x0000000000001c14i64,
             0x0000000000001400i64,
             0i64),
        ( 4, 0x0000000000284400i64,
             0x0000000000003828i64,
             0x0000000000002800i64,
             0i64),
        ( 5, 0x0000000000508800i64,
             0x0000000000007050i64,
             0x0000000000005000i64,
             0i64),
        ( 6, 0x0000000000a01000i64,
             0x000000000000e0a0i64,
             0x000000000000a000i64,
             0i64),
        ( 7, 0x0000000000402000i64,
             0x000000000000c040i64,
             0x0000000000004000i64,
             0i64),
        ( 8, 0x0000000002040004i64,
             0x0000000000030203i64,
             0x0000000000020000i64,
             0x0000000000000002i64),
        ( 9, 0x0000000005080008i64,
             0x0000000000070507i64,
             0x0000000000050000i64,
             0x0000000000000005i64),
        (10, 0x000000000a110011i64,
             0x00000000000e0a0ei64,
             0x00000000000a0000i64,
             0x000000000000000ai64),
        (11, 0x0000000014220022i64,
             0x00000000001c141ci64,
             0x0000000000140000i64,
             0x0000000000000014i64),
        (12, 0x0000000028440044i64,
             0x0000000000382838i64,
             0x0000000000280000i64,
             0x0000000000000028i64),
        (13, 0x0000000050880088i64,
             0x0000000000705070i64,
             0x0000000000500000i64,
             0x0000000000000050i64),
        (14, 0x00000000a0100010i64,
             0x0000000000e0a0e0i64,
             0x0000000000a00000i64,
             0x00000000000000a0i64),
        (15, 0x0000000040200020i64,
             0x0000000000c040c0i64,
             0x0000000000400000i64,
             0x0000000000000040i64),
        (16, 0x0000000204000402i64,
             0x0000000003020300i64,
             0x0000000002000000i64,
             0x0000000000000200i64),
        (17, 0x0000000508000805i64,
             0x0000000007050700i64,
             0x0000000005000000i64,
             0x0000000000000500i64),
        (18, 0x0000000a1100110ai64,
             0x000000000e0a0e00i64,
             0x000000000a000000i64,
             0x0000000000000a00i64),
        (19, 0x0000001422002214i64,
             0x000000001c141c00i64,
             0x0000000014000000i64,
             0x0000000000001400i64),
        (20, 0x0000002844004428i64,
             0x0000000038283800i64,
             0x0000000028000000i64,
             0x0000000000002800i64),
        (21, 0x0000005088008850i64,
             0x0000000070507000i64,
             0x0000000050000000i64,
             0x0000000000005000i64),
        (22, 0x000000a0100010a0i64,
             0x00000000e0a0e000i64,
             0x00000000a0000000i64,
             0x000000000000a000i64),
        (23, 0x0000004020002040i64,
             0x00000000c040c000i64,
             0x0000000040000000i64,
             0x0000000000004000i64),
        (24, 0x0000020400040200i64,
             0x0000000302030000i64,
             0x0000000200000000i64,
             0x0000000000020000i64),
        (25, 0x0000050800080500i64,
             0x0000000705070000i64,
             0x0000000500000000i64,
             0x0000000000050000i64),
        (26, 0x00000a1100110a00i64,
             0x0000000e0a0e0000i64,
             0x0000000a00000000i64,
             0x00000000000a0000i64),
        (27, 0x0000142200221400i64,
             0x0000001c141c0000i64,
             0x0000001400000000i64,
             0x0000000000140000i64),
        (28, 0x0000284400442800i64,
             0x0000003828380000i64,
             0x0000002800000000i64,
             0x0000000000280000i64),
        (29, 0x0000508800885000i64,
             0x0000007050700000i64,
             0x0000005000000000i64,
             0x0000000000500000i64),
        (30, 0x0000a0100010a000i64,
             0x000000e0a0e00000i64,
             0x000000a000000000i64,
             0x0000000000a00000i64),
        (31, 0x0000402000204000i64,
             0x000000c040c00000i64,
             0x0000004000000000i64,
             0x0000000000400000i64),
        (32, 0x0002040004020000i64,
             0x0000030203000000i64,
             0x0000020000000000i64,
             0x0000000002000000i64),
        (33, 0x0005080008050000i64,
             0x0000070507000000i64,
             0x0000050000000000i64,
             0x0000000005000000i64),
        (34, 0x000a1100110a0000i64,
             0x00000e0a0e000000i64,
             0x00000a0000000000i64,
             0x000000000a000000i64),
        (35, 0x0014220022140000i64,
             0x00001c141c000000i64,
             0x0000140000000000i64,
             0x0000000014000000i64),
        (36, 0x0028440044280000i64,
             0x0000382838000000i64,
             0x0000280000000000i64,
             0x0000000028000000i64),
        (37, 0x0050880088500000i64,
             0x0000705070000000i64,
             0x0000500000000000i64,
             0x0000000050000000i64),
        (38, 0x00a0100010a00000i64,
             0x0000e0a0e0000000i64,
             0x0000a00000000000i64,
             0x00000000a0000000i64),
        (39, 0x0040200020400000i64,
             0x0000c040c0000000i64,
             0x0000400000000000i64,
             0x0000000040000000i64),
        (40, 0x0204000402000000i64,
             0x0003020300000000i64,
             0x0002000000000000i64,
             0x0000000200000000i64),
        (41, 0x0508000805000000i64,
             0x0007050700000000i64,
             0x0005000000000000i64,
             0x0000000500000000i64),
        (42, 0x0a1100110a000000i64,
             0x000e0a0e00000000i64,
             0x000a000000000000i64,
             0x0000000a00000000i64),
        (43, 0x1422002214000000i64,
             0x001c141c00000000i64,
             0x0014000000000000i64,
             0x0000001400000000i64),
        (44, 0x2844004428000000i64,
             0x0038283800000000i64,
             0x0028000000000000i64,
             0x0000002800000000i64),
        (45, 0x5088008850000000i64,
             0x0070507000000000i64,
             0x0050000000000000i64,
             0x0000005000000000i64),
        (46, -6913025356609880064i64 /* 0xa0100010a0000000 */,
             0x00e0a0e000000000i64,
             0x00a0000000000000i64,
             0x000000a000000000i64),
        (47, 0x4020002040000000i64,
             0x00c040c000000000i64,
             0x0040000000000000i64,
             0x0000004000000000i64),
        (48, 0x0400040200000000i64,
             0x0302030000000000i64,
             0x0200000000000000i64,
             0x0000020000000000i64),
        (49, 0x0800080500000000i64,
             0x0705070000000000i64,
             0x0500000000000000i64,
             0x0000050000000000i64),
        (50, 0x1100110a00000000i64,
             0x0e0a0e0000000000i64,
             0x0a00000000000000i64,
             0x00000a0000000000i64),
        (51, 0x2200221400000000i64,
             0x1c141c0000000000i64,
             0x1400000000000000i64,
             0x0000140000000000i64),
        (52, 0x4400442800000000i64,
             0x3828380000000000i64,
             0x2800000000000000i64,
             0x0000280000000000i64),
        (53, -8646761407372591104i64 /* 0x8800885000000000 */,
             0x7050700000000000i64,
             0x5000000000000000i64,
             0x0000500000000000i64),
        (54, 0x100010a000000000i64,
             -2260560722335367168i64 /* 0xe0a0e00000000000 */,
             -6917529027641081856i64 /* 0xa000000000000000 */,
             0x0000a00000000000i64),
        (55, 0x2000204000000000i64,
             -4593460513685372928i64 /* 0xc040c00000000000 */,
             0x4000000000000000i64,
             0x0000400000000000i64),
        (56, 0x0004020000000000i64,
             0x0203000000000000i64,
             0i64,
             0x0002000000000000i64),
        (57, 0x0008050000000000i64,
             0x0507000000000000i64,
             0i64,
             0x0005000000000000i64),
        (58, 0x00110a0000000000i64,
             0x0a0e000000000000i64,
             0i64,
             0x000a000000000000i64),
        (59, 0x0022140000000000i64,
             0x141c000000000000i64,
             0i64,
             0x0014000000000000i64),
        (60, 0x0044280000000000i64,
             0x2838000000000000i64,
             0i64,
             0x0028000000000000i64),
        (61, 0x0088500000000000i64,
             0x5070000000000000i64,
             0i64,
             0x0050000000000000i64),
        (62, 0x0010a00000000000i64,
             -6854478632857894912i64 /* 0xa0e0000000000000 */,
             0i64,
             0x00a0000000000000i64),
        (63, 0x0020400000000000i64,
             0x40c0000000000000i64,
             0i64,
             0x0040000000000000i64)
    }

    ///
    /// Rook, bishop and queen attacks from a spread of squares - corners, both edge
    /// files, the centre - under six occupancies, against python-chess. Each row is
    /// `(square, occupancy, rook, bishop)`; the queen is checked as `rook | bishop`,
    /// which is what `Bitboard.queenAttacks` computes.
    ///
    @Test
    pub def testMagicAttacksAgainstReference(): Unit \ Assert = {
        let t = Tables.mk();
        report(List.filterMap(row -> {
            let (sq, occ, r, b) = row;
            let gotR = Bitboard.rookAttacks(t, sq, occ);
            let gotB = Bitboard.bishopAttacks(t, sq, occ);
            let gotQ = Bitboard.queenAttacks(t, sq, occ);
            if (gotR == r and gotB == b and gotQ == Bits.borL(r, b)) None
            else Some("sliders on square ${sq} occ ${occ}: expected rook ${r} bishop ${b}, got rook ${gotR} bishop ${gotB} queen ${gotQ}")
        }, sliderReference()))
    }

    def sliderReference(): List[(Int32, Int64, Int64, Int64)] = List#{
        // empty board
        ( 0, 0i64,
             0x01010101010101fei64,
             -9205322385119247872i64 /* 0x8040201008040200 */),
        ( 1, 0i64,
             0x02020202020202fdi64,
             0x0080402010080500i64),
        ( 7, 0i64,
             -9187201950435737473i64 /* 0x808080808080807f */,
             0x0102040810204000i64),
        ( 8, 0i64,
             0x010101010101fe01i64,
             0x4020100804020002i64),
        ( 9, 0i64,
             0x020202020202fd02i64,
             -9205322385119182843i64 /* 0x8040201008050005 */),
        (24, 0i64,
             0x01010101fe010101i64,
             0x1008040200020408i64),
        (27, 0i64,
             0x08080808f7080808i64,
             -9205038694072573375i64 /* 0x8041221400142241 */),
        (28, 0i64,
             0x10101010ef101010i64,
             0x0182442800284482i64),
        (31, 0i64,
             -9187201950452514688i64 /* 0x808080807f808080 */,
             0x0810204000402010i64),
        (35, 0i64,
             0x080808f708080808i64,
             0x4122140014224180i64),
        (36, 0i64,
             0x101010ef10101010i64,
             -9060072569221905919i64 /* 0x8244280028448201 */),
        (54, 0i64,
             0x40bf404040404040i64,
             -6917353036926680575i64 /* 0xa000a01008040201 */),
        (55, 0i64,
             -9187483425412448128i64 /* 0x807f808080808080 */,
             0x4000402010080402i64),
        (56, 0i64,
             -143832609275707135i64 /* 0xfe01010101010101 */,
             0x0002040810204080i64),
        (62, 0i64,
             -4665658569255796672i64 /* 0xbf40404040404040 */,
             0x00a0100804020100i64),
        (63, 0i64,
             0x7f80808080808080i64,
             0x0040201008040201i64),
        // every square occupied
        ( 0, -1i64 /* 0xffffffffffffffff */,
             0x0000000000000102i64,
             0x0000000000000200i64),
        ( 1, -1i64 /* 0xffffffffffffffff */,
             0x0000000000000205i64,
             0x0000000000000500i64),
        ( 7, -1i64 /* 0xffffffffffffffff */,
             0x0000000000008040i64,
             0x0000000000004000i64),
        ( 8, -1i64 /* 0xffffffffffffffff */,
             0x0000000000010201i64,
             0x0000000000020002i64),
        ( 9, -1i64 /* 0xffffffffffffffff */,
             0x0000000000020502i64,
             0x0000000000050005i64),
        (24, -1i64 /* 0xffffffffffffffff */,
             0x0000000102010000i64,
             0x0000000200020000i64),
        (27, -1i64 /* 0xffffffffffffffff */,
             0x0000000814080000i64,
             0x0000001400140000i64),
        (28, -1i64 /* 0xffffffffffffffff */,
             0x0000001028100000i64,
             0x0000002800280000i64),
        (31, -1i64 /* 0xffffffffffffffff */,
             0x0000008040800000i64,
             0x0000004000400000i64),
        (35, -1i64 /* 0xffffffffffffffff */,
             0x0000081408000000i64,
             0x0000140014000000i64),
        (36, -1i64 /* 0xffffffffffffffff */,
             0x0000102810000000i64,
             0x0000280028000000i64),
        (54, -1i64 /* 0xffffffffffffffff */,
             0x40a0400000000000i64,
             -6917353105780637696i64 /* 0xa000a00000000000 */),
        (55, -1i64 /* 0xffffffffffffffff */,
             -9205216900856938496i64 /* 0x8040800000000000 */,
             0x4000400000000000i64),
        (56, -1i64 /* 0xffffffffffffffff */,
             0x0201000000000000i64,
             0x0002000000000000i64),
        (62, -1i64 /* 0xffffffffffffffff */,
             -6899514629131599872i64 /* 0xa040000000000000 */,
             0x00a0000000000000i64),
        (63, -1i64 /* 0xffffffffffffffff */,
             0x4080000000000000i64,
             0x0040000000000000i64),
        // both pawn ranks plus the four corner rooks
        ( 0, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x00000000000001fei64,
             0x0000000000000200i64),
        ( 1, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x00000000000002fdi64,
             0x0000000000000500i64),
        ( 7, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x000000000000807fi64,
             0x0000000000004000i64),
        ( 8, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x0001010101010201i64,
             0x0020100804020002i64),
        ( 9, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x0002020202020502i64,
             0x0040201008050005i64),
        (24, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x00010101fe010100i64,
             0x0008040200020400i64),
        (27, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x00080808f7080800i64,
             0x0041221400142200i64),
        (28, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x00101010ef101000i64,
             0x0082442800284400i64),
        (31, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x008080807f808000i64,
             0x0010204000402000i64),
        (35, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x000808f708080800i64,
             0x0022140014224100i64),
        (36, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x001010ef10101000i64,
             0x0044280028448200i64),
        (54, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x40a0404040404000i64,
             -6917353036926680576i64 /* 0xa000a01008040200 */),
        (55, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             -9205216348945219584i64 /* 0x8040808080808000 */,
             0x4000402010080400i64),
        (56, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             -143833713099145216i64 /* 0xfe01000000000000 */,
             0x0002000000000000i64),
        (62, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             -4665729213955833856i64 /* 0xbf40000000000000 */,
             0x00a0000000000000i64),
        (63, -9079538323755565183i64 /* 0x81ff00000000ff81 */,
             0x7f80000000000000i64,
             0x0040000000000000i64),
        // the four centre squares
        ( 0, 0x0000001818000000i64,
             0x01010101010101fei64,
             0x0000000008040200i64),
        ( 1, 0x0000001818000000i64,
             0x02020202020202fdi64,
             0x0000000010080500i64),
        ( 7, 0x0000001818000000i64,
             -9187201950435737473i64 /* 0x808080808080807f */,
             0x0000000010204000i64),
        ( 8, 0x0000001818000000i64,
             0x010101010101fe01i64,
             0x0000000804020002i64),
        ( 9, 0x0000001818000000i64,
             0x020202020202fd02i64,
             0x0000000008050005i64),
        (24, 0x0000001818000000i64,
             0x010101010e010101i64,
             0x1008040200020408i64),
        (27, 0x0000001818000000i64,
             0x0000000817080808i64,
             0x0001021400142241i64),
        (28, 0x0000001818000000i64,
             0x00000010e8101010i64,
             0x0080402800284482i64),
        (31, 0x0000001818000000i64,
             -9187201950704172928i64 /* 0x8080808070808080 */,
             0x0810204000402010i64),
        (35, 0x0000001818000000i64,
             0x0808081708000000i64,
             0x4122140014020100i64),
        (36, 0x0000001818000000i64,
             0x101010e810000000i64,
             -9060072569222168576i64 /* 0x8244280028408000 */),
        (54, 0x0000001818000000i64,
             0x40bf404040404040i64,
             -6917353037061160960i64 /* 0xa000a01000000000 */),
        (55, 0x0000001818000000i64,
             -9187483425412448128i64 /* 0x807f808080808080 */,
             0x4000402010000000i64),
        (56, 0x0000001818000000i64,
             -143832609275707135i64 /* 0xfe01010101010101 */,
             0x0002040800000000i64),
        (62, 0x0000001818000000i64,
             -4665658569255796672i64 /* 0xbf40404040404040 */,
             0x00a0100800000000i64),
        (63, 0x0000001818000000i64,
             0x7f80808080808080i64,
             0x0040201000000000i64),
        // files a and h
        ( 0, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x00000000000001fei64,
             -9205322385119247872i64 /* 0x8040201008040200 */),
        ( 1, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x02020202020202fdi64,
             0x0080402010080500i64),
        ( 7, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x000000000000807fi64,
             0x0102040810204000i64),
        ( 8, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x000000000001fe01i64,
             0x4020100804020002i64),
        ( 9, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x020202020202fd02i64,
             -9205322385119182843i64 /* 0x8040201008050005 */),
        (24, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x00000001fe010000i64,
             0x1008040200020408i64),
        (27, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x08080808f7080808i64,
             -9205038694072573375i64 /* 0x8041221400142241 */),
        (28, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x10101010ef101010i64,
             0x0182442800284482i64),
        (31, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x000000807f800000i64,
             0x0810204000402010i64),
        (35, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x080808f708080808i64,
             0x4122140014224180i64),
        (36, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x101010ef10101010i64,
             -9060072569221905919i64 /* 0x8244280028448201 */),
        (54, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x40bf404040404040i64,
             -6917353036926680575i64 /* 0xa000a01008040201 */),
        (55, -9114861777597660799i64 /* 0x8181818181818181 */,
             -9187483977324167168i64 /* 0x807f800000000000 */,
             0x4000402010080402i64),
        (56, -9114861777597660799i64 /* 0x8181818181818181 */,
             -143833713099145216i64 /* 0xfe01000000000000 */,
             0x0002040810204080i64),
        (62, -9114861777597660799i64 /* 0x8181818181818181 */,
             -4665658569255796672i64 /* 0xbf40404040404040 */,
             0x00a0100804020100i64),
        (63, -9114861777597660799i64 /* 0x8181818181818181 */,
             0x7f80000000000000i64,
             0x0040201008040201i64),
        // a scattered mask
        ( 0, 0x1248103a5c208001i64,
             0x01010101010101fei64,
             0x0000000008040200i64),
        ( 1, 0x1248103a5c208001i64,
             0x00000002020202fdi64,
             0x0000000010080500i64),
        ( 7, 0x1248103a5c208001i64,
             0x000000000000807fi64,
             0x0000000000204000i64),
        ( 8, 0x1248103a5c208001i64,
             0x010101010101fe01i64,
             0x0000000004020002i64),
        ( 9, 0x1248103a5c208001i64,
             0x000000020202fd02i64,
             0x0000000008050005i64),
        (24, 0x1248103a5c208001i64,
             0x0101010106010101i64,
             0x0000000200020408i64),
        (27, 0x1248103a5c208001i64,
             0x0000000814080808i64,
             0x0001021400142241i64),
        (28, 0x1248103a5c208001i64,
             0x0000001068101010i64,
             0x0000002800280402i64),
        (31, 0x1248103a5c208001i64,
             -9187201951509479424i64 /* 0x8080808040808000 */,
             0x0810204000402010i64),
        (35, 0x1248103a5c208001i64,
             0x0008081608000000i64,
             0x0102140014000000i64),
        (36, 0x1248103a5c208001i64,
             0x0000102810000000i64,
             0x0244280028408000i64),
        (54, 0x1248103a5c208001i64,
             0x40b8404040000000i64,
             -6917353037061160960i64 /* 0xa000a01000000000 */),
        (55, 0x1248103a5c208001i64,
             -9205216348945219584i64 /* 0x8040808080808000 */,
             0x4000402000000000i64),
        (56, 0x1248103a5c208001i64,
             0x0201010101010101i64,
             0x0002040800000000i64),
        (62, 0x1248103a5c208001i64,
             -5746593124524752896i64 /* 0xb040000000000000 */,
             0x00a0100000000000i64),
        (63, 0x1248103a5c208001i64,
             0x7080808080808000i64,
             0x0040000000000000i64)
    }

    ///
    /// `BETWEEN` and `RAYS` for a spread of square pairs, against python-chess
    /// (`chess.BB_BETWEEN` / `chess.BB_RAYS`), covering rank, file, both diagonals,
    /// adjacent squares, non-aligned pairs and `a == b`.
    ///
    @Test
    pub def testBetweenRaysAgainstReference(): Unit \ Assert = {
        let t = Tables.mk();
        report(List.filterMap(row -> {
            let (a, b, between, rays) = row;
            let gotBetween = Bitboard.between(t, a, b);
            let gotRays = Bitboard.rays(t, a, b);
            if (gotBetween == between and gotRays == rays) None
            else Some("between/rays(${a}, ${b}): expected ${between}/${rays}, got ${gotBetween}/${gotRays}")
        }, betweenRaysReference()))
    }

    def betweenRaysReference(): List[(Int32, Int32, Int64, Int64)] = List#{
        ( 0,  7, 0x000000000000007ei64,
                0x00000000000000ffi64),
        ( 0, 56, 0x0001010101010100i64,
                0x0101010101010101i64),
        ( 0, 63, 0x0040201008040200i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        ( 0,  9, 0i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        ( 0,  1, 0i64,
                0x00000000000000ffi64),
        ( 0,  8, 0i64,
                0x0101010101010101i64),
        ( 0,  2, 0x0000000000000002i64,
                0x00000000000000ffi64),
        ( 7, 56, 0x0002040810204000i64,
                0x0102040810204080i64),
        ( 7, 63, 0x0080808080808000i64,
                -9187201950435737472i64 /* 0x8080808080808080 */),
        (63, 56, 0x7e00000000000000i64,
                -72057594037927936i64 /* 0xff00000000000000 */),
        (27, 45, 0x0000001000000000i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        (27, 36, 0i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        (27, 35, 0i64,
                0x0808080808080808i64),
        (27, 24, 0x0000000006000000i64,
                0x00000000ff000000i64),
        (27, 31, 0x0000000070000000i64,
                0x00000000ff000000i64),
        (27,  3, 0x0000000000080800i64,
                0x0808080808080808i64),
        (27, 59, 0x0008080800000000i64,
                0x0808080808080808i64),
        (27,  0, 0x0000000000040200i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        (27, 63, 0x0040201000000000i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        ( 4, 60, 0x0010101010101000i64,
                0x1010101010101010i64),
        ( 3, 17, 0x0000000000000400i64,
                0x0000000001020408i64),
        (10, 53, 0i64,
                0i64),
        ( 1, 16, 0i64,
                0i64),
        ( 5,  5, 0i64,
                0i64),
        ( 0,  0, 0i64,
                0i64),
        (63, 63, 0i64,
                0i64),
        (20, 34, 0x0000000008000000i64,
                0x0001020408102040i64),
        (20, 41, 0x0000000408000000i64,
                0x0001020408102040i64),
        (56,  7, 0x0002040810204000i64,
                0x0102040810204080i64),
        (12, 26, 0x0000000000080000i64,
                0x0000010204081020i64),
        (12, 33, 0x0000000004080000i64,
                0x0000010204081020i64),
        (33, 12, 0x0000000004080000i64,
                0x0000010204081020i64),
        ( 9, 54, 0x0000201008040000i64,
                -9205322385119247871i64 /* 0x8040201008040201 */),
        ( 9, 55, 0i64,
                0i64),
        (62, 47, 0i64,
                0i64),
        ( 8, 15, 0x0000000000007e00i64,
                0x000000000000ff00i64),
        (15,  8, 0x0000000000007e00i64,
                0x000000000000ff00i64)
    }

    ///
    /// `Bitboard.aligned(t, a, b, c)` - Scala's `Square.aligned` - on triples chosen
    /// so that each of rank, file, both diagonals and "not on a line" is represented,
    /// including the degenerate cases where `c` equals `a` or `b`.
    ///
    @Test
    pub def testAlignedTriples(): Unit \ Assert = {
        let t = Tables.mk();
        report(List.filterMap(row -> {
            let (a, b, c, expected) = row;
            let got = Bitboard.aligned(t, a, b, c);
            if (got == expected) None else Some("aligned(${a}, ${b}, ${c}): expected ${expected}, got ${got}")
        }, alignedReference()))
    }

    def alignedReference(): List[(Int32, Int32, Int32, Bool)] = List#{
        ( 0,  7,  3, true),
        ( 0,  7,  4, true),
        ( 0,  7,  8, false),
        ( 0,  7,  0, true),
        ( 0,  7,  7, true),
        ( 0, 63,  9, true),
        ( 0, 63, 54, true),
        ( 0, 63, 55, false),
        ( 0, 56, 24, true),
        ( 0, 56, 25, false),
        ( 4, 60, 36, true),
        ( 4, 60, 37, false),
        (27, 45, 36, true),
        (27, 45, 54, true),
        (27, 45, 53, false),
        (10, 53,  0, false),
        (10, 53, 10, false),
        ( 3, 17, 10, true),
        ( 3, 17, 24, true),
        ( 3, 17, 11, false),
        (63, 56, 60, true),
        (63, 56, 52, false),
        (12, 26, 19, true),
        (12, 26, 33, true),
        (56,  7, 28, true),
        (56,  7, 35, true),
        ( 1, 16,  8, false),
        ( 1, 16,  9, false)
    }

    ///
    /// `lsb` / `msb` / `moreThanOne` / `contains` / `squareSet` at the boundaries:
    /// bit 0, bit 63, a mask that is *only* the sign bit, and masks that are negative
    /// as `Int64`. Java's `Long.numberOfLeadingZeros` / `numberOfTrailingZeros` treat
    /// the word as unsigned, so a negative mask must still report `msb == 63`, and
    /// `moreThanOne(Int64.minValue)` must be `false` even though the value is
    /// negative and `b - 1` overflows to `Int64.maxValue`.
    ///
    @Test
    pub def testBitScanBoundaries(): Unit \ Assert = {
        let signBit = Int64.minValue();                         // 0x8000000000000000
        let corners = -9223372036854775807i64;                  // 0x8000000000000001
        let topTwo  = -4611686018427387904i64;                  // 0xc000000000000000

        Assert.assertEq(expected = signBit, Bits.bit(63));
        Assert.assertEq(expected = 1i64, Bits.bit(0));

        Assert.assertEq(expected = 0,  Bitboard.lsb(1i64));
        Assert.assertEq(expected = 0,  Bitboard.msb(1i64));
        Assert.assertEq(expected = 63, Bitboard.lsb(signBit));
        Assert.assertEq(expected = 63, Bitboard.msb(signBit));
        Assert.assertEq(expected = 0,  Bitboard.lsb(corners));
        Assert.assertEq(expected = 63, Bitboard.msb(corners));
        Assert.assertEq(expected = 0,  Bitboard.lsb(-1i64));
        Assert.assertEq(expected = 63, Bitboard.msb(-1i64));
        Assert.assertEq(expected = 62, Bitboard.lsb(topTwo));
        Assert.assertEq(expected = 63, Bitboard.msb(topTwo));
        Assert.assertEq(expected = 1,  Bitboard.lsb(-2i64));     // 0xfffffffffffffffe
        Assert.assertEq(expected = 63, Bitboard.msb(-2i64));

        Assert.assertFalse(Bitboard.moreThanOne(signBit));
        Assert.assertTrue(Bitboard.moreThanOne(corners));
        Assert.assertTrue(Bitboard.moreThanOne(topTwo));
        Assert.assertTrue(Bitboard.moreThanOne(-1i64));
        Assert.assertFalse(Bitboard.moreThanOne(1i64));
        Assert.assertFalse(Bitboard.moreThanOne(0i64));

        Assert.assertTrue(Bitboard.contains(signBit, 63));
        Assert.assertFalse(Bitboard.contains(signBit, 62));
        Assert.assertFalse(Bitboard.contains(signBit, 0));
        Assert.assertTrue(Bitboard.contains(corners, 0));
        Assert.assertTrue(Bitboard.contains(corners, 63));
        Assert.assertFalse(Bitboard.contains(corners, 1));
        Assert.assertEq(expected = 64, countContained(-1i64, 0, 0));
        Assert.assertEq(expected = 0, countContained(0i64, 0, 0));

        Assert.assertEq(expected = Set#{63}, Bitboard.squareSet(signBit));
        Assert.assertEq(expected = Set#{0, 63}, Bitboard.squareSet(corners));
        Assert.assertEq(expected = Set#{62, 63}, Bitboard.squareSet(topTwo))
    }

    /// How many of squares 0..63 `contains` reports as members of `b`.
    def countContained(b: Int64, sq: Int32, acc: Int32): Int32 =
        if (sq >= 64) acc
        else countContained(b, sq + 1, if (Bitboard.contains(b, sq)) acc + 1 else acc)

    ///
    /// Structural invariants of `BETWEEN` and `RAYS` over all 4096 pairs: both tables
    /// are symmetric, `BETWEEN(a, b)` is a subset of `RAYS(a, b)`, a non-empty ray
    /// contains both endpoints and never contains a square between-set member twice,
    /// and the diagonal `a == b` is empty in both (the Scala loop only writes an entry
    /// when `b` is reachable from `a`, and no square attacks itself).
    ///
    @Test
    pub def testBetweenRaysInvariants(): Unit \ Assert = {
        let t = Tables.mk();
        Assert.assertEq(expected = 0, pairLoop(t, 0, 0, 0))
    }

    def pairLoop(t: Tables, a: Int32, b: Int32, bad: Int32): Int32 =
        if (a >= 64) bad
        else if (b >= 64) pairLoop(t, a + 1, 0, bad)
        else {
            let ab = Bitboard.between(t, a, b);
            let ba = Bitboard.between(t, b, a);
            let rab = Bitboard.rays(t, a, b);
            let rba = Bitboard.rays(t, b, a);
            let symmetric = ab == ba and rab == rba;
            let subset = Bits.bandL(ab, Bits.bnotL(rab)) == 0i64;
            let endpoints =
                if (rab == 0i64) ab == 0i64
                else Bitboard.contains(rab, a) and Bitboard.contains(rab, b);
            let selfEmpty = if (a == b) ab == 0i64 and rab == 0i64 else true;
            let noEndpointsBetween =
                if (a == b) true
                else not Bitboard.contains(ab, a) and not Bitboard.contains(ab, b);
            let ok = symmetric and subset and endpoints and selfEmpty and noEndpointsBetween;
            pairLoop(t, a, b + 1, if (ok) bad else bad + 1)
        }
}
