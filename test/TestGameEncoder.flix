///
/// Acceptance tests for the game (move) compressor, ported from
/// `src/test/scala/HuffmanPgnTest.scala`.
///
/// All of the PGN below is the Scala suite's own fixture data, verbatim. Every
/// expected value is **reference output produced by running the Scala
/// implementation** (`org.lichess.compression.game.Encoder`, Scala 3.8.2, on
/// this machine) over that data — nothing here was read off the Flix port.
///
/// The reference for the 114-game fixture list is one line per game,
///
/// ```
///   <encoded bytes, hex> | <halfMoveClock> | <positionHashes, hex> | <lastUci>
/// ```
///
/// and it was independently cross-checked against the `v1` base64 list that the
/// Scala suite carries as its stable-format golden data: all 114 encodings agree
/// byte for byte, so these bytes are the published on-disk format, not just what
/// today's encoder happens to emit.
///
/// Three separate claims are tested over that data:
///
///   * `encode(pgn)` is byte-identical to Scala's (`testFixturesEncodeToScalaBytes`);
///   * decoding **Scala's** bytes reproduces the PGN, the half-move clock, the
///     position-hash stack and the last UCI move (`testFixturesDecodeScalaBytes`);
///   * `decode(encode(pgn))` is the identity on the SAN token list
///     (`testFixturesRoundTrip`).
///
/// The first two together are what makes this a real acceptance test: a port
/// that merely agreed with itself would pass the third alone.
///
mod TestGameEncoder {

    // ------------------------------------------------------------------ helpers

    def hexDigits(): String = "0123456789abcdef"

    /// Lowercase hex, two characters per byte.
    def hexOf(v: Vector[Int8]): String =
        Vector.foldLeft((acc, b) -> {
            let u = Bits.byteToUnsigned(b);
            let hi = String.charAt(Bits.ushr(u, 4), hexDigits());
            let lo = String.charAt(Bits.band(u, 15), hexDigits());
            "${acc}${hi}${lo}"
        }, "", v)

    def hexVal(c: Char): Int32 =
        if ('0' <= c and c <= '9')
            Char.toBmpCodePoint(c) - Char.toBmpCodePoint('0')
        else if ('a' <= c and c <= 'f')
            10 + Char.toBmpCodePoint(c) - Char.toBmpCodePoint('a')
        else
            bug!("TestGameEncoder.hexVal: not a hex digit")

    /// The Scala test's `hexToBytes`.
    def bytesOfHex(s: String): Vector[Int8] =
        let n = String.length(s) / 2;
        List.range(0, n)
            |> List.map(i ->
                Bits.toByte(hexVal(String.charAt(2 * i, s)) * 16
                          + hexVal(String.charAt(2 * i + 1, s))))
            |> List.toVector

    /// The Scala test's `pgn.split(" ")`.
    def movesOf(pgn: String): Vector[String] =
        String.splitOn(substr = " ", pgn) |> List.toVector

    def joinMoves(v: Vector[String]): String =
        String.intercalate(" ", Vector.toList(v))

    /// `Encoder.encode`, failing loudly instead of returning `null`.
    def encodeOrFail(gt: GameTables, pgn: String): Vector[Int8] =
        match GameEncoder.encode(gt, movesOf(pgn)) {
            case Some(b) => b
            case None    => bug!("encode returned None for: ${pgn}")
        }

    /// Field `i` of a `|`-separated reference line.
    def field(s: String, i: Int32): String =
        String.splitOn(substr = "|", s) |> List.toVector |> Vector.get(i)

    /// Everything after the first `|`-separated field.
    def dropField(s: String): String =
        String.splitOn(substr = "|", s) |> List.drop(1) |> String.intercalate("|")

    /// `Option(lastUci)` rendered the way the reference generator renders it.
    def uciStr(u: Option[String]): String = match u {
        case None    => "-"
        case Some(s) => s
    }

    /// `enc|halfMoveClock|positionHashes|lastUci` for one game, from its bytes.
    def summarise(rc: Region[r], gt: GameTables, bytes: Vector[Int8], plies: Int32
                 ): (String, String) \ r =
        let d = GameEncoder.decode(rc, gt, bytes, plies);
        (joinMoves(DecodeResult.pgnMoves(d)),
         "${DecodeResult.halfMoveClock(d)}|${hexOf(DecodeResult.positionHashes(d))}|"
             + "${uciStr(DecodeResult.lastUci(d))}")

    // --------------------------------------------------------- the 114 fixtures

    ///
    /// `encode` agrees with the Scala byte for byte on every fixture game.
    ///
    @Test
    pub def testFixturesEncodeToScalaBytes(): Unit \ Assert = {
        let gt = GameTables.mk();
        let fs = fixtures();
        let rs = references();
        Assert.assertEq(expected = Vector.length(fs), Vector.length(rs));
        def loop(i) =
            if (i >= Vector.length(fs)) ()
            else {
                let expected = field(Vector.get(i, rs), 0);
                let actual = hexOf(encodeOrFail(gt, Vector.get(i, fs)));
                Assert.assertEq(expected = "game ${i}: ${expected}", "game ${i}: ${actual}");
                loop(i + 1)
            };
        loop(0)
    }

    ///
    /// Decoding the *Scala's* bytes — the stable on-disk format — reproduces the
    /// SAN tokens, the half-move clock, the position-hash stack and the last UCI
    /// move. This is the Scala suite's "stable format" test, widened.
    ///
    @Test
    pub def testFixturesDecodeScalaBytes(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let fs = fixtures();
        let rs = references();
        def loop(i) =
            if (i >= Vector.length(fs)) ()
            else {
                let pgn = Vector.get(i, fs);
                let ref = Vector.get(i, rs);
                let plies = Vector.length(movesOf(pgn));
                let (moves, facts) = summarise(rc, gt, bytesOfHex(field(ref, 0)), plies);
                Assert.assertEq(expected = "game ${i}: ${pgn}", "game ${i}: ${moves}");
                Assert.assertEq(expected = "game ${i}: ${dropField(ref)}", "game ${i}: ${facts}");
                loop(i + 1)
            };
        loop(0)
    }

    ///
    /// `decode(encode(pgn))` is the identity on the SAN token list.
    ///
    @Test
    pub def testFixturesRoundTrip(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let fs = fixtures();
        def loop(i) =
            if (i >= Vector.length(fs)) ()
            else {
                let pgn = Vector.get(i, fs);
                let plies = Vector.length(movesOf(pgn));
                let d = GameEncoder.decode(rc, gt, encodeOrFail(gt, pgn), plies);
                Assert.assertEq(expected = "game ${i}: ${pgn}",
                                "game ${i}: ${joinMoves(DecodeResult.pgnMoves(d))}");
                loop(i + 1)
            };
        loop(0)
    }

    // ------------------------------------------------------------- named cases

    ///
    /// Scala "least surprise": 22 zero bytes are the most probable game.
    ///
    @Test
    pub def testLeastSurprise(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let d = GameEncoder.decode(rc, gt, Vector.repeat(22, 0i8), 22);
        Assert.assertEq(expected = "e4 e5 Nf3 Nf6 Nxe5 Nxe4 Nxf7 Kxf7 d4 Nxf2 Kxf2 d5 Nc3 Nc6 Nxd5 Qxd5 Kg1 Nxd4 Qxd4 Qxd4+ Be3 Qxe3#", joinMoves(DecodeResult.pgnMoves(d)))
    }

    ///
    /// Scala "unmoved rooks": a rook that leaves h8 and comes back has still lost
    /// its castling right, so the right must be tracked by rook *movement*, not by
    /// occupancy. `decode(_, 0)` also exercises the degenerate `plies == 0` path on
    /// a non-empty stream.
    ///
    @Test
    pub def testUnmovedRooks(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let bytes = encodeOrFail(gt, "d4 h5 c4 Rh6 Nf3 Rh8");
        Assert.assertEq(expected = "884d1bd0", hexOf(bytes));

        let d0 = GameEncoder.decode(rc, gt, bytes, 0);
        Assert.assertEq(expected = Set#{0, 7, 56, 63},
            Bitboard.squareSet(Board.castlingRights(DecodeResult.board(d0))));

        let d6 = GameEncoder.decode(rc, gt, bytes, 6);
        Assert.assertEq(expected = Set#{0, 7, 56},
            Bitboard.squareSet(Board.castlingRights(DecodeResult.board(d6))))
    }

    ///
    /// Scala "half-move clock": the clock at every prefix length, 0..28. Captures
    /// and pawn moves reset it; castling and the en-passant capture do not.
    ///
    @Test
    pub def testHalfMoveClock(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "e4 e5 Nf3 Nc6 Nc3 Nf6 Bb5 d6 O-O Be7 d4 exd4 Nxd4 Bd7 Bg5 O-O Nxc6 bxc6 Bd3 h6 Bh4 Ne8 Bxe7 Qxe7 Qf3 Nf6 Rfe1 Rfe8";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "024167358e455b9beb3826048a", hexOf(bytes));
        let plies = Vector.length(movesOf(pgn));
        let clocks =
            List.range(0, plies + 1)
                |> List.map(i -> DecodeResult.halfMoveClock(GameEncoder.decode(rc, gt, bytes, i)));
        Assert.assertEq(expected = 0 :: 0 :: 0 :: 1 :: 2 :: 3 :: 4 :: 5 :: 0 :: 1 :: 2 :: 0 :: 0 :: 0 :: 1 :: 2 :: 3 :: 0 :: 0 :: 1 :: 0 :: 1 :: 2 :: 0 :: 0 :: 1 :: 2 :: 3 :: 4 :: Nil, clocks)
    }

    ///
    /// Scala "last uci": `null` at ply 0, the final move's UCI at the end.
    ///
    @Test
    pub def testLastUci(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "e4 e5 Nf3 Nc6 Bc4 Nf6 d4 exd4 O-O Bc5 e5 d5 exf6 dxc4 Re1+ Be6 Ng5 Qxf6 Nxe6 Qxe6";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "0250975aace2ce44ca00", hexOf(bytes));
        Assert.assertEq(expected = None,
            DecodeResult.lastUci(GameEncoder.decode(rc, gt, bytes, 0)));
        Assert.assertEq(expected = Some("f6e6"),
            DecodeResult.lastUci(GameEncoder.decode(rc, gt, bytes,
                Vector.length(movesOf(pgn)))))
    }

    ///
    /// Scala "position hash 1. e4 d5 2. e5 f5 3. Ke2 Kf7": the hash stack at every
    /// prefix. The stack resets on an irreversible move and grows otherwise, and
    /// the en-passant right after `f5` has to be in the hash.
    ///
    @Test
    pub def testPositionHashes1(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "e4 d5 e5 f5 Ke2 Kf7";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "1fcacb3d", hexOf(bytes));
        let hashes =
            List.range(0, 7)
                |> List.map(i ->
                    hexOf(DecodeResult.positionHashes(GameEncoder.decode(rc, gt, bytes, i))));
        Assert.assertEq(expected = "463b96" :: "823c9b" :: "0756b9" :: "662faf" :: "22a48b" :: "652a6022a48b" :: "00fdd3652a6022a48b" :: Nil, hashes)
    }

    ///
    /// Scala "position hash 1. a4 b5 2. h4 b4 3. c4 bxc3 4. Ra3": the same, through
    /// an en-passant capture and a rook move that drops a castling right.
    ///
    @Test
    pub def testPositionHashes2(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "a4 b5 h4 b4 c4 bxc3 Ra3";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "e5be7dccc0", hexOf(bytes));
        let hashes =
            List.range(0, 8)
                |> List.map(i ->
                    hexOf(DecodeResult.positionHashes(GameEncoder.decode(rc, gt, bytes, i))));
        Assert.assertEq(expected = "463b96" :: "2df2e8" :: "4df682" :: "d1551e" :: "b0982f" :: "3c8123" :: "93d326" :: "5c3f9b93d326" :: Nil, hashes)
    }

    ///
    /// Scala "position hash threefold" (lichess.org/V0m3eSGN): a ten-position hash
    /// stack in which the same position occurs three times, so the repetitions must
    /// hash identically.
    ///
    @Test
    pub def testPositionHashThreefold(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "Nf3 d5 d4 c5 dxc5 e6 c4 Bxc5 Nc3 Nf6 e3 O-O cxd5 Nxd5 Nxd5 Qxd5 Qxd5 exd5 Be2 Nc6 a3 Bf5 b4 Bb6 Bb2 Rfd8 Rd1 Rac8 O-O Ne7 Nd4 Bg6 Rc1 Rxc1 Rxc1 Nf5 Bf3 Kf8 Nb3 Nxe3 Bd4 Nc2 Bxb6 axb6 Bd1 Re8 Bxc2 Bxc2 Nd4 Bd3 f3 Bc4 Kf2 Re5 g4 g6 Rc3 Ke7 Re3 Kf6 h4 Rxe3 Kxe3 Ke5 f4+ Kd6 g5 Ke7 Nf3 Ke6 Nd4+ Ke7 Nf3 Ke6 Nd4+ Ke7";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "dd3e0bc46ed60690363a9bb4efab9e4a8c826dbfc67da1bb8456b24fcb2c458eb330e7669dc28ee140", hexOf(bytes));
        let (moves, facts) = summarise(rc, gt, bytes, Vector.length(movesOf(pgn)));
        Assert.assertEq(expected = pgn, moves);
        Assert.assertEq(expected = "9|96637965afff1bc865e804e396637965afff1bc865e804e3966379ef8a0b|e6e7", facts)
    }

    ///
    /// Scala "position hash compat" (lichess.org/DoqH1EQP): an 88-ply game whose
    /// hash stack is checked against the base64 blob the Scala suite stores.
    ///
    @Test
    pub def testPositionHashCompat(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nc6 Nc3 g6 Be3 Bg7 Bc4 Nf6 f3 O-O Qd2 Nd7 O-O-O a5 g4 Nce5 Be2 a4 a3 Nb6 h4 Nbc4 Bxc4 Nxc4 Qf2 Qb6 b3 Nxe3 Qxe3 e5 Nf5 Qxe3+ Nxe3 axb3 cxb3 Rxa3 Kb2 Ra6 h5 h6 hxg6 fxg6 Ned5 Rxf3 Ne7+ Kf7 Nxc8 Ke6 Nxd6 Rf2+ Kb1 Rxd6 Nd5 Rc6 Rc1 Rxc1+ Rxc1 Re2 Rc7 Rxe4 Nb6 Bf8 Rxb7 Rb4 Rb8 Rxb3+ Kc2 Rb5 Rxf8 Rxb6 Rg8 Kf6 Rf8+ Kg5 Rh8 Rd6 Re8 Kxg4 Rxe5 g5 Re3 Kf5";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "3c17f9367faecae36cdc9fd6b1b92fbe6563811ebc767712042bcc5ca0a7faae0286bb20b83fc9e7bbb985316b58e05ce0", hexOf(bytes));
        let (moves, facts) = summarise(rc, gt, bytes, Vector.length(movesOf(pgn)));
        Assert.assertEq(expected = pgn, moves);
        Assert.assertEq(expected = "2|a01f48d61d5ee980f2|g4f5", facts)
    }

    ///
    /// Scala "work with all black legal moves in YycayYfM": the same 61-ply prefix
    /// followed by each of the 25 legal replies in turn. This is the disambiguation
    /// stress case — `R8c7`/`R5c7`, `R8c6`/`R5c6`, `Re5+` and four king moves all
    /// have to round-trip, and each one gets a different rank out of the move list.
    ///
    @Test
    pub def testAllBlackLegalMoves(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let prefix = "e4 c6 Nf3 d5 exd5 cxd5 d4 Nc6 c3 Nf6 Bf4 Bg4 Be2 e6 Nbd2 Bd6 Bxd6 Qxd6 O-O O-O Re1 a6 Ne5 Bxe2 Qxe2 Nd7 Nxd7 Qxd7 a4 Rab8 Nf3 b5 axb5 axb5 Ne5 Nxe5 Qxe5 b4 c4 dxc4 Rac1 Rbc8 Qa5 Qb7 Re2 c3 bxc3 bxc3 Rec2 Qe4 Qe5 Qxe5 dxe5 Rc5 f4 Rfc8 Kf2 f6 exf6 gxf6 Ke3";
        let legals = legalReplies();
        let rs = legalReferences();
        def loop(i) =
            if (i >= Vector.length(legals)) ()
            else {
                let legal = Vector.get(i, legals);
                let pgn = "${prefix} ${legal}";
                let bytes = encodeOrFail(gt, pgn);
                let ref = Vector.get(i, rs);
                Assert.assertEq(expected = "${legal}: ${field(ref, 0)}", "${legal}: ${hexOf(bytes)}");
                let (moves, facts) = summarise(rc, gt, bytes, Vector.length(movesOf(pgn)));
                Assert.assertEq(expected = "${legal}: ${pgn}", "${legal}: ${moves}");
                Assert.assertEq(expected = "${legal}: ${dropField(ref)}", "${legal}: ${facts}");
                loop(i + 1)
            };
        loop(0)
    }

    ///
    /// Scala "work with CwdQG2Es" (lila#5594): `Rxc5 Raxc5`, where the second token
    /// needs file disambiguation between two rooks that can both capture on c5.
    ///
    @Test
    pub def testCwdQG2Es(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let pgn = "c4 e5 g3 h5 Nc3 h4 Bg2 Nf6 d3 Bb4 Bd2 d6 Nf3 h3 Bf1 Nc6 e3 Bg4 Be2 d5 Nxd5 Nxd5 cxd5 Qxd5 Bxb4 Nxb4 Qa4+ c6 Qxb4 Bxf3 Bxf3 Qxf3 Rg1 O-O-O Qe4 Qf6 O-O-O Rd5 f4 Rhd8 Rgf1 Qe6 Kb1 f5 Qc4 e4 d4 Kb8 Rc1 Qe7 Rg1 Qd7 Qc2 Re8 Qe2 Ra5 g4 g6 gxf5 gxf5 Qh5 Rd8 Qh6 c5 Rg7 Qa4 a3 Qb3 Qf6 Rc8 Qd6+ Ka8 Rxc5 Raxc5";
        let bytes = encodeOrFail(gt, pgn);
        Assert.assertEq(expected = "c8b2cdc7d9defb559f0955778cd095d4480ffb7e6dfb8efe3ab1f7896599e0ee56c7f1fe37fb1ee377d6bd5fbe4dd0", hexOf(bytes));
        let (moves, facts) = summarise(rc, gt, bytes, Vector.length(movesOf(pgn)));
        Assert.assertEq(expected = pgn, moves);
        Assert.assertEq(expected = "0|c0dec5|a5c5", facts)
    }

    ///
    /// The empty game: no bytes, no plies. `positionHashes` is the Polyglot hash of
    /// the starting position (`463b96`) and `lastUci` is `null`.
    ///
    @Test
    pub def testEmptyGame(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        Assert.assertEq(expected = Some(Vector#{}), GameEncoder.encode(gt, Vector#{}));
        let d = GameEncoder.decode(rc, gt, Vector#{}, 0);
        Assert.assertEq(expected = Vector#{}, DecodeResult.pgnMoves(d));
        Assert.assertEq(expected = 0, DecodeResult.halfMoveClock(d));
        Assert.assertEq(expected = "463b96", hexOf(DecodeResult.positionHashes(d)));
        Assert.assertEq(expected = None, DecodeResult.lastUci(d))
    }

    ///
    /// Decoding a prefix of a game gives exactly the prefix of its SAN tokens —
    /// including the `+`/`#` suffix on the last one, which `decode` only appends on
    /// the extra `i == plies` iteration. Checked at *every* prefix length of a game
    /// that contains a check, a promotion and a mate.
    ///
    @Test
    pub def testEveryPrefixDecodes(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        def check(pgn) = {
            let moves = movesOf(pgn);
            let bytes = encodeOrFail(gt, pgn);
            def loop(k) =
                if (k > Vector.length(moves)) ()
                else {
                    let d = GameEncoder.decode(rc, gt, bytes, k);
                    Assert.assertEq(
                        expected = joinMoves(Vector.slice(start = 0, end = k, moves)),
                        joinMoves(DecodeResult.pgnMoves(d)));
                    loop(k + 1)
                };
            loop(0)
        };
        // ends in `Qd1#`, and contains `b8=Q` and `Ba4+`
        check("e3 e5 Nc3 Nf6 Bc4 d5 Bb3 c5 Ba4+ Bd7 Bxd7+ Qxd7 d4 exd4 exd4 cxd4 Qxd4 Qe6+ Be3 Ne4 Nf3 Nxc3 Qxc3 Nc6 Nd4 Nxd4 Qxd4 a5 a3 b5 O-O Be7 Rad1 O-O Qxd5 Qxd5 Rxd5 b4 Rd7 Rfe8 axb4 Bxb4 c3 Be7 Rfd1 a4 Ra1 h6 Rd4 Bf6 Rdxa4 Rxa4 Rxa4 g5 g3 h5 Kg2 Kg7 h4 gxh4 gxh4 Bxh4 Rxh4 Kg6 b4 Re5 Bd4 Rg5+ Kf3 f5 c4 Rg4 Rxg4+ fxg4+ Kg3 Kg5 b5 h4+ Kg2 h3+ Kh2 Kh4 Be5 Kg5 b6 Kf5 Bg3 Ke4 b7 Kf3 b8=Q Ke2 Qd8 Kf1 Qd1#");
        // ends in `Qf7#`
        check("Nf3 f6 d3 e5 Nbd2 g5 e4 g4 Ng1 Bb4 Qxg4 d5 Qh5+ Kf8 a3 dxe4 axb4 exd3 Bxd3 e4 Bc4 f5 Qf7#")
    }

    ///
    /// The two `return null` paths in the Scala, plus the SAN shapes that sit right
    /// on the edge of the pattern: a bare square is a legal SAN token but names no
    /// legal move here, `Ke2` needs the `([1-8])?` group abandoned, and a castling
    /// token in a position with no back-rank rook is rejected by the move search.
    ///
    @Test
    pub def testEncodeRejectsIllegalInput(): Unit \ Assert = {
        let gt = GameTables.mk();
        // not SAN at all
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"e4", "xyz"}));
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{""}));
        // SAN, but no such legal move
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"a1"}));
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"e4", "O-O"}));
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"Ke2"}));
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"e4", "e5", "Nf3", "Nf3"}))
    }

    // ---------------------------------------------------------- reference data

    /// The Scala suite's `fixtures` list, verbatim.
    def fixtures(): Vector[String] = Vector#{
        "d3 d5 g3 e6 Bg2 Nf6 Nf3 Be7 O-O O-O Re1 a6 e4 c5 e5 Nfd7 d4 Nb6 dxc5 Bxc5 Nc3 N8d7 a4 Be7 a5 Nc4 b3 Ncxe5 Nxe5 Nxe5 Rxe5 Bd6 Re1 Bd7 Bf4 Bc6 Bxd6 Qxd6 Na4 Rad8 Nb6 Rfe8 Ra4 Bxa4 bxa4 Qc5 Qa1 Qxa5 Qd4 Rd6 Nc4 Qb4 Nxd6 Qxd4 Nxe8 Qd2 Rb1 Qxc2 Rxb7 Qxa4 Rb8 Kf8 Nd6+ Ke7 Nf5+ Kf6 Nh4 Qd1+ Bf1 Qd4 Kg2 a5 Rb7 a4 Rxf7+ Kxf7 Nf3 Ke7 Ne5 Kd6 Nf3 Qc4 Nd4 Qc3 Nf5+ Ke5 Ne3 Kf6 Nxd5+ exd5",
        "e4 e6 Nf3 c5 g3 a6 Bg2 Nc6 O-O d6 h3 Be7 Nc3 Qc7 d4 cxd4 Nxd4 Nxd4 Qxd4 Bf6 Qd1 e5 Nd5 Qc6 Nxf6+ Nxf6 Re1 O-O Bg5 Nd7 f4 exf4 Bxf4 Ne5 Bxe5 dxe5 a3 Be6 b4 Rad8 Qe2 Rd4 Rad1 Rfd8 Rxd4 Rxd4 c3 Rc4 Qc2 f6 Rd1 Qc7 a4 Rxb4 Rc1 Rc4 Bf1 Rc5 c4 Qb6 Qd2 Rxc4+ Kh1 Rxc1 Qxc1 Qc6 Qd1 Qxe4+ Bg2 Qd4 Qc1",
        "e4 g6 Nf3 Bg7 d4 e6 Nc3 Ne7 Be3 O-O Be2 d6 O-O b6 Qd2 Bb7 Bh6 c5 Bxg7 Kxg7 dxc5 bxc5 Rad1 d5 exd5 exd5 Rfe1 d4 Nb5 a6 Na3 Kg8 c3 Nbc6 cxd4 cxd4 Nxd4 Nxd4 Qxd4 Qxd4 Rxd4 Nc6 Rd7 Rab8 Red1 Ne5 Re7 Nc6 Rc7 Nb4 Rdd7 Be4 Bc4 Bd5 Bxd5 Nxd5 Rxd5 Rxb2 Rc2 Rfb8 f3 Rxc2 Nxc2 Rb2 Rd8+ Kg7 Rc8 Rxa2 Nb4 Ra4 Nd5 Ra1+ Kf2 a5 Kg3 a4 Ra8 a3 Nc3 Rc1 Nb5 Rb1 Nxa3 Ra1",
        "e4 g6 d4 Bg7 e5 e6 f4 Ne7 Nf3 d5 Nc3 O-O Be3 Nd7 Bd3 b6 Nb5 c5 Nd6 cxd4 Nxd4 Nxe5 fxe5 Bxe5 Nxc8 Rxc8 O-O Nc6 Nxc6 Rxc6 c3 Bc7 Bd4 Qd6 Qg4 Qxh2+ Kf2 e5 Rh1 Qf4+ Qxf4 exf4 Rh6 Re6 Rah1 f5 Rxh7 Bd8 Rh8+ Kf7 R1h7+ Ke8 Bb5+ Rc6 Bxc6#",
        "e4 c5 Nf3 Nc6 Bc4 Nf6 Nc3 e5 O-O d6 a3 Nd4 Nxd4 exd4 Nd5 Be6 Nxf6+ Qxf6 Bxe6 Qxe6 c3 d3 Qa4+ Ke7 e5 d5 Re1 c4 Qb4+ Kd7 Qxb7+ Ke8 Qxa8+ Kd7 Qxa7+ Kc8 b3 Qf5 bxc4 dxc4 Qa8+ Kc7 Rb1 Bc5 Rb7+ Kc6 Qa6+ Kd5 Rf1 Re8 Rc7 Rxe5 Qc6#",
        "b3 d5 Bb2 Nf6 g3 e5 Bg2 Nc6 d3 Be6 e3 Qd6 Nd2 O-O-O Ne2 g6 c4 dxc4 bxc4 Bg7 O-O Nd7 d4 exd4 exd4 Nb4 Ne4 Qe7 d5 Bg4 Bxg7 Rhg8 Bc3 Bxe2 Qxe2 f5 Bxb4 Qxb4 Rab1 Qa3 Nc3 Rde8 Qb2 Qa6 Qb5 Qa3 Qb4 Qa6 a4 Nb6 Qb5 Qxb5 axb5 Nxc4 d6 Nd2 Bxb7+ Kxb7 Rbe1",
        "e4 d5 exd5 Qxd5 Nc3 Qd8 Nf3 Nf6 d4 g6 Bc4 Bg7 Bg5 O-O O-O Be6 Bxe6 fxe6 Re1 Nc6 d5 e5 dxc6",
        "e3 e5 Nc3 Nf6 Bc4 d5 Bb3 c5 Ba4+ Bd7 Bxd7+ Qxd7 d4 exd4 exd4 cxd4 Qxd4 Qe6+ Be3 Ne4 Nf3 Nxc3 Qxc3 Nc6 Nd4 Nxd4 Qxd4 a5 a3 b5 O-O Be7 Rad1 O-O Qxd5 Qxd5 Rxd5 b4 Rd7 Rfe8 axb4 Bxb4 c3 Be7 Rfd1 a4 Ra1 h6 Rd4 Bf6 Rdxa4 Rxa4 Rxa4 g5 g3 h5 Kg2 Kg7 h4 gxh4 gxh4 Bxh4 Rxh4 Kg6 b4 Re5 Bd4 Rg5+ Kf3 f5 c4 Rg4 Rxg4+ fxg4+ Kg3 Kg5 b5 h4+ Kg2 h3+ Kh2 Kh4 Be5 Kg5 b6 Kf5 Bg3 Ke4 b7 Kf3 b8=Q Ke2 Qd8 Kf1 Qd1#",
        "Nf3 f6 d3 e5 Nbd2 g5 e4 g4 Ng1 Bb4 Qxg4 d5 Qh5+ Kf8 a3 dxe4 axb4 exd3 Bxd3 e4 Bc4 f5 Qf7#",
        "e4 d5 exd5 Qxd5 Nc3 Qa5 b3 c6 Bb2 Nf6 Be2 Bf5 Nf3 e6 O-O Nbd7 a3 Qc7 a4 Bd6 d3 Ng4 h3 Ngf6 Ne4 Nxe4 dxe4 Bg6 Bd3 f6 Nh4 Bf7 g3 Qb6 Kg2 g5 Nf3 h5 Nh2 Qc7 Qf3 Ne5 Qxf6 Nxd3 Qxh8+ Kd7 Qg7 Nxb2 Qxf7+ Kc8 Qe8+ Qd8 Qxe6+ Kc7 Qf7+ Be7 Qxh5 Qd2 Qf7 Qd6 Rfb1 Rf8 Qg7 Qf6 Qxf6 Bxf6 Ra2 c5 Raxb2 Bxb2 Rxb2 Rd8 c4 Rd3",
        "e4 c6 e5 d6 exd6 exd6 d4 g6 Bd2 Bg7 Bc3 Ne7 Bc4 Be6 b3 b5 Bxe6 fxe6 d5 Nxd5 Bxg7 Rg8 Bh6 Qf6 c3 Nd7 Qf3 O-O-O Ne2 Qxf3 gxf3 Ne5 Nd4 Rde8 f4 Nd3+ Kf1 Kb7 Nd2 N5xf4 Bxf4 Nxf4 Ne4 Rgf8 Nxd6+ Kb6 Nxe8 Rxe8 Re1 c5 Rxe6+ Nxe6 Nxe6 Rxe6 Rg1 a5 Rg4 Kc6 Rg5 Kd6 Kg2 Re5 Rg4 h5 Rxg6+ Kd5 Ra6 c4 Rxa5 Kc6 b4 Rg5+ Kf1 Rg8 Ra6+",
        "f4 d5 Nf3 Nc6 e3 e6 Bb5 Nf6 d3 Bd7 O-O a6 Ba4 b5 Bb3 Bd6 c3 O-O Bc2 h6 e4 dxe4 dxe4 Be7 e5 Nd5 Qd3 g6 f5 exf5 Bxh6 Re8 Qxd5 Be6 Qxd8 Raxd8 Nbd2 Rd5 Rae1 Bc5+ Kh1 Red8 Nb3 Bb6 Bg5 R8d7 Bf6 a5 Rd1 a4 Nc1 Be3 Nd3 Na5 Nb4 Rxd1 Rxd1 Rxd1+ Bxd1 Nc4 Nd3 Na5 Bd8 Bb6 a3 Bc4 Nb4 Kf8 Nd4 Ke8 Bf6 Bxd4 cxd4 Kd7 d5 Nb7 Bf3 Nc5 Nc6 Nd3 Na5 Nxb2 Nxc4 bxc4 e6+ fxe6 Bxb2 exd5 Bxd5 Kd6 Bxc4 g5 Bb5 c6 Bxa4 Kd5 Bc2 f4 Bc1 Ke5 Kg1 c5 Kf2 g4 g3 f3 Be3 Kd5 Bf4 c4 a4 Kc5 Be5 Kb4 a5",
        "e4 e5 Nc3 Nf6 d3 c6 f4 exf4 Bxf4 d5 e5 d4 Nce2 Nd5 Bd2 c5 c4 Ne3 Bxe3 dxe3 Nf3 Be7 Nc3 Bg4 Be2 O-O O-O Nc6 Nd5 Nd4 Nxd4 cxd4 Bxg4 Bc5 e6 fxe6 Bxe6+ Kh8 Rxf8+ Qxf8 Qf3 Qd6 Bf5 Rf8 Qe4 g6 Bg4 a5 Bf3 Ba7 a3 Bb8 g3 Ba7 b4 h5 c5 Qd7 Qxg6 Qh7 Qxh7+ Kxh7 Bxh5 Bb8 Rf1 Rd8 Nf6+ Kh6 g4 Kg5 Kg2 axb4 axb4 Rc8 Ne4+ Kh6 Rf6+ Kg7 g5 Be5 Rf7+ Kg8 Rxb7 Rf8 Bf3 Ra8 Ng3 Ra2+ Ne2 Bf4 h4 Kf8 b5 Rd2 c6 Rxd3 b6",
        "d4 d5 h3 e6 a3 Nf6 Nf3 b6 e3 c5 c4 cxd4 Qxd4 Nc6 Qd1 Be7 cxd5 Nxd5 Bb5 Bb7 Bxc6+ Bxc6 e4 Nf6 Qxd8+ Rxd8 Nc3 O-O e5 Bxf3 gxf3 Nd5 Nxd5 Rxd5 f4 f6 Be3 fxe5 fxe5 Rxe5 O-O-O Bf6 Kb1 Rb5 Rd2 Rd8 Rhd1 Rf8 Ka2 a5 Rd6 e5 b4 axb4 axb4 Ra8+ Kb3 Be7 Rxb6 Rxb6 Bxb6 Rb8 Ba5 Rb5 Ka4 Rb7 Re1 Bd6 Rd1 Rd7 Rc1 Kf7 Rg1 g6 h4 Ke6 Rg5 Rf7 Bb6 Rf4 h5 Kf6 Rg2 gxh5 Ba5 Rg4 Rh2 h4 f3 Rf4 Rh3 Kf5 Kb5 e4 fxe4+ Kxe4 Kc6 Be5 b5 Rf6+ Kd7 Rd6+ Ke7 Rd5 Rxh4+ Kf3 Rb4 Bd6+ Ke6 Bxb4 Kxd5 Bxa5 Kc6 h5 Kb7 h4 Ka6 Bd8 b6 Bxb6 Kxb6 h3",
        "d4 d5 c4 c5 e3 e6 cxd5 cxd4 dxe6 dxe3 Qxd8+ Kxd8 exf7 exf2+ Kxf2 Nf6 Bg5 Be6 Nf3 Bxf7 Nc3 Be7 Be2 Nc6 Rhd1+ Kc7 Bf4+ Kc8 Bb5 Bc5+ Kf1 Nb4 a3 Nc2 Rac1 Ne3+ Bxe3 Bxe3 Rc2 a6 Re2 axb5 Rxe3 Bc4+ Kg1 Re8 Rxe8+ Nxe8 Ne5 h6 Nxc4 bxc4 Rd4 b5 Nxb5 Kb7 Nd6+ Kb6 Nxc4+ Kc5",
        "e4 e5 Bc4 Qf6 d3 Bc5 Qf3 d6 Nc3 c6 Bg5 Qxf3 Nxf3 h6 Bh4 g5 Bg3 Nf6 h4 g4 Nd2 h5 f3 Nbd7 fxg4 Nxg4 Rf1 Ndf6 Nf3 Be6 Ng5 Bxc4 dxc4 O-O-O Bf2 Nxf2 Rxf2 Bxf2+ Kxf2 Ng4+ Kg1 Rdf8 Rf1 f6 Ne6 Kd7 Nxf8+ Rxf8 Rf5 Ke6 Rxh5 Ne3 Rh7 Nxc4 b3 Ne3 Rxb7 Nxc2 Rxa7 Rh8 g3 Rg8 Kh2 Ne3 Ra6 c5 Nb5 Rd8 h5 Ng4+ Kh3 f5 exf5+ Kxf5 Rxd6 Rxd6 Nxd6+ Kg5 a4 Nf6 a5 Nd7 Ne4+ Kxh5 a6 Kg6 a7 Nb6 Nxc5 Kf5 Nd7 e4 Nxb6 e3 a8=Q e2 Qf3+",
        "e4 c6 Bc4 d5 exd5 cxd5 Bb3 Nf6 c3 Nc6 d3 e5 h3 Bd6 Ne2 Be6 O-O O-O f4 e4 dxe4 Nxe4 Nd4 Kh8 f5 Nxd4 cxd4 Bd7 Bxd5 Bc6 Bxc6 bxc6 Nc3 Nxc3 bxc3 c5 d5 c4 Be3 Re8 Bd4 Be5 Bxe5 Rxe5 Qd4 Qb6 Qxb6 axb6 d6 Rd5 Rf4 b5 Rd4 Rxd4 cxd4 Rd8 Rb1 g6 Rxb5 Rxd6 fxg6 fxg6 Rc5 Rxd4 a4 c3 a5 Ra4 Rxc3 Rxa5 g4 Ra2 Rc7 h5 Rc6 Kg7 gxh5 gxh5 Rc4 Kg6 h4 Kf5 Rc5+ Kg4 Rc4+ Kg3 Re4 Ra1+ Re1 Rxe1#",
        "e4 e5 Nf3 Nc6 Bb5 Nf6 Bxc6 dxc6 d3 Bd6 O-O O-O Nbd2 b5 Qe2 a5 h3 Bd7 a4 b4 b3 c5 Nc4 Be7 Ncxe5 Be6 Bb2 Qc8 Rad1 h6 Kh2 Re8 Ng1 Nh7 f4 f6 Nef3 Bf7 f5 Bd6+ Kh1 c6 Bc1 Bc7 Qf2 Bh5 g4 Bf7 Nh4 Ng5 Bf4 Bxf4 Qxf4 Re7 Ng2 Qc7 Qxc7 Rxc7 h4 Nh7 Kh2 Re8 Kg3 Rd7 Nf4 Nf8 Nf3 Red8 g5 hxg5 hxg5 fxg5 Nxg5 Be8 Rh1 g6 Rh6 Kg7 Rdh1 Kf6 Nf3 Rg7 Kg4 Ke7 e5 Kd7 f6 Rf7 e6+ Kc7 exf7 Bxf7 Rh7 Rd7 Rxf7 Rxf7 Kg5 Kd6 Ne6",
        "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 e5 Nb3 a6 Nc3 b5 Nd5 Bb4+ c3 Bf8 Be3 Nf6 h3 Nxe4 Bd3 f5 Bxe4 fxe4 O-O Be7 Bc5 Bxc5 Nxc5 d6 Nxe4 Be6 Ne3 O-O Qxd6 Qxd6 Nxd6 e4 a3 Ne5 Nxe4 Nd3 Rad1 Nxb2 Rd2 Nc4 Nxc4 Bxc4 Nd6 Bxf1 Kxf1 Rad8 Ne4 Rxd2 Nxd2 Rc8 c4 bxc4 Ne4 c3 Nd6 c2 Ne4 c1=Q+ Ke2 Rc2+ Kf3",
        "d4 b6 e4 Bb7 Ba6 g6 Bxb7 Na6 Bxa8 Qxa8 Nc3 c6 Qe2 b5 Nf3 Qb7 O-O b4 Nd1 c5 dxc5 Nxc5 c3 Qxe4 Qxe4 Nxe4 Ne3 bxc3 bxc3 Nxc3 Bb2 Ne2+ Kh1 f5 Rfe1 Nf4 g3 Nh5 Ng5 Bh6 f4 Bxg5 fxg5 h6 Nd5 hxg5 Bxh8 Kf7 Bb2 e6 Nc3 Ngf6 Rad1 Ne4 Nxe4 fxe4 Rxd7+ Ke8 Rxa7 Nxg3+ hxg3 g4 Rc1 g5 Rc8#",
        "g3 c5 Bg2 d6 Nf3 e6 O-O Nf6 d3 Be7 Nbd2 h6 b3 a6 Bb2 Nbd7 Ne4 Nxe4 dxe4 Rb8 e5 d5 Nd2 b6 c4 dxc4 Nxc4 b5 Nd6+ Kf8 Bc6 Bb7 Bxb7 Qc7 Bg2 Bg5 Ne4 Be7 f4 Nb6 Rc1 Rd8 Qc2 Nd5 Nxc5 Ne3 Nxe6+ fxe6 Qxc7 Nxf1 Rxf1",
        "e4 b6 d3 Bb7 Nc3 d6 Be3 e5 Nf3 f6 Be2 g5 O-O h5 Qd2 g4 Ne1 Qd7 f3 Bh6 fxg4 Bxe3+ Qxe3 hxg4 Qg3 Qh7 Bxg4 Nh6 h3 Nxg4 Qxg4 Qg8",
        "e4 e6 Nf3 c6 Nc3 d5 exd5 cxd5 d4 Nf6 Bd3 Be7 Ne5 O-O O-O Nbd7 f4 a6 Kh1 b5 a3 Bb7 Qf3 h6 Qg3 Nh7 Ng4 f5 Nxh6+ Kh8 Qg6 gxh6 Qxe6 Rf6 Qe2 Rg6 Bxf5 Rg7 Qe6 Ndf6 Re1 Bd6 Qe3",
        "c4 c6 Nc3 e6 e4 Nf6 Nf3 Be7 d4 d5 cxd5 exd5 e5 Nfd7 Bd3 Na6 a3 Nc7 O-O Nb6 h3 Be6 Re1 Nd7 Qc2 c5",
        "e4 c6 d3 d5 Nc3 dxe4 dxe4 Nd7 Nf3 Ngf6 Bd3 e6 O-O Bd6 Re1 Qc7 Bg5 Ng4 g3 h6 Bd2 Nde5 Nxe5 Nxe5 Bf4 Nxd3 Bxd6 Qxd6 Qxd3 Qxd3 cxd3 O-O Kf1",
        "e4 e5 Qf3 Nf6 a4 Nc6 a5 Nxa5 Rxa5 c6 Rxe5+ Be7 Qg3 d6 Rxe7+ Qxe7 Qxg7 Rg8 Qh6 Qxe4+ Kd1 Bg4+ f3",
        "e4 e6 Nf3 d5 e5 c5 d3 Nc6 Nbd2 Nge7 b3 Ng6 Bb2 Qc7 Qe2 Be7 O-O-O O-O Ne4 dxe4 Qxe4 b5 d4 c4 bxc4 bxc4 Bxc4 Na5 Bd3 Bb7 Nh4 Bxe4 Bxe4 Rac8",
        "e4 e5 Nf3 Bc5 c3 f6 d4 Be7 Be3 Nc6 Nbd2 Nxd4 cxd4 exd4 Nxd4 Bb4 Be2 Qe7 O-O c5 Nf5 Qe5 Nc4 Qxe4 Nxg7+ Kd8 Qd6 Ne7 Ne6+ Ke8 Nc7+ Kf8 Bh6+ Kf7 Bh5+ Ng6 Bxg6+ Kxg6 Bf4 Qxc4 Nxa8 Qf7 Qd3+ f5 Qd6+ Qf6",
        "d4 d5 Bg5 Nd7 g3 Ngf6 Bh3 e6 Nc3 Be7 Bxf6 Nxf6 e3 a6 Nge2 b5 O-O O-O Qb1 c5 dxc5 Bxc5 b4 Bb6 a4 Bb7 a5 Bc7 Nd1 e5 c3 e4 f4 Bc8 Bxc8 Rxc8 Nd4 Bb8 Nf2 Qd7 Ra3 Ng4 Nxg4 Qxg4 Rf2 h5 Kg2 h4 Raa2 h3+ Kh1 Ba7 Rac2 Bxd4 cxd4 Rxc2 Qxc2 Rc8 Qb2",
        "d4 d5 f3 e6 Nh3 f5 g3 Nf6 e3 Be7 f4 c5 Qd2 cxd4 Qxd4 Nc6 Qd2 Bd7 Nc3 O-O Qe2 d4 Bd2 dxc3 Bxc3 b6 O-O-O Bc5 Kb1 b5 Bd4 Bxd4 exd4 Be8 c4 Bf7 d5 Ne7 d6 Nc6 cxb5 Nb8 d7 a6 Rc1 Nfxd7 Qd2 Nf6 Qxd8 Rxd8 bxa6 Nbd7 Bb5 Rxa6 Bxa6 Nc5 Bc4 Rc8 b4 Nce4 Bb3 Rd8 Rhd1 h6 Rxd8+ Kh7 Rdd1 Kg6 Rg1 Nd7 Rgf1 Nb6 Nf2 Nd6 Nd3 Nb5 Nc5 Nd5 Bxd5 exd5 Nd7 d4 Ne5+ Kf6 Nxf7 Kxf7 Rfd1 Nc3+ Rxc3 dxc3 Rc1 c2+ Rxc2 Kg6 Rc5 Kf6 h3 g6 Rc6+ Kf7 g4 fxg4 hxg4 g5 fxg5",
        "e4 e5 Nf3 Nc6 Bb5 d6 Bxc6+ bxc6 d4 Nf6 dxe5 dxe5 Qxd8+ Kxd8 Nxe5 Bd6 Nxf7+ Ke8 Nxh8 Bb7 f4 Ke7 e5 Bb4+ Nc3 Bxc3+ bxc3 Ne4 O-O Nxc3 Bd2 Ne2+ Kh1 Rxh8 f5 Rf8 Rae1 Nd4 Bg5+ Ke8 f6 g6 e6 Nf5 e7 Rf7 g4 Nxe7 Rxe7+ Kf8 Rxf7+ Kxf7 Re1 c5+ Kg1 Bd5",
        "e4 e6 c4 d5 exd5 exd5 cxd5 Nf6 b3 Nxd5 Bb2 Nf6 Nf3 Be7 Be2 O-O O-O h6 Re1 Re8 d4 Nbd7 Nc3 Nb6 Qc2 c6 Rad1 Nbd5 Ne5 Be6 Bd3",
        "e4 e5 Nc3 d6 Bc4 f5 exf5 Bxf5 d4 e4 d5 Nf6 Nge2 Nbd7 Ng3 Bg6 h4 Ne5 Be2 Bf7 h5 g6 h6 Nfg4 Be3 Nxe3 fxe3 Qf6 Qd2 Qe7 O-O-O O-O-O Rdf1 a6 Rf2 Be8 Rhf1 Bd7 Ngxe4 Ng4 Bxg4 Bxg4 Nf6 Bxh6 Nxg4 Bg5 Qe2 Rhe8",
        "d4 d5 Nf3 Nf6 e3 Bg4 h3 Bh5 g4 Bg6 Ne5 Nbd7 Nxg6 hxg6 Bg2 e6 a3 Nb6 g5 Nh5 e4 c6 exd5 Nxd5 Bxd5 cxd5 Nd2 Qxg5 Nf3 Qd8 Bg5 Be7 Bxe7 Qxe7 Qd3 O-O O-O-O Rac8 Ne5 Qc7 Rhg1 Nf4 Qd2 Nxh3 Rg3 Nxf2 Qxf2 Qb6 c3 Qb3 Kb1",
        "e4 c6 Nc3 d6 d4 g6 f4 Bg7 Nf3 Nf6 Bd3 O-O O-O Bg4 Qe1 Nbd7 Be3 c5 Rd1 cxd4 Bxd4 Qa5 h3 Bxf3 Rxf3 e5 Be3 exf4 Bxf4 Ne5 Bxe5 dxe5 Nd5 Qxe1+ Rxe1 Nxd5 exd5 f5 Bc4 e4 Rb3 b6 d6+ Kh8 d7 Rad8 Bb5 a6 Bc6 b5 Rd1 Rf6 Kf2 Rxc6 a4 Rc7 axb5 Rdxd7 Rxd7 Rxd7 bxa6 Bd4+ Ke2 Ra7 Rb8+ Kg7 Rb7+ Rxb7 axb7 Ba7 c4 Kf7 b4 Ke7 c5 Kd7 b5 Kc7 c6 Bb8 Ke3 Kb6 Kd4 Kxb5 Kd5 Kb6 Ke6 Kxc6 Kf7 f4 Kg7 e3 Kxh7 e2 Kxg6 e1=Q Kg5 Qg3+ Kf5 Qxg2 h4 f3",
        "e3 e6 b3 d5 Bb2 c5 h3 Nf6 g4 Bd6 h4 d4 h5 dxe3 dxe3 Nc6 h6 g6 g5 Rg8 Bxf6 Qb6 Nc3 e5 Nd5 Qa5+ Qd2 Qa3 Nf3 Nb4 Rd1 Be6 Bb5+ Nc6 Bxc6+ bxc6 Nc3 Be7 Ne4 Bxf6 Nxf6+ Ke7 Nxg8+ Rxg8 Qd7+ Kf8 Qd8#",
        "Nc3 Nf6 e4 d5 e5 d4 exf6 dxc3 fxg7 cxd2+ Qxd2 Qxd2+ Bxd2 Bxg7 O-O-O O-O Ne2 Nc6 Bc3 Bg4 f3 Bf5 Bxg7 Kxg7 Ng3 Bg6 Bd3 Rad8 Be4 Bxe4 Nxe4 b6 h4 e6 c3 Ne5 Rh3 Rxd1+ Kxd1 Rd8+ Kc2 f6 h5 Kf7 Rg3 Nc4 f4 Nd6 Nxd6+ cxd6 Kd3 f5 Rg5 Rg8 Kd4 e5+ Kd5",
        "e4 d5 exd5 Qxd5 Nc3 Qd7 Bc4 e6 Nf3 Bd6 O-O h6 d4 c6 Ne5 Bxe5 dxe5 Qxd1 Rxd1 Ne7 b4 O-O Rd3 b5 Rg3 Nf5 Rg4 bxc4 Ne4 Nd7 Rb1 Ba6 a4",
        "d4 d5 Nf3 Nd7 c3 e6 Bf4 Ngf6 e3 c5 Bd3 c4 Bc2 b5 Nbd2 b4 Qe2 a5 e4 a4 O-O dxe4 Nxe4 Ba6 Nd6+ Bxd6 Bxd6 b3 Bb1 Nd5 Re1 Ne7",
        "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6 Bc4 Bg7 f3 O-O Be3 Nc6 Qd2 Bd7 O-O-O Rc8 Bb3 a6 g4 Ne5 Rdf1 Nc4 Bxc4 Rxc4 Bh6 b5 Bxg7 Kxg7 g5 Nh5 b3 Rc5 f4 Qc7 Nd5 Rxd5 exd5 Rc8 f5 Qc3 Qxc3 Rxc3",
        "e3 Nf6 d4 g6 c4 Bg7 Nc3 d6 Nf3 O-O Be2 Bg4 h3 Bxf3 Bxf3 c6 O-O d5 Bd2 dxc4 Be2 b5 b3 cxb3 axb3 Nd5 Nxd5 Qxd5 Qc2 c5 dxc5 Bxa1 Bxb5 Bg7 Bc4 Qc6 Rd1 Qxc5 Bxf7+ Rxf7 Qxc5 Nd7 Qc7 Nf6 Rc1 Raf8 f3 Nd5 Qc5 Rf5 Qd4 Bxd4 exd4 Nf4 Bxf4 Rxf4 Rc4 R4f7 Ra4 Rf6 Rxa7 Rb6 Ra3 Rd8 Ra4 Rxb3 Kf2 Rd3 d5 R3xd5 Re4 e5 Kg3 Kf7 f4 exf4+ Rxf4+ Ke6 Re4+ Re5 Rf4 Rf5 Rg4 Kf6 Kh2 Rd3 Rd4 Rf2 Rd6+ Rxd6 Kg3 Rdd2 Kh4 Rxg2",
        "e4 e6 d4 d5 exd5 exd5 Nf3 Nf6 Be2 h6 Nc3 c6 Bd2 Bf5 a3 Bd6 Nh4 Bh7 Be3 Ne4 Nxe4 dxe4 g3 O-O Ng2 f5 Bc4+ Kh8 Nf4 Qb6 Bb3 a5 O-O Nd7 Ne6 Rf6 d5 c5 c4",
        "c4 e5 e4 Nc6 d3 a6 Nf3 d6 a3 Bg4 Be2 Qf6 O-O h5 Nc3 Be6 Nd5 Bxd5 cxd5 Nd4 Nxd4 exd4 Bxh5 g6 Bf3 O-O-O Bg4+ Kb8 b4 Bh6 b5 a5 Bd2 b6 Bxh6 Rxh6 a4 Ne7 Qc2 Qe5 h3 f5 Bf3 f4 Bg4",
        "e4 c6 Nf3 d5 exd5 cxd5 d4 Nc6 c4 dxc4 Bxc4 e6 O-O Nf6 Re1 Bb4 Nc3 O-O Bd2 a6 a3 Ba5 b4 Bb6 Be3",
        "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 e5 Nxc6 bxc6 Nc3 Bc5 Be3 Bxe3 fxe3 Qh4+ g3 Qd8 Qd2 Nf6 O-O-O O-O h3 a5 g4 h6 Qg2 Qb6 g5 Qxe3+ Kb1 hxg5 Be2 Rb8 h4 Qxc3 b3 a4 Bc4 a3 Kc1 Qa1+ Kd2 Qxa2 hxg5 Nh7 Qh3 Re8 Qxh7+ Kf8 Qh8+ Ke7 Qxg7 Rf8 Qf6+ Ke8 g6 fxg6 Rh8 Rxh8",
        "e4 e5 Nf3 Nf6 Bc4 Bc5 O-O O-O Nxe5 Nxe4 Re1 Qe8 d4 Bb4 Rxe4 d6 Bxf7+ Rxf7 Nxf7 Qxf7 Qe2 Qg6 Re8+ Kf7 Qe7#",
        "e4 g6 d4 d6 Nf3 Bg7 Be3 b6 c4 Ba6 b3 e6 Nc3 Ne7 Bd3 c5 d5 Bxc3+ Nd2 Bxa1 Qxa1 exd5 Qxh8+ Kd7 Qf6 dxc4 bxc4 Ng8 Qxf7+ Kc6 Qd5+ Kd7 e5 Nc6 Qxd6+ Kc8 Qxc6+ Qc7 Qe6+ Kb8 Be4 Bb7 Qxg8+ Qc8 Qxc8+ Bxc8 Bxa8 Kxa8 O-O Be6 f4 Kb7 g4",
        "e4 e6 d4 d5 e5 Nc6 c3 g6 Nf3 Bh6 Bxh6 Nxh6 Bd3 O-O Qd2 Nf5 h4 Qe7 h5 g5 Bxf5 exf5 Nxg5 f6 Nf3 Qg7 g3 f4 Qxf4 fxe5 Qg5 Qxg5 Nxg5 exd4 cxd4 Nxd4 Na3 Nf3+ Kf1 Nxg5 Kg2 Bh3+ Rxh3 Nxh3 Kxh3 Rxf2 b3 c5 Nb5 c4 bxc4 dxc4 Rc1 Rxa2 Rxc4 Ra5 Nd6 Rxh5+ Kg4",
        "e4 e6 d4 d6 Nc3 Nd7 Nf3 Ne7 Bd3 Ng6 Be3 Be7 Qd2 c6 O-O-O O-O h4 b5 h5 Nh8 Kb1 a5 e5 d5 Bh6 Re8 Rh3 f5 exf6 Nxf6 Rg3 Bf8 Ne5 Nf7 Nxf7 Kxf7 Bg5 h6 Bg6+ Kg8 Bxe8 Qxe8 Bxf6 Qxh5 Qf4 Qf5 Qxh6 Kf7",
        "d4 d6 e4 e5 dxe5 dxe5 Qxd8+ Kxd8 Nf3 Nc6 Bb5 Bd7 Nc3 f6 O-O g5 h3 h5 a3 a6 Bxc6 Bxc6 Rd1+ Ke8 Nd5 Bd6 c4 Ne7 Nxf6+ Kf7 Nd5 g4 Ng5+ Ke8 h4 Ng6 Nf6+ Ke7 Nd5+ Bxd5 cxd5 Nf4 Bxf4 exf4 Ne6 c6 Rac1 f3 g3 Rh6 Ng5 cxd5 exd5 Bc7 Re1+ Kd6 Rcd1 Bd8 Re6+ Rxe6 Nxe6",
        "e4 d5 exd5 Qxd5 Nc3 Qe5+ Qe2 Qxe2+ Bxe2 Bf5 Nd5 Kd8 c3 c6 Ne3 e6 Nxf5 exf5 Nf3 g6 Bc4 Ke7 O-O Nf6 Re1+ Kd7 Ne5+ Kc7 Nxf7 Rg8 Ng5 Rh8 Ne6+ Kc8 d3 Nbd7 Bg5 Be7",
        "e4 e5 Nf3 d6 d4 exd4 Qxd4 Nf6 Nc3 Nc6 Bb5 Bd7 Bxc6 Bxc6 O-O Be7 Re1 O-O Bf4 Nd7 Qd2 Bf6 Nd4 Ne5 Bxe5 Bxe5 Nxc6 bxc6 Rab1 g6 Ne2 Qh4 f4 Bg7 g3 Qf6 c3 a6 Nd4 c5 Nf3 Rab8 Re2 a5 Rc1 a4 a3 Rb3 Rc2 Rfb8 Qd5 Qe6 Qd3",
        "e4 e5 Nc3 Qe7 Bc4 c6 d3 h6 Nge2 a5 a3 g5 Ng3 Bg7 Nf5 Qf6 O-O d6 Bd2 Bxf5 exf5 Qxf5 Ne4 d5 Nd6+ Kd7 Nxf5 Nf6 Nxg7 dxc4 dxc4 Kc8 Nf5 Nbd7 Bc3 Rd8 Nd6+ Kb8 Nxf7 Rf8 Nxe5",
        "e4 e6 d4 c5 d5 exd5 Qxd5 d6 Bc4 Be6 Qd3 d5 exd5 Bxd5 Bxd5 Nf6 Bxb7 Qxd3 cxd3 Bd6 Bxa8 O-O Bf3 Nbd7 Nh3 Ne5 Be2 Rb8 Nc3 a6 O-O Nc6 b3 Nb4 Bb2 Nc2 Rac1 Nd4 Ne4 Nxe2+ Kh1 Nxc1 Rxc1 Nxe4 dxe4 Re8 f3 f6 Nf2 Rc8",
        "e4 c5 b3 Nc6 Bb2 d6 Bb5 Nf6 Qe2 e5 f4 a6 Bxc6+ bxc6 fxe5 dxe5 Nf3 Bd6 O-O O-O d3 Re8 Nbd2",
        "g3 d5 Bg2 e6 e4 Nf6 exd5 exd5 d4 Nc6 c3 Be6 h3 Be7 Bf3 Qd7 g4 O-O-O Ne2 a6 Nf4 Bd6 Be3 Rde8 Nd2 g5 Ng2 h6 h4 gxh4 Nxh4",
        "b4 e6 Bb2 d5 a3 Nf6 e3 Be7 Bxf6 O-O Bxe7 Qxe7 d4 b6 Nd2 Bb7 c4 Nd7 cxd5 exd5 Ngf3 c5 bxc5 bxc5 Nb3 c4 Nbd2 Bc6 Nb1 Rab8 Nc3 Rb3 Qc2 Rfb8 Rb1 Qxa3 Rxb3 Rxb3 Be2 Rxc3 Qb1 Rc1+ Qxc1 Qxc1+ Bd1 Qc3+ Nd2 a5 O-O a4 Nb1 Qb2 Bxa4 Bxa4 g3 c3 Kg2 c2 Na3 Qxa3",
        "e4 d6 Nf3 Bd7 e5 Qc8 Ng5 Nc6 Nxf7 Kxf7 exd6 cxd6 Bc4+ Ke8 Bxg8 Rxg8 O-O Nd8 Qh5+ g6 Qxh7 Rg7 Qh4 Be6 d3 Bf7 Nc3 g5 Qa4+ Nc6 d4 Be6 d5 Bd7 dxc6 Bxc6 Qd4 g4 Bf4 Rf7 Bg3 Bg7 Qd3 Bd7 Qh7",
        "c4 e6 Nf3 Nf6 Nc3 d5 d4 Be7 Bg5 Nbd7 e3 c6 c5 h6 Bh4 a5 a3 O-O Bd3 b6 b4 axb4 axb4 Rxa1 Qxa1 bxc5 bxc5 Nh7 Bxe7 Qxe7 Qb1 Nhf6 O-O e5 dxe5 Nxe5 Nxe5 Qxe5 Ne2",
        "d4 d5 c4 Nc6 Nc3 e5 e3 exd4 exd4 dxc4 Bxc4 Nf6 Nge2 Bb4 O-O Bg4 f3 Bh5 a3 Bd6 b4 O-O Qb3 Bg6 Bb2 Nxd4 Nxd4 Bxh2+ Kxh2 Qxd4 Ne4 Qd7 Rad1 Qf5 Ng3 Qf4 Rd4 Qh6+ Kg1 Rfe8 Rg4 Nxg4 fxg4 Qe3+ Kh2 Qxb3 Bxb3 Rad8 Nh5 Rd2 Bc1 Rd3 Bc4 Rc3 Bb5 c6 Ba4 b5 Bb2 Rce3 Bd1 a6 Nxg7 Bd3 Rf3",
        "e4 e5 f4 d6 fxe5 dxe5 Nf3 Nc6 Bc4 Be7 O-O Nf6 Ng5 O-O Qf3 Nd4 Qh3 h6 Rxf6 Bxh3 Nxf7 Ne2+ Kh1 Rxf7 Bxf7+ Kh8 gxh3 Bxf6 d3",
        "c4 e5 Nc3 Nf6 g3 Nc6 d3 d5 cxd5 Nxd5 Bg2 Be6 h4 Bb4 Bd2 Nxc3 Bxc6+ bxc6 bxc3 Ba3 h5 Qd5 Nf3 e4 dxe4 Qxe4 Rh4 Qf5",
        "e4 e5 Nf3 Nc6 Bc4 Bc5 d3 Nf6 Nc3 d6 Bg5 Bg4 Nd5 Nd4 h3 Bxf3 gxf3 c6 Nxf6+ gxf6 Be3 Ne6 Qd2 Qb6 O-O-O Rg8 Rhg1 O-O-O Bxe6+ fxe6 Bxc5 Qxc5 Qe3 Qxe3+ fxe3 Kd7 f4 Ke7 f5 d5 Rxg8 Rxg8 fxe6 Kxe6 exd5+ cxd5 Rd2 Rg3 Rh2 Rxe3 Kd2 Rg3 b3 d4 c3 Kd5 c4+ Ke6 a3 f5 b4 e4 dxe4 fxe4 h4 Rxa3 Rg2 Ra2+",
        "e4 e5 Nf3 Nc6 Bb5 Nf6 d3 a6 Ba4 b5 Bb3 Na5 c3 c6 Bc2 Bc5 b4 Bxf2+ Kxf2 Ng4+ Ke2 O-O bxa5",
        "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6 Be3 e5 Nb3 Be6 f3 Be7 Qd2 Nbd7 g4 Qc7 O-O-O Rc8 g5 Nh5 Kb1 b5 Nd5 Bxd5 exd5 O-O Na5 Nb8 Bd3 f5 gxf6 Bxf6 Rhg1 Kh8 Qg2 Qxa5 Qg4 Nf4 Bxf4 exf4 Qh5 h6 Qg6 Kg8 Rde1 Be5 Qh7+ Kf7 Qf5+ Ke7 Rxg7+ Kd8 Rxe5 dxe5 Qxe5 Re8 Qd6+ Nd7 Qxd7#",
        "e4 e5 Nf3 Nc6 Bb5 Nf6 O-O Be7 d4 exd4 Nxd4 Nxd4 Qxd4 O-O Nc3 d6 h3 h6 Bf4 b6 e5 c5 Qc4 Be6 Qa4 Nd5 Nxd5 Bxd5 Rad1 Bh4 Rxd5 Qe7 Rxd6 Qe6 Bxh6 Rfd8 Rxd8+ Rxd8 Qxh4 gxh6 Qxd8+ Kg7",
        "e4 e5 Nf3 Nc6 Bb5 a6 Bxc6 dxc6 Nxe5 Bd6 Nf3 Nf6 Nc3 Bc5 h3 O-O O-O b5 d4 Bb4 Bg5 Be7 Qd2",
        "Nf3 c5 g3 Nc6 Bg2 e5 Nc3 e4 Nh4 d5 b3 Be7 Bb2 Bxh4 gxh4 Qxh4 Nxd5 Qd8 Bxg7 Qxd5 Bxh8 f6 e3 Ne5 Qh5+ Kf8 d4 Bg4 Qh4 Nf3+ Bxf3 Bxf3 Bxf6 Bxh1 O-O-O Bf3 Be5",
        "e4 e5 Bc4 c6 Nf3 d5 exd5 cxd5 Bb3 e4 d3 exf3 Qxf3 Be6 Nc3 Nf6 Bg5 Bg4 Bxf6 Bxf3 Bxd8 Kxd8 gxf3 Bc5 Bxd5 Nc6 Bxf7 Rf8 Bb3 Rxf3 O-O-O Rxf2 Ne4 Be3+ Kb1 Nd4 Nxf2 Bxf2 Rhf1 Be3 Rfe1 Bg5 Rf1 Kc7 Rde1 a6 Rf7+ Kb6 c3",
        "f4 e6 b3 c6 Bb2 d5 Nf3 Nf6 e3 Nbd7 c4 b6 d3 Bb7 Be2 c5 O-O Qc7 Nbd2 Be7 Qc1 O-O Ne5 Nxe5 fxe5 Nd7 d4 Bg5 Rf3 Rad8 Rg3 Bh6 Nf3 dxc4 Bxc4 cxd4 Bxd4 Nc5 Ng5 Qe7 h4 Kh8 Qc2 g6",
        "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 g6 Bc4 Bg7 Be3 e6 Nc3 Nge7 O-O O-O f4 a6 a4 Nxd4 Bxd4 Nc6 Bxg7 Kxg7 f5 exf5 exf5 Qe7 f6+ Qxf6 Rxf6 Kxf6 Nd5+ Kg7 Qf3 f5 Qf4 b5 axb5 axb5 Rxa8 Bb7 Rxf8 Kxf8 Bxb5 Kg7 Bxc6 Bxc6 Qe5+ Kf7 Qe7+ Kg8 Nf6+ Kh8 Qxh7#",
        "e4 e5 Nf3 Nc6 Bb5 d6 Nc3 f5 d4 fxe4 Nxe4 Bg4 d5 a6 Bxc6+ bxc6 dxc6 Nf6 Nxf6+ Qxf6 Bg5 Qg6 Qd2 Qe4+ Qe3 Bxf3 gxf3 Qxc6",
        "e4 c5 d3 d6 f4 Nf6 Nf3 g6 Nc3 Bg7 Bd2 O-O Be2 Nc6 O-O a6 h3 b5 g4 Qb6 Qc1 b4 Nd1 a5 Kh2 a4 f5 Bb7 Nf2 a3 b3 e6 Rb1 exf5 gxf5 Ne5 Nxe5 dxe5 Be3 Qc7 Ng4 Nxg4+ Bxg4 Rfd8 Bh6 f6 Bxg7 Qxg7 Rg1 g5 h4 h6 hxg5 hxg5 Kg3 Kf7 Bh5+ Ke7 Bg6 Rh8 Qe3 Rh6 Qxc5+ Kd7 Rh1 Rah8 Qb5+ Kc7 Qc4+ Kb8 Kg2 Rxh1 Rxh1 Rxh1 Kxh1 Qh6+ Kg2",
        "e4 d5 exd5 Qxd5 Nc3 Qa5 d4 c6 Nf3 Bf5 Bd3 e6 Bxf5 Qxf5 O-O Qa5 Bd2 Nd7 Qe2 Ngf6 a3 Qc7 Rfe1 Bd6 h3 O-O Ne4 Nxe4 Qxe4 Nf6 Qh4 Rfe8 c4 Be7 Bf4 Qd8 Be5 Nd7 Qe4 Nxe5 dxe5 Qb6 b4 c5 b5 Red8 a4 a5 Red1 Qc7 Qe2 b6 Qc2 h6 Rxd8+ Rxd8 Rd1 Rxd1+ Qxd1 Qd8 Qxd8+ Bxd8 Kf1 f6 Ke2 Bc7 exf6 gxf6 g4 Kf7 Ke3 Kg6 Ke4 Kf7 Nh4 Bd6 f4 Be7 f5",
        "d4 Nf6 c4 e6 Nf3 Bb4+ Bd2 Qe7 g3 Bxd2+ Qxd2 Nc6 Bg2 d5 O-O O-O b3 Ne4 Qc2 f5 Nbd2 Bd7 Nxe4 fxe4 Ne5 Nxd4 Qc3 Nxe2+",
        "e4 c5 f4 Nc6 Nf3 d6 d3 Bd7 Be3 Qc7 Nbd2 O-O-O a3 e6 g3 Be7 Bg2 f6 O-O h5 b4 h4 bxc5 hxg3 hxg3 dxc5 Rb1 g5 fxg5 f5 Bf4 e5 Be3 f4 Bf2 fxg3 Bxg3 Bxg5 Nc4 Nf6 Nxg5 Rdg8 Qd2 Ng4",
        "e4 e6 Nf3 g6 d4 Bh6 Bd3 d6 O-O Bd7 c4 Qe7 Nc3 Nc6 d5 exd5 exd5 Ne5 Re1 f6 Bxh6 Nxh6 Qd2 O-O-O Nd4 f5 Qxh6 Ng4 Rxe7 Rhe8 Qxh7 Rxe7 Qxe7 Re8 Qg5 f4 Qxf4 Nxh2 Kxh2 Rh8+ Kg1 Rh5 Bxg6 Re5 Qf8+",
        "d4 d5 Nf3 Nf6 e3 Nc6 Be2 Bf5 a3 e6 O-O Bd6 Ne1 e5 c3 e4 f4 O-O c4 Qe7 Nc3 Be6 cxd5 Bxd5 Bg4 Bc4 Rf2 Kh8",
        "e3 e5 d4 Nc6 d5 Nb4 e4 a6 a3 Nxd5 exd5 c6 c4 cxd5 cxd5 d6 Nc3 b6 Nge2 Bb7 g3 Nf6 Bg2 Qc8 Bg5 Be7 Rc1 h6 Bxf6 Bxf6 Ne4 Qd8 Nxf6+ Qxf6 O-O O-O f4 exf4 Nxf4 Qe7 Re1 Qc7 Rxc7 Rae8 Rxe8 Rxe8 Rxb7 Re5 Bh3 Kh7 Qc2+ g6 Rxf7+ Kg8 Qxg6+ Kh8 Qg7#",
        "e4 c6 Nf3 Qc7 d4 Nf6 Bd3 d6 O-O Bg4 c4 Nbd7 Nbd2 e5 d5 Be7 Qc2 h5 h3 Bxf3 Nxf3 O-O b3 cxd5 exd5 Nc5 Bf5 e4 Ne1 a5 Be3 b6 Bxc5 Qxc5 Bxe4 Qd4 Bd3 Qxa1 Nf3",
        "e4 d5 exd5 Qxd5 Nc3 Qd8 Nf3 Nf6 d4 e6 Bd3 Bb4 O-O O-O Be3 Nd5 a3 Bxc3 bxc3 Nxc3 Qd2 Nd5 Ne5 Nxe3 Qxe3 Nd7 Qh3 g6 Ng4 h5 Ne5 Nxe5 dxe5 Qg5 f4 Qh6 Qg3 Bd7 f5 exf5 Bxf5 Bxf5 Rxf5 Kh7 Rff1 Rae8 Rab1 b6 Rbc1 c5 Rcd1 Qg7 Rd7 Rxe5 h3 Rf5 Rxf5 gxf5 Qf3 Qd4+ Rxd4 cxd4 Qxf5+",
        "e4 d5 exd5 Qxd5 Nc3 Qa5 d4 e5 Nf3 Bg4 Be2 Bb4 Bd2 Nc6 Nxe5 Bxe2 Qxe2 Nxe5 dxe5 O-O-O a3 Ne7 O-O Bxc3 Bxc3 Qb6 Rad1 Nd5 Bd4 Nf4 Qg4+ Qe6 Qxf4 Rd5 Bc3 Rhd8 Rxd5 Rxd5 h3 h6 Qg4 Qxg4 hxg4 Kd7 Re1 c5 f4 g6 Kf2 b5 Re2",
        "e4 c5 f4 g6 Nf3 Bg7 a3 f6 c3 Qc7 e5 fxe5 fxe5 Bxe5 Nxe5 Qxe5+ Be2 d5 O-O Nf6 d4 Qd6 Bf4 Qb6 Be5 O-O dxc5 Qxc5+ Bd4 Qd6 Nd2 Nc6 Bf2 Bf5 Nf3 Ng4 Nd4 Qxh2#",
        "e4 d5 exd5 Qxd5 Nc3 Qd8 Nf3 Nf6 Be2 e6 O-O Be7 d4 O-O Bg5 b6 h3 Ba6 Bxa6 Nxa6 a3 c5 Qd3 cxd4 Qxd4 Qxd4 Nxd4 Rac8 Rad1 h6 Bh4 Nc5 Rfe1 g5 Bg3 Nh5 Bh2 Bd8 Ndb5 a6",
        "e4 c5 d3 Nc6 f4 e5 c3 d6 Nf3 Bg4 Be2 Bxf3 Bxf3 Nf6 O-O Be7 a4 O-O Na3 a6 Be3 Rc8 Nc4 b5 axb5 axb5 Nd2 Qd7 Qe2 h6 Ra6 b4 Rfa1 Rc7 Nc4 Rb7 fxe5 dxe5 Rxc6 Qxc6 Nxe5 Qe6 Nc4 Rbb8 e5",
        "e4 e5 Nf3 d6 Bc4 Bg4 O-O Qf6 h3 Bxf3 Qxf3 Qxf3 gxf3 Nc6 Nc3 Nd4 Bd3 c6 Ne2 Nxf3+ Kg2 Nh4+ Kg3 Ng6 Bc4 Nh6 d4 Be7 dxe5 Bh4+ Kh2 dxe5 Be3 b5 Bb3 O-O Bxh6 gxh6 Ng3",
        "g3 c6 Bg2 d5 e3 e6 Ne2 Nf6 d4 Be7 O-O O-O b3 h6 c4 b6 cxd5 exd5 Nbc3 Bb4 Bb2 Bxc3 Bxc3 Bf5 Nf4 Ne4 Bb4 Re8 f3 Nd6 Bh3 Bxh3 Nxh3 a5 Bxd6 Qxd6 Re1 c5 dxc5 bxc5 Nf4 d4 exd4 Rxe1+ Qxe1",
        "d4 d5 c4 c6 Nf3 Bg4 cxd5 cxd5 Qb3 Qd7 Ne5 Qc8 Nxg4 Qxg4 Qxb7 Qd7 Qxa8 Qc7 Nc3 e6 Bd2 Bb4 Rc1 Nf6 a3 Ba5 b4 Bb6 Nxd5 Qxc1+ Bxc1 O-O Nxf6+ gxf6 Bh6 Re8 e3 e5 Bb5 Rc8 O-O exd4 exd4 Bxd4 Qf3 f5 Qxf5 Rd8 Bd3",
        "c4 e5 g3 Nf6 Bg2 Nc6 e3 d6 Nc3 Be6 b3 Rb8 Nge2 a6 d4 exd4 exd4 Bf5 O-O Be7 Bg5 O-O Bxf6 Bxf6 d5 Ne5 Nd4 Bg6 f4 Nd7 Nde2 h6 Rc1 Bf5 Nd4 Bxd4+ Qxd4 Qf6 Qd2 Qd4+ Qxd4",
        "Nf3 d5 g3 Nf6 Bg2 c5 O-O Nc6 d4 cxd4 Nxd4 e5 Nxc6 bxc6 c4 Bb7 cxd5 cxd5 Nc3 Bc5 Bg5 Bd4 Bxf6 gxf6 Qb3 Bxc3 Qxb7 Bd4 Bxd5 O-O Qxa8 Qxa8 Bxa8 Rxa8 Rab1 Rb8 b4 Kf8 e3 Bc3 b5 Ke7 Rfc1 Ba5 a4 Rd8 Rd1 Rc8 Rbc1 Rb8 Rc6 Bb6 Kg2 Rg8 e4 h5 h4 Rg4 f3 Rg8",
        "e4 e6 f4 Ne7 Nf3 d5 exd5 exd5 Be2 Nf5 O-O Be7 d4 O-O Nc3 Nh4 Nxh4 Bxh4 Be3 Bf6 Qd3 c6 Bd2 Nd7 Rab1 Qc7 Nd1 c5 dxc5 Qxc5+ Be3 d4 Bf2 Qc7 Bxd4 Bxd4+ Qxd4 Nf6 Bd3 Bd7 Qf2 Bc6 Nc3 Qb6 Qxb6 axb6 a3 Nd5 Nxd5 Bxd5 c4 Bc6 f5 f6 Rbe1 Rfd8 Be4 Rd2 Bxc6 bxc6 Rf2 Rd3 Rf3 Rd2 Rf2 Rd4 Rf3 Kf7 Rb3 b5 cxb5 cxb5 Rxb5 Ra7 Ra1 Rd2 a4 Rad7 a5 Re7",
        "d4 Nf6 c4 g6 Nc3 Bg7 e4 O-O e5 Ne8 f4 d6 Nf3 dxe5 fxe5 f6 Be2 fxe5 dxe5 Qxd1+ Bxd1 Nc6 Bf4 e6 Bg3 Bd7 Bc2 Rxf3 gxf3 Nd4 O-O-O Nxf3 Rhf1 Nxe5 Bxe5 Bxe5 Nb5 Bxb5 cxb5 Nf6 Kb1 Nd5 Bb3 Ne3",
        "d4 b6 Nf3 Bb7 c4 Nf6 Nc3 g6 g3 Bg7 Bg2 O-O Nh4 d5 cxd5 Nxd5 Nxd5 Bxd5 e4 Bb7 Be3 e6 O-O Nd7 Rc1 Rc8 Qa4 a5 Qb5 Nf6 f3 Ra8 a4 Ba6 Qc6 Bxf1 Bxf1 Rc8 Ba6 Ra8 Bb7 Ra7 e5 Qxd4 Bxd4 Ne8 Qd7 Rxb7 Bc3 f6 Qe7 c5 Qxe6+ Kh8 exf6 Nxf6",
        "d4 f5 Nf3 Nf6 h4 e6 Ng5 d5 e3 c6 c3 Be7 Nd2 b5 Ndf3 a5 Ne5 Ne4 Ngf7 Qc7 Nxh8 Bf6 Qh5+ Kf8 Qxh7 Bxe5 Ng6+ Kf7 Nxe5+ Kf8 Qh8+ Ke7 Qxg7+ Kd8 Qf8#",
        "Nc3 Nf6 e4 d6 f4 g6 Nf3 Bg7 Bc4 c5 O-O O-O d3 Nc6 Kh1 a6 a3 b5 Ba2 Bb7 Nd5 Qc7 c4 Rad8 Rb1 b4 Nxc7",
        "d4 d5 c4 e6 a3 Nf6 Nc3 Be7 Bf4 Nh5 Be5 f6 Bg3 Nxg3 fxg3 dxc4 e4 c5 d5 O-O Bxc4 a6 Nf3 b5 Be2 c4 O-O Qb6+ Kh1 e5 Nh4 Rd8 Bg4 Bb7 Nf5 Bf8 Ne3 Nd7 Be6+ Kh8 Nf5 Nc5 Qg4 Nxe6 dxe6 Qxe6 Rad1 g6 Ne3 Qxg4 Nxg4 Rxd1 Rxd1 f5 exf5 gxf5 Nxe5 Bg7 Nf7+ Kg8 Rd7 Bc6 Rc7 Be8 Nd6 Rd8 Nxf5 Rd1+ Nxd1",
        "e4 e5 Nc3 Bb4 a3 Ba5 b4 Bb6 Na4 Nc6 Nxb6 axb6 Nf3 d6 Bc4 Bg4 h3 Bxf3 Qxf3 Qf6 Qb3 Nd4 Qa2 Qg6 O-O b5 Bd5 c6 Bb3 Nf6 d3 O-O Be3 Nf3+ Kh1 Nh4 Rg1 Qh5 c4 Ng6 Bd1 Qh4",
        "d4 g6 e3 Nf6 Bd3 d6 h3 Bg7 f4 b6 c4 Bb7 Nf3 O-O O-O c5 d5 Qc8 Nh4 e6 e4 h6 Nc3 a6 f5 gxf5 exf5 exf5 Nxf5 Qe8",
        "e4 e5 Nf3 d6 Bc4 Bg4 Nc3 Bxf3 Qxf3 Nf6 Nd5 Nbd7 Nxf6+ Nxf6 d3 Qd7 Bg5 Be7 Bxf6 O-O-O Bxe7 Qxe7 Bxf7 Rhf8 Qf5+ Qd7 Qxh7 Qxf7 Qh3+ Kb8 O-O-O Qf4+ Kb1",
        "e4 e5 Nf3 Nc6 Bb5 a6 Bxc6 bxc6 Nxe5 Qe7 d4 d6 Nf3 Qxe4+ Be3 Nf6 Nc3 Qg6 O-O Bf5 Nh4 Qh5 Qxh5 Nxh5 Nxf5 g6 Ng3 Nxg3 fxg3 Bg7 Rae1 O-O",
        "e4 a6 Nf3 b5 Be2 Bb7 e5 Nc6 O-O e6 d4 Bb4 c3 Ba5 Bg5 Nge7 a4 h6 Bxe7 Qxe7 axb5 axb5 Bxb5 O-O Nbd2 Bb6 Qc2 Ra5 Bd3 Rfa8 Rxa5 Rxa5 Nc4 Ra2 Nxb6 cxb6 Qb3 Ra8 Qxb6 d5 Qb3 g5 h3 Na5 Qc2 Ba6 Bxa6 Rxa6 Qa4 Qb7",
        "e4 d5 exd5 Qxd5 Qf3 Qe6+ Qe3 Nc6 Qxe6 Bxe6 c3 Bf5 d4 O-O-O Be3 e5 dxe5 Nxe5 f3 b6 Nd2 Nd3+ Bxd3 Bxd3 Kf2 Nf6 Ne2 Bd6 Nb3 Rhe8 Rad1 Bc4 Nbc1 Nd5 Bd4 c5 Bxg7 Bxe2 Nxe2 Kc7 Rxd5 Bg3+ hxg3 Rxd5 Bh6 a5 Bf4+ Kc6 Rh6+ Kb7 Rxh7 Re7 g4 Red7 g3 Rd1 Be3 Ra1 a3 Ra2 Bc1 Ra1 g5 Kc6 Rh6+ Kb5 b3 Rb1 c4+ Ka6",
        "d4 Nf6 c4 c5 d5 e6 Nc3 exd5 cxd5 d6 e4 g6 h3 Bg7 Nf3 O-O Bd3 a6 a4 Re8 O-O Nbd7 Bf4 Qc7 Rc1 Nh5 Bh2 Ne5 Nxe5 Bxe5 Bxe5 Rxe5 f4 Re8 e5 dxe5 f5 c4 Ne4 Bxf5 Rxf5 gxf5 Qxh5 fxe4 Qg5+ Kh8 Qf6+ Kg8 Bxe4 Qe7 Qf5 f6 Rc3 Kh8 d6 Qf7 Rxc4",
        "e4 e5 Bc4 Nf6 Nc3 Bb4 Nd5 Nxd5 Bxd5 O-O a3 Ba5 b4 Bb6 Qe2 c6 Bb3 d5 exd5 cxd5 Nf3 Bg4 h3 Bh5 g4 Bg6 d3 Nc6 Be3",
        "d4 d5 c4 Nf6 Nc3 Bf5 Nf3 Nc6 e3 e6 Be2 Bb4 O-O O-O cxd5 Nxd5 Bd2 a5 a3 Nxc3 bxc3 Bd6 c4 Qf6 c5 Be7 Rc1 Qg6 Kh1 Rfe8 Qb3 Bf6 Qxb7 Be4 Qxc7 e5 Qd7 exd4 exd4 Nxd4 Rfe1",
        "c4 e5 Nc3 Nf6 d3 Ng4 e4 f5 exf5 Bb4 Qxg4 h5 Qe2 d5 Qxe5+ Qe7 Qxe7+ Kxe7 Bd2 Bxf5 Nxd5+ Kd6 Nxb4 b5 g3 bxc4 Bg2 cxd3 Bxa8 Re8+ Kd1 h4 gxh4 c5 Nxd3 c4 Nf4 Ke5 Nge2 c3 bxc3 Nd7 Bc6 Kd6 Bxd7 Kxd7 Rb1 a5 Rb5 a4 Rxf5 a3 Ra5 Rb8 Rg1 Rb1+ Kc2 Rb6 Rxg7+ Kd6 Rg6+ Kc7 Rxb6 Kxb6 Rxa3 Kb5 c4+ Kxc4 Rd3 Kc5 Ne6+ Kc4 Rd8 Kb5 Kc3 Ka4 Kc4 Ka3 Rb8 Kxa2 Kc3 Ka1 Kc2",
        "c4 Nf6 Nc3 c5 e3 d6 d4 cxd4 exd4 a6 Nf3 Bg4 Be2 Bxf3 Bxf3 Nc6 O-O e6 Bg5 Be7 a3 O-O b4 e5 b5 axb5 cxb5 Nxd4 Bxb7 Rb8 Ba6 Qa5 Bd2 Nb3 Ra2 Nxd2 Qxd2 Qb6 a4 Nh5 a5 Qc5 b6 Nf4 Rb1 Qc6 f3 d5 Bb5 Qc5+ Kf1 d4 Ne4",
        "d3 Nf6 g3 g6 Bg2 Bg7 Nf3 O-O e3 d6 h4 h5 Nh2 c5 Nc3 a6 f3 Nc6 g4 hxg4 fxg4 Qd7 Bd2 Nxg4 Nxg4 Qxg4 Qxg4 Bxg4 Bh3 Bh5 Ne2 e6 Nf4 Bf3 Rg1 e5 Ne2 Nb4 Bxb4 cxb4 Ng3 f5 Rf1 Bg4 Bxg4 fxg4 O-O-O Rxf1 Rxf1 Rf8 Rxf8+ Bxf8 Ne4 Be7 Ng5 Bxg5 hxg5 Kf7 Kd2 Ke6 Ke2 Kf5 Kf2 Kxg5 Kg3 e4 dxe4 Kf6 Kxg4 b5 Kf4 a5 e5+ dxe5+ Ke4 a4",
        "e4 e5 Nf3 Nc6 Bc4 d6 Nc3 Nf6 d4 exd4 Nxd4 Bd7 Bf4 Be7 O-O O-O Nf3 Nh5 Be3 Bg4 h3 Bxf3 Qxf3 Ne5 Qxh5 Nxc4 Bc1 Bf6 Re1 Ne5 Bf4 Ng6 Re3 Bd4 Rg3 Nxf4 Qg4 Ng6 Rd1 Bxc3 bxc3 Qe7 Rd5 Qe6 Rg5 Qxg4 R3xg4 f6 Rh5 Ne5 Rf4 g6 Rhh4 g5",
        "d4 d5 c4 dxc4 Nc3 Nf6 Nf3 e6 a3 Nc6 g3 Be7 Bg2 O-O O-O Bd6 e4 e5 dxe5 Nxe5 Nxe5 Bxe5 Qxd8 Rxd8 Bg5 Rd6 Nd5 Nxd5 exd5 b5 Be7 Rd7 Bb4 Rxd5 Bxd5 Ba6 Bxa8",
        "e4 e5 Nf3 Nc6 c3 Nf6 d3 d6 Bg5 Bg4 h3 Bxf3 Qxf3 Be7 Bxf6 Bxf6 Nd2 Qe7 a3 O-O-O b4 Bg5 Nb3 b6 a4 h5 b5 Na5 Nxa5 bxa5 Be2 Qe6 O-O",
        "d4 e6 c4 d5 Nf3 c6 Nc3 Bd6 e3 f5 Bd3 Nf6 Qc2 O-O O-O Bd7 c5 Bc7 b4 Be8 Ng5 Ne4 Nxe6 Qh4 Nxf8 Qxh2#",
        "e4 b6 d4 Bb7 Bd3 e6 c4 Bb4+ Nc3 Bxc3+ bxc3 h6 Nf3 Nf6 Qe2 O-O O-O d6 h3 Nbd7 a4 e5 Re1 a5 Nh2 Nh7 d5 Nc5 Bc2 Bc8 f4 Qh4 Rf1 Nf6 fxe5 dxe5 Nf3 Qg3 Kh1",
        "e4 d5 exd5 Qxd5 Nc3 Qd8 Bc4 Nf6 d3 Bg4 f3 Bf5 Be3 e6 Nge2 c6 Ng3 Bg6 Qd2 Bd6 Nce4 Nxe4 Nxe4 Bc7 Bb3 Ba5 c3 Bxe4 fxe4 O-O O-O-O b5 h4 Bb6 d4 Nd7 g4 c5 g5 cxd4 Bxd4 Bxd4 Qxd4 Nb8 Qe3 Qc7"
    }

    ///
    /// One line per fixture:
    /// `<encoded bytes hex>|<halfMoveClock>|<positionHashes hex>|<lastUci or "-">`,
    /// produced by running the Scala `Encoder` on the fixture list.
    ///
    def references(): Vector[String] = Vector#{
        "eea6ac25ecf33c92b5e658fd09b6d885e100eb74bd0c4dfba9833f1dc38db226e16c933fdb126a4b0aff9d5017efd467df1fefb000|0|0a5145|e6d5",
        "2a34dbfd9cede854c817f955c878ed6de3b361e57dba13730dfb95ffaf7da4fc7fd575a2c15b37d4c0|3|a17a6135a13e4ab057ff4074|d1c1",
        "329d28ad62efb62d25c6687a9019867f922a4d8100757be0c7fdc99e2bf0863bbd03a22659cbce71cf67d45984c0|1|8c169e7227f3|b1a1",
        "32153ac744889b30b53a00219b21c74992dc36d506b9cbe9f532e5a680|0|5db9bd|b5c6",
        "3c37649e4f5dbbba00d75635b51742a689512becb2b03c89f73d50|1|f66f8cff61fe|a6c6",
        "b37b1b3a74eaf6f5f5e4da6fef1e1f27def116ba0f4db38b1be9fd437eb7f6ce561ffec140|1|9b79e62fade6|b1e1",
        "1f0d799a7e97ac1b591938cad0|0|14a94e|d5c6",
        "520a67c1ad27e908c8cbc914387bc5e2f5807cd5862e54a9bb80060d78fe09401f6f3f58a8dec9ab5b2a2d4daba9099c7c|4|d55d2b21cce984d3129bb87ee4a4b0|d8d1",
        "d7d4a7f797ee7d6cc26858df8c|1|3504cfa88475|h5f7",
        "1f0dc5c6f1bd22f3bcd7b96551231101f579c6f7f3ffb133e247eb4163207e0d4d673d67d43f605b402a2d|1|de676bda74fb|d8d3",
        "2ccec01ee5746d6bd7a4e1a67c2b16bdcb74a543333b5015d174eac015faf29148ab45cfd2bbe9da|4|f777ecc0e6af66933739636c999170|a5a6",
        "ce49b14a5b7dfeda89d377fd07f2dbbfc5a74924cd14b7f5d56bb3f1dc5ed7ffd009bf70bf88b5ff72702195b35d6693c2030af6f194aff655aadf7559bceb9540|0|1f11e0|a4a5",
        "086b4f43e7987fcd3e5ffd02eb7acd9a7748b890812b3731e5be2ee279b785af14977ba9749e668e1a8b1b87947b176074734b1d85aaa4e8|0|983165|b5b6",
        "93c5e61ff5ea59352dcdbd057c010e0d253d813da995abdc136975212fb690470c98e753af83f6dafb6cbd61673cccfd65fdcbcb598133455f515e132bf642673bb700|0|ef5f13|h4h3",
        "93e7cef66eee800cd8473a657e445cfbe7dce81997a08142910f733bb73a|1|4460555d9061|b6c5",
        "0542f58baf2ba738ec58f509d8f764f76a5927a9c2181ef6c99c29b8b0b3d02edb9fdc173ebb9ac3481b75abf4ad9d5f7c55a0e8|1|2e291f51d20c|a8f3",
        "2ceb6184fb14b77678efb8982e21d87c174012f2b17ccc838d33ebaf42bb0214e39dd7c32d2ce6a0c6bcb6a91bdf48|0|e98bd4|a1e1",
        "027486d64cd4e58abfdd6d6bf2973ef96ddef06feb764bce167f77c7fbfeae4c1dd0f535d6ef542f080799e09dbf70475ed788ef5da159835ca0|3|326eb3a8b97a4ca9f68ada63|f4e6",
        "3c37f12713fbf1d7bfe8784f81cae40130e407234febb9e9b8417615e1a69a0880|3|590a8790e970163212c51b5c|e2f3",
        "980ad605e113e7cdedbee36a1c442401b2c63b827f39e1a797379bafe94881a06fedc0|1|1c6ae77b726e|c1c8",
        "b72ef755052edb85b528397bb6a78e0be4caa2e783909f962df6270240|0|23e2ca|c1f1",
        "305eceac98e9bf53ee78d1f9b80678f79f0960|1|e96c33355825|h7g8",
        "2a708f4214aecec9f3c496d9acf1ff98ade9905b8f2db3d673df00|6|1add84089c6e40de56c46a583d2d5b915d41201fa1|e6e3",
        "cacad0973e9b8354b96e08f379e5c940|0|65e0b5|c6c5",
        "2c56f42a45dc359ddfd8f06d4210017f80|2|afaeb18e0b9f|g1f1",
        "060d4f60dc31c088ffb57a|0|bfee0f|f2f3",
        "2a63e7fc24cf317690cfb51a7bc790e2e7af10c0|1|2ff4af39b26e|a8c8",
        "03ad7cfd62cd8077bdf3fbeca365571bd1e271938f177b2acf2320|2|ba5ce8afd57ce9f8bf|f7f6",
        "92fbfcc8add959d27e230fc16dbfabd4ff6bec7d30dcb50dfe0cdaf98edcf704401d90|2|35919ec86a1363312b|c2b2",
        "93fd3beb42ab126443848ccb1561f1ad5ba21fd2abdfee74c74dfcafb7815d24a43fdf6eebc97b5abbeb19394541fe902a83085d751d58d13b00|0|ddb061|f4g5",
        "027761f6040d814d3189905f22a720cbce8f6cdf6affe480ba28|2|5dcd3b18bdd62916e5|b7d5",
        "2bef08131c670d431b7d3c2d9a77bc3b4b2e|5|a6c2427899462c21d4f1190bd882845f200f|e2d3",
        "09549431397a49cf3f27127ea5f5f55daee56a1f66785b42704f45c140|3|3b744833362675fec0c32c9f|h8e8",
        "9037bcfc4fa8ad177cf1dc31b468694d6f40461e6b11bfe661ce209a80|2|69a3fbe3d765c5b376|c1b1",
        "2cda1bf8a4df39546895c467ba71fcd94121260ae67dd9b5ce74ef73e063f0d20cd4f402d461ef8a8bb17d63ae2f681dae3a17caa4b8|0|c730b4|f4f3",
        "55e11d8ed1a5b317286bc52dbe6f7622c3846bceba68d34b2a42f1b0|3|803d19884d33c46926109081|d7d8",
        "a8279fa68480de537bdc7e03ac88bc9f39d7b59856a5ee3ba74892cd722d7d40|1|ae18ed6583ff|d4d5",
        "1f0dc6abbdcfc98dc007eba79e17f4b9cb2c|0|aa54fa|a2a4",
        "90dfb34dffbd4964fddb3128c218266bdc4f518c|4|747808d5c95f517d51956d8eb9aebc|d5e7",
        "3c17f921f65f10cb75ddfbe736fe47dfc0f5e93b8bc1b5ed69ebdb4d|0|ddc84d|c8c3",
        "5861c2a69e5fbe05987eb8d358c8c92fc54a7ab65c02b2eb4ee335d87b06c19ef9e9964ac2dcfa38b7fe41d72dd0bec4bdea94b0|0|43fd52|f2g2",
        "28fc008b263bd32be7197e64f9857fd92ee7fd5a4f8bd680|0|c72ca3|c2c4",
        "c825606e557ee7fe3a816063de6d3fb31a6efe4c369884b5d7c0|1|75dec622b1d4|f3g4",
        "2c8d811242bfee15b831fc12245e80|2|656cdbc73f1c986231|d2e3",
        "3c37f12122e91fdc393fa3dc1de7bdc70d5e717af2f1acf178887ff8c87007ee6228c8|0|ddc8bd|f8h8",
        "00a5cdc1ef2b6144278de713|5|2b43354ed21ccd68cda1c448cee93f58efb0|e2e7",
        "3228eafff963de8a3d7815034ec8dca4189902786752007bb6ee00|0|b7421f|g2g4",
        "28fcd9c4d1904f59b6bb15da4fcbcfe7b04cd80bfe14f903268c72780ff4d0|1|3a5c4ba9d8e7|h3g4",
        "28a944aec35bc9dcdb5ff7079de36ebf649ea688a32cfe0697bf7e80|1|f53abf76806e|g8f7",
        "8a340047337879ff96f9b2876ad5ba6df8efd7bce5bd0a01edd2fffaf8348ef70b80|0|459abc|g5e6",
        "1f0dff44bd3315ebf411aacb93bb4b3cef3468bd|3|9c8760884b134e11447df23f|f8e7",
        "02bf01518b0b358b59f0dad903cff6e1f3f7e5e19cd6bd6dfb59e5b92372e4|6|46b747850f963b2eda70e9e85557ba6c56b5674a2e|d5d3",
        "09cd7eaf6b043eeaa73fae21bdb68900d2fdf09e80|0|63951b|f7e5",
        "28c7890a42d9c44240d2f7dbcfdd39cdb4d3eb7e6d4210dfdfeae0|2|7c172433cbfd2058f1|e8c8",
        "3cfdaea74ca71edd21b5872aea|2|22d0977bbe2f67efe8|b1d2",
        "b77abfe043167fab2fe653ceaaa29be08f8680|0|45a2d3|g2h4",
        "c16fb9c5e9e406aa92501c70e751cb584feb9e55514f8f81bbea16dc8df7a8dd50|0|fa03ef|b2a3",
        "163be6764349541e7e6413bf35fe5be14c737b19eae5e76cc7c4|7|74aae9b7ea44cc0cdbf0f9814045bc767402bc65006731e6|d3h7",
        "cab4dfdbdeed3ebebdcf3bd35884840b03cdc1f803e0|1|7c4e0fcc5533|c3e2",
        "93e6efc5921bb74fa91e2d7893df7aa0057ef397861ff19dcc26c871f71a57f0fc93f7c472d38f6c|2|659cc931e05b961f19|f1f3",
        "0c6a06d33296677462e54b1e6ab74200|0|895372|d2d3",
        "c8d1b2bf12f3eab0d26250c9c6059f80|2|2df8c8c309f2ed7342|e4f5",
        "0252d4ddaaaea177192935ab6e8f212568fb5cffe1000ebec3de7c767f60eeea61c8b4|2|3aeb8702f370aa2c4a|a3a2",
        "0274af31b7dfff93ff4d05bbe4|0|299d71|b4a5",
        "3c17f9216d44958aa8ae1dfbe3122feeec763fd5649970c0ed56bf8756ccb19dd228578680|0|ce429c|d6d7",
        "0274f3bc36075664c5b711f276efcb939fd1d3d9e42434|1|7caf655261d9|g8g7",
        "0277080ad4963b947e89d60e|4|065edb2e46940b1da8cd47ff51cdf4|d1d2",
        "dcb2a53704f6c77480fc26277db8f2ecd2011beb80|3|fe0e31742e823052f8|f6e5",
        "05f931c11f7ec16877d5da36a42ee1f2ad141d51fb3cc9f2f8a0|0|fea0d0|c2c3",
        "ceace179a518bf56aeec2aab0bac2c496dace6c76ecabf07f82563d0|0|584a35|g7g6",
        "3c37f11f5ef56aacf1ef2d12e0f09bea90536defc0348693750344|0|07ccdf|e7h7",
        "027777f240ba2da09a57d773bb00|0|bd8a7d|e4c6",
        "3ca5fa0d1dacf65f2a6f3673eb5667efded71afaf1b21b05cfdd17f7105bdfbc9bf5ea7ace57f12df71aa0d02790|2|efce34a030723d0663|h1g2",
        "1f0dc5314bd7432fdd5eedace77cee844b5c4d77ff2ff49b8f856f99b2f67cedc241c1de7ba17e6fe76956f7b8|0|349f02|f4f5",
        "835256ddb2158ecbbdaf3ed760a670|0|3b1fa8|d4e2",
        "3c6a1b17777d744ea368624ffb2084bb8fda47c6a4145cbdfc|3|bb0e75262d2e0e3561408cb0|f6g4",
        "2a7d30bae0c6bc9bc79aecb1410ff5c7e1c03bc5247198e780|2|92a591087d7aebc48d|f4f8",
        "9034bd73bcd7d787f660e6bb2d272d65c7|4|86af1ecf653adb2d9ac1858b931aab|g8h8",
        "531d609ada9c9c31856e3da6e6e11d63407b07eef61867737488499faa0168|2|525ddcac12d1e5d8f5|g6g7",
        "2c8a4ed60afecc7c169b5a19f64dcd1c56d7ed860ba0|1|b20647256ad1|e1f3",
        "1f0d799a552e196b39d853206e2d98be68393b3bbc4009b6efffbe7de57636de97f400|0|8bf948|f3f5",
        "1f0dc51e67ac43ba434cb0edba318a84d9069179ac7610ccc919e1e5c0|1|63a4f95e4328|e1e2",
        "3c6b0179fefafe0005757df95fbcc82375493ace2e60|0|3b8ad0|d6h2",
        "1f0d799ae5e5c67bff9b011f2881932cf9aad57c4affccc0|0|18f339|a7a6",
        "3cadfc9e3a8ac847f5f75f9a66f0d1ef6fe59c5ffc773a01927eb0|0|3b66e0|e4e5",
        "02abb9b9804916ff1c1faabb4d48d06fff11b1c0|1|a1c1d0728452|e2g3",
        "b5bbead292b0f13cf1fd24cb49b17f3b8acfd25a0c48138e68|0|901ab9|d1e1",
        "93e7d97077beb544c96aabdee15e71ffd6a9dd33ed67cfad81d52ec0|2|e13db27f38e470f494|b5d3",
        "c8b0e8a68919be3d0f3eca50bc19f1b4aeb1801fbc00|0|3632f4|d2d4",
        "ddc22fd4468920f7a1b3bf777b2bd9e5543c664dcb23fcff6d0b632cece0ed7dfcb1a8|1|5eafd5b25c03|g4g8",
        "2bfecb01ccf2e786384d56be44e627e937bc148533bc555943cd06f389c5dd357fd2b1aac6e4a07f6ab07470|1|e0244ec47bdc|d7e7",
        "835e6d0e4ecc5c207e44926948a5d35399904f4added80|5|4bfa08160e2be6374d222792a8530c811ec7|d5e3",
        "984eff92c7abdf713c084d6ebadf5fcd0fd8b88798ad5e6b304333405bf86f3b593600|0|81e91d|e8f6",
        "9e05baf8bf5eeeff4268434e8ccc2bb08984fc|2|6e37cca920174fe9b1|g7f8",
        "a82fd6e7753f3393e65e37f2af4f2c7de600|0|863f04|d5c7",
        "93e2bfbbd5e1e63c240c69332dd6defb9fb549b3c5dffe2f6657742238fccd913817fe77ae697b1a00|0|c1c2cc|c3d1",
        "097cb1ffef0d0177acd2f9df1b7ef2c4acec64e39c18ff05e0f8|3|26cb79ba6a48f5a100d5b8c3|h5h4",
        "99297ab1dfbe7cbcf5f4a8e5efcbf9be716e8300|1|4d8ddb9cf554|c8e8",
        "02abba05549b55279097bec8c3ff40|5|4553d1cf274f0d2a7c|c1b1",
        "0277090e6b71829fbdac6d48609922dc|3|9c1078|e8g8",
        "19be5fa8df762b5c17a932001dab74ef906f49761aad7787530620|2|bf27200a9ae291f10b|e7b7",
        "1f0459541fbc11d481c313bf83326d9de7ee26fce290e02493e258eb01aebbf66efe877ec3cff6d7dcd000|1|cae88fe94400|b5a6",
        "834de0dd043f26a6556b4cc162f98dea908fa38a625ca6c0645279cfee7eaa20|0|104782|c3c4",
        "0537abb3dcfea75cdb93e1bdf5234b5b40|2|aa860fd98eb472636c|c1e3",
        "93e4deecddbd64835df3cd9ecade19d9f96f4731e0dc06c0|1|126a5f96de51|f1e1",
        "c8d2b21e971bb1ec90f497d49f2749da799f87589270d9502d6b9d37efbfad10571680aa667359988952161780|3|7349afd370455638702d6be6|c3c2",
        "ca567b5c4169d600d4a993b87ec4340cf151f315aa99ffe2ea6bde09e22ef7f6f3d0|1|01303e1f5930|c3e4",
        "ecff6a3ba8a57ecc69d58f67c2797800d246e957c9f2d0f5fe728600a1bae042fbb7d1082175ea94a0|0|f6ae58|a5a4",
        "0256e98bb3bba9dd270c9d90569c64cbb49fccec11faf22e0c66c7d85dfea8|0|9b8b40|g6g5",
        "93e1b2579bf57bce1d31c084db669f72420398|0|6402ec|d5a8",
        "0234495be42048c47d7d9c306d71e95d70|3|e4ab6f|e1g1",
        "949fe8f62ee3ddbf9e5536ff8ddc7f60|0|3e2eb0|h4h2",
        "3015d58ee43393d65b48ac3f23349f98bf7ff165fee1b9fe|3|b48104852a37f8b531b3e61e|g1h1",
        "1f0d795d577166bdde2f3eb17a6f172f2f0d2dfbf5feed27fd4d227cf4|3|7c3ed47a21ebce8462fd6719|d8c7"
    }

    /// The 25 legal black replies from the YycayYfM position.
    def legalReplies(): Vector[String] = Vector#{
        "Kh8",
        "Kf8",
        "Kg7",
        "Kf7",
        "Rf8",
        "Re8",
        "Rd8",
        "Rb8",
        "Ra8",
        "R8c7",
        "R8c6",
        "R5c7",
        "R5c6",
        "Rh5",
        "Rg5",
        "Rf5",
        "Re5+",
        "Rd5",
        "Rb5",
        "Ra5",
        "Rc4",
        "h6",
        "f5",
        "e5",
        "h5"
    }

    /// The same four fields as `references`, for each of `legalReplies`.
    def legalReferences(): Vector[String] = Vector#{
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09a60|2|394532708f166a9380|g8h8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09b60|2|b516d9708f166a9380|g8f8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09be0|2|5e41aa708f166a9380|g8g7",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09b40|2|f335c7708f166a9380|g8f7",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09d00|2|dbd42e708f166a9380|c8f8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09c|2|3f53cf708f166a9380|c8e8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09e80|2|7f4366708f166a9380|c8d8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09a80|2|06bc5a708f166a9380|c8b8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09f40|2|66c9d7708f166a9380|c8a8",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09dc0|2|5aa312708f166a9380|c8c7",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09a00|2|e463f2708f166a9380|c8c6",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09b80|2|daedf8708f166a9380|c5c7",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09fa0|2|642d18708f166a9380|c5c6",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09da0|2|548a2e708f166a9380|c5h5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09fd0|2|17c1c5708f166a9380|c5g5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09f20|2|b2a965708f166a9380|c5f5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09fe0|2|4fe5ff708f166a9380|c5e5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09f80|2|de74c5708f166a9380|c5d5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09e60|2|16de9d708f166a9380|c5b5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09d80|2|d35363708f166a9380|c5a5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09e40|2|4aef62708f166a9380|c5c4",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09b00|0|e2785d|h7h6",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a098|0|d06350|f6f5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09ff0|0|7456ca|e6e5",
        "2c8d8131c8b7d343d75f0504e167baf49a4f8f033e7e65f9241346d08e6b26a09e00|0|6dd188|h7h5"
    }
}
