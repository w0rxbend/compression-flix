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
///     already restricted to `[NBKRQ]` — so it is `bug!` here. It is spelled
///     `codeToRole` and takes a code point, because that is what the matcher below
///     hands back.
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
/// so `sanFind` is a hand-written matcher for exactly that pattern, with Java's
/// semantics: leftmost match wins, and at a given start position the greedy `?`
/// quantifiers are tried *present first* and backtracked in right-to-left order.
/// `findLoop` enumerates `(start position, subset mask)` in exactly that order and
/// packs the six capture groups into an `Int64`; see the long note on it for why
/// the enumeration order is the same walk the nested transcription performed, and
/// for the 679 045-input three-way fuzz against `java.util.regex` that checks it.
/// The trailing `(?:=...)?` and `[\+#]?` cannot cause failure, so once group 4
/// matches the whole match succeeds.
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
    case GameTables(Tables[Static], Psqt, Vector[Int32], Huffman.HuffmanTable)
}

mod GameTables {

    ///
    /// Builds all four tables. Pure, and expensive (~100 ms); call once.
    ///
    pub def mk(): GameTables =
        GameTables.GameTables(Tables.mk(), Psqt.mk(), ZobristHash.polyglot(), Huffman.mkTable())

    /// The `Bitboard` attack tables.
    pub def tables(gt: GameTables): Tables[Static] =
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
    case DecodeResult(Array[String, r], Board[r], Int32, Array[Int8, r], Option[String])
}

mod DecodeResult {

    /// Scala `result.pgnMoves`.
    pub def pgnMoves(d: DecodeResult[r]): Array[String, r] =
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
    pub def positionHashes(d: DecodeResult[r]): Array[Int8, r] =
        let DecodeResult.DecodeResult(_, _, _, h, _) = d;
        h

    /// Scala `result.lastUci`, with `null` spelled `None`.
    pub def lastUci(d: DecodeResult[r]): Option[String] =
        let DecodeResult.DecodeResult(_, _, _, _, u) = d;
        u
}

mod GameEncoder {

    import java.lang.Character
    import java.lang.{String => JString}

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
                discard Board.legalMoves(board, legals);
                // The parsed promotion is turned into a code once, so the predicate
                // compares two `Int32`s instead of building an `Option[Role]` per
                // candidate move. Same test: the encoding of `Option[Role]` as
                // `0` / `Role.index + 1` is injective.
                let roleIndex = Role.index(role);
                let promotionCode = match promotion {
                    case None    => 0
                    case Some(p) => Role.index(p) + 1
                };
                let found = MoveList.find(legals, legal ->
                    Move.roleIndex(legal) == roleIndex and
                    Move.toSq(legal) == toSq and
                    Move.promotionCode(legal) == promotionCode and
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
        if (hasPrefix(pgnMove, "O-O-O")) {
            let backRank = Bits.bandL(Board.rooks(board), Bitboard.ranks(t, if (Board.turn(board)) 0 else 7));
            Some((Role.King, None, Board.kings(board), Bitboard.lsb(backRank)))
        } else if (hasPrefix(pgnMove, "O-O")) {
            let backRank = Bits.bandL(Board.rooks(board), Bitboard.ranks(t, if (Board.turn(board)) 0 else 7));
            Some((Role.King, None, Board.kings(board), Bitboard.msb(backRank)))
        } else {
            let m = sanFind(pgnMove);
            if (m == noMatch()) None else {
                let g1 = group(m, 0);
                let g2 = group(m, 7);
                let g3 = group(m, 14);
                let toFile = group(m, 21);
                let toRank = group(m, 28);
                let g5 = group(m, 35);
                let role = if (g1 == 0) Role.Pawn else codeToRole(g1);
                let fromFile = if (g2 == 0) Bitboard.all() else Bitboard.files(t, g2 - lowerA());
                let fromMask0 = Bits.bandL(Bitboard.all(), fromFile);
                let fromMask =
                    if (g3 == 0) fromMask0
                    else Bits.bandL(fromMask0, Bitboard.ranks(t, g3 - digit1()));
                let toSq = Square.square(toFile - lowerA(), toRank - digit1());
                let promotion = if (g5 == 0) None else Some(codeToRole(g5));
                Some((role, promotion, fromMask, toSq))
            }
        }
    }

    ///
    /// Scala `private def charToRole(c: Char): Role`, taking the character as a
    /// code point because that is what the matcher hands back. The
    /// `IllegalArgumentException` branch is unreachable for the same reason it is
    /// in the original: every caller passes a character the SAN pattern has already
    /// constrained to `[NBKRQ]`.
    ///
    @Inline
    def codeToRole(c: Int32): Role =
        if (c == Character.hashCode('N')) Role.Knight
        else if (c == Character.hashCode('B')) Role.Bishop
        else if (c == Character.hashCode('R')) Role.Rook
        else if (c == Character.hashCode('Q')) Role.Queen
        else if (c == Character.hashCode('K')) Role.King
        else bug!("Encoder.codeToRole: not a role character")

    // -------------------------------------------------------------- SAN regex

    ///
    /// The SAN matcher: `([NBKRQ])?([a-h])?([1-8])?x?([a-h][1-8])(?:=([NBRQK]))?[\\+#]?`
    /// applied as `java.util.regex.Matcher.find()`, i.e. leftmost match wins.
    ///
    /// # Why it is flat and packed
    ///
    /// This was six mutually recursive `def`s returning
    /// `Option[(Option[Char], Option[Char], Option[Char], Char, Char, Option[Char])]`.
    /// Every level allocated: a `Some` per character examined (`charAt` returned
    /// `Option[Char]`), a `Value$` per level per attempt, a heap continuation per
    /// backtrack, and a six-wide `Tuple$` on success — on a function the encoder
    /// runs once per ply, with backtracking, over eight to fourteen characters.
    /// It was measured as the largest single allocation site in the port.
    ///
    /// The replacement is one self-recursive loop over `(start position, subset
    /// mask)` returning the six capture groups packed into an `Int64` as six 7-bit
    /// ASCII codes, with `0` meaning "group absent" — `0` is not a SAN character,
    /// so there is no ambiguity — and `-1` meaning "no match". Nothing is allocated.
    ///
    /// # Why the exploration order is the same
    ///
    /// `mask` bit 3 is group 1, bit 2 is group 2, bit 1 is group 3, bit 0 is the
    /// uncaptured `x?`. The nested matcher tried each optional group present-first
    /// and abandoned the rightmost group first, which is a depth-first walk whose
    /// leaves are exactly the masks in *descending* numeric order; counting `mask`
    /// down from 15 to 0 at each start position reproduces it, and stepping `pos`
    /// outward reproduces leftmost-match-wins.
    ///
    /// That argument is checked rather than asserted. A three-way fuzz compared
    /// this matcher against a transcription of the nested one AND against
    /// `java.util.regex` running the Scala original's own pattern
    /// (`src/main/scala/game/Encoder.scala:11`) over 679 045 inputs: every string
    /// of length 0..4 over `NBKRQabh18x=+#-O`, every one- and two-character string
    /// over printable ASCII, 600 000 random strings up to length 10, and twenty real
    /// SAN tokens with check/mate/promotion decorations. Zero disagreements on all
    /// three pairings. `difftest`'s `SanFuzzTest` and the byte-level
    /// `DifferentialTest` are the gates that matter, and both were re-run after this.
    ///

    /// `s.charAt(i)` as a code point, or `0` past either end.
    ///
    /// `Character.hashCode` rather than `Char.toBmpCodePoint`: the latter is
    /// `Short.valueOf(x).intValue()` masked, a boxed conversion, while
    /// `Character.hashCode` is specified as `(int) c` and is a pure `java.lang`
    /// static. `String.charAt` is on the compiler's pure-methods whitelist.
    @Inline
    def code(s: String, n: Int32, i: Int32): Int32 =
        if (i < 0 or i >= n) 0 else Character.hashCode(String.charAt(i, s))

    /// `'a'`, `'1'`, `'x'` and `'='` as code points, so the matcher is arithmetic.
    @Inline
    def lowerA(): Int32 = Character.hashCode('a')
    @Inline
    def digit1(): Int32 = Character.hashCode('1')

    /// `[NBKRQ]`, as a code point. Also group 5's `[NBRQK]`, which is the same set.
    @Inline
    def isRoleCode(c: Int32): Bool =
        c == Character.hashCode('N') or c == Character.hashCode('B') or
        c == Character.hashCode('K') or c == Character.hashCode('R') or
        c == Character.hashCode('Q')

    /// `[a-h]`, as a code point.
    @Inline
    def isFileCode(c: Int32): Bool = lowerA() <= c and c <= Character.hashCode('h')

    /// `[1-8]`, as a code point.
    @Inline
    def isRankCode(c: Int32): Bool = digit1() <= c and c <= Character.hashCode('8')

    /// The "no match" sentinel. Distinguishable from every packed match, whose
    /// top bits are always zero.
    @Inline
    def noMatch(): Int64 = -1i64

    /// Capture group `shift` of a packed match, as a code point (`0` if absent).
    @Inline
    def group(m: Int64, shift: Int32): Int32 =
        Bits.toInt(Bits.bandL(Bits.ushrL(m, shift), 0x7fi64))

    /// The six groups as one `Int64`; see `group` for the layout.
    @Inline
    def pack(g1: Int32, g2: Int32, g3: Int32, f: Int32, r: Int32, g5: Int32): Int64 =
        Bits.borL(
            Bits.borL(Bits.borL(Bits.toLongU(g1), Bits.shlL(Bits.toLongU(g2), 7)),
                      Bits.borL(Bits.shlL(Bits.toLongU(g3), 14), Bits.shlL(Bits.toLongU(f), 21))),
            Bits.borL(Bits.shlL(Bits.toLongU(r), 28), Bits.shlL(Bits.toLongU(g5), 35)))

    ///
    /// `Matcher.find()`: the packed groups of the leftmost match, or `noMatch()`.
    ///
    /// Group 4 is the only mandatory part and is two characters wide, so no match
    /// can start later than `length - 2`; scanning to `length` is harmless and
    /// mirrors the original loop.
    ///
    def sanFind(s: String): Int64 = findLoop(s, String.length(s), 0, 15)

    /// The `(pos, mask)` walk. Self-recursive on both axes, so Flix compiles it to
    /// a loop rather than a chain of heap continuations.
    def findLoop(s: String, n: Int32, pos: Int32, mask: Int32): Int64 =
        if (pos >= n)
            noMatch()
        else if (mask < 0)
            findLoop(s, n, pos + 1, 15)
        else {
            let r = tryMask(s, n, pos, mask);
            if (r != noMatch()) r else findLoop(s, n, pos, mask - 1)
        }

    ///
    /// The pattern anchored at `pos` with exactly the optional groups named by
    /// `mask` present. Each `present` test is a mask bit, so no character is read
    /// for a group this attempt has chosen to omit.
    ///
    @Inline
    def tryMask(s: String, n: Int32, pos: Int32, mask: Int32): Int64 = {
        let has1 = Bits.band(mask, 8) != 0;
        let has2 = Bits.band(mask, 4) != 0;
        let has3 = Bits.band(mask, 2) != 0;
        let hasX = Bits.band(mask, 1) != 0;
        let g1 = if (has1) code(s, n, pos) else 0;
        let p1 = if (has1) pos + 1 else pos;
        if (has1 and not isRoleCode(g1)) noMatch() else {
            let g2 = if (has2) code(s, n, p1) else 0;
            let p2 = if (has2) p1 + 1 else p1;
            if (has2 and not isFileCode(g2)) noMatch() else {
                let g3 = if (has3) code(s, n, p2) else 0;
                let p3 = if (has3) p2 + 1 else p2;
                if (has3 and not isRankCode(g3)) noMatch() else {
                    let xc = if (hasX) code(s, n, p3) else 0;
                    let p4 = if (hasX) p3 + 1 else p3;
                    if (hasX and xc != Character.hashCode('x')) noMatch() else {
                        let f = code(s, n, p4);
                        let r = code(s, n, p4 + 1);
                        if (isFileCode(f) and isRankCode(r)) {
                            // `(?:=([NBRQK]))?` — greedy, but it can never fail the
                            // match, so there is no mask bit for it.
                            let eq = code(s, n, p4 + 2);
                            let pr = code(s, n, p4 + 3);
                            let g5 = if (eq == Character.hashCode('=') and isRoleCode(pr)) pr else 0;
                            pack(g1, g2, g3, f, r, g5)
                        } else
                            noMatch()
                    }
                }
            }
        }
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
    pub def decode(rc: Region[r], gt: GameTables, input: Array[Int8, r], plies: Int32
                  ): DecodeResult[r] \ r = {
        let rd     = BitReader.mk(rc, input);
        // Round 6 tried `Array.empty` here — which is what the original's
        // `Array.ofDim[String](plies)` actually is, since that fills with `null`, not
        // `""` — and MEASURED IT WORSE: game decode allocation 53,753 -> 54,340
        // (short) and 69,046 -> 69,760 (median) B/op, with the `sanBuf` site below
        // converted at the same time. Reverted. `Array.repeat` is not free everywhere
        // (see `BitOps.readSignedArray`, where dropping it won a row), but it is not
        // uniformly costly either, and these two sites are on the wrong side.
        let output = Array.repeat(rc, plies, "");
        let board  = Board.initial(rc, GameTables.tables(gt), GameTables.psqt(gt), GameTables.zobrist(gt));
        let legals = MoveList.mkDefault(rc);
        // `Array.empty`, not `Array.repeat(..., 0i8)`: `setHash` writes all
        // `3 * (plies + 1)` bytes and `Reflect.default()` for `Int8` is the same zero.
        let positionHashes = Array.empty(rc, 3 * (plies + 1));
        // One scratch buffer for every SAN token: the longest is "Qa1xb2=Q" at 8.
        let sanBuf = Array.repeat(rc, 16, ' ');
        setHash(positionHashes, -1, Board.zobristHash(board));

        let (lastZeroingPly, lastIrreversiblePly, lastUci) =
            decodeLoop(rc, gt, rd, board, legals, output, positionHashes, sanBuf, plies, 0, -1, -1, None);

        DecodeResult.DecodeResult(
            output,
            board,
            plies - 1 - lastZeroingPly,
            sliceBytes(rc, positionHashes, 3 * (plies - lastIrreversiblePly)),
            lastUci)
    }

    ///
    /// The `for i <- 0 to plies` loop — note the inclusive upper bound: the extra
    /// iteration exists only to append the `+`/`#` suffix to the last move.
    ///
    /// Returns `(lastZeroingPly, lastIrreversiblePly, lastUci)`.
    ///
    def decodeLoop(rc: Region[r], gt: GameTables, rd: BitReader[r], board: Board[r], legals: MoveList[r],
                   output: Array[String, r], positionHashes: Array[Int8, r], sanBuf: Array[Char, r], plies: Int32,
                   i: Int32, lastZeroingPly: Int32, lastIrreversiblePly: Int32,
                   lastUci: Option[String]): (Int32, Int32, Option[String]) \ r =
        if (i > plies)
            (lastZeroingPly, lastIrreversiblePly, lastUci)
        else {
            // `0 < i || i < plies` is false only for the degenerate `plies == 0`.
            //
            // `legalMoves` hands back `checkers != 0`, which is exactly what the
            // original's `isCheck()` recomputes here — `attacksTo(king, !turn)` on a
            // board `legalMoves` did not mutate. Using it deletes one `attacksTo` per
            // ply (12.0% of decode's magic-bitboard lookups) plus a trampolined
            // `Def$isCheck` and `Def$attacksToOcc` call. The value is only consulted
            // when `0 < i`, and `0 < i` implies the guard below is true, so it is
            // always the flag from the `legalMoves` call for *this* position; the
            // `false` fallback belongs to the degenerate `plies == 0` path, where
            // `0 < i` is false and short-circuits before reading it.
            let inCheck = if (0 < i or i < plies) Board.legalMoves(board, legals) else false;

            if (0 < i and inCheck) {
                let suffix = if (MoveList.isEmpty(legals)) "#" else "+";
                Array.put(String.concat(Array.get(i - 1, output), suffix), i - 1, output)
            } else ();

            if (i < plies) {
                let rank = Huffman.read(GameTables.huffman(gt), rd);
                let move = MoveList.selectRank(legals, rank);
                Array.put(san(gt, move, legals, sanBuf), i, output);
                Board.play(board, move);
                let nextZeroing = if (Move.isZeroing(move)) i else lastZeroingPly;
                let nextIrreversible = if (Move.isIrreversible(move)) i else lastIrreversiblePly;
                setHash(positionHashes, i, Board.zobristHash(board));
                let nextUci = if (i + 1 == plies) Some(Move.uci(move)) else lastUci;
                decodeLoop(rc, gt, rd, board, legals, output, positionHashes, sanBuf, plies,
                           i + 1, nextZeroing, nextIrreversible, nextUci)
            } else
                decodeLoop(rc, gt, rd, board, legals, output, positionHashes, sanBuf, plies,
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
    /// # Why a scratch `char` buffer and neither interpolation nor a `StringBuilder`
    ///
    /// Interpolation was tried first and is the worst of the three: Flix compiles
    /// `"${a}${b}"` to a chain of `java.lang.String.concat` and a `Char` inside one
    /// to `Character.toString`, which for this function meant thirteen `concat` sites
    /// and five `Character.toString` sites, each allocating a `String` **and** a
    /// fresh `byte[]`, and it built the six-part result out of already-concatenated
    /// intermediates — roughly 480 bytes for a disambiguated non-pawn move.
    ///
    /// A `StringBuilder` replaced it and was much better, but Flix's `StringBuilder`
    /// is `enum StringBuilder[_: Region](JStringBuilder)`, so each token still cost a
    /// `Tag$Obj` wrapper, a `java.lang.StringBuilder`, its default 16-char `byte[]`,
    /// the result `String` and *its* `byte[]` — about 126 B/ply, against the Scala
    /// original's `StringBuilder(6)` route at about 101 B/ply.
    ///
    /// This form writes the characters into ONE buffer allocated per `decode` call
    /// (not per ply) and materialises the token with a single `String.valueOf`, so a
    /// token costs a `String` and one `byte[]`. The buffer is 16 chars; the longest
    /// token this function can write is 8 (`Qa1xb2=Q`) and the check suffix is
    /// appended afterwards by `String.concat`, so there is no overflow path.
    ///
    /// The characters, their order and the branches that select them are transcribed
    /// unchanged from the `StringBuilder` version; `difftest` compares the decoded
    /// SAN token array against the Scala original over the whole corpus.
    ///
    def san(gt: GameTables, move: Move, legals: MoveList[r], buf: Array[Char, r]): String \ r =
        if (Move.moveType(move) == Move.castling())
            if (Move.fromSq(move) < Move.toSq(move)) "O-O" else "O-O-O"
        else if (Move.moveType(move) == Move.normal() or Move.moveType(move) == Move.enPassant()) {
            let t = GameTables.tables(gt);
            let fromSq = Move.fromSq(move);
            let toSq = Move.toSq(move);

            let isPawn = Move.roleIndex(move) == Role.index(Role.Pawn);
            let n0 = if (not isPawn) { putChar(buf, 0, roleChar(Move.role(move))); 1 } else 0;

            let n1 =
                if (not isPawn) {
                    let others = othersLoop(move, legals, 0, 0i64);
                    if (others != 0i64) {
                        let sameRank = Bits.bandL(others, Bitboard.ranks(t, Square.rank(fromSq))) != 0i64;
                        let sameFile = Bits.bandL(others, Bitboard.files(t, Square.file(fromSq))) != 0i64;
                        let file = if (sameFile) sameRank else true;
                        let na = if (file) { putChar(buf, n0, fileChar(fromSq)); n0 + 1 } else n0;
                        if (sameFile) { putChar(buf, na, rankChar(fromSq)); na + 1 } else na
                    } else n0
                } else if (Move.capture(move)) { putChar(buf, n0, fileChar(fromSq)); n0 + 1 }
                else n0;

            let n2 = if (Move.capture(move)) { putChar(buf, n1, 'x'); n1 + 1 } else n1;   // 'x'
            putChar(buf, n2, fileChar(toSq));
            putChar(buf, n2 + 1, rankChar(toSq));
            let n3 = n2 + 2;

            let promotionCode = Move.promotionCode(move);
            let n4 =
                if (promotionCode != 0) {
                    putChar(buf, n3, '=');
                    putChar(buf, n3 + 1, roleChar(Role.ofIndex(promotionCode - 1)));
                    n3 + 2
                } else n3;
            mkString(buf, n4)
        } else
            "--"

    /// `buf(i) = (char) cp`. `Character.toChars`-free: every code point written here
    /// is ASCII.
    @Inline
    def putChar(buf: Array[Char, r], i: Int32, c: Char): Unit \ r =
        Array.put(c, i, buf)

    /// `(char) ('a' + Square.file(sq))`, without an Int32 -> Char conversion:
    /// Flix has none, and `String.charAt` is on the compiler's pure whitelist.
    @Inline
    def fileChar(sq: Int32): Char = String.charAt(Square.file(sq), "abcdefgh")

    @Inline
    def rankChar(sq: Int32): Char = String.charAt(Square.rank(sq), "12345678")

    /// The role's SAN letter. Never called for a pawn, whose symbol is empty.
    @Inline
    def roleChar(r: Role): Char = String.charAt(0, Role.symbol(r))

    /// `new java.lang.String(buf, 0, n)` — one `String` and one `byte[]`, against the
    /// `StringBuilder` wrapper enum + `java.lang.StringBuilder` + its `byte[]` +
    /// the `String` + its `byte[]` that the builder form allocated.
    @Inline
    def mkString(buf: Array[Char, r], n: Int32): String \ r =
        unsafe IO as r { JString.valueOf(buf, 0, n) }

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
                if (Move.roleIndex(other) == Move.roleIndex(move) and
                    Move.toSq(other) == Move.toSq(move) and
                    Move.fromSq(other) != Move.fromSq(move))
                    Bits.borL(acc, Bits.bit(Move.fromSq(other)))
                else
                    acc;
            othersLoop(move, legals, i + 1, next)
        }

    ///
    /// `s.startsWith(p)`, without the named-argument record.
    ///
    /// `String.startsWith(prefix = p, s)` takes a `{prefix = String}` record, which
    /// Flix compiles to a heap `RecordExtend$Obj` plus a string-keyed field lookup
    /// plus a trampolined call — twice per encoded ply, unconditionally. The
    /// standard library's own body is `s.startsWith(prefix#prefix)` inside a *pure*
    /// def, which is the proof that `java.lang.String` instance methods need no
    /// `unsafe` here.
    ///
    @Inline
    def hasPrefix(s: String, p: String): Bool = s.startsWith(p)

    ///
    /// `buffer.slice(0, n)` on a byte array: exactly ONE copy, which is what Scala's
    /// `positionHashes.slice` costs. This replaced
    /// `Vector.slice(0, n, Array.toVector(buffer))`, which copied twice, and whose
    /// result `Api.resultPositionHashes` then copied a third time.
    ///
    def sliceBytes(rc: Region[r], buffer: Array[Int8, r], n: Int32): Array[Int8, r] \ r =
        let out = Array.empty(rc, n);
        def loop(i) = {
            if (i < n) { Array.put(Array.get(i, buffer), i, out); loop(i + 1) } else ()
        };
        loop(0);
        out

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
    /// `decode` takes and returns region arrays rather than `Vector`s (it wraps the
    /// caller's bytes the way `ByteBuffer.wrap` does, and hands back the `String[]`
    /// the original hands back), so the fixtures are converted at the boundary.
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
                    let d = GameEncoder.decode(rc, gt, Vector.toArray(rc, bytes), 6);
                    Assert.assertEq(expected = moves, Array.toVector(DecodeResult.pgnMoves(d)));
                    Assert.assertEq(expected = 2, DecodeResult.halfMoveClock(d));
                    Assert.assertEq(
                        expected = Vector#{0i8, -3i8, -45i8, 101i8, 42i8, 96i8, 34i8, -92i8, -117i8},
                        Array.toVector(DecodeResult.positionHashes(d)));
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
        let d = GameEncoder.decode(rc, gt, Array.empty(rc, 0), 0);
        Assert.assertEq(expected = Vector#{70i8, 59i8, -106i8},
                        Array.toVector(DecodeResult.positionHashes(d)));
        Assert.assertEq(expected = None, DecodeResult.lastUci(d))
    }

    ///
    /// The "least surprise" test: 22 zero bytes decode to the most probable game.
    ///
    @Test
    pub def testLeastSurprise(): Unit \ Assert = region rc {
        let gt = GameTables.mk();
        let d = GameEncoder.decode(rc, gt, Array.repeat(rc, 22, 0i8), 22);
        Assert.assertEq(
            expected = "e4 e5 Nf3 Nf6 Nxe5 Nxe4 Nxf7 Kxf7 d4 Nxf2 Kxf2 d5 Nc3 Nc6 Nxd5 Qxd5 "
                     + "Kg1 Nxd4 Qxd4 Qxd4+ Be3 Qxe3#",
            String.intercalate(" ", Array.toList(DecodeResult.pgnMoves(d))))
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
