///
/// `Board` regression tests, driven by perft.
///
/// Perft is the only test that meaningfully validates a move generator: it counts
/// the leaves of the legal-move tree, so a single wrong bit anywhere in attack
/// generation, pin detection, check evasion, castling, en passant or promotion
/// shows up as a wrong number.
///
/// Two independent sources of truth are used, and no expected value in this file
/// was read off the Flix implementation:
///
///   * the six "tricky" positions and their counts come from
///     `src/test/scala/PerftTest.scala` (`trickyBatch`) and, for the depths the
///     Scala suite does not assert, from the published perft results at
///     <https://www.chessprogramming.org/Perft_Results>;
///   * the `gentest-N` positions are transcribed verbatim (bitboards *and* node
///     counts) from the `batch0..batch17` data in the same Scala file, which was
///     generated from <https://marcelk.net/rookie/nostalgia/v3/perft-random.epd>.
///
/// The 88-position subset was chosen from the 6838 Scala cases by feature, not at
/// random: every position that has a legal en passant at the root, the one double
/// check, every checkmate/stalemate, every position with two or more pinned pieces,
/// a spread of promotion / castling / in-check positions, one position per distinct
/// `castlingRights` value (all sixteen), the largest node count in the file, and a
/// deterministic every-683rd sample.
///
/// Runtime: about 100M nodes, ~15 s wall on this machine. Anything materially more
/// expensive than that is present but `@Skip`ped, with the expected number recorded.
///
mod TestBoard {

    ///
    /// The eleven arguments of the Scala `Board` constructor:
    /// pawns, knights, bishops, rooks, queens, kings, white, black, turn, epSquare,
    /// castlingRights.
    ///
    type alias Pos = (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64)

    /// A named perft case: position, depth, expected leaf count.
    type alias Case = (String, Pos, Int32, Int64)

    // ------------------------------------------------------------------ harness

    /// `PerftTest.perft`: the number of leaves of the legal-move tree.
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

    def boardOf(rc: Region[r], t: Tables, ps: Psqt, z: Vector[Int32], p: Pos): Board[r] \ r = {
        let (pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr) = p;
        Board.mk(rc, t, ps, z, pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr)
    }

    ///
    /// Runs every case and reports *all* mismatches, each naming the position, the
    /// depth, the expected count and the count this implementation produced. A
    /// failing perft is a real bug in the port, so the diagnostic has to be useful.
    ///
    def checkPerfts(cases: List[Case]): Unit \ Assert = {
        let t = Tables.mk();
        let ps = Psqt.mk();
        let z = ZobristHash.polyglot();
        let failures = List.filterMap(c -> {
            let (name, pos, depth, expected) = c;
            let actual = region rc { perft(boardOf(rc, t, ps, z, pos), depth) };
            if (actual == expected) None
            else Some("${name} depth ${depth}: expected ${expected} nodes, got ${actual}")
        }, cases);
        Assert.assertEq(expected = (Nil: List[String]), failures)
    }

    /// Every legal move of `p`, as UCI strings, sorted.
    def legalUci(p: Pos): List[String] = region rc {
        let b = boardOf(rc, Tables.mk(), Psqt.mk(), ZobristHash.polyglot(), p);
        let moves = MoveList.mkDefault(rc);
        Board.legalMoves(b, moves);
        List.sort(List.map(Move.uci, MoveList.toList(moves)))
    }

    def findUci(b: Board[r], u: String): Move \ r = region rc {
        let moves = MoveList.mkDefault(rc);
        Board.legalMoves(b, moves);
        match MoveList.find(moves, m -> Move.uci(m) == u) {
            case Some(m) => m
            case None    => bug!("TestBoard.findUci: no legal move ${u}")
        }
    }

    /// The full observable state of a board, in `Pos` order.
    def stateOf(b: Board[r]): Pos \ r =
        (Board.pawns(b), Board.knights(b), Board.bishops(b), Board.rooks(b),
         Board.queens(b), Board.kings(b), Board.whitePieces(b), Board.blackPieces(b),
         Board.turn(b), Board.epSquare(b), Board.castlingRights(b))

    /// Plays `ucis` in order from `p`, returning the state after each move.
    def playSeq(p: Pos, ucis: List[String]): List[Pos] = region rc {
        let b = boardOf(rc, Tables.mk(), Psqt.mk(), ZobristHash.polyglot(), p);
        playLoop(b, ucis, Nil)
    }

    def playLoop(b: Board[r], ucis: List[String], acc: List[Pos]): List[Pos] \ r = match ucis {
        case Nil       => List.reverse(acc)
        case u :: rest =>
            let m = findUci(b, u);
            Board.play(b, m);
            playLoop(b, rest, stateOf(b) :: acc)
    }
    // ------------------------------------------------------ reference positions
    /// The standard starting position.
    ///
    /// `rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -`
    def start(): Pos =
        (0x00ff00000000ff00i64, 0x4200000000000042i64, 0x2400000000000024i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
         0x000000000000ffffi64, -281474976710656i64 /* 0xffff000000000000 */,
         true, 0, -9151314442816847743i64 /* 0x8100000000000081 */)
    /// Kiwipete (Peter McKenzie), `PerftTest.trickyBatch` position 2: both sides can
    /// castle either way, and the position is dense with pins and discovered checks.
    ///
    /// `r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -`
    def kiwipete(): Pos =
        (0x002d50081280e700i64, 0x0000221000040000i64, 0x0040010000001800i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0010000000200000i64, 0x1000000000000010i64,
         0x000000181024ff91i64, -7963082122242031616i64 /* 0x917d730002800000 */,
         true, 0, -9151314442816847743i64 /* 0x8100000000000081 */)
    /// `PerftTest.trickyBatch` position 3: the en-passant / discovered-check position
    /// where a5-b5 and the h5 rook conspire against the white king.
    ///
    /// `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -`
    def epPin(): Pos =
        (0x0004080220005000i64, 0i64, 0i64,
         0x0000008002000000i64, 0i64, 0x0000000180000000i64,
         0x0000000302005000i64, 0x00040880a0000000i64,
         true, 0, 0i64)
    /// `PerftTest.trickyBatch` position 4 (the mirror of the wiki's "Position 4"):
    /// under-promotions on both wings, plus a rook capture that removes a castling right.
    ///
    /// `r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ -`
    def promotions(): Pos =
        (0x00cb00140200ef00i64, 0x0000200001a00000i64, 0x0000000300420000i64,
         0x2100000000000081i64, 0x0800010000000000i64, 0x4000000000000010i64,
         0x000201000162ee91i64, 0x69c9201702800100i64,
         false, 0, 0x0000000000000081i64)
    /// `PerftTest.trickyBatch` position 5.
    ///
    /// `rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ -`
    def position5(): Pos =
        (0x00eb04000000c700i64, 0x0200000000003002i64, 0x0410000004000004i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x2000000000000010i64,
         0x000800000400d79fi64, -5768262299684954112i64 /* 0xaff3040000002000 */,
         true, 0, 0x0000000000000081i64)
    /// `PerftTest.trickyBatch` position 6 (Steven Edwards).
    ///
    /// `r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - -`
    def position6(): Pos =
        (0x00e609101009e600i64, 0x0000240000240000i64, 0x0000004444000000i64,
         0x2100000000000021i64, 0x0010000000001000i64, 0x4000000000000040i64,
         0x00000040142df661i64, 0x61f62d1440000000i64,
         true, 0, 0i64)
    ///
    /// Reference positions from `PerftTest.scala`, part A of 4 (22 positions,
    /// 13223169 nodes at depth 4). The comment on each entry is the FEN and the reason it
    /// was selected.
    ///
    def gentestA(): List[Case] = List#{
        // gentest-1  cr8100000000000081,spread
        // rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
        ("gentest-1",
         (0x00ff00000000ff00i64, 0x4200000000000042i64, 0x2400000000000024i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000000000ffffi64, -281474976710656i64 /* 0xffff000000000000 */,
          true, 0, -9151314442816847743i64 /* 0x8100000000000081 */),
         4, 197281i64),

        // gentest-7  cr0000000000000081
        // rnkq1bnr/p3ppp1/1ppp3p/3B4/6b1/2PQ3P/PP1PPP2/RNB1K1NR w KQ - 0 1
        ("gentest-7",
         (0x00718e0000843b00i64, 0x4200000000000042i64, 0x2000000840000004i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000080000i64, 0x0400000000000010i64,
          0x00000008008c3bd7i64, -1193016294551584768i64 /* 0xef718e0040000000 */,
          true, 0, 0x0000000000000081i64),
         4, 891412i64),

        // gentest-11  castle
        // rn1q1bnr/3kppp1/2pp3p/pp6/1P2b3/2PQ1N1P/P2PPPB1/RNB1K2R w KQ - 0 1
        ("gentest-11",
         (0x00708c0302843900i64, 0x4200000000200002i64, 0x2000000010004004i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000080000i64, 0x0008000000000010i64,
          0x0000000002ac7997i64, -1479278532809981952i64 /* 0xeb788c0310000000 */,
          true, 0, 0x0000000000000081i64),
         4, 784949i64),

        // gentest-13  cr0000000000000001
        // rnkq1bnr/4pp2/2pQ2pp/pp6/1P5N/2P4P/P2PPP2/RNB1KB1b w Q - 0 1
        ("gentest-13",
         (0x0030c40302843900i64, 0x4200000080000002i64, 0x20000000000000a4i64,
          -9151314442816847871i64 /* 0x8100000000000001 */, 0x0800080000000000i64, 0x0400000000000010i64,
          0x0000080082843937i64, -1211252782598717312i64 /* 0xef30c40300000080 */,
          true, 0, 0x0000000000000001i64),
         4, 807330i64),

        // gentest-24  check
        // r4br1/8/2Q2npp/Pkn1p3/8/2PPP1qP/4bP2/RNB1KB2 b Q - 0 1
        ("gentest-24",
         (0x0000c011009c2000i64, 0x0000200400000002i64, 0x2000000000001024i64,
          0x4100000000000001i64, 0x0000040000400000i64, 0x0000000200000010i64,
          0x00000401009c2037i64, 0x6100e01600401000i64,
          false, 0, 0x0000000000000001i64),
         4, 16244i64),

        // gentest-27  cr0000000000000000
        // r4b2/6r1/3k2pp/P2np3/4n1P1/R1PPP2P/4b1B1/1NB1K3 w - - 0 1
        ("gentest-27",
         (0x0000c011409c0000i64, 0x0000000810000002i64, 0x2000000000005004i64,
          0x0140000000010000i64, 0i64, 0x0000080000000010i64,
          0x00000001409d4016i64, 0x2140c81810001000i64,
          true, 0, 0i64),
         4, 631901i64),

        // gentest-72  promo
        // 8/8/6b1/k3p2N/8/b1PB4/K6p/8 b - - 0 1
        ("gentest-72",
         (0x0000001000048000i64, 0x0000008000000000i64, 0x0000400000090000i64,
          0i64, 0i64, 0x0000000100000100i64,
          0x00000080000c0100i64, 0x0000401100018000i64,
          false, 0, 0i64),
         4, 128257i64),

        // gentest-89  cr8000000000000081
        // 2bqkbnr/rppppppp/n7/p7/2P5/PP6/3PPPPP/RNBQKBNR w KQk - 0 1
        ("gentest-89",
         (0x00fe00010403f800i64, 0x4000010000000042i64, 0x2400000000000024i64,
          -9223090561878065023i64 /* 0x8001000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000000403f8ffi64, -216453153283899392i64 /* 0xfcff010100000000 */,
          true, 0, -9223372036854775679i64 /* 0x8000000000000081 */),
         4, 204573i64),

        // gentest-101  cr0000000000000080
        // 2bq1b2/2pkp3/nr1p1n1p/3P1pp1/ppP3P1/PPBQP2P/3N1P2/1R2KBNR w K - 0 1
        ("gentest-101",
         (0x0014886847932000i64, 0x0000210000000840i64, 0x2400000000040020i64,
          0x0000020000000082i64, 0x0800000000080000i64, 0x0008000000000010i64,
          0x00000008449f28f2i64, 0x2c1cab6003000000i64,
          true, 0, 0x0000000000000080i64),
         4, 725952i64),

        // gentest-176  cr8100000000000080
        // rnbqkb1r/ppp1p1pp/5n2/3p4/P1P2p2/R2P4/1P2PPPP/1NBQKBNR b Kkq - 0 1
        ("gentest-176",
         (0x00d700082508f200i64, 0x0200200000000042i64, 0x2400000000000024i64,
          -9151314442816782208i64 /* 0x8100000000010080 */, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000000509f2fei64, -4623191273203826688i64 /* 0xbfd7200820000000 */,
          false, 0, -9151314442816847744i64 /* 0x8100000000000080 */),
         4, 880242i64),

        // gentest-225  terminal
        // 5k2/4R1q1/8/8/P3p2r/1p1P4/7K/1r6 w - - 0 1
        ("gentest-225",
         (0x00000000110a0000i64, 0i64, 0i64,
          0x0010000080000002i64, 0x0040000000000000i64, 0x2000000000008000i64,
          0x0010000001088000i64, 0x2040000090020002i64,
          true, 0, 0i64),
         4, 0i64),

        // gentest-228  cr8100000000000001
        // rnbqkbnr/1pppp1p1/p6p/5p2/7P/7N/PPPPPPP1/RNBQKBR1 w Qkq - 0 1
        ("gentest-228",
         (0x005e812080007f00i64, 0x4200000000800002i64, 0x2400000000000024i64,
          -9151314442816847807i64 /* 0x8100000000000041 */, 0x0800000000000008i64, 0x1000000000000010i64,
          0x0000000080807f7fi64, -45456971788189696i64 /* 0xff5e812000000000 */,
          true, 0, -9151314442816847871i64 /* 0x8100000000000001 */),
         4, 165912i64),

        // gentest-233  cr8100000000000000
        // r1b1kb1r/1pq1n1p1/2npp2p/p1p2p2/4P2P/2PP1P1N/PP1NB1P1/R1BQ1K1R b kq - 0 1
        ("gentest-233",
         (0x00429825902c4300i64, 0x0010040000800800i64, 0x2400000000001004i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0004000000000008i64, 0x1000000000000020i64,
          0x0000000090ac5badi64, -5379941022119755776i64 /* 0xb5569c2500000000 */,
          false, 0, -9151314442816847872i64 /* 0x8100000000000000 */),
         4, 930788i64),

        // gentest-319  cr0100000000000000
        // r3kbr1/p1p2ppp/2n4n/1p3bq1/P2pp1PP/1PN2P1R/2PPPK2/R1BQ1BN1 b q - 0 1
        ("gentest-319",
         (0x00e50002d9221c00i64, 0x0000840000040040i64, 0x2000002000000024i64,
          0x4100000000800001i64, 0x0000004000000008i64, 0x1000000000002000i64,
          0x00000000c1a63c6di64, 0x71e5846218000000i64,
          false, 0, 0x0100000000000000i64),
         4, 1305153i64),

        // gentest-335  ep
        // r2n3r/1bNk2pp/6P1/pP3p2/3pPqnP/1P1P1p1R/2P3B1/Q1B1bKN1 b - e3 0 1
        ("gentest-335",
         (0x00c04023982a0400i64, 0x0804000040000040i64, 0x0002000000004014i64,
          -9151314442808459264i64 /* 0x8100000000800000 */, 0x0000000020000001i64, 0x0008000000000020i64,
          0x00044002908a4465i64, -8517995601737023472i64 /* 0x89ca002168200010 */,
          false, 20, 0i64),
         4, 2468318i64),

        // gentest-336  doublecheck
        // r2n3r/1bNk2pp/6P1/pP3p2/3pPq1P/1P1PB2R/2P3p1/Q3bKN1 w - - 0 1
        ("gentest-336",
         (0x00c04023980a4400i64, 0x0804000000000040i64, 0x0002000000100010i64,
          -9151314442808459264i64 /* 0x8100000000800000 */, 0x0000000020000001i64, 0x0008000000000020i64,
          0x00044002909a0461i64, -8517995602812846064i64 /* 0x89ca002128004010 */,
          true, 0, 0i64),
         4, 165481i64),

        // gentest-411  terminal
        // r1b1k2Q/bp1p1p2/n1pB1P1p/8/Pp6/1q2P3/2PP3P/RN2KBNR b KQ - 0 1
        ("gentest-411",
         (0x002aa40003108c00i64, 0x0000010000000042i64, 0x0401080000000020i64,
          0x0100000000000081i64, -9223372036854644736i64 /* 0x8000000000020000 */, 0x1000000000000010i64,
          -9223328056371802893i64 /* 0x8000280001108cf3 */, 0x152b850002020000i64,
          false, 0, 0x0000000000000081i64),
         4, 0i64),

        // gentest-563  promo
        // 8/3k4/4R3/2PP4/1K2p3/5Pp1/4r1p1/8 b - - 0 1
        ("gentest-563",
         (0x0000000c10604000i64, 0i64, 0i64,
          0x0000100000001000i64, 0i64, 0x0008000002000000i64,
          0x0000100c02200000i64, 0x0008000010405000i64,
          false, 0, 0i64),
         4, 100882i64),

        // gentest-681  check
        // 5b2/4k3/rp2bqN1/p4p1r/PpPpP3/1Q6/3P1PBP/RN2K2R b KQ - 0 1
        ("gentest-681",
         (0x000002211f00a800i64, 0x0000400000000002i64, 0x2000100000004000i64,
          0x0000018000000081i64, 0x0000200000020000i64, 0x0010000000000010i64,
          0x000040001502e893i64, 0x201033a10a000000i64,
          false, 0, 0x0000000000000081i64),
         4, 286832i64),

        // gentest-682  castle
        // 5b2/8/rp2bqN1/p1k2p1r/PpPpP3/1Q5P/3P1PB1/RN2K2R w KQ - 0 1
        ("gentest-682",
         (0x000002211f802800i64, 0x0000400000000002i64, 0x2000100000004000i64,
          0x0000018000000081i64, 0x0000200000020000i64, 0x0000000400000010i64,
          0x0000400015826893i64, 0x200033a50a000000i64,
          true, 0, 0x0000000000000081i64),
         4, 1365571i64),

        // gentest-684  spread
        // 2b2b1N/7r/rp6/p1k2pq1/PpPpP3/1Q3P1P/3P4/RN2KB1R w KQ - 0 1
        ("gentest-684",
         (0x000002211fa00800i64, -9223372036854775806i64 /* 0x8000000000000002 */, 0x2400000000000020i64,
          0x0080010000000081i64, 0x0000004000020000i64, 0x0000000400000010i64,
          -9223372036491835213i64 /* 0x8000000015a208b3 */, 0x248003650a000000i64,
          true, 0, 0x0000000000000081i64),
         4, 1133362i64),

        // gentest-742  promo
        // 4b3/2b4P/8/4k3/8/8/5r2/4n1K1 w - - 0 1
        ("gentest-742",
         (0x0080000000000000i64, 0x0000000000000010i64, 0x1004000000000000i64,
          0x0000000000002000i64, 0i64, 0x0000001000000040i64,
          0x0080000000000040i64, 0x1004001000002010i64,
          true, 0, 0i64),
         4, 32729i64)
    }
    ///
    /// Reference positions from `PerftTest.scala`, part B of 4 (22 positions,
    /// 20842731 nodes at depth 4). The comment on each entry is the FEN and the reason it
    /// was selected.
    ///
    def gentestB(): List[Case] = List#{
        // gentest-756  cr0100000000000081
        // rnbqkbr1/pppp1ppp/8/4p3/P2PPB2/3Q4/1PP2PPP/RN2KnNR w KQq - 0 1
        ("gentest-756",
         (0x00ef00101900e600i64, 0x0200000000000062i64, 0x2400000020000000i64,
          0x4100000000000081i64, 0x0800000000080000i64, 0x1000000000000010i64,
          0x000000003908e6d3i64, 0x7fef001000000020i64,
          true, 0, 0x0100000000000081i64),
         4, 1904130i64),

        // gentest-869  terminal
        // 3Qk1B1/r7/2p1p1p1/ppP1P1Bp/PP6/3RKP1P/6P1/1N4R1 b - - 0 1
        ("gentest-869",
         (0x0000549703a04000i64, 0x0000000000000002i64, 0x4000004000000000i64,
          0x0001000000080040i64, 0x0800000000000000i64, 0x1000000000100000i64,
          0x4800005403b84042i64, 0x1001548300000000i64,
          false, 0, 0i64),
         4, 0i64),

        // gentest-991  cr0100000000000001
        // rnb1kb2/p1qppppr/1pp2n1p/7P/8/P1NP4/1PP1PPPR/R1BQKBN1 w Qq - 0 1
        ("gentest-991",
         (0x0079868000097600i64, 0x0200200000040040i64, 0x2400000000000024i64,
          0x0180000000008001i64, 0x0004000000000008i64, 0x1000000000000010i64,
          0x00000080000df67di64, 0x37fda60000000000i64,
          true, 0, 0x0100000000000001i64),
         4, 702291i64),

        // gentest-1007  castle
        // r1b1k3/p2p1Nr1/3b3p/1n1pp1pP/2BB1P2/P6R/Q1P3P1/R3K1N1 w Qq - 0 1
        ("gentest-1007",
         (0x000980d820014400i64, 0x0020000200000040i64, 0x040008000c000000i64,
          0x0140000000800001i64, 0x0000000000000100i64, 0x1000000000000010i64,
          0x002000802c814551i64, 0x1549885a00000000i64,
          true, 0, 0x0100000000000001i64),
         4, 1837308i64),

        // gentest-1061  cr8000000000000000
        // 1rbqkb1r/1p1p2pp/p1p2n2/1B2pp2/3P3P/1PP1P1Q1/P2K1PP1/RNB3NR w k - 0 1
        ("gentest-1061",
         (0x00ca053088166100i64, 0x0000200000000042i64, 0x2400000200000004i64,
          -9079256848778919807i64 /* 0x8200000000000081 */, 0x0800000000400000i64, 0x1000000000000800i64,
          0x00000002885669c7i64, -4698902373119033344i64 /* 0xbeca253000000000 */,
          true, 0, -9223372036854775808i64 /* 0x8000000000000000 */),
         4, 1338114i64),

        // gentest-1160  pins
        // 2bkrb2/r6p/p1n2pp1/2PppP1P/Q1p1P2B/N2R4/P2P4/3R1KN1 b - - 0 1
        ("gentest-1160",
         (0x008061bc14000900i64, 0x0000040000010040i64, 0x2400000080000000i64,
          0x1001000000080008i64, 0x0000000001000000i64, 0x0800000000000020i64,
          0x000000a491090968i64, 0x3c81651804000000i64,
          false, 0, 0i64),
         4, 1646818i64),

        // gentest-1370  spread
        // 8/1k2N3/P3Q3/1p3r2/4r3/1p5K/1b6/8 b - - 0 1
        ("gentest-1370",
         (0x0000010200020000i64, 0x0010000000000000i64, 0x0000000000000200i64,
          0x0000002010000000i64, 0x0000100000000000i64, 0x0002000000800000i64,
          0x0010110000800000i64, 0x0002002210020200i64,
          false, 0, 0i64),
         4, 68646i64),

        // gentest-1501  check
        // 1r1k1bnN/q7/1B1p4/3Pp1p1/2b2pBp/5PP1/2R2nR1/4K3 b - - 0 1
        ("gentest-1501",
         (0x00000858a0600000i64, -4611686018427379712i64 /* 0xc000000000002000 */, 0x2000020044000000i64,
          0x0200000000004400i64, 0x0001000000000000i64, 0x0800000000000010i64,
          -9223369802391731184i64 /* 0x8000020840604410 */, 0x6a010850a4002000i64,
          false, 0, 0i64),
         4, 147271i64),

        // gentest-1579  promo
        // 2b1kb2/3np3/P1p2rp1/B2PP2p/1rP5/1N1R2P1/p4P1P/2K4R b - - 0 1
        ("gentest-1579",
         (0x001045980440a100i64, 0x0008000000020000i64, 0x2400000100000000i64,
          0x0000200002080080i64, 0i64, 0x1000000000000004i64,
          0x00000119044aa084i64, 0x3418648002000100i64,
          false, 0, 0i64),
         4, 919098i64),

        // gentest-2011  largest
        // rnNk4/6rb/1p2q3/6pp/Qb1PPP2/P3BN1P/1P4K1/1b1B3R b - - 0 1
        ("gentest-2011",
         (0x000002c038810200i64, 0x0600000000200000i64, 0x008000000210000ai64,
          0x0140000000000080i64, 0x0000100001000000i64, 0x0800000000004000i64,
          0x0400000039b14288i64, 0x0bc012c002000002i64,
          false, 0, 0i64),
         4, 5113041i64),

        // gentest-2053  spread
        // 4B2k/8/n2BP1R1/1p3P1K/8/8/8/8 b - - 0 1
        ("gentest-2053",
         (0x0000102200000000i64, 0x0000010000000000i64, 0x1000080000000000i64,
          0x0000400000000000i64, 0i64, -9223371487098961920i64 /* 0x8000008000000000 */,
          0x100058a000000000i64, -9223370928753213440i64 /* 0x8000010200000000 */,
          false, 0, 0i64),
         4, 30524i64),

        // gentest-2104  ep
        // rnbqk1nr/p2p3p/1p5b/2pPppp1/8/P7/1PPQPPPP/RNB1KBNR w KQkq c6 0 1
        ("gentest-2104",
         (0x0089027c0001f600i64, 0x4200000000000042i64, 0x0400800000000024i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000800i64, 0x1000000000000010i64,
          0x000000080001fef7i64, -2339195096714444800i64 /* 0xdf89827400000000 */,
          true, 42, -9151314442816847743i64 /* 0x8100000000000081 */),
         4, 476024i64),

        // gentest-2109  cr8000000000000080
        // 3qk1nr/p2b3p/n2p1P1b/p1pPp3/P5p1/RrP5/1P2PP1P/1NB1KBNR b Kk - 0 1
        ("gentest-2109",
         (0x0081281d4104b200i64, 0x4000010000000042i64, 0x0008800000000024i64,
          -9223372036854579072i64 /* 0x8000000000030080 */, 0x0800000000000000i64, 0x1000000000000010i64,
          0x000020080105b2f6i64, -2843590965346566144i64 /* 0xd889891540020000 */,
          false, 0, -9223372036854775680i64 /* 0x8000000000000080 */),
         4, 690708i64),

        // gentest-2114  castle
        // 1nb1k1nr/6bp/p2p1q2/p1pP4/P1P1N1p1/R4P2/2r1PNBP/2B1K2R w Kk - 0 1
        ("gentest-2114",
         (0x0080090d45209000i64, 0x4200000010002000i64, 0x0440000000004004i64,
          -9223372036854709120i64 /* 0x8000000000010480 */, 0x0000200000000000i64, 0x1000000000000010i64,
          0x000000081521f094i64, -2972330651539209216i64 /* 0xd6c0290540000400 */,
          true, 0, -9223372036854775680i64 /* 0x8000000000000080 */),
         4, 1784793i64),

        // gentest-2213  check
        // 1n6/rb4b1/1P1p1k2/pP2Pr2/2P1P1p1/BN2K1P1/1R4BP/7R b - - 0 1
        ("gentest-2213",
         (0x00000a1354408000i64, 0x0200000000020000i64, 0x0042000000014000i64,
          0x0001002000000280i64, 0i64, 0x0000200000100000i64,
          0x000002121453c280i64, 0x0243282140000000i64,
          false, 0, 0i64),
         4, 287802i64),

        // gentest-2331  promo
        // 8/4kb2/4p3/4PB1p/4P2P/2K5/1p6/6N1 b - - 0 1
        ("gentest-2331",
         (0x0000109090000200i64, 0x0000000000000040i64, 0x0020002000000000i64,
          0i64, 0i64, 0x0010000000040000i64,
          0x0000003090040040i64, 0x0030108000000200i64,
          false, 0, 0i64),
         4, 30911i64),

        // gentest-2453  castle
        // r3kb1r/4pppp/2p5/p1p4n/q1Pn1P2/R3P2N/3P3P/1NB1KB1R b kq - 0 1
        ("gentest-2453",
         (0x00f0040524108800i64, 0x0000008008800002i64, 0x2000000000000024i64,
          -9151314442816782208i64 /* 0x8100000000010080 */, 0x0000000001000000i64, 0x1000000000000010i64,
          0x00000000249188b6i64, -5624990965157593088i64 /* 0xb1f0048509000000 */,
          false, 0, -9151314442816847872i64 /* 0x8100000000000000 */),
         4, 446916i64),

        // gentest-2736  spread
        // r3k2B/pRb5/P1P5/2Pr4/B7/N5P1/1P2K2P/2q5 w - - 0 1
        ("gentest-2736",
         (0x0001050400408200i64, 0x0000000000010000i64, -9222246136931155968i64 /* 0x8004000001000000 */,
          0x0102000800000000i64, 0x0000000000000004i64, 0x1000000000001000i64,
          -9222803572142272000i64 /* 0x8002050401419200 */, 0x1105000800000004i64,
          true, 0, 0i64),
         4, 968017i64),

        // gentest-2855  ep
        // rnb1k2r/pp1p1p1p/1q1P4/2pnpPp1/6P1/2N5/PP1BP2P/R2QKBNR w KQkq e6 0 1
        ("gentest-2855",
         (0x00ab087440009300i64, 0x0200000800040040i64, 0x0400000000000820i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0000020000000008i64, 0x1000000000000010i64,
          0x0000082040049bf9i64, -7517912558804664320i64 /* 0x97ab025c00000000 */,
          true, 44, -9151314442816847743i64 /* 0x8100000000000081 */),
         4, 912423i64),

        // gentest-2857  castle
        // r1b1k2r/ppqp1p1p/2nP4/2pN1Pp1/4p1P1/1Q5P/PP1BP3/R3KBNR w KQkq - 0 1
        ("gentest-2857",
         (0x00ab086450801300i64, 0x0000040800000040i64, 0x0400000000000820i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0004000000020000i64, 0x1000000000000010i64,
          0x0000082840821bf1i64, -7660899750761201664i64 /* 0x95af044410000000 */,
          true, 0, -9151314442816847743i64 /* 0x8100000000000081 */),
         4, 1163424i64),

        // gentest-2873  check
        // r3k3/3N1N2/3P4/pp6/4B1rp/P3q2P/1P1BPK2/R5R1 w - - 0 1
        ("gentest-2873",
         (0x0000080380811200i64, 0x0028000000000000i64, 0x0000000010000800i64,
          0x0100000040000041i64, 0x0000000000100000i64, 0x1000000000002000i64,
          0x0028080010813a41i64, 0x11000003c0100000i64,
          true, 0, 0i64),
         4, 124599i64),

        // gentest-3419  spread
        // 7R/8/PP4P1/8/3p1k2/1r1P1b2/8/3N2K1 w - - 0 1
        ("gentest-3419",
         (0x0000430008080000i64, 0x0000000000000008i64, 0x0000000000200000i64,
          -9223372036854644736i64 /* 0x8000000000020000 */, 0i64, 0x0000000020000040i64,
          -9223298369575190456i64 /* 0x8000430000080048 */, 0x0000000028220000i64,
          true, 0, 0i64),
         4, 249873i64)
    }
    ///
    /// Reference positions from `PerftTest.scala`, part C of 4 (22 positions,
    /// 11181858 nodes at depth 4). The comment on each entry is the FEN and the reason it
    /// was selected.
    ///
    def gentestC(): List[Case] = List#{
        // gentest-3442  terminal
        // 1nk2Q2/4R3/8/7K/4P3/8/8/8 b - - 0 1
        ("gentest-3442",
         (0x0000000010000000i64, 0x0200000000000000i64, 0i64,
          0x0010000000000000i64, 0x2000000000000000i64, 0x0400008000000000i64,
          0x2010008010000000i64, 0x0600000000000000i64,
          false, 0, 0i64),
         4, 0i64),

        // gentest-3476  ep
        // 1n4kr/2B4p/2nb2b1/ppp5/P1PpP3/3P4/5K2/1N1R4 b - c3 0 1
        ("gentest-3476",
         (0x008000071d080000i64, 0x0200040000000002i64, 0x0004480000000000i64,
          -9223372036854775800i64 /* 0x8000000000000008 */, 0i64, 0x4000000000002000i64,
          0x000400001508200ai64, -4431458440249868288i64 /* 0xc2804c0708000000 */,
          false, 18, 0i64),
         4, 375145i64),

        // gentest-3498  promo
        // b3k3/n7/5n2/P1p5/2PpPN2/3Pb3/1p4K1/8 b - - 0 1
        ("gentest-3498",
         (0x000000051c080200i64, 0x0001200020000000i64, 0x0100000000100000i64,
          0i64, 0i64, 0x1000000000004000i64,
          0x0000000134084000i64, 0x1101200408100200i64,
          false, 0, 0i64),
         4, 122479i64),

        // gentest-3535  cr8000000000000001
        // 3qkb1r/1ppbppp1/r1n2n2/p6p/1P1p2P1/B2PP2P/P1P2PBR/RN1QK1N1 w Qk - 0 1
        ("gentest-3535",
         (0x007600814a982500i64, 0x0000240000000042i64, 0x2008000000014000i64,
          -9223370937343115263i64 /* 0x8000010000008001 */, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000004299e55bi64, -5152639687550042112i64 /* 0xb87e258108000000 */,
          true, 0, -9223372036854775807i64 /* 0x8000000000000001 */),
         4, 1085160i64),

        // gentest-3705  ep
        // r1bqkb1r/p1p1pnpp/1pn5/3pPp2/6P1/2N2P2/PPPPQ2P/R1B1KBNR w KQkq d6 0 1
        ("gentest-3705",
         (0x00d5023840208f00i64, 0x0020040000040040i64, 0x2400000000000024i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000001000i64, 0x1000000000000010i64,
          0x0000001040249ff5i64, -4758890662378602496i64 /* 0xbdf5062800000000 */,
          true, 43, -9151314442816847743i64 /* 0x8100000000000081 */),
         4, 987048i64),

        // gentest-3731  check
        // 2b1k3/4p2p/1r1nP1r1/p5p1/Pp4P1/1Q1n1P2/N6P/4KR1R w - - 0 1
        ("gentest-3731",
         (0x0090104143208000i64, 0x0000080000080100i64, 0x0400000000000000i64,
          0x00004200000000a0i64, 0x0000000000020000i64, 0x1000000000000010i64,
          0x00001000412281b0i64, 0x14904a4102080000i64,
          true, 0, 0i64),
         4, 91337i64),

        // gentest-3972  castle
        // r3kb1r/pbnpp2p/2p2p1p/Rp6/3PPP2/4B3/2P1B1PP/1K4NR b q - 0 1
        ("gentest-3972",
         (0x0099a4023800c400i64, 0x0004000000000040i64, 0x2002000000101000i64,
          -9151314438521880448i64 /* 0x8100000100000080 */, 0i64, 0x1000000000000002i64,
          0x000000013810d4c2i64, -5647615079202422784i64 /* 0xb19fa40200000000 */,
          false, 0, 0x0100000000000000i64),
         4, 551317i64),

        // gentest-4026  promo
        // 2rk4/7p/7P/3p4/R7/2b5/1p4K1/8 b - - 0 1
        ("gentest-4026",
         (0x0080800800000200i64, 0i64, 0x0000000000040000i64,
          0x0400000001000000i64, 0i64, 0x0800000000004000i64,
          0x0000800001004000i64, 0x0c80000800040200i64,
          false, 0, 0i64),
         4, 230041i64),

        // gentest-4035  terminal
        // 8/7p/2k4P/8/8/5q2/1r6/4b1K1 w - - 0 1
        ("gentest-4035",
         (0x0080800000000000i64, 0i64, 0x0000000000000010i64,
          0x0000000000000200i64, 0x0000000000200000i64, 0x0000040000000040i64,
          0x0000800000000040i64, 0x0080040000200210i64,
          true, 0, 0i64),
         4, 0i64),

        // gentest-4042  ep
        // rn2kbnr/p3q1p1/2pp1p1p/Pp1bp3/4PB2/1P1P2PP/R1P2P2/1N1QKBNR w Kkq b6 0 1
        ("gentest-4042",
         (0x0041ac1310ca2400i64, 0x4200000000000042i64, 0x2000000820000020i64,
          -9151314442816847488i64 /* 0x8100000000000180 */, 0x0010000000000008i64, 0x1000000000000010i64,
          0x0000000130ca25fai64, -913760021710372864i64 /* 0xf351ac1a00000000 */,
          true, 41, -9151314442816847744i64 /* 0x8100000000000080 */),
         4, 809788i64),

        // gentest-4102  spread
        // k7/2q1n3/4K3/rp1P3R/1p4NP/1PR5/8/8 w - - 0 1
        ("gentest-4102",
         (0x0000000a82020000i64, 0x0010000040000000i64, 0i64,
          0x0000008100040000i64, 0x0004000000000000i64, 0x0100100000000000i64,
          0x00001088c0060000i64, 0x0114000302000000i64,
          true, 0, 0i64),
         4, 488217i64),

        // gentest-4214  cr0100000000000080
        // r1bqkbr1/p2p2p1/np2pn2/7p/P1pP4/8/RPP1P1PP/1NBQKBNR w Kq - 0 1
        ("gentest-4214",
         (0x004912800d00d600i64, 0x0000210000000042i64, 0x2400000000000024i64,
          0x4100000000000180i64, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000000900d7fei64, 0x7d49338004000000i64,
          true, 0, 0x0100000000000080i64),
         4, 632364i64),

        // gentest-4396  check
        // r1b1kb1r/2Bp3p/1p2P1p1/p4pq1/P1p5/5Nn1/Q3KPPP/R4B1R w kq - 0 1
        ("gentest-4396",
         (0x008852210500e000i64, 0x0000000000600000i64, 0x2404000000000020i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0000004000000100i64, 0x1000000000001000i64,
          0x000410000120f1a1i64, -5365965971561381888i64 /* 0xb588426104400000 */,
          true, 0, -9151314442816847872i64 /* 0x8100000000000000 */),
         4, 195394i64),

        // gentest-4564  pins
        // rnb1k2r/p2p1p1p/1p6/6p1/1bPq2P1/1PNPP1Bn/P2K3P/R2Q2NR w - - 0 1
        ("gentest-4564",
         (0x00a90240441a8100i64, 0x0200000000840040i64, 0x0400000002400000i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0000000008000008i64, 0x1000000000000800i64,
          0x00000000445e89c9i64, -7518475628841009152i64 /* 0x97a902400a800000 */,
          true, 0, 0i64),
         4, 1259827i64),

        // gentest-4650  castle
        // rnbq1br1/p2p4/1pp2pkp/1P1Np1p1/3Pn3/P2N3P/2PB4/R3KBQR w KQ - 0 1
        ("gentest-4650",
         (0x0009a65208810400i64, 0x0200000810080000i64, 0x2400000000000820i64,
          0x4100000000000081i64, 0x0800000000000040i64, 0x0000400000000010i64,
          0x0000000a08890cf1i64, 0x6f09e65010000000i64,
          true, 0, 0x0000000000000081i64),
         4, 1950811i64),

        // gentest-4785  spread
        // 8/8/P7/2p5/P1P2p2/2k2N2/6K1/3R4 b - - 0 1
        ("gentest-4785",
         (0x0000010425000000i64, 0x0000000000200000i64, 0i64,
          0x0000000000000008i64, 0i64, 0x0000000000044000i64,
          0x0000010005204008i64, 0x0000000420040000i64,
          false, 0, 0i64),
         4, 20915i64),

        // gentest-4893  terminal
        // N4Q1k/8/8/8/4B3/1p3K2/7p/8 b - - 0 1
        ("gentest-4893",
         (0x0000000000028000i64, 0x0100000000000000i64, 0x0000000010000000i64,
          0i64, 0x2000000000000000i64, -9223372036852678656i64 /* 0x8000000000200000 */,
          0x2100000010200000i64, -9223372036854611968i64 /* 0x8000000000028000 */,
          false, 0, 0i64),
         4, 0i64),

        // gentest-4929  pins
        // 1k4n1/1p2B2p/3pp3/4Qp1P/2pP4/1R2b3/8/K5RB b - - 0 1
        ("gentest-4929",
         (0x008218a00c000000i64, 0x4000000000000000i64, 0x0010000000100080i64,
          0x0000000000020040i64, 0x0000001000000000i64, 0x0200000000000001i64,
          0x00100090080200c1i64, 0x4282182004100000i64,
          false, 0, 0i64),
         4, 1011494i64),

        // gentest-4931  check
        // 1k6/4B2p/3pp3/1Q3pRP/2pPn3/4b3/8/KR5B b - - 0 1
        ("gentest-4931",
         (0x008018a00c000000i64, 0x0000000010000000i64, 0x0010000000100080i64,
          0x0000004000000002i64, 0x0000000200000000i64, 0x0200000000000001i64,
          0x001000c208000083i64, 0x0280182014100000i64,
          false, 0, 0i64),
         4, 113840i64),

        // gentest-4953  terminal
        // 8/8/Q5RP/k1B5/3P4/8/8/bK6 b - - 0 1
        ("gentest-4953",
         (0x0000800008000000i64, 0i64, 0x0000000400000001i64,
          0x0000400000000000i64, 0x0000010000000000i64, 0x0000000100000002i64,
          0x0000c10408000002i64, 0x0000000100000001i64,
          false, 0, 0i64),
         4, 0i64),

        // gentest-5071  ep
        // 8/4kqr1/p3pnpB/7p/P1pPP2P/1r3P1B/R4K2/2B4R b - d3 0 1
        ("gentest-5071",
         (0x000051809d200000i64, 0x0000200000000000i64, 0x0000800000800004i64,
          0x0040000000020180i64, 0x0020000000000000i64, 0x0010000000002000i64,
          0x0000800099a02184i64, 0x0070718004020000i64,
          false, 19, 0i64),
         4, 1206620i64),

        // gentest-5090  pins
        // 5r2/k7/4p1p1/p6p/P6P/3pnP2/6R1/1Rr1BK2 w - - 0 1
        ("gentest-5090",
         (0x0000508181280000i64, 0x0000000000100000i64, 0x0000000000000010i64,
          0x2000000000004006i64, 0i64, 0x0001000000000020i64,
          0x0000000081204032i64, 0x2001508100180004i64,
          true, 0, 0i64),
         4, 50061i64)
    }
    ///
    /// Reference positions from `PerftTest.scala`, part D of 4 (21 positions,
    /// 15320397 nodes at depth 4). The comment on each entry is the FEN and the reason it
    /// was selected.
    ///
    def gentestD(): List[Case] = List#{
        // gentest-5103  promo
        // 1r6/8/1k4p1/7p/P4P1P/2B5/3pR2R/7K b - - 0 1
        ("gentest-5103",
         (0x00004080a1000800i64, 0i64, 0x0000000000040000i64,
          0x0200000000009000i64, 0i64, 0x0000020000000080i64,
          0x00000000a1049080i64, 0x0200428000000800i64,
          false, 0, 0i64),
         4, 238282i64),

        // gentest-5144  pins
        // 3rkb2/4pprp/2P1nnp1/p7/pP6/2P4b/3B1P1P/1RNK1BqR w - - 0 1
        ("gentest-5144",
         (0x00b044010304a000i64, 0x0000300000000004i64, 0x2000000000800820i64,
          0x0840000000000082i64, 0x0000000000000040i64, 0x1000000000000008i64,
          0x000004000204a8aei64, 0x38f0700101800040i64,
          true, 0, 0i64),
         4, 495084i64),

        // gentest-5152  pins
        // 8/3k1p1p/6r1/p2rp1R1/1b6/pRPNBB1b/3K1P1P/8 w - - 0 1
        ("gentest-5152",
         (0x00a000110005a000i64, 0x0000000000080000i64, 0x0000000002b00000i64,
          0x0000404800020000i64, 0i64, 0x0008000000000800i64,
          0x00000040003ea800i64, 0x00a8401902810000i64,
          true, 0, 0i64),
         4, 1391693i64),

        // gentest-5154  pins
        // 8/3k1p2/6r1/p1Brp1Rp/1b6/p1PN3b/3K1P1P/1R5B w - - 0 1
        ("gentest-5154",
         (0x002000910005a000i64, 0x0000000000080000i64, 0x0000000402800080i64,
          0x0000404800000002i64, 0i64, 0x0008000000000800i64,
          0x00000044000ca882i64, 0x0028409902810000i64,
          true, 0, 0i64),
         4, 1500655i64),

        // gentest-5158  pins
        // 1R6/5p2/2rk4/p2r3p/1b2p3/p1PN3b/R2K1PBP/8 w - - 0 1
        ("gentest-5158",
         (0x002000811005a000i64, 0x0000000000080000i64, 0x0000000002804000i64,
          0x0200040800000100i64, 0i64, 0x0000080000000800i64,
          0x02000000000ce900i64, 0x00200c8912810000i64,
          true, 0, 0i64),
         4, 775593i64),

        // gentest-5550  check
        // 8/p7/P6B/4k3/N2q3p/2K5/8/8 w - - 0 1
        ("gentest-5550",
         (0x0001010080000000i64, 0x0000000001000000i64, 0x0000800000000000i64,
          0i64, 0x0000000008000000i64, 0x0000001000040000i64,
          0x0000810001040000i64, 0x0001001088000000i64,
          true, 0, 0i64),
         4, 15699i64),

        // gentest-5560  castle
        // r1bqk1n1/p2pbpp1/npr5/2p1p3/1P1P1NPp/5P1B/P1P1P2P/RNBQK2R w KQq - 0 1
        ("gentest-5560",
         (0x00690214ca209500i64, 0x4000010020000002i64, 0x0410000000800004i64,
          0x0100040000000081i64, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000006aa0959fi64, 0x5d79071480000000i64,
          true, 0, 0x0100000000000081i64),
         4, 1173039i64),

        // gentest-5600  pins
        // 5k2/6p1/3K4/8/b3pP1R/6qn/3N3P/3q4 w - - 0 1
        ("gentest-5600",
         (0x0040000030008000i64, 0x0000000000800800i64, 0x0000000001000000i64,
          0x0000000080000000i64, 0x0000000000400008i64, 0x2000080000000000i64,
          0x00000800a0008800i64, 0x2040000011c00008i64,
          true, 0, 0i64),
         4, 294358i64),

        // gentest-5724  terminal
        // b6K/8/7k/6r1/2n5/2p3b1/8/2r4n w - - 0 1
        ("gentest-5724",
         (0x0000000000040000i64, 0x0000000004000080i64, 0x0100000000400000i64,
          0x0000004000000004i64, 0i64, -9223231299366420480i64 /* 0x8000800000000000 */,
          -9223372036854775808i64 /* 0x8000000000000000 */, 0x0100804004440084i64,
          true, 0, 0i64),
         4, 0i64),

        // gentest-5801  promo
        // 5B2/P1k5/7P/4P1P1/2K1b3/8/8/8 w - - 0 1
        ("gentest-5801",
         (0x0001805000000000i64, 0i64, 0x2000000010000000i64,
          0i64, 0i64, 0x0004000004000000i64,
          0x2001805004000000i64, 0x0004000010000000i64,
          true, 0, 0i64),
         4, 81297i64),

        // gentest-5855  castle
        // r1b1kbnQ/1p1pp2p/8/p4pp1/1qPn1P2/4B1PN/3NP2P/R3KB1R w KQq - 0 1
        ("gentest-5855",
         (0x009a006124409000i64, 0x4000000008800800i64, 0x2400000000100020i64,
          0x0100000000000081i64, -9223372036821221376i64 /* 0x8000000002000000 */, 0x1000000000000010i64,
          -9223372036237125455i64 /* 0x8000000024d098b1 */, 0x759a00610a000000i64,
          true, 0, 0x0100000000000081i64),
         4, 1007819i64),

        // gentest-6144  ep
        // 8/4k1B1/1p2p2r/1N3b2/pP3P1P/3R4/5QB1/1N4KR b - b3 0 1
        ("gentest-6144",
         (0x00001200a3000000i64, 0x0000000200000002i64, 0x0040002000004000i64,
          0x0000800000080080i64, 0x0000000000002000i64, 0x0010000000000040i64,
          0x00400002a20860c2i64, 0x0010922001000000i64,
          false, 17, 0i64),
         4, 822730i64),

        // gentest-6151  spread
        // 4N3/1B2k1B1/7R/1p2p1r1/1P2QP2/p5R1/8/1b4K1 w - - 0 1
        ("gentest-6151",
         (0x0000001222010000i64, 0x1000000000000000i64, 0x0042000000000002i64,
          0x0000804000400000i64, 0x0000000010000000i64, 0x0010000000000040i64,
          0x1042800032400040i64, 0x0010005200010002i64,
          true, 0, 0i64),
         4, 629469i64),

        // gentest-6159  check
        // 4N3/5k2/4R3/1B2B1P1/1P2b2R/p7/4p3/5K2 w - - 0 1
        ("gentest-6159",
         (0x0000004002011000i64, 0x1000000000000000i64, 0x0000001210000000i64,
          0x0000100080000000i64, 0i64, 0x0020000000000020i64,
          0x1000105282000020i64, 0x0020000010011000i64,
          true, 0, 0i64),
         4, 57092i64),

        // gentest-6390  promo
        // 6n1/4br2/1r2kp1p/pp4BP/P5P1/N2P1P2/2p3BK/6R1 b - - 0 1
        ("gentest-6390",
         (0x0000a08341280400i64, 0x4000000000010000i64, 0x0010004000004000i64,
          0x0020020000000040i64, 0i64, 0x0000100000008000i64,
          0x000000c04129c040i64, 0x4030b20300000400i64,
          false, 0, 0i64),
         4, 485309i64),

        // gentest-6709  castle
        // rnbqk2r/1ppp1p1p/4p1pn/p3b3/2PPP1P1/7N/PP3PBP/RNBQK2R w KQkq - 0 1
        ("gentest-6709",
         (0x00ae50015c00a300i64, 0x0200800000800002i64, 0x0400001000004004i64,
          -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
          0x000000005c80e39fi64, -6940381204298334208i64 /* 0x9faed01100000000 */,
          true, 0, -9151314442816847743i64 /* 0x8100000000000081 */),
         4, 1367780i64),

        // gentest-6723  ep
        // 2b1kr2/r2pbp1p/2n3N1/QpP1qP2/PP1p4/4pP2/3NK1BP/R1R5 w - b6 0 1
        ("gentest-6723",
         (0x00a800260b308000i64, 0x0000440000000800i64, 0x0410000000004000i64,
          0x2001000000000005i64, 0x0000001100000000i64, 0x1000000000001000i64,
          0x000040250320d805i64, 0x34b9041208100000i64,
          true, 41, 0i64),
         4, 2597219i64),

        // gentest-6728  promo
        // 1nb1k1r1/r1Q1bp2/3p3p/1PP1NP2/RP6/3p1P2/3p1KBq/2R5 b - - 0 1
        ("gentest-6728",
         (0x0020882602280800i64, 0x0200001000000000i64, 0x0410000000004000i64,
          0x4001000001000004i64, 0x0004000000008000i64, 0x1000000000002000i64,
          0x0004003603206004i64, 0x5631880000088800i64,
          false, 0, 0i64),
         4, 2333106i64),

        // gentest-6751  terminal
        // 8/3q1k2/2n5/4KP1p/3r4/8/7R/8 w - - 0 1
        ("gentest-6751",
         (0x000000a000000000i64, 0x0000040000000000i64, 0i64,
          0x0000000008008000i64, 0x0008000000000000i64, 0x0020001000000000i64,
          0x0000003000008000i64, 0x0028048008000000i64,
          true, 0, 0i64),
         4, 0i64),

        // gentest-6781  check
        // rn1kq2r/1bQ4p/2p5/p1Pp4/P5n1/2Np4/1R1P3R/2B3nK b - - 0 1
        ("gentest-6781",
         (0x0080040d01080800i64, 0x0200000040040040i64, 0x0002000000000004i64,
          -9151314442816814592i64 /* 0x8100000000008200 */, 0x1004000000000000i64, 0x0800000000000080i64,
          0x0004000401048a84i64, -7241220813082853312i64 /* 0x9b82040940080040 */,
          false, 0, 0i64),
         4, 18254i64),

        // gentest-6834  spread
        // 1k6/5b2/8/3pn1p1/8/N2pn3/3K4/8 w - - 0 1
        ("gentest-6834",
         (0x0000004800080000i64, 0x0000001000110000i64, 0x0020000000000000i64,
          0i64, 0i64, 0x0200000000000800i64,
          0x0000000000010800i64, 0x0220005800180000i64,
          true, 0, 0i64),
         4, 35919i64)
    }

    // --------------------------------------------------------------------- perft

    ///
    /// The six positions of `PerftTest.trickyBatch`, plus the start position.
    /// Depths 1..3 are exactly what the Scala suite asserts; the deeper counts are
    /// the published reference values.
    ///
    @Test
    pub def testPerftTrickyPositions(): Unit \ Assert =
        checkPerfts(List#{
            ("start", start(), 1, 20i64),
            ("start", start(), 2, 400i64),
            ("start", start(), 3, 8902i64),
            ("start", start(), 4, 197281i64),
            ("start", start(), 5, 4865609i64),

            ("kiwipete", kiwipete(), 1, 48i64),
            ("kiwipete", kiwipete(), 2, 2039i64),
            ("kiwipete", kiwipete(), 3, 97862i64),
            ("kiwipete", kiwipete(), 4, 4085603i64),

            ("epPin", epPin(), 1, 14i64),
            ("epPin", epPin(), 2, 191i64),
            ("epPin", epPin(), 3, 2812i64),
            ("epPin", epPin(), 4, 43238i64),
            ("epPin", epPin(), 5, 674624i64),

            ("promotions", promotions(), 1, 6i64),
            ("promotions", promotions(), 2, 264i64),
            ("promotions", promotions(), 3, 9467i64),
            ("promotions", promotions(), 4, 422333i64),

            ("position5", position5(), 1, 44i64),
            ("position5", position5(), 2, 1486i64),
            ("position5", position5(), 3, 62379i64),
            ("position5", position5(), 4, 2103487i64),

            ("position6", position6(), 1, 46i64),
            ("position6", position6(), 2, 2079i64),
            ("position6", position6(), 3, 89890i64),
            ("position6", position6(), 4, 3894594i64)
        })

    /// 11030083 nodes: the deepest en-passant / discovered-check search that still
    /// fits the runtime budget.
    @Test
    pub def testPerftEnPassantDepth6(): Unit \ Assert =
        checkPerfts(List#{("epPin", epPin(), 6, 11030083i64)})

    /// 15833292 nodes of nothing but promotions and pinned pieces.
    @Test
    pub def testPerftPromotionsDepth5(): Unit \ Assert =
        checkPerfts(List#{("promotions", promotions(), 5, 15833292i64)})

    @Test
    pub def testPerftReferenceBatchA(): Unit \ Assert = checkPerfts(gentestA())

    @Test
    pub def testPerftReferenceBatchB(): Unit \ Assert = checkPerfts(gentestB())

    @Test
    pub def testPerftReferenceBatchC(): Unit \ Assert = checkPerfts(gentestC())

    @Test
    pub def testPerftReferenceBatchD(): Unit \ Assert = checkPerfts(gentestD())

    ///
    /// Skipped: correct, but ~15 s on its own. Un-skip when changing move generation.
    ///
    @Skip
    @Test
    pub def testPerftStartDepth6(): Unit \ Assert =
        checkPerfts(List#{("start", start(), 6, 119060324i64)})

    /// Skipped: 193690690 nodes, several minutes.
    @Skip
    @Test
    pub def testPerftKiwipeteDepth5(): Unit \ Assert =
        checkPerfts(List#{("kiwipete", kiwipete(), 5, 193690690i64)})

    /// Skipped: 89941194 nodes.
    @Skip
    @Test
    pub def testPerftPosition5Depth5(): Unit \ Assert =
        checkPerfts(List#{("position5", position5(), 5, 89941194i64)})

    /// Skipped: 164075551 nodes.
    @Skip
    @Test
    pub def testPerftPosition6Depth5(): Unit \ Assert =
        checkPerfts(List#{("position6", position6(), 5, 164075551i64)})

    // ------------------------------------------------------- move-list fidelity

    ///
    /// The exact set of legal moves, in UCI, for a handful of positions. Perft only
    /// counts; this pins down *which* moves are generated and how `Move.uci`
    /// renders them (in particular that castling, stored king-square -> rook-square,
    /// comes back out as `e1g1`/`e1c1`).
    ///
    /// The expected lists were produced by an independent engine (python-chess),
    /// not by this implementation.
    ///
    @Test
    pub def testLegalMoveUci(): Unit \ Assert = {
        // start - the opening position: sixteen pawn moves and four knight moves, no castling
        // rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1
        Assert.assertEq(
            expected = List#{
                "a2a3",
                "a2a4",
                "b1a3",
                "b1c3",
                "b2b3",
                "b2b4",
                "c2c3",
                "c2c4",
                "d2d3",
                "d2d4",
                "e2e3",
                "e2e4",
                "f2f3",
                "f2f4",
                "g1f3",
                "g1h3",
                "g2g3",
                "g2g4",
                "h2h3",
                "h2h4"
            },
            legalUci(start()));

        // kiwipete - both castlings appear as `e1c1`/`e1g1`, i.e. the king-to-rook internal encoding is translated back for UCI
        // r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1
        Assert.assertEq(
            expected = List#{
                "a1b1",
                "a1c1",
                "a1d1",
                "a2a3",
                "a2a4",
                "b2b3",
                "c3a4",
                "c3b1",
                "c3b5",
                "c3d1",
                "d2c1",
                "d2e3",
                "d2f4",
                "d2g5",
                "d2h6",
                "d5d6",
                "d5e6",
                "e1c1",
                "e1d1",
                "e1f1",
                "e1g1",
                "e2a6",
                "e2b5",
                "e2c4",
                "e2d1",
                "e2d3",
                "e2f1",
                "e5c4",
                "e5c6",
                "e5d3",
                "e5d7",
                "e5f7",
                "e5g4",
                "e5g6",
                "f3d3",
                "f3e3",
                "f3f4",
                "f3f5",
                "f3f6",
                "f3g3",
                "f3g4",
                "f3h3",
                "f3h5",
                "g2g3",
                "g2g4",
                "g2h3",
                "h1f1",
                "h1g1"
            },
            legalUci(kiwipete()));

        // epPin - no en passant is available, and the b4 rook is pinned to nothing while the white king on a5 restricts the b-pawn
        // 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1
        Assert.assertEq(
            expected = List#{
                "a5a4",
                "a5a6",
                "b4a4",
                "b4b1",
                "b4b2",
                "b4b3",
                "b4c4",
                "b4d4",
                "b4e4",
                "b4f4",
                "e2e3",
                "e2e4",
                "g2g3",
                "g2g4"
            },
            legalUci(epPin()));

        // promotions - black is in check from the a6 queen: pure check evasion, six moves
        // r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1
        Assert.assertEq(
            expected = List#{
                "b5c4",
                "c5c4",
                "d7d5",
                "f6d5",
                "f8f7",
                "g8h8"
            },
            legalUci(promotions()));

        // gentest-336 - the only double check in the whole Scala data set - king moves only
        // r2n3r/1bNk2pp/6P1/pP3p2/3pPq1P/1P1PB2R/2P3p1/Q3bKN1 w - - 0 1
        Assert.assertEq(
            expected = List#{
                "f1e1",
                "f1e2",
                "f1g2"
            },
            legalUci(gentest336()));

        // gentest-2104 - an en-passant capture (`d5c6`) among the legal moves
        // rnbqk1nr/p2p3p/1p5b/2pPppp1/8/P7/1PPQPPPP/RNB1KBNR w KQkq c6 0 1
        Assert.assertEq(
            expected = List#{
                "a1a2",
                "a3a4",
                "b1c3",
                "b2b3",
                "b2b4",
                "c2c3",
                "c2c4",
                "d2a5",
                "d2b4",
                "d2c3",
                "d2d1",
                "d2d3",
                "d2d4",
                "d2e3",
                "d2f4",
                "d2g5",
                "d5c6",
                "d5d6",
                "e1d1",
                "e2e3",
                "e2e4",
                "f2f3",
                "f2f4",
                "g1f3",
                "g1h3",
                "g2g3",
                "g2g4",
                "h2h3",
                "h2h4"
            },
            legalUci(gentest2104()));

        // gentest-6728 - promotions, including under-promotions, from both a capture and a push
        // 1nb1k1r1/r1Q1bp2/3p3p/1PP1NP2/RP6/3p1P2/3p1KBq/2R5 b - - 0 1
        Assert.assertEq(
            expected = List#{
                "a7a4",
                "a7a5",
                "a7a6",
                "a7a8",
                "a7b7",
                "a7c7",
                "b8a6",
                "b8c6",
                "b8d7",
                "c8a6",
                "c8b7",
                "c8d7",
                "c8e6",
                "c8f5",
                "d2c1b",
                "d2c1n",
                "d2c1q",
                "d2c1r",
                "d2d1b",
                "d2d1n",
                "d2d1q",
                "d2d1r",
                "d6c5",
                "d6d5",
                "d6e5",
                "e7d8",
                "e7f6",
                "e7f8",
                "e7g5",
                "e7h4",
                "e8f8",
                "f7f6",
                "g8f8",
                "g8g2",
                "g8g3",
                "g8g4",
                "g8g5",
                "g8g6",
                "g8g7",
                "g8h8",
                "h2e5",
                "h2f4",
                "h2g1",
                "h2g2",
                "h2g3",
                "h2h1",
                "h2h3",
                "h2h4",
                "h2h5",
                "h6h5"
            },
            legalUci(gentest6728()))
    }

    /// `r2n3r/1bNk2pp/6P1/pP3p2/3pPq1P/1P1PB2R/2P3p1/Q3bKN1 w - - 0 1`
    def gentest336(): Pos =
        (0x00c04023980a4400i64, 0x0804000000000040i64, 0x0002000000100010i64,
         -9151314442808459264i64 /* 0x8100000000800000 */, 0x0000000020000001i64, 0x0008000000000020i64,
         0x00044002909a0461i64, -8517995602812846064i64 /* 0x89ca002128004010 */,
         true, 0, 0i64)

    /// `rnbqk1nr/p2p3p/1p5b/2pPppp1/8/P7/1PPQPPPP/RNB1KBNR w KQkq c6 0 1`
    def gentest2104(): Pos =
        (0x0089027c0001f600i64, 0x4200000000000042i64, 0x0400800000000024i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000800i64, 0x1000000000000010i64,
         0x000000080001fef7i64, -2339195096714444800i64 /* 0xdf89827400000000 */,
         true, 42, -9151314442816847743i64 /* 0x8100000000000081 */)

    /// `1nb1k1r1/r1Q1bp2/3p3p/1PP1NP2/RP6/3p1P2/3p1KBq/2R5 b - - 0 1`
    def gentest6728(): Pos =
        (0x0020882602280800i64, 0x0200001000000000i64, 0x0410000000004000i64,
         0x4001000001000004i64, 0x0004000000008000i64, 0x1000000000002000i64,
         0x0004003603206004i64, 0x5631880000088800i64,
         false, 0, 0i64)

    ///
    /// `Board.hasLegalEnPassant` for one position. Kept out of the test body, and
    /// `@DontInline`, because inlining eleven copies of `Board.mk` overflows the JVM
    /// 64 KB method limit at code generation time (`flix check` does not catch it).
    ///
    @DontInline
    def hasEp(t: Tables, ps: Psqt, z: Vector[Int32], p: Pos): Bool =
        region rc { Board.hasLegalEnPassant(boardOf(rc, t, ps, z, p)) }

    /// `Board.isCheck` for one position; `@DontInline` for the same reason as `hasEp`.
    @DontInline
    def isCheckAt(t: Tables, ps: Psqt, z: Vector[Int32], p: Pos): Bool =
        region rc { Board.isCheck(boardOf(rc, t, ps, z, p)) }

    ///
    /// Both predicate tests are written data-driven rather than as a run of
    /// `Assert.assertTrue` calls. A `@Test` body has effect `Assert`, so Flix
    /// CPS-transforms it, and a dozen effectful statements in one body overflows the
    /// JVM 64 KB method limit at code generation. `flix check` accepts it and
    /// `flix build`/`flix test` then die with `MethodTooLargeException`.
    ///
    def checkEp(cases: List[(String, Pos, Bool)]): Unit \ Assert = checkPredicate(hasEp, "hasLegalEnPassant", cases)

    def checkCheck(cases: List[(String, Pos, Bool)]): Unit \ Assert = checkPredicate(isCheckAt, "isCheck", cases)

    def checkPredicate(f: (Tables, Psqt, Vector[Int32], Pos) -> Bool,
                       label: String,
                       cases: List[(String, Pos, Bool)]): Unit \ Assert = {
        let t = Tables.mk();
        let ps = Psqt.mk();
        let z = ZobristHash.polyglot();
        let failures = List.filterMap(c -> {
            let (name, p, expected) = c;
            if (f(t, ps, z, p) == expected) None
            else Some("${name}: ${label} expected ${expected}, got ${not expected}")
        }, cases);
        Assert.assertEq(expected = (Nil: List[String]), failures)
    }

    // ------------------------------------------------------------- en passant

    ///
    /// `hasLegalEnPassant` (used by the game encoder, and *not* covered by perft).
    /// True for every position in the Scala data set that has an en-passant square,
    /// false when the capture would leave the king in check, and false when there is
    /// no en-passant square at all.
    ///
    @Test
    pub def testHasLegalEnPassant(): Unit \ Assert =
        checkEp(List#{
            // gentest-335  ep=20  r2n3r/1bNk2pp/6P1/pP3p2/3pPqnP/1P1P1p1R/2P3B1/Q1B1bKN1 b - e3 0 1
            ("gentest-335", epPos335(), true),
            // gentest-2104  ep=42  rnbqk1nr/p2p3p/1p5b/2pPppp1/8/P7/1PPQPPPP/RNB1KBNR w KQkq c6 0 1
            ("gentest-2104", epPos2104(), true),
            // gentest-2855  ep=44  rnb1k2r/pp1p1p1p/1q1P4/2pnpPp1/6P1/2N5/PP1BP2P/R2QKBNR w KQkq e6 0 1
            ("gentest-2855", epPos2855(), true),
            // gentest-3476  ep=18  1n4kr/2B4p/2nb2b1/ppp5/P1PpP3/3P4/5K2/1N1R4 b - c3 0 1
            ("gentest-3476", epPos3476(), true),
            // gentest-3705  ep=43  r1bqkb1r/p1p1pnpp/1pn5/3pPp2/6P1/2N2P2/PPPPQ2P/R1B1KBNR w KQkq d6 0 1
            ("gentest-3705", epPos3705(), true),
            // gentest-4042  ep=41  rn2kbnr/p3q1p1/2pp1p1p/Pp1bp3/4PB2/1P1P2PP/R1P2P2/1N1QKBNR w Kkq b6 0 1
            ("gentest-4042", epPos4042(), true),
            // gentest-5071  ep=19  8/4kqr1/p3pnpB/7p/P1pPP2P/1r3P1B/R4K2/2B4R b - d3 0 1
            ("gentest-5071", epPos5071(), true),
            // gentest-6144  ep=17  8/4k1B1/1p2p2r/1N3b2/pP3P1P/3R4/5QB1/1N4KR b - b3 0 1
            ("gentest-6144", epPos6144(), true),
            // gentest-6723  ep=41  2b1kr2/r2pbp1p/2n3N1/QpP1qP2/PP1p4/4pP2/3NK1BP/R1R5 w - b6 0 1
            ("gentest-6723", epPos6723(), true),
            // The en-passant square is set (the c4 pawn does attack d3) but the capture
            // is illegal: it would open the fourth rank onto the black king on a4.
            // `8/8/8/8/k1pP3R/8/8/3K4 b - - 0 1`
            ("epTrap", epTrap(), false),
            // No en-passant square at all.
            ("start", start(), false)
        })

    /// `r2n3r/1bNk2pp/6P1/pP3p2/3pPqnP/1P1P1p1R/2P3B1/Q1B1bKN1 b - e3 0 1`
    def epPos335(): Pos =
        (0x00c04023982a0400i64, 0x0804000040000040i64, 0x0002000000004014i64,
         -9151314442808459264i64 /* 0x8100000000800000 */, 0x0000000020000001i64, 0x0008000000000020i64,
         0x00044002908a4465i64, -8517995601737023472i64 /* 0x89ca002168200010 */,
         false, 20, 0i64)

    /// `rnbqk1nr/p2p3p/1p5b/2pPppp1/8/P7/1PPQPPPP/RNB1KBNR w KQkq c6 0 1`
    def epPos2104(): Pos =
        (0x0089027c0001f600i64, 0x4200000000000042i64, 0x0400800000000024i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000800i64, 0x1000000000000010i64,
         0x000000080001fef7i64, -2339195096714444800i64 /* 0xdf89827400000000 */,
         true, 42, -9151314442816847743i64 /* 0x8100000000000081 */)

    /// `rnb1k2r/pp1p1p1p/1q1P4/2pnpPp1/6P1/2N5/PP1BP2P/R2QKBNR w KQkq e6 0 1`
    def epPos2855(): Pos =
        (0x00ab087440009300i64, 0x0200000800040040i64, 0x0400000000000820i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0000020000000008i64, 0x1000000000000010i64,
         0x0000082040049bf9i64, -7517912558804664320i64 /* 0x97ab025c00000000 */,
         true, 44, -9151314442816847743i64 /* 0x8100000000000081 */)

    /// `1n4kr/2B4p/2nb2b1/ppp5/P1PpP3/3P4/5K2/1N1R4 b - c3 0 1`
    def epPos3476(): Pos =
        (0x008000071d080000i64, 0x0200040000000002i64, 0x0004480000000000i64,
         -9223372036854775800i64 /* 0x8000000000000008 */, 0i64, 0x4000000000002000i64,
         0x000400001508200ai64, -4431458440249868288i64 /* 0xc2804c0708000000 */,
         false, 18, 0i64)

    /// `r1bqkb1r/p1p1pnpp/1pn5/3pPp2/6P1/2N2P2/PPPPQ2P/R1B1KBNR w KQkq d6 0 1`
    def epPos3705(): Pos =
        (0x00d5023840208f00i64, 0x0020040000040040i64, 0x2400000000000024i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000001000i64, 0x1000000000000010i64,
         0x0000001040249ff5i64, -4758890662378602496i64 /* 0xbdf5062800000000 */,
         true, 43, -9151314442816847743i64 /* 0x8100000000000081 */)

    /// `rn2kbnr/p3q1p1/2pp1p1p/Pp1bp3/4PB2/1P1P2PP/R1P2P2/1N1QKBNR w Kkq b6 0 1`
    def epPos4042(): Pos =
        (0x0041ac1310ca2400i64, 0x4200000000000042i64, 0x2000000820000020i64,
         -9151314442816847488i64 /* 0x8100000000000180 */, 0x0010000000000008i64, 0x1000000000000010i64,
         0x0000000130ca25fai64, -913760021710372864i64 /* 0xf351ac1a00000000 */,
         true, 41, -9151314442816847744i64 /* 0x8100000000000080 */)

    /// `8/4kqr1/p3pnpB/7p/P1pPP2P/1r3P1B/R4K2/2B4R b - d3 0 1`
    def epPos5071(): Pos =
        (0x000051809d200000i64, 0x0000200000000000i64, 0x0000800000800004i64,
         0x0040000000020180i64, 0x0020000000000000i64, 0x0010000000002000i64,
         0x0000800099a02184i64, 0x0070718004020000i64,
         false, 19, 0i64)

    /// `8/4k1B1/1p2p2r/1N3b2/pP3P1P/3R4/5QB1/1N4KR b - b3 0 1`
    def epPos6144(): Pos =
        (0x00001200a3000000i64, 0x0000000200000002i64, 0x0040002000004000i64,
         0x0000800000080080i64, 0x0000000000002000i64, 0x0010000000000040i64,
         0x00400002a20860c2i64, 0x0010922001000000i64,
         false, 17, 0i64)

    /// `2b1kr2/r2pbp1p/2n3N1/QpP1qP2/PP1p4/4pP2/3NK1BP/R1R5 w - b6 0 1`
    def epPos6723(): Pos =
        (0x00a800260b308000i64, 0x0000440000000800i64, 0x0410000000004000i64,
         0x2001000000000005i64, 0x0000001100000000i64, 0x1000000000001000i64,
         0x000040250320d805i64, 0x34b9041208100000i64,
         true, 41, 0i64)

    /// `8/8/8/8/k1pP3R/8/8/3K4 b - - 0 1` - `8/8/8/8/k1p4R/8/3P4/3K4 w - -` after `d2d4`.
    def epTrap(): Pos =
        (0x000000000c000000i64, 0i64, 0i64,
         0x0000000080000000i64, 0i64, 0x0000000001000008i64,
         0x0000000088000008i64, 0x0000000005000000i64,
         false, 19, 0i64)

    // ---------------------------------------------------------------- Board.play

    ///
    /// A Ruy Lopez down to White castling short and Black winning the e-pawn. Every
    /// intermediate state - all six role bitboards, both colour bitboards, the side to
    /// move, the en-passant square and the castling rights - is checked.
    ///
    /// The expected states come from python-chess, with the Scala en-passant rule
    /// (`epSquare` is set only when an enemy pawn could actually capture) applied on
    /// top of it.
    ///
    /// `rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1`
    ///
    @Test
    pub def testPlayOpening(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
            (0x00ff00001000ef00i64, 0x4200000000000042i64, 0x2400000000000024i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
             0x000000001000efffi64, -281474976710656i64 /* 0xffff000000000000 */,
             false, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x00ef00101000ef00i64, 0x4200000000000042i64, 0x2400000000000024i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
             0x000000001000efffi64, -4785005884604416i64 /* 0xffef001000000000 */,
             true, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x00ef00101000ef00i64, 0x4200000000200002i64, 0x2400000000000024i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
             0x000000001020efbfi64, -4785005884604416i64 /* 0xffef001000000000 */,
             false, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x00ef00101000ef00i64, 0x4000040000200002i64, 0x2400000000000024i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
             0x000000001020efbfi64, -148895795913949184i64 /* 0xfdef041000000000 */,
             true, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x00ef00101000ef00i64, 0x4000040000200002i64, 0x2400000200000004i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
             0x000000021020ef9fi64, -148895795913949184i64 /* 0xfdef041000000000 */,
             false, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x00ef00101000ef00i64, 0x0000240000200002i64, 0x2400000200000004i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
             0x000000021020ef9fi64, -4760546629969248256i64 /* 0xbdef241000000000 */,
             true, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x00ef00101000ef00i64, 0x0000240000200002i64, 0x2400000200000004i64,
             -9151314442816847839i64 /* 0x8100000000000021 */, 0x0800000000000008i64, 0x1000000000000040i64,
             0x000000021020ef6fi64, -4760546629969248256i64 /* 0xbdef241000000000 */,
             false, 0, -9151314442816847872i64 /* 0x8100000000000000 */),

            (0x00ef00100000ef00i64, 0x0000040010200002i64, 0x2400000200000004i64,
             -9151314442816847839i64 /* 0x8100000000000021 */, 0x0800000000000008i64, 0x1000000000000040i64,
             0x000000020020ef6fi64, -4760581814072901632i64 /* 0xbdef041010000000 */,
             true, 0, -9151314442816847872i64 /* 0x8100000000000000 */)
            },
            playSeq(start(), List#{"e2e4",
                     "e7e5",
                     "g1f3",
                     "b8c6",
                     "f1b5",
                     "g8f6",
                     "e1g1",
                     "f6e4"}))

    ///
    /// White castles short, Black castles long, then a pawn capture. Castling is stored
    /// king-square -> rook-square internally, so this checks that both rook and king
    /// land on the right squares and that the mover's two rights are cleared.
    ///
    /// The expected states come from python-chess, with the Scala en-passant rule
    /// (`epSquare` is set only when an enemy pawn could actually capture) applied on
    /// top of it.
    ///
    /// `r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1`
    ///
    @Test
    pub def testPlayKiwipeteCastling(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
            (0x002d50081280e700i64, 0x0000221000040000i64, 0x0040010000001800i64,
             -9151314442816847839i64 /* 0x8100000000000021 */, 0x0010000000200000i64, 0x1000000000000040i64,
             0x000000181024ff61i64, -7963082122242031616i64 /* 0x917d730002800000 */,
             false, 0, -9151314442816847872i64 /* 0x8100000000000000 */),

            (0x002d50081280e700i64, 0x0000221000040000i64, 0x0040010000001800i64,
             -8646911284551352287i64 /* 0x8800000000000021 */, 0x0010000000200000i64, 0x0400000000000040i64,
             0x000000181024ff61i64, -8323370092431671296i64 /* 0x8c7d730002800000 */,
             true, 0, 0i64),

            (0x002d50001280e700i64, 0x0000221000040000i64, 0x0040010000001800i64,
             -8646911284551352287i64 /* 0x8800000000000021 */, 0x0010000000200000i64, 0x0400000000000040i64,
             0x000010101024ff61i64, -8323387684617715712i64 /* 0x8c7d630002800000 */,
             false, 0, 0i64),

            (0x002550001280e700i64, 0x0000221000040000i64, 0x0040010000001800i64,
             -8646911284551352287i64 /* 0x8800000000000021 */, 0x0010000000200000i64, 0x0400000000000040i64,
             0x000000101024ff61i64, -8325621892245356544i64 /* 0x8c75730002800000 */,
             true, 0, 0i64)
            },
            playSeq(kiwipete(), List#{"e1g1",
                     "e8c8",
                     "d5e6",
                     "d7e6"}))

    ///
    /// Under-promotion by capture on a rook's home square must clear that rook's castling
    /// right (Scala: `castlingRights &= ~bit(to)` on any capture), for both colours,
    /// and the remaining rights must still allow the two castlings that are left.
    ///
    /// The expected states come from python-chess, with the Scala en-passant rule
    /// (`epSquare` is set only when an enemy pawn could actually capture) applied on
    /// top of it.
    ///
    /// `r3k2r/1P6/8/8/8/8/6p1/R3K2R w KQkq - 0 1`
    ///
    @Test
    pub def testPlayPromotionClearsCastlingRights(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
            (0x0000000000004000i64, 0x0100000000000000i64, 0i64,
             -9223372036854775679i64 /* 0x8000000000000081 */, 0i64, 0x1000000000000010i64,
             0x0100000000000091i64, -8070450532247912448i64 /* 0x9000000000004000 */,
             false, 0, -9223372036854775679i64 /* 0x8000000000000081 */),

            (0i64, 0x0100000000000080i64, 0i64,
             -9223372036854775807i64 /* 0x8000000000000001 */, 0i64, 0x1000000000000010i64,
             0x0100000000000011i64, -8070450532247928704i64 /* 0x9000000000000080 */,
             true, 0, -9223372036854775807i64 /* 0x8000000000000001 */),

            (0i64, 0x0100000000000080i64, 0i64,
             -9223372036854775800i64 /* 0x8000000000000008 */, 0i64, 0x1000000000000004i64,
             0x010000000000000ci64, -8070450532247928704i64 /* 0x9000000000000080 */,
             false, 0, -9223372036854775808i64 /* 0x8000000000000000 */),

            (0i64, 0x0100000000000080i64, 0i64,
             0x2000000000000008i64, 0i64, 0x4000000000000004i64,
             0x010000000000000ci64, 0x6000000000000080i64,
             true, 0, 0i64)
            },
            playSeq(promotionCorner(), List#{"b7a8n",
                     "g2h1n",
                     "e1c1",
                     "e8g8"}))

    ///
    /// The en-passant capture removes the pawn on `Square.combine(to, from)` - c5, not c6.
    ///
    /// The expected states come from python-chess, with the Scala en-passant rule
    /// (`epSquare` is set only when an enemy pawn could actually capture) applied on
    /// top of it.
    ///
    /// `rnbqk1nr/p2p3p/1p5b/2pPppp1/8/P7/1PPQPPPP/RNB1KBNR w KQkq c6 0 1`
    ///
    @Test
    pub def testPlayEnPassantCapture(): Unit \ Assert =
        Assert.assertEq(
            expected = List#{
            (0x008906700001f600i64, 0x4200000000000042i64, 0x0400800000000024i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000800i64, 0x1000000000000010i64,
             0x000004000001fef7i64, -2339195113894313984i64 /* 0xdf89827000000000 */,
             false, 0, -9151314442816847743i64 /* 0x8100000000000081 */),

            (0x008106700001f600i64, 0x4200000000000042i64, 0x0400800000000024i64,
             -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000800i64, 0x1000000000000010i64,
             0x000000000001fef7i64, -2341442515661488128i64 /* 0xdf81867000000000 */,
             true, 0, -9151314442816847743i64 /* 0x8100000000000081 */)
            },
            playSeq(gentest2104(), List#{"d5c6",
                     "d7c6"}))

    /// `r3k2r/1P6/8/8/8/8/6p1/R3K2R w KQkq -`
    def promotionCorner(): Pos =
        (0x0002000000004000i64, 0i64, 0i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0i64, 0x1000000000000010i64,
         0x0002000000000091i64, -7998392938209984512i64 /* 0x9100000000004000 */,
         true, 0, -9151314442816847743i64 /* 0x8100000000000081 */)

    ///
    /// A fidelity detail of the original that perft cannot see, because it changes no
    /// legal move: Scala's `play` sets `epSquare` **only when an enemy pawn could
    /// actually take**, not on every double push. `1. e4` from the start position must
    /// therefore leave `epSquare == 0`, while the same push with a black pawn on d4
    /// must set it to e3 (square 20). Getting this wrong would still perft correctly
    /// but would change the Zobrist hash, and so the compressed output.
    ///
    @Test
    pub def testEnPassantSquareOnlyWhenCapturable(): Unit \ Assert = {
        let after = p -> match playSeq(p, List#{"e2e4"}) {
            case s :: _ => { let (_, _, _, _, _, _, _, _, _, ep, _) = s; ep }
            case Nil    => -1
        };
        Assert.assertEq(expected = 0, after(start()));
        Assert.assertEq(expected = 20, after(blackPawnOnD4()))
    }

    /// `rnbqkbnr/ppp1pppp/8/8/3p4/8/PPPPPPPP/RNBQKBNR w KQkq -`
    def blackPawnOnD4(): Pos =
        (0x00f700000800ff00i64, 0x4200000000000042i64, 0x2400000000000024i64,
         -9151314442816847743i64 /* 0x8100000000000081 */, 0x0800000000000008i64, 0x1000000000000010i64,
         0x000000000000ffffi64, -2533274656178176i64 /* 0xfff7000008000000 */,
         true, 0, -9151314442816847743i64 /* 0x8100000000000081 */)

    // ------------------------------------------------------------------ isCheck

    ///
    /// `isCheck` on positions the Scala data set marks as in check (including the one
    /// double check), and on positions that are not.
    ///
    @Test
    pub def testIsCheck(): Unit \ Assert =
        checkCheck(List#{
            ("promotions",   promotions(),   true),
            ("gentest-336",  gentest336(),   true),
            ("start",        start(),        false),
            ("kiwipete",     kiwipete(),     false),
            ("epPin",        epPin(),        false),
            ("position5",    position5(),    false),
            ("position6",    position6(),    false),
            ("gentest-2104", gentest2104(),  false)
        })
}
