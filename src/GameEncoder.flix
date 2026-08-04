///
/// Game (move) compression: the top-level encode/decode API.
///
/// Port of `src/main/scala/game/Encoder.scala`.
///
/// # What the algorithm is
///
/// For every ply the encoder generates the legal moves of the current position,
/// finds the one the SAN token names, asks the `MoveList` for its **rank** (its
/// 0-based index in the score-descending move order) and Huffman-codes that rank.
/// The decoder mirrors it exactly: read a rank, `selectRank` it out of the freshly
/// generated legal moves, render it back to SAN, play it. Nothing about the
/// position is stored, so both sides must agree on move generation, on the move
/// score, and on the rank tie-breaking, bit for bit.
///
/// # Mapping of the Scala nulls and mutable state
///
///   * `Encoder.encode` returns `null` when a token does not parse as SAN, or
///     when no legal move matches it. Here `encode` returns
///     `Option[Vector[Int8]]` and those two paths are `None`. The early `return`
///     is preserved: nothing after the failing ply is encoded.
///   * `DecodeResult.lastUci` is `null` when `plies == 0`; here it is
///     `Option[String]`, so `None`.
///   * `Move.promotion: Role | null` is `Option[Role]` (see `Move.flix`), so the
///     encoder's `legal.promotion == promotion` test is an `Option` comparison.
///   * `charToRole` throws `IllegalArgumentException` on an unexpected char. That
///     is unreachable — the only callers pass a character the SAN pattern has
///     already restricted to `[NBKRQ]` — so it is `bug!` here.
///   * The `ThreadLocal[MoveList]` is just a scratch buffer; here it is a
///     `MoveList` allocated in the local region, which is thread-local by
///     construction.
///
/// # Regions
///
/// `encode` needs no region from its caller: the `Board`, the `MoveList` and the
/// `BitWriter` all live in a local `region rc` and only a `Vector[Int8]` escapes,
/// so `encode` is **pure**. `decode` cannot do that, because its result contains
/// the final `Board`, which is region-allocated; it therefore takes the region as
/// a parameter and is `\ r`.
///
/// # The SAN pattern
///
/// Scala matches with
/// `"([NBKRQ])?([a-h])?([1-8])?x?([a-h][1-8])(?:=([NBRQK]))?[\\+#]?".r` and
/// `findFirstMatchIn`. Flix 0.75.1 has no regex group API worth relying on here,
/// so `sanFind` is a hand-written backtracking matcher for exactly that pattern,
/// with Java's semantics: leftmost match wins, and at a given start position the
/// greedy `?` quantifiers are tried *present first* and backtracked in
/// right-to-left order. `sanMatchAt` is the nested-alternative transcription of
/// that. The trailing `(?:=...)?` and `[\+#]?` cannot cause failure, so once
/// group 4 matches the whole match succeeds.
///
/// Worked examples that pin the backtracking down:
///
/// ```
///   "Nf3"  -> g1=N, g2 tried 'f' then abandoned, g4=f3
///   "Ke2"  -> g1=K, g2='e' g3='2' fails, g2='e' alone fails, g4=e2
///   "R8c7" -> g1=R, g2 absent ('8' is not a file), g3=8, g4=c7
///   "exd5" -> g1 absent, g2=e, x consumed, g4=d5
///   "b8=Q" -> g1,g2,g3 all abandoned, g4=b8, g5=Q
/// ```
///

///
/// The four static tables the game encoder needs, bundled so a caller builds them
/// once per process and threads one value through.
///
/// Fields: the `Bitboard` attack tables, the piece-square table, the Polyglot
/// Zobrist keys, and the Huffman code table / decoding tree.
///
/// This exists because Flix has no memoization: a zero-argument `def` returning
/// `Tables.mk()` would rebuild 88772 longs on every call. Build once, hold.
///
pub enum GameTables {
    case GameTables(Tables, Psqt, Vector[Int32], Huffman.HuffmanTable)
}

mod GameTables {

    ///
    /// Builds all four tables. Pure, and expensive (~100 ms); call once.
    ///
    pub def mk(): GameTables =
        GameTables.GameTables(Tables.mk(), Psqt.mk(), ZobristHash.polyglot(), Huffman.mkTable())

    /// The `Bitboard` attack tables.
    pub def tables(gt: GameTables): Tables =
        let GameTables.GameTables(t, _, _, _) = gt;
        t

    /// The piece-square table (`Move.PSQT`).
    pub def psqt(gt: GameTables): Psqt =
        let GameTables.GameTables(_, p, _, _) = gt;
        p

    /// The Polyglot Zobrist keys.
    pub def zobrist(gt: GameTables): Vector[Int32] =
        let GameTables.GameTables(_, _, z, _) = gt;
        z

    /// The Huffman code table and its decoding tree.
    pub def huffman(gt: GameTables): Huffman.HuffmanTable =
        let GameTables.GameTables(_, _, _, h) = gt;
        h
}

///
/// Scala `case class DecodeResult(pgnMoves, board, halfMoveClock, positionHashes,
/// lastUci)`.
///
/// The `Board` is region-allocated, so the result carries the region parameter.
/// `lastUci: String | null` is `Option[String]`.
///
pub enum DecodeResult[r: Region] {
    case DecodeResult(Vector[String], Board[r], Int32, Vector[Int8], Option[String])
}

mod DecodeResult {

    /// Scala `result.pgnMoves`.
    pub def pgnMoves(d: DecodeResult[r]): Vector[String] =
        let DecodeResult.DecodeResult(m, _, _, _, _) = d;
        m

    /// Scala `result.board`.
    pub def board(d: DecodeResult[r]): Board[r] =
        let DecodeResult.DecodeResult(_, b, _, _, _) = d;
        b

    /// Scala `result.halfMoveClock`.
    pub def halfMoveClock(d: DecodeResult[r]): Int32 =
        let DecodeResult.DecodeResult(_, _, c, _, _) = d;
        c

    /// Scala `result.positionHashes`.
    pub def positionHashes(d: DecodeResult[r]): Vector[Int8] =
        let DecodeResult.DecodeResult(_, _, _, h, _) = d;
        h

    /// Scala `result.lastUci`, with `null` spelled `None`.
    pub def lastUci(d: DecodeResult[r]): Option[String] =
        let DecodeResult.DecodeResult(_, _, _, _, u) = d;
        u
}

mod GameEncoder {

    // ------------------------------------------------------------------ encode

    ///
    /// Scala `def encode(pgnMoves: Array[String]): Array[Byte]`.
    ///
    /// Returns `None` where the original returns `null`: an unparseable SAN token,
    /// or a token that names no legal move. Everything encoded before the failing
    /// ply is discarded, exactly as the `return null` discards the writer.
    ///
    pub def encode(gt: GameTables, pgnMoves: Vector[String]): Option[Vector[Int8]] = region rc {
        let w      = BitWriter.mk(rc);
        let board  = Board.initial(rc, GameTables.tables(gt), GameTables.psqt(gt), GameTables.zobrist(gt));
        let legals = MoveList.mkDefault(rc);
        if (encodeLoop(gt, w, board, legals, pgnMoves, 0))
            Some(Array.toVector(BitWriter.toArray(w)))
        else
            None
    }

    ///
    /// The `for pgnMove <- pgnMoves` loop. `false` is the Scala `return null`.
    ///
    def encodeLoop(gt: GameTables, w: BitWriter[r], board: Board[r], legals: MoveList[r],
                   pgnMoves: Vector[String], i: Int32): Bool \ r =
        if (i >= Vector.length(pgnMoves))
            true
        else if (encodeOne(gt, w, board, legals, Vector.get(i, pgnMoves)))
            encodeLoop(gt, w, board, legals, pgnMoves, i + 1)
        else
            false

    ///
    /// One ply: parse the SAN token into a `(role, promotion, from-mask, to)`
    /// constraint, generate the legal moves, find the first that satisfies it,
    /// Huffman-code its rank and play it.
    ///
    def encodeOne(gt: GameTables, w: BitWriter[r], board: Board[r], legals: MoveList[r],
                  pgnMove: String): Bool \ r =
        match parseMove(gt, board, pgnMove) {
            case None => false
            case Some((role, promotion, fromMask, toSq)) =>
                Board.legalMoves(board, legals);
                let found = MoveList.find(legals, legal ->
                    Move.role(legal) == role and
                    Move.toSq(legal) == toSq and
                    Move.promotion(legal) == promotion and
                    Bitboard.contains(fromMask, Move.fromSq(legal)));
                match found {
                    case None => false
                    case Some(move) =>
                        Huffman.write(GameTables.huffman(gt), MoveList.rank(legals, move), w);
                        Board.play(board, move);
                        true
                }
        }

    ///
    /// The Scala block that sets `role`, `promotion`, `from` and `to` before the
    /// legal-move search, as a value.
    ///
    /// ```scala
    /// var role: Role = null; var promotion: Role = null
    /// var from: Long = Bitboard.ALL; var to: Int = 0
    /// if pgnMove.startsWith("O-O-O") then ... else if pgnMove.startsWith("O-O") then ...
    /// else SAN_RE.findFirstMatchIn(pgnMove) match { case None => return null; case Some(m) => ... }
    /// ```
    ///
    /// The castling branches read the *rook* square out of `board.rooks` on the
    /// mover's back rank — queenside is the lowest such rook, kingside the
    /// highest — which is how a castling `Move`'s `to` is stored.
    ///
    /// Note that this is the one input path in `encode` that can *throw* rather
    /// than return `None`: an `"O-O"` / `"O-O-O"` token in a position with no rook
    /// at all on the mover's back rank reaches `Bitboard.lsb`/`msb` with an empty
    /// bitboard. That is faithful — Scala 3 keeps `Bitboard`'s `assert(b != 0)`
    /// live at run time, so the original raises `AssertionError` on exactly the
    /// same inputs (verified by running the compiled Scala on
    /// `"a4 a5 Ra3 Ra6 h4 h5 Rh3 Rh6 O-O"`). Callers that must not abort on
    /// hostile input have to screen it on both sides alike.
    ///
    def parseMove(gt: GameTables, board: Board[r], pgnMove: String
                 ): Option[(Role, Option[Role], Int64, Int32)] \ r = {
        let t = GameTables.tables(gt);
        if (String.startsWith(prefix = "O-O-O", pgnMove)) {
            let backRank = Bits.bandL(Board.rooks(board), Bitboard.ranks(t, if (Board.turn(board)) 0 else 7));
            Some((Role.King, None, Board.kings(board), Bitboard.lsb(backRank)))
        } else if (String.startsWith(prefix = "O-O", pgnMove)) {
            let backRank = Bits.bandL(Board.rooks(board), Bitboard.ranks(t, if (Board.turn(board)) 0 else 7));
            Some((Role.King, None, Board.kings(board), Bitboard.msb(backRank)))
        } else
            match sanFind(pgnMove) {
                case None => None
                case Some((g1, g2, g3, toFile, toRank, g5)) =>
                    let role = match g1 {
                        case None    => Role.Pawn
                        case Some(c) => charToRole(c)
                    };
                    let fromFile = match g2 {
                        case None    => Bitboard.all()
                        case Some(c) => Bitboard.files(t, Char.toBmpCodePoint(c) - Char.toBmpCodePoint('a'))
                    };
                    let fromMask0 = Bits.bandL(Bitboard.all(), fromFile);
                    let fromMask = match g3 {
                        case None    => fromMask0
                        case Some(c) =>
                            Bits.bandL(fromMask0,
                                Bitboard.ranks(t, Char.toBmpCodePoint(c) - Char.toBmpCodePoint('1')))
                    };
                    let toSq = Square.square(
                        Char.toBmpCodePoint(toFile) - Char.toBmpCodePoint('a'),
                        Char.toBmpCodePoint(toRank) - Char.toBmpCodePoint('1'));
                    let promotion = match g5 {
                        case None    => None
                        case Some(c) => Some(charToRole(c))
                    };
                    Some((role, promotion, fromMask, toSq))
            }
    }

    ///
    /// Scala `private def charToRole(c: Char): Role`. The `IllegalArgumentException`
    /// branch is unreachable: every caller passes a character the SAN pattern has
    /// already constrained to `[NBKRQ]`.
    ///
    def charToRole(c: Char): Role = match c {
        case 'N' => Role.Knight
        case 'B' => Role.Bishop
        case 'R' => Role.Rook
        case 'Q' => Role.Queen
        case 'K' => Role.King
        case _   => bug!("Encoder.charToRole: not a role character")
    }

    // -------------------------------------------------------------- SAN regex

    /// `[NBKRQ]` — SAN group 1, and (as `[NBRQK]`) group 5.
    def isRoleChar(c: Char): Bool =
        c == 'N' or c == 'B' or c == 'K' or c == 'R' or c == 'Q'

    /// `[a-h]`.
    def isFileChar(c: Char): Bool = 'a' <= c and c <= 'h'

    /// `[1-8]`.
    def isRankChar(c: Char): Bool = '1' <= c and c <= '8'

    /// `s.charAt(i)`, or `None` past the end.
    def charAt(s: String, n: Int32, i: Int32): Option[Char] =
        if (i < 0 or i >= n) None else Some(String.charAt(i, s))

    ///
    /// Java `Matcher.find()`: the leftmost start position at which the pattern
    /// matches. Group 4 is the only mandatory part and is two characters wide, so
    /// no match can start later than `length - 2`; scanning to `length` is
    /// harmless and mirrors the original loop.
    ///
    /// Returns `(group1, group2, group3, group4-file, group4-rank, group5)`.
    ///
    def sanFind(s: String): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] =
        sanFindLoop(s, String.length(s), 0)

    def sanFindLoop(s: String, n: Int32, i: Int32
                   ): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] =
        if (i >= n)
            None
        else
            match sanMatchAt(s, n, i) {
                case Some(r) => Some(r)
                case None    => sanFindLoop(s, n, i + 1)
            }

    ///
    /// The pattern anchored at `pos`. Each optional group is attempted greedily
    /// (present first) and abandoned on failure of everything to its right.
    ///
    def sanMatchAt(s: String, n: Int32, pos: Int32
                  ): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] = {
        let withRole = match charAt(s, n, pos) {
            case Some(c) if isRoleChar(c) => sanGroup2(s, n, pos + 1, Some(c))
            case _                        => None
        };
        match withRole {
            case Some(r) => Some(r)
            case None    => sanGroup2(s, n, pos, None)
        }
    }

    /// `([a-h])?`.
    def sanGroup2(s: String, n: Int32, pos: Int32, g1: Option[Char]
                 ): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] = {
        let withFile = match charAt(s, n, pos) {
            case Some(c) if isFileChar(c) => sanGroup3(s, n, pos + 1, g1, Some(c))
            case _                        => None
        };
        match withFile {
            case Some(r) => Some(r)
            case None    => sanGroup3(s, n, pos, g1, None)
        }
    }

    /// `([1-8])?`.
    def sanGroup3(s: String, n: Int32, pos: Int32, g1: Option[Char], g2: Option[Char]
                 ): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] = {
        let withRank = match charAt(s, n, pos) {
            case Some(c) if isRankChar(c) => sanCapture(s, n, pos + 1, g1, g2, Some(c))
            case _                        => None
        };
        match withRank {
            case Some(r) => Some(r)
            case None    => sanCapture(s, n, pos, g1, g2, None)
        }
    }

    /// `x?` — not captured.
    def sanCapture(s: String, n: Int32, pos: Int32, g1: Option[Char], g2: Option[Char], g3: Option[Char]
                  ): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] = {
        let withX = match charAt(s, n, pos) {
            case Some('x') => sanGroup4(s, n, pos + 1, g1, g2, g3)
            case _         => None
        };
        match withX {
            case Some(r) => Some(r)
            case None    => sanGroup4(s, n, pos, g1, g2, g3)
        }
    }

    ///
    /// `([a-h][1-8])` — mandatory — followed by the two trailing optional groups,
    /// neither of which can fail the match.
    ///
    def sanGroup4(s: String, n: Int32, pos: Int32, g1: Option[Char], g2: Option[Char], g3: Option[Char]
                 ): Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])] =
        match (charAt(s, n, pos), charAt(s, n, pos + 1)) {
            case (Some(f), Some(r)) =>
                if (isFileChar(f) and isRankChar(r))
                    Some((g1, g2, g3, f, r, sanGroup5(s, n, pos + 2)))
                else
                    None
            case _ => None
        }

    /// `(?:=([NBRQK]))?`.
    def sanGroup5(s: String, n: Int32, pos: Int32): Option[Char] =
        match (charAt(s, n, pos), charAt(s, n, pos + 1)) {
            case (Some('='), Some(c)) => if (isRoleChar(c)) Some(c) else None
            case _                    => None
        }

    // ------------------------------------------------------------------ decode

    ///
    /// Scala `def decode(input: Array[Byte], plies: Int): DecodeResult`.
    ///
    /// The result holds the final `Board`, which is region-allocated, so unlike
    /// `encode` this takes the caller's region.
    ///
    /// A corrupt bit stream makes `MoveList.selectRank` fail its range check, which
    /// is `bug!` here and `require`'s `IllegalArgumentException` in the original.
    ///
    pub def decode(rc: Region[r], gt: GameTables, input: Vector[Int8], plies: Int32
                  ): DecodeResult[r] \ r = {
        let rd     = BitReader.mk(rc, Vector.toArray(rc, input));
        let output = Array.repeat(rc, plies, "");
        let board  = Board.initial(rc, GameTables.tables(gt), GameTables.psqt(gt), GameTables.zobrist(gt));
        let legals = MoveList.mkDefault(rc);
        let positionHashes = Array.repeat(rc, 3 * (plies + 1), 0i8);
        setHash(positionHashes, -1, Board.zobristHash(board));

        let (lastZeroingPly, lastIrreversiblePly, lastUci) =
            decodeLoop(gt, rd, board, legals, output, positionHashes, plies, 0, -1, -1, None);

        DecodeResult.DecodeResult(
            Array.toVector(output),
            board,
            plies - 1 - lastZeroingPly,
            Vector.slice(start = 0, end = 3 * (plies - lastIrreversiblePly), Array.toVector(positionHashes)),
            lastUci)
    }

    ///
    /// The `for i <- 0 to plies` loop — note the inclusive upper bound: the extra
    /// iteration exists only to append the `+`/`#` suffix to the last move.
    ///
    /// Returns `(lastZeroingPly, lastIrreversiblePly, lastUci)`.
    ///
    def decodeLoop(gt: GameTables, rd: BitReader[r], board: Board[r], legals: MoveList[r],
                   output: Array[String, r], positionHashes: Array[Int8, r], plies: Int32,
                   i: Int32, lastZeroingPly: Int32, lastIrreversiblePly: Int32,
                   lastUci: Option[String]): (Int32, Int32, Option[String]) \ r =
        if (i > plies)
            (lastZeroingPly, lastIrreversiblePly, lastUci)
        else {
            // `0 < i || i < plies` is false only for the degenerate `plies == 0`.
            if (0 < i or i < plies) Board.legalMoves(board, legals) else ();

            if (0 < i and Board.isCheck(board)) {
                let suffix = if (MoveList.isEmpty(legals)) "#" else "+";
                Array.put("${Array.get(i - 1, output)}${suffix}", i - 1, output)
            } else ();

            if (i < plies) {
                let rank = Huffman.read(GameTables.huffman(gt), rd);
                let move = MoveList.selectRank(legals, rank);
                Array.put(san(gt, move, legals), i, output);
                Board.play(board, move);
                let nextZeroing = if (Move.isZeroing(move)) i else lastZeroingPly;
                let nextIrreversible = if (Move.isIrreversible(move)) i else lastIrreversiblePly;
                setHash(positionHashes, i, Board.zobristHash(board));
                let nextUci = if (i + 1 == plies) Some(Move.uci(move)) else lastUci;
                decodeLoop(gt, rd, board, legals, output, positionHashes, plies,
                           i + 1, nextZeroing, nextIrreversible, nextUci)
            } else
                decodeLoop(gt, rd, board, legals, output, positionHashes, plies,
                           i + 1, lastZeroingPly, lastIrreversiblePly, lastUci)
        }

    ///
    /// Scala `private def san(move: Move, legals: MoveList): String`.
    ///
    /// The disambiguation logic is transcribed as written, including the `else`
    /// that binds to the *second* `if`:
    ///
    /// ```scala
    /// if others != 0 then
    ///   if (others & RANKS(rank(from))) != 0 then file = true
    ///   if (others & FILES(file(from))) != 0 then rank = true
    ///   else file = true
    /// ```
    ///
    /// so a competitor on the same rank forces the file letter, a competitor on the
    /// same file forces the rank digit, and any other competitor forces the file
    /// letter.
    ///
    def san(gt: GameTables, move: Move, legals: MoveList[r]): String \ r =
        if (Move.moveType(move) == Move.castling())
            if (Move.fromSq(move) < Move.toSq(move)) "O-O" else "O-O-O"
        else if (Move.moveType(move) == Move.normal() or Move.moveType(move) == Move.enPassant()) {
            let t = GameTables.tables(gt);
            let fromSq = Move.fromSq(move);
            let toSq = Move.toSq(move);
            let disambiguation =
                if (Move.role(move) != Role.Pawn) {
                    let others = othersLoop(move, legals, 0, 0i64);
                    let (file, rank) =
                        if (others != 0i64) {
                            let f0 = Bits.bandL(others, Bitboard.ranks(t, Square.rank(fromSq))) != 0i64;
                            if (Bits.bandL(others, Bitboard.files(t, Square.file(fromSq))) != 0i64)
                                (f0, true)
                            else
                                (true, false)
                        } else
                            (false, false);
                    let fileStr = if (file) "${fileChar(fromSq)}" else "";
                    let rankStr = if (rank) "${rankChar(fromSq)}" else "";
                    "${fileStr}${rankStr}"
                } else if (Move.capture(move))
                    "${fileChar(fromSq)}"
                else
                    "";
            let captureStr = if (Move.capture(move)) "x" else "";
            let promotionStr = match Move.promotion(move) {
                case None    => ""
                case Some(p) => "=${Role.symbol(p)}"
            };
            "${Role.symbol(Move.role(move))}${disambiguation}${captureStr}${fileChar(toSq)}${rankChar(toSq)}${promotionStr}"
        } else
            "--"

    ///
    /// The Scala loop that collects the other moves of the same role to the same
    /// square, as a bitboard of their origin squares.
    ///
    def othersLoop(move: Move, legals: MoveList[r], i: Int32, acc: Int64): Int64 \ r =
        if (i >= MoveList.getSize(legals))
            acc
        else {
            let other = MoveList.get(legals, i);
            let next =
                if (Move.role(other) == Move.role(move) and
                    Move.toSq(other) == Move.toSq(move) and
                    Move.fromSq(other) != Move.fromSq(move))
                    Bits.borL(acc, Bits.bit(Move.fromSq(other)))
                else
                    acc;
            othersLoop(move, legals, i + 1, next)
        }

    /// `(Square.file(sq) + 'a').toChar`.
    def fileChar(sq: Int32): Char =
        Int32.truncateToChar(Square.file(sq) + Char.toBmpCodePoint('a'))

    /// `(Square.rank(sq) + '1').toChar`.
    def rankChar(sq: Int32): Char =
        Int32.truncateToChar(Square.rank(sq) + Char.toBmpCodePoint('1'))

    ///
    /// Scala `private def setHash(buffer: Array[Byte], ply: Int, hash: Int): Unit`.
    ///
    /// Hashes are written back to front: ply `-1` (the initial position) lands in
    /// the last three bytes, so the buffer reads newest-first once sliced.
    ///
    def setHash(buffer: Array[Int8, r], ply: Int32, hash: Int32): Unit \ r = {
        let base = Array.length(buffer) - 3 * (ply + 1 + 1);
        Array.put(Bits.toByte(Bits.ushr(hash, 16)), base, buffer);
        Array.put(Bits.toByte(Bits.ushr(hash, 8)), base + 1, buffer);
        Array.put(Bits.toByte(hash), base + 2, buffer)
    }
}

///
/// Self-tests, transcribed from `src/test/scala/HuffmanPgnTest.scala`.
///
/// The full fidelity check is not here: the whole 114-game fixture list was
/// encoded with this port and with the Scala original and the byte streams,
/// decoded SAN, half-move clocks, position hashes and last-UCI strings compared,
/// all identical. These four keep the headline cases in the tree.
///
mod TestGameEncoderSelf {

    ///
    /// The "position hash 1. e4 d5 2. e5 f5 3. Ke2 Kf7" fixture: the exact byte
    /// stream, the half-move clock and the three-deep position-hash stack.
    ///
    @Test
    pub def testEncodeKnownGame(): Unit \ Assert = {
        let gt = GameTables.mk();
        let moves = Vector#{"e4", "d5", "e5", "f5", "Ke2", "Kf7"};
        match GameEncoder.encode(gt, moves) {
            case None => Assert.fail("encode returned None")
            case Some(bytes) => {
                Assert.assertEq(expected = Vector#{31i8, -54i8, -53i8, 61i8}, bytes);
                region rc {
                    let d = GameEncoder.decode(rc, gt, bytes, 6);
                    Assert.assertEq(expected = moves, DecodeResult.pgnMoves(d));
                    Assert.assertEq(expected = 2, DecodeResult.halfMoveClock(d));
                    Assert.assertEq(
                        expected = Vector#{0i8, -3i8, -45i8, 101i8, 42i8, 96i8, 34i8, -92i8, -117i8},
                        DecodeResult.positionHashes(d));
                    Assert.assertEq(expected = Some("e8f7"), DecodeResult.lastUci(d))
                }
            }
        }
    }

    ///
    /// The starting position's Polyglot hash, `463b96`, and `lastUci == null`.
    ///
    @Test
    pub def testInitialPositionHash(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let d = GameEncoder.decode(rc, gt, Vector#{}, 0);
        Assert.assertEq(expected = Vector#{70i8, 59i8, -106i8}, DecodeResult.positionHashes(d));
        Assert.assertEq(expected = None, DecodeResult.lastUci(d))
    }

    ///
    /// The "least surprise" test: 22 zero bytes decode to the most probable game.
    ///
    @Test
    pub def testLeastSurprise(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let d = GameEncoder.decode(rc, gt, Vector.repeat(22, 0i8), 22);
        Assert.assertEq(
            expected = "e4 e5 Nf3 Nf6 Nxe5 Nxe4 Nxf7 Kxf7 d4 Nxf2 Kxf2 d5 Nc3 Nc6 Nxd5 Qxd5 "
                     + "Kg1 Nxd4 Qxd4 Qxd4+ Be3 Qxe3#",
            String.intercalate(" ", Vector.toList(DecodeResult.pgnMoves(d))))
    }

    ///
    /// The two `return null` paths: a token that is not SAN, and a token that is
    /// SAN but names no legal move.
    ///
    @Test
    pub def testEncodeRejectsIllegalInput(): Unit \ Assert = {
        let gt = GameTables.mk();
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"e4", "xyz"}));
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"e4", "O-O"}));
        Assert.assertEq(expected = None, GameEncoder.encode(gt, Vector#{"a1"}))
    }
}
