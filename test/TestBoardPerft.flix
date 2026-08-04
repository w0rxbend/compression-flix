///
/// Perft regression tests for `Board`.
///
/// The expected node counts are the ones asserted by `trickyBatch()` in
/// `src/test/scala/PerftTest.scala`, plus the standard start-position counts.
/// They cover castling, en passant, promotion, double check and pinned pieces.
///
/// The full sweep (all 6838 `batch0..batchN` gentest positions at depth 4, the
/// start position at depth 5, and a Scala-vs-Flix checksum over move order and
/// scores) is not run here — it takes minutes. See the notes in `src/Board.flix`.
///
/// Each `@Test` builds `Tables`/`Psqt`/`polyglot` itself because a Flix `def` is not
/// memoized and there is no way to share a value between tests; that is ~100 ms per
/// test, which is why the depths here are kept small.
///
mod TestBoardPerft {

    /// Counts the leaves of the legal-move tree, as `PerftTest.perft`.
    def perft(b: Board[r], depth: Int32): Int64 \ r =
        if (depth >= 1) region rc {
            let moves = MoveList.mkDefault(rc);
            Board.legalMoves(b, moves);
            if (depth == 1) Int32.toInt64(MoveList.getSize(moves))
            else childLoop(b, moves, depth, 0, 0i64)
        } else 1i64

    def childLoop(b: Board[r], moves: MoveList[r2], depth: Int32, i: Int32, acc: Int64): Int64 \ r + r2 =
        if (i >= MoveList.getSize(moves)) acc
        else region rc {
            let child = Board.copy(rc, b);
            Board.play(child, MoveList.get(moves, i));
            childLoop(b, moves, depth, i + 1, acc + perft(child, depth - 1))
        }

    /// Perft from a position given as the Scala `Board` constructor arguments.
    def perftFrom(p: (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64),
            depth: Int32): Int64 = {
        let (pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr) = p;
        let tables = Tables.mk();
        let psqt = Psqt.mk();
        let zob = ZobristHash.polyglot();
        region rc {
            perft(Board.mk(rc, tables, psqt, zob, pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr), depth)
        }
    }

    /// The standard starting position.
    def startPosition(): (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64) =
        (0x00ff00000000ff00i64, 0x4200000000000042i64, 0x2400000000000024i64, -9151314442816847743i64,
         0x0800000000000008i64, 0x1000000000000010i64, 0x000000000000ffffi64, -281474976710656i64,
         true, 0, -9151314442816847743i64)

    /// Kiwipete, `r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -`.
    def kiwipete(): (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64) =
        (12754369552377600i64, 37452115083264i64, 18015498021115904i64, -9151314442816847743i64,
         4503599629467648i64, 1152921504606846992i64, 103350075281i64, -7963082122242031616i64,
         true, 0, -9151314442816847743i64)

    /// `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -` — the classic en-passant pin position.
    def enPassantPin(): (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64) =
        (1134705126690816i64, 0i64, 0i64, 549789368320i64, 0i64, 6442450944i64, 12918476800i64,
         1135248440033280i64, true, 0, 0i64)

    /// `r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ -` — promotions.
    def promotions(): (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64) =
        (57139506205224704i64, 35184399351808i64, 12889227264i64, 2377900603251622017i64,
         576461851815051264i64, 4611686018427387920i64, 564049488309905i64, 7622659127499555072i64,
         false, 0, 129i64)

    /// `rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ -`.
    def position5(): (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64) =
        (66151017573566208i64, 144115188075868162i64, 292733975846191108i64, -9151314442816847743i64,
         576460752303423496i64, 2305843009213693968i64, 2251799880849311i64, -5768262299684954112i64,
         true, 0, 129i64)

    /// `r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - -`.
    def position6(): (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64) =
        (64749209236661760i64, 39582420959232i64, 293198626816i64, 2377900603251621921i64,
         4503599627374592i64, 4611686018427387968i64, 275216463457i64, 7058879030946168832i64,
         true, 0, 0i64)

    @Test
    pub def testPerftStartPosition(): Unit \ Assert = {
        Assert.assertEq(expected = 20i64, perftFrom(startPosition(), 1));
        Assert.assertEq(expected = 400i64, perftFrom(startPosition(), 2));
        Assert.assertEq(expected = 8902i64, perftFrom(startPosition(), 3));
        Assert.assertEq(expected = 197281i64, perftFrom(startPosition(), 4))
    }

    @Test
    pub def testPerftKiwipete(): Unit \ Assert = {
        Assert.assertEq(expected = 48i64, perftFrom(kiwipete(), 1));
        Assert.assertEq(expected = 2039i64, perftFrom(kiwipete(), 2));
        Assert.assertEq(expected = 97862i64, perftFrom(kiwipete(), 3))
    }

    @Test
    pub def testPerftEnPassantPin(): Unit \ Assert = {
        Assert.assertEq(expected = 14i64, perftFrom(enPassantPin(), 1));
        Assert.assertEq(expected = 191i64, perftFrom(enPassantPin(), 2));
        Assert.assertEq(expected = 2812i64, perftFrom(enPassantPin(), 3));
        Assert.assertEq(expected = 43238i64, perftFrom(enPassantPin(), 4))
    }

    @Test
    pub def testPerftPromotions(): Unit \ Assert = {
        Assert.assertEq(expected = 6i64, perftFrom(promotions(), 1));
        Assert.assertEq(expected = 264i64, perftFrom(promotions(), 2));
        Assert.assertEq(expected = 9467i64, perftFrom(promotions(), 3))
    }

    @Test
    pub def testPerftPosition5(): Unit \ Assert = {
        Assert.assertEq(expected = 44i64, perftFrom(position5(), 1));
        Assert.assertEq(expected = 1486i64, perftFrom(position5(), 2));
        Assert.assertEq(expected = 62379i64, perftFrom(position5(), 3))
    }

    @Test
    pub def testPerftPosition6(): Unit \ Assert = {
        Assert.assertEq(expected = 46i64, perftFrom(position6(), 1));
        Assert.assertEq(expected = 2079i64, perftFrom(position6(), 2));
        Assert.assertEq(expected = 89890i64, perftFrom(position6(), 3))
    }

    ///
    /// The incremental Zobrist hash equals a from-scratch recomputation at every node
    /// of a 3-ply tree, i.e. `discardAt`/`put`/`play` maintain it correctly.
    ///
    @Test
    pub def testIncrementalHash(): Unit \ Assert = {
        let tables = Tables.mk();
        let psqt = Psqt.mk();
        let zob = ZobristHash.polyglot();
        let positions = List#{startPosition(), kiwipete(), enPassantPin(), promotions()};
        let bad = List.foldLeft((acc, p) -> {
            let (pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr) = p;
            acc + region rc {
                hashWalk(Board.mk(rc, tables, psqt, zob, pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr), 3)
            }
        }, 0, positions);
        Assert.assertEq(expected = 0, bad)
    }

    def hashWalk(b: Board[r], depth: Int32): Int32 \ r = {
        let recomputed =
            Bits.bxor(
                ZobristHash.hashPieces(Board.zobrist(b), Board.occupied(b),
                                       sq -> Board.whiteAt(b, sq),
                                       sq -> Option.getWithDefault(Role.Pawn, Board.roleAt(b, sq))),
                ZobristHash.hashTurn(Board.zobrist(b), Board.turn(b)));
        let here = if (recomputed == Board.incrementalHash(b)) 0 else 1;
        if (depth <= 0) here
        else region rc {
            let moves = MoveList.mkDefault(rc);
            Board.legalMoves(b, moves);
            here + hashChildren(b, moves, depth, 0, 0)
        }
    }

    def hashChildren(b: Board[r], moves: MoveList[r2], depth: Int32, i: Int32, acc: Int32): Int32 \ r + r2 =
        if (i >= MoveList.getSize(moves)) acc
        else region rc {
            let child = Board.copy(rc, b);
            Board.play(child, MoveList.get(moves, i));
            hashChildren(b, moves, depth, i + 1, acc + hashWalk(child, depth - 1))
        }
}
