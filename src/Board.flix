///
/// A mutable chess position: bitboards, castling rights, en passant square, the
/// incremental Zobrist hash, and full legal move generation.
///
/// Port of `src/main/scala/game/Board.scala`.
///
/// # Shape
///
/// The Scala class is mutable and is mutated in place by `play`, so this is a
/// region-allocated `struct`, not an immutable value. Flix only resolves `b->field`
/// inside the module named after the struct, so *everything* that touches board
/// state — which is the whole move generator — lives in `mod Board`.
///
/// # The three static tables travel with the board
///
/// Scala reaches `Bitboard.ATTACKS`, `Move.PSQT` and `ZobristHash.POLYGLOT` as
/// statics. Flix has no statics and no `@Memoize`, so each of the three is a value
/// that must be built once and threaded (see PORTING-NOTES.md). Rather than add
/// three parameters to every one of the twenty functions below, they are stored as
/// **immutable** fields on the board:
///
/// ```flix
/// let tables  = Tables.mk();            // ~100 ms, once per process
/// let psqt    = Psqt.mk();
/// let zobrist = ZobristHash.polyglot();
/// region rc {
///     let b = Board.initial(rc, tables, psqt, zobrist);
///     let ml = MoveList.mkDefault(rc);
///     Board.legalMoves(b, ml)
/// }
/// ```
///
/// `Board.copy` copies the three references, so a perft/search tree shares one set
/// of tables. Reading a non-`mut` field is pure, so they cost nothing extra.
///
/// # `null` and early `return`
///
///   * `roleAt` returns `Role` or `null` in Scala. Here `roleAt` returns
///     `Option[Role]`; the internal callers (`discardAt`, `pieceMap`, the Zobrist
///     piece loop) only ever ask about occupied squares and use `roleAtOrBug`,
///     whose `bug!` stands in for the `MatchError`/NPE Scala would raise.
///   * Scala's `discard` is `discardAt` here: **`discard` is a keyword in Flix
///     0.75.1** and cannot be a `def` name. It joins `and`/`or`/`not`/`run`/`new`
///     on the reserved list in PORTING-NOTES.md.
///   * `move.promotion != null` becomes `Option` matching.
///   * The one `break` in the program (`genCastling`'s king-path scan) becomes a
///     tail-recursive predicate `kingPathIsSafe`: `break` means "a square on the
///     king's path is attacked", and falling out of the loop with `kingPath == 0`
///     is exactly the condition Scala re-tests afterwards. The `breakable` block
///     encloses that re-test, so a `break` skips the `pushCastle` entirely — which
///     is what returning `false` does here.
///   * Every `while` over a bitboard becomes a tail-recursive helper with the
///     bitboard as an accumulator; `x &= x - 1` (clear lowest set bit) is preserved
///     verbatim, so squares are visited in ascending order and moves are pushed in
///     exactly the Scala order. That order is load-bearing: `MoveList.selectRank`'s
///     quickselect resolves score ties by position.
///
/// # Fidelity notes
///
///   * Scala's `&` binds tighter than `|`, so `a & b | c & d` is `(a&b) | (c&d)`.
///     Every such expression (`sliderBlockers`, `attacksTo`) is parenthesised
///     explicitly here.
///   * `Square.aligned(a, b, c)` is `Bitboard.aligned(tables, a, b, c)` — see
///     `Bitboard.flix` for why it had to move.
///   * `Bitboard.RANKS(i)` is `Bitboard.ranks(tables, i)`, the table read, not the
///     equivalent `Bitboard.rankMask(i)`.
///   * `0x8100000000000081L` and `0xffff000000000000L` exceed `Int64.maxValue` when
///     parsed as magnitudes, which Flix rejects; they are written as signed decimal
///     with the hex in a comment (PORTING-NOTES.md).
///   * All hash arithmetic is 32-bit `Int32` XOR, matching the Scala `Int`.
///
/// # Verified against the Scala original
///
/// **Perft**, against the reference counts in `src/test/scala/PerftTest.scala`:
/// all 16 `trickyBatch` assertions (Kiwipete and the standard castling /
/// en-passant / promotion / pin positions), all 6838 `batch0..batchN` gentest
/// positions at depth 4, and, from the same positions taken deeper, the start
/// position to depth 5 (4865609), Kiwipete to depth 4 (4085603), position (3) to
/// depth 6 (11030083), position (4) to depth 5 (15833292), position (5) to depth 4
/// (2103487) and position (6) to depth 4 (3894594). Every count matched.
///
/// Perft only checks the *set* of legal moves, so two further cross-checks were run
/// against the compiled Scala implementation itself:
///
///   * **Move order, scores and position hash.** An FNV-1a checksum over, at every
///     node of the tree, the generated moves in *buffer order* with each move's
///     `uci()` and `score`, plus `zobristHash()`, `isCheck()` and `pieceMap()`.
///     Scala and Flix produce bit-identical checksums over 6643 nodes (3 ply from
///     six positions) and over 277955 nodes (4 ply, moves + hash). This pins down
///     the push order that `MoveList.rank`/`selectRank` — and therefore the
///     encoder's output bytes — depend on.
///   * **The incremental hash.** `incrementalHash` equals a from-scratch
///     `hashPieces ^ hashTurn` at all 277955 nodes, so `discardAt`/`put`/`play`
///     maintain it correctly.
///
mod Board {

    ///
    /// The position. Field order follows the Scala constructor, with `occupied` and
    /// `incrementalHash` (the two derived `var`s) last and the three static tables
    /// first.
    ///
    /// (Doc-comments are illegal on struct fields in Flix 0.75.1, so the field
    /// notes are here: `tables` is Scala's `Bitboard` object, `psqt` is `Move.PSQT`,
    /// `zobrist` is `ZobristHash.POLYGLOT`; `turn` is `true` for White to move;
    /// `epSquare` is `0` for "none", not `-1`; `castlingRights` is a bitboard of the
    /// *rook* squares that still carry rights.)
    pub struct Board[r: Region] {
        tables: Tables[Static],
        psqt: Psqt,
        zobrist: Vector[Int32],
        mut pawns: Int64,
        mut knights: Int64,
        mut bishops: Int64,
        mut rooks: Int64,
        mut queens: Int64,
        mut kings: Int64,
        mut white: Int64,
        mut black: Int64,
        mut turn: Bool,
        mut epSquare: Int32,
        mut castlingRights: Int64,
        mut occupied: Int64,
        mut incrementalHash: Int32
    }

    ///
    /// The Scala primary constructor, including
    /// `occupied = white | black` and
    /// `incrementalHash = ZobristHash.hashPieces(this) ^ ZobristHash.hashTurn(this)`.
    ///
    pub def mk(
        rc: Region[r],
        tables: Tables[Static],
        psqt: Psqt,
        zobrist: Vector[Int32],
        pawns: Int64,
        knights: Int64,
        bishops: Int64,
        rooks: Int64,
        queens: Int64,
        kings: Int64,
        white: Int64,
        black: Int64,
        turn: Bool,
        epSquare: Int32,
        castlingRights: Int64
    ): Board[r] \ r = {
        let b = new Board @ rc {
            tables = tables,
            psqt = psqt,
            zobrist = zobrist,
            pawns = pawns,
            knights = knights,
            bishops = bishops,
            rooks = rooks,
            queens = queens,
            kings = kings,
            white = white,
            black = black,
            turn = turn,
            epSquare = epSquare,
            castlingRights = castlingRights,
            occupied = Bits.borL(white, black),
            incrementalHash = 0
        };
        let pieces = ZobristHash.hashPieces(zobrist, b->occupied,
                                            sq -> whiteAt(b, sq),
                                            sq -> roleAtOrBug(b, sq));
        b->incrementalHash = Bits.bxor(pieces, ZobristHash.hashTurn(zobrist, turn));
        b
    }

    ///
    /// The Scala default arguments: the standard starting position, White to move,
    /// no en-passant square, all four castling rights.
    ///
    pub def initial(rc: Region[r], tables: Tables[Static], psqt: Psqt, zobrist: Vector[Int32]): Board[r] \ r =
        mk(rc, tables, psqt, zobrist,
           0x00ff00000000ff00i64,
           0x4200000000000042i64,
           0x2400000000000024i64,
           -9151314442816847743i64,  /* 0x8100000000000081L */
           0x0800000000000008i64,
           0x1000000000000010i64,
           0x000000000000ffffi64,
           -281474976710656i64,      /* 0xffff000000000000L */
           true,
           0,
           -9151314442816847743i64)  /* 0x8100000000000081L */

    ///
    /// Scala `def copy(): Board`.
    ///
    /// The original re-runs the constructor and then overwrites `occupied` and
    /// `incrementalHash`; copying them straight across is the same value without the
    /// 32-square hash walk. The three static tables are shared, not rebuilt.
    ///
    pub def copy(rc: Region[r2], b: Board[r]): Board[r2] \ r + r2 =
        new Board @ rc {
            tables = b->tables,
            psqt = b->psqt,
            zobrist = b->zobrist,
            pawns = b->pawns,
            knights = b->knights,
            bishops = b->bishops,
            rooks = b->rooks,
            queens = b->queens,
            kings = b->kings,
            white = b->white,
            black = b->black,
            turn = b->turn,
            epSquare = b->epSquare,
            castlingRights = b->castlingRights,
            occupied = b->occupied,
            incrementalHash = b->incrementalHash
        }

    // ---------------------------------------------------------------- accessors

    /// Scala `board.pawns`.
    pub def pawns(b: Board[r]): Int64 \ r = b->pawns

    /// Scala `board.knights`.
    pub def knights(b: Board[r]): Int64 \ r = b->knights

    /// Scala `board.bishops`.
    pub def bishops(b: Board[r]): Int64 \ r = b->bishops

    /// Scala `board.rooks`.
    pub def rooks(b: Board[r]): Int64 \ r = b->rooks

    /// Scala `board.queens`.
    pub def queens(b: Board[r]): Int64 \ r = b->queens

    /// Scala `board.kings`.
    pub def kings(b: Board[r]): Int64 \ r = b->kings

    /// Scala `board.white`.
    pub def whitePieces(b: Board[r]): Int64 \ r = b->white

    /// Scala `board.black`.
    pub def blackPieces(b: Board[r]): Int64 \ r = b->black

    /// Scala `board.occupied`.
    pub def occupied(b: Board[r]): Int64 \ r = b->occupied

    /// Scala `board.turn`; `true` = White to move.
    pub def turn(b: Board[r]): Bool \ r = b->turn

    /// Scala `board.epSquare`; `0` means none.
    pub def epSquare(b: Board[r]): Int32 \ r = b->epSquare

    /// Scala `board.castlingRights`.
    pub def castlingRights(b: Board[r]): Int64 \ r = b->castlingRights

    /// Scala `board.incrementalHash`.
    pub def incrementalHash(b: Board[r]): Int32 \ r = b->incrementalHash

    /// The attack tables this board was built with.
    pub def tables(b: Board[r]): Tables[Static] = b->tables

    /// The piece-square table this board was built with.
    pub def psqt(b: Board[r]): Psqt = b->psqt

    /// The Polyglot key table this board was built with.
    pub def zobrist(b: Board[r]): Vector[Int32] = b->zobrist

    // ------------------------------------------------------------ piece queries

    ///
    /// Scala `private def isOccupied(square: Int): Boolean`.
    ///
    @Inline
    def isOccupied(b: Board[r], square: Int32): Bool \ r =
        Bitboard.contains(b->occupied, square)

    ///
    /// Scala `def roleAt(square: Int): Role`, with `null` spelled `None`.
    ///
    /// The test order — pawn, knight, bishop, rook, queen, king — is the Scala
    /// order; the six boards are disjoint so it does not affect the answer.
    ///
    pub def roleAt(b: Board[r], square: Int32): Option[Role] \ r =
        if (Bitboard.contains(b->pawns, square)) Some(Role.Pawn)
        else if (Bitboard.contains(b->knights, square)) Some(Role.Knight)
        else if (Bitboard.contains(b->bishops, square)) Some(Role.Bishop)
        else if (Bitboard.contains(b->rooks, square)) Some(Role.Rook)
        else if (Bitboard.contains(b->queens, square)) Some(Role.Queen)
        else if (Bitboard.contains(b->kings, square)) Some(Role.King)
        else None

    ///
    /// `roleAt` for the internal callers that have already established the square is
    /// occupied. Scala returns `null` there and immediately `match`es on it, so an
    /// empty square is a crash in the original too; `bug!` is that crash.
    ///
    def roleAtOrBug(b: Board[r], square: Int32): Role \ r =
        if (Bitboard.contains(b->pawns, square)) Role.Pawn
        else if (Bitboard.contains(b->knights, square)) Role.Knight
        else if (Bitboard.contains(b->bishops, square)) Role.Bishop
        else if (Bitboard.contains(b->rooks, square)) Role.Rook
        else if (Bitboard.contains(b->queens, square)) Role.Queen
        else if (Bitboard.contains(b->kings, square)) Role.King
        else bug!("Board.roleAt: no piece on square")

    ///
    /// Scala `def whiteAt(square: Int): Boolean`.
    ///
    @Inline
    pub def whiteAt(b: Board[r], square: Int32): Bool \ r =
        Bitboard.contains(b->white, square)

    ///
    /// Scala `def us(): Long = byColor(this.turn)`.
    ///
    @Inline
    pub def us(b: Board[r]): Int64 \ r = byColor(b, b->turn)

    ///
    /// Scala `def them(): Long = byColor(!this.turn)`.
    ///
    @Inline
    pub def them(b: Board[r]): Int64 \ r = byColor(b, not b->turn)

    ///
    /// Scala `def byColor(white: Boolean): Long`.
    ///
    @Inline
    pub def byColor(b: Board[r], white: Bool): Int64 \ r =
        if (white) b->white else b->black

    ///
    /// Scala `private def getKing(white: Boolean): Int`.
    ///
    @Inline
    def getKing(b: Board[r], white: Bool): Int32 \ r =
        Bitboard.lsb(Bits.bandL(b->kings, byColor(b, white)))

    ///
    /// Scala `def pieceMap(): Map[Int, Piece]`.
    ///
    pub def pieceMap(b: Board[r]): Map[Int32, Piece] \ r =
        pieceMapLoop(b, b->occupied, Map.empty())

    def pieceMapLoop(b: Board[r], remaining: Int64, acc: Map[Int32, Piece]): Map[Int32, Piece] \ r =
        if (remaining == 0i64) acc
        else {
            let sq = Bitboard.lsbAt(remaining);
            let piece = Piece.Piece(whiteAt(b, sq), roleAtOrBug(b, sq));
            pieceMapLoop(b, Bits.bandL(remaining, remaining - 1i64), Map.insert(sq, piece, acc))
        }

    // ------------------------------------------------------------------ hashing

    ///
    /// Scala `def zobristHash(): Int`:
    /// `incrementalHash ^ hashCastling(this) ^ hashEnPassant(this)`.
    ///
    /// `ZobristHash.hashEnPassant` takes `board.hasLegalEnPassant()` as a flag
    /// because it cannot see `Board`; the short-circuit is preserved by Flix's
    /// eager evaluation only in so far as the flag is always computed — and
    /// `hasLegalEnPassant` itself returns `false` immediately when `epSquare == 0`,
    /// which is the case the Scala short-circuit was avoiding work for.
    ///
    pub def zobristHash(b: Board[r]): Int32 \ r = {
        let h1 = Bits.bxor(b->incrementalHash, ZobristHash.hashCastling(b->zobrist, b->castlingRights));
        Bits.bxor(h1, ZobristHash.hashEnPassant(b->zobrist, hasLegalEnPassant(b), b->epSquare))
    }

    // ---------------------------------------------------------- board mutations

    ///
    /// Scala `private def discard(square: Int): Unit`, renamed because **`discard`
    /// is a keyword in Flix 0.75.1** (`'discard' is a keyword`, verified by compile
    /// failure).
    ///
    /// `color` is read *before* `white`/`black` are updated, exactly as in the
    /// original, and the hash is folded in last.
    ///
    def discardAt(b: Board[r], square: Int32): Unit \ r =
        if (isOccupied(b, square)) {
            let mask = Bits.bit(square);
            let role = roleAtOrBug(b, square);
            xorRole(b, role, mask);
            let color = whiteAt(b, square);
            if (color) b->white = Bits.bxorL(b->white, mask)
            else b->black = Bits.bxorL(b->black, mask);
            b->occupied = Bits.bxorL(b->occupied, mask);
            b->incrementalHash =
                Bits.bxor(b->incrementalHash, ZobristHash.hashPiece(b->zobrist, square, color, role))
        } else
            ()

    ///
    // ------------------------------------------------------- a note on `; ()`
    //
    // Several defs below end in `<call>;` followed by a bare `()`. That `()` is
    // not dead code and must not be tidied away.
    //
    // Flix compiles a call to a *different* def in TAIL position into a heap
    // continuation: `new Board/Def$put; putfield arg0..argN; areturn`, which the
    // caller's trampoline then dispatches through `invokeinterface Thunk$.invoke()`
    // — megamorphic, because ~3000 classes in the jar implement `Thunk$`. Moving
    // the same call out of tail position compiles it to a plain `invokestatic`.
    // A trailing `()` on a `Unit`-returning def does exactly that, and is the
    // identity on a `Unit` expression. (`let r = f(x); r` does NOT work: a let of
    // a tail call is still a tail call.)
    //
    // Self-recursive tail calls are unaffected — Flix compiles those to `goto` —
    // and this is only applied to BOUNDED delegations (a wrapper calling a loop,
    // one extra JVM frame). Never do it to a recursive or mutually recursive loop:
    // the thunk is what makes those stack-safe.
    //
    // The same reasoning is why `attacksTo`, `sliderBlockers`, `genSafeKing`,
    // `genEnPassant` and `genCastling` are `@Inline`: their bodies are a single
    // delegation, so inlining makes the *caller* issue the `invokestatic` and the
    // thunk never exists.

    /// Scala `private def put(square: Int, color: Boolean, role: Role): Unit`.
    ///
    def put(b: Board[r], square: Int32, color: Bool, role: Role): Unit \ r = {
        discardAt(b, square);
        let mask = Bits.bit(square);
        xorRole(b, role, mask);
        if (color) b->white = Bits.bxorL(b->white, mask)
        else b->black = Bits.bxorL(b->black, mask);
        b->occupied = Bits.bxorL(b->occupied, mask);
        b->incrementalHash =
            Bits.bxor(b->incrementalHash, ZobristHash.hashPiece(b->zobrist, square, color, role))
    }

    ///
    /// The `role match { case Role.PAWN => this.pawns ^= mask; ... }` shared by
    /// `discardAt` and `put`.
    ///
    def xorRole(b: Board[r], role: Role, mask: Int64): Unit \ r = match role {
        case Role.Pawn   => b->pawns   = Bits.bxorL(b->pawns, mask)
        case Role.Knight => b->knights = Bits.bxorL(b->knights, mask)
        case Role.Bishop => b->bishops = Bits.bxorL(b->bishops, mask)
        case Role.Rook   => b->rooks   = Bits.bxorL(b->rooks, mask)
        case Role.Queen  => b->queens  = Bits.bxorL(b->queens, mask)
        case Role.King   => b->kings   = Bits.bxorL(b->kings, mask)
    }

    ///
    /// Scala `def play(move: Move): Unit`.
    ///
    /// Note that a castling move is stored king-square -> **rook**-square, so the
    /// castling branch discards both and puts the rook and king on their destination
    /// squares; and that an en-passant move's captured pawn sits on
    /// `Square.combine(to, from)` — the file of `to` and the rank of `from`.
    ///
    pub def play(b: Board[r], move: Move): Unit \ r = {
        b->epSquare = 0;
        let ty = Move.moveType(move);
        if (ty == Move.normal()) playNormal(b, move)
        else if (ty == Move.castling()) playCastling(b, move)
        else if (ty == Move.enPassant()) playEnPassant(b, move)
        else bug!("Board.play: unknown move type");
        b->turn = not b->turn;
        b->incrementalHash = Bits.bxor(b->incrementalHash, ZobristHash.turnKey(b->zobrist))
    }

    /// The `case Move.NORMAL` branch of `play`.
    def playNormal(b: Board[r], move: Move): Unit \ r = {
        let fromSq = Move.fromSq(move);
        let toSq = Move.toSq(move);
        // Set the en-passant square only if some enemy pawn could actually take.
        if (Move.roleIndex(move) == Role.index(Role.Pawn) and Bits.absInt(fromSq - toSq) == 16) {
            let theirPawns = Bits.bandL(them(b), b->pawns);
            if (theirPawns != 0i64) {
                let sq = fromSq + (if (b->turn) 8 else -8);
                if (Bits.bandL(Bitboard.pawnAttacks(b->tables, b->turn, sq), theirPawns) != 0i64)
                    b->epSquare = sq
                else ()
            } else ()
        } else ();

        if (b->castlingRights != 0i64) {
            if (Move.roleIndex(move) == Role.index(Role.King))
                b->castlingRights =
                    Bits.bandL(b->castlingRights, Bitboard.ranks(b->tables, if (b->turn) 7 else 0))
            else if (Move.roleIndex(move) == Role.index(Role.Rook))
                b->castlingRights = Bits.bandL(b->castlingRights, Bits.bnotL(Bits.bit(fromSq)))
            else ();
            if (Move.capture(move))
                b->castlingRights = Bits.bandL(b->castlingRights, Bits.bnotL(Bits.bit(toSq)))
            else ()
        } else ();

        discardAt(b, fromSq);
        // `Move.promotionCode`, not `Move.promotion`: the latter would allocate a
        // `Some` on every promotion just to be matched apart again. Both arms are
        // already role *indices*, so only one `Role.ofIndex` is needed.
        let promotionCode = Move.promotionCode(move);
        let placed =
            Role.ofIndex(if (promotionCode == 0) Move.roleIndex(move) else promotionCode - 1);
        put(b, toSq, b->turn, placed);
        ()
    }

    /// The `case Move.CASTLING` branch of `play`.
    def playCastling(b: Board[r], move: Move): Unit \ r = {
        let fromSq = Move.fromSq(move);
        let toSq = Move.toSq(move);
        b->castlingRights = Bits.bandL(b->castlingRights, Bitboard.ranks(b->tables, if (b->turn) 7 else 0));
        let rookTo = Square.combine(if (toSq < fromSq) Square.d1() else Square.f1(), toSq);
        let kingTo = Square.combine(if (toSq < fromSq) Square.c1() else Square.g1(), fromSq);
        discardAt(b, fromSq);
        discardAt(b, toSq);
        put(b, rookTo, b->turn, Role.Rook);
        put(b, kingTo, b->turn, Role.King);
        ()
    }

    /// The `case Move.EN_PASSANT` branch of `play`.
    def playEnPassant(b: Board[r], move: Move): Unit \ r = {
        let fromSq = Move.fromSq(move);
        let toSq = Move.toSq(move);
        discardAt(b, Square.combine(toSq, fromSq));
        discardAt(b, fromSq);
        put(b, toSq, b->turn, Role.Pawn);
        ()
    }

    // --------------------------------------------------------- attack detection

    ///
    /// Scala `private def sliderBlockers(king: Int): Long`.
    ///
    /// Scala's `&` binds tighter than `|`, so the snipers expression groups as
    /// `(rookAttacks & (rooks ^ queens)) | (bishopAttacks & (bishops ^ queens))`.
    ///
    @Inline
    def sliderBlockers(b: Board[r], king: Int32): Int64 \ r = {
        let t = b->tables;
        let snipers =
            Bits.bandL(
                them(b),
                Bits.borL(
                    Bits.bandL(Bitboard.rookAttacks(t, king, 0i64), Bits.bxorL(b->rooks, b->queens)),
                    Bits.bandL(Bitboard.bishopAttacks(t, king, 0i64), Bits.bxorL(b->bishops, b->queens))));
        sliderBlockersLoop(b, king, snipers, 0i64)
    }

    def sliderBlockersLoop(b: Board[r], king: Int32, remainingSnipers: Int64, blockers: Int64): Int64 \ r =
        if (remainingSnipers == 0i64) blockers
        else {
            let sniper = Bitboard.lsbAt(remainingSnipers);
            let between = Bits.bandL(Bitboard.between(b->tables, king, sniper), b->occupied);
            let next = if (not Bitboard.moreThanOne(between)) Bits.borL(blockers, between) else blockers;
            sliderBlockersLoop(b, king, Bits.bandL(remainingSnipers, remainingSnipers - 1i64), next)
        }

    ///
    /// Scala `def isCheck(): Boolean`.
    ///
    pub def isCheck(b: Board[r]): Bool \ r =
        attacksTo(b, getKing(b, b->turn), not b->turn) != 0i64

    ///
    /// Scala `private def attacksTo(sq: Int, attacker: Boolean): Long`, using the
    /// board's current occupancy.
    ///
    @Inline
    def attacksTo(b: Board[r], sq: Int32, attacker: Bool): Int64 \ r =
        attacksToOcc(b, sq, attacker, b->occupied)

    ///
    /// Scala `private def attacksTo(sq: Int, attacker: Boolean, occupied: Long): Long`.
    ///
    /// The five `&` terms are OR-ed together; `&` binds tighter than `|` in Scala,
    /// so each pairing is as parenthesised here.
    ///
    def attacksToOcc(b: Board[r], sq: Int32, attacker: Bool, occ: Int64): Int64 \ r = {
        let t = b->tables;
        let a1 = Bits.bandL(Bitboard.rookAttacks(t, sq, occ), Bits.bxorL(b->rooks, b->queens));
        let a2 = Bits.bandL(Bitboard.bishopAttacks(t, sq, occ), Bits.bxorL(b->bishops, b->queens));
        let a3 = Bits.bandL(Bitboard.knightAttacks(t, sq), b->knights);
        let a4 = Bits.bandL(Bitboard.kingAttacks(t, sq), b->kings);
        let a5 = Bits.bandL(Bitboard.pawnAttacks(t, not attacker, sq), b->pawns);
        Bits.bandL(
            byColor(b, attacker),
            Bits.borL(Bits.borL(Bits.borL(Bits.borL(a1, a2), a3), a4), a5))
    }

    // A short-circuiting `isAttacked(b, sq, attacker)` was tried here and REVERTED.
    // `isCheck`, `genSafeKingLoop` and `kingPathIsSafe` only ever test this set
    // against zero, and by distributivity of `&` over `|` the five terms can be
    // evaluated one at a time, cheapest first, stopping at the first hit — which
    // skips both magic lookups whenever a knight, king or pawn already attacks the
    // square, and is genuinely less work than the Scala original does. It measured
    // as nothing: encode and decode both moved less than the run-to-run spread of a
    // three-iteration JMH run. Forty lines restating `attacksToOcc`'s five terms in
    // a reference implementation is not worth an unmeasurable gain, so it is gone.
    // If someone revisits it, measure with `-f 2 -i 5`, not `-i 3`.

    // ---------------------------------------------------------- move generation

    ///
    /// Scala `def legalMoves(moves: MoveList): Unit`.
    ///
    /// ```scala
    /// moves.clear()
    /// if this.epSquare != 0 then genEnPassant(moves)
    /// val king     = getKing(this.turn)
    /// val checkers = attacksTo(king, !this.turn)
    /// if checkers == 0 then
    ///   val target = ~us()
    ///   genNonKing(target, moves); genSafeKing(king, target, moves); genCastling(king, moves)
    /// else genEvasions(king, checkers, moves)
    /// val blockers = sliderBlockers(king)
    /// if blockers != 0 || this.epSquare != 0 then moves.retain(isSafe(king, _, blockers))
    /// ```
    ///
    /// The `MoveCtx` (the five things `Move.set` reads off the board) is built once
    /// here: nothing in generation mutates the board, so it is constant throughout.
    ///
    pub def legalMoves(b: Board[r], moves: MoveList[r2]): Unit \ r + r2 = {
        MoveList.clear(moves);
        let ctx = moveCtx(b);
        if (b->epSquare != 0) genEnPassant(b, ctx, moves) else ();

        let king = getKing(b, b->turn);
        let checkers = attacksTo(b, king, not b->turn);
        if (checkers == 0i64) {
            let target = Bits.bnotL(us(b));
            genNonKing(b, ctx, target, moves);
            genSafeKing(b, ctx, king, target, moves);
            genCastling(b, ctx, king, moves)
        } else
            genEvasions(b, ctx, king, checkers, moves);

        let blockers = sliderBlockers(b, king);

        if (blockers != 0i64 or b->epSquare != 0)
            MoveList.retain(moves, m -> isSafe(b, king, m, blockers))
        else
            ();
        ()
    }

    ///
    /// The `MoveCtx` for the current position: `Move.set` reads exactly `board.turn`,
    /// `board.pawns` and `board.them()`, plus the two static tables.
    ///
    @Inline
    def moveCtx(b: Board[r]): MoveCtx \ r =
        MoveCtx.mk(b->tables, b->psqt, b->turn, b->pawns, them(b))

    ///
    /// Scala `def hasLegalEnPassant(): Boolean`.
    ///
    /// The throwaway `MoveList(2)` lives in a nested region, whose effect is
    /// discharged at the block boundary, so this is still just `\ r`.
    ///
    pub def hasLegalEnPassant(b: Board[r]): Bool \ r =
        if (b->epSquare == 0) false
        else region rc {
            let moves = MoveList.mk(rc, 2);
            genEnPassant(b, moveCtx(b), moves);
            let king = getKing(b, b->turn);
            let blockers = sliderBlockers(b, king);
            MoveList.exists(moves, m -> isSafe(b, king, m, blockers))
        }

    ///
    /// Scala `private def genNonKing(mask: Long, moves: MoveList): Unit`: pawns,
    /// then knights, bishops, rooks, queens — in that order, and within each piece
    /// type from the lowest square upwards.
    ///
    def genNonKing(b: Board[r], ctx: MoveCtx, mask: Int64, moves: MoveList[r2]): Unit \ r + r2 = {
        genPawn(b, ctx, mask, moves);
        genKnights(b, ctx, mask, moves, Bits.bandL(us(b), b->knights));
        genBishops(b, ctx, mask, moves, Bits.bandL(us(b), b->bishops));
        genRooks(b, ctx, mask, moves, Bits.bandL(us(b), b->rooks));
        genQueens(b, ctx, mask, moves, Bits.bandL(us(b), b->queens));
        ()
    }

    def genKnights(b: Board[r], ctx: MoveCtx, mask: Int64, moves: MoveList[r2], pieces: Int64): Unit \ r + r2 =
        if (pieces == 0i64) ()
        else {
            let fromSq = Bitboard.lsbAt(pieces);
            let targets = Bits.bandL(Bitboard.knightAttacks(b->tables, fromSq), mask);
            pushTargets(b, ctx, Role.Knight, fromSq, moves, targets);
            genKnights(b, ctx, mask, moves, Bits.bandL(pieces, pieces - 1i64))
        }

    def genBishops(b: Board[r], ctx: MoveCtx, mask: Int64, moves: MoveList[r2], pieces: Int64): Unit \ r + r2 =
        if (pieces == 0i64) ()
        else {
            let fromSq = Bitboard.lsbAt(pieces);
            let targets = Bits.bandL(Bitboard.bishopAttacks(b->tables, fromSq, b->occupied), mask);
            pushTargets(b, ctx, Role.Bishop, fromSq, moves, targets);
            genBishops(b, ctx, mask, moves, Bits.bandL(pieces, pieces - 1i64))
        }

    def genRooks(b: Board[r], ctx: MoveCtx, mask: Int64, moves: MoveList[r2], pieces: Int64): Unit \ r + r2 =
        if (pieces == 0i64) ()
        else {
            let fromSq = Bitboard.lsbAt(pieces);
            let targets = Bits.bandL(Bitboard.rookAttacks(b->tables, fromSq, b->occupied), mask);
            pushTargets(b, ctx, Role.Rook, fromSq, moves, targets);
            genRooks(b, ctx, mask, moves, Bits.bandL(pieces, pieces - 1i64))
        }

    def genQueens(b: Board[r], ctx: MoveCtx, mask: Int64, moves: MoveList[r2], pieces: Int64): Unit \ r + r2 =
        if (pieces == 0i64) ()
        else {
            let fromSq = Bitboard.lsbAt(pieces);
            let targets = Bits.bandL(Bitboard.queenAttacks(b->tables, fromSq, b->occupied), mask);
            pushTargets(b, ctx, Role.Queen, fromSq, moves, targets);
            genQueens(b, ctx, mask, moves, Bits.bandL(pieces, pieces - 1i64))
        }

    /// The inner `while targets != 0` loop shared by the four non-pawn generators.
    def pushTargets(b: Board[r], ctx: MoveCtx, role: Role, fromSq: Int32,
                    moves: MoveList[r2], targets: Int64): Unit \ r + r2 =
        if (targets == 0i64) ()
        else {
            let toSq = Bitboard.lsbAt(targets);
            MoveList.pushNormal(moves, ctx, role, fromSq, isOccupied(b, toSq), toSq);
            pushTargets(b, ctx, role, fromSq, moves, Bits.bandL(targets, targets - 1i64))
        }

    ///
    /// Scala `private def genSafeKing(king: Int, mask: Long, moves: MoveList): Unit`.
    ///
    /// The safety test uses the *current* occupancy, so the king is still standing
    /// on its origin square while its destinations are tested — that is what the
    /// original does, and `genEvasions` compensates by masking out slider rays.
    ///
    @Inline
    def genSafeKing(b: Board[r], ctx: MoveCtx, king: Int32, mask: Int64, moves: MoveList[r2]): Unit \ r + r2 =
        genSafeKingLoop(b, ctx, king, moves, Bits.bandL(Bitboard.kingAttacks(b->tables, king), mask))

    def genSafeKingLoop(b: Board[r], ctx: MoveCtx, king: Int32,
                        moves: MoveList[r2], targets: Int64): Unit \ r + r2 =
        if (targets == 0i64) ()
        else {
            let toSq = Bitboard.lsbAt(targets);
            if (attacksTo(b, toSq, not b->turn) == 0i64)
                MoveList.pushNormal(moves, ctx, Role.King, king, isOccupied(b, toSq), toSq)
            else ();
            genSafeKingLoop(b, ctx, king, moves, Bits.bandL(targets, targets - 1i64))
        }

    ///
    /// Scala `private def genEvasions(king: Int, checkers: Long, moves: MoveList): Unit`.
    ///
    /// `attacked` is the union of the rays through the king from each checking
    /// slider, minus the slider square itself, so the king may not step backwards
    /// along a checking line. `checkers & (bishops ^ rooks ^ queens)` is the Scala
    /// expression verbatim — a triple XOR, not an OR.
    ///
    def genEvasions(b: Board[r], ctx: MoveCtx, king: Int32, checkers: Int64,
                    moves: MoveList[r2]): Unit \ r + r2 = {
        let sliders = Bits.bandL(checkers, Bits.bxorL(Bits.bxorL(b->bishops, b->rooks), b->queens));
        let attacked = evasionRays(b, king, sliders, 0i64);

        genSafeKing(b, ctx, king, Bits.bandL(Bits.bnotL(us(b)), Bits.bnotL(attacked)), moves);

        if (checkers != 0i64 and not Bitboard.moreThanOne(checkers)) {
            let checker = Bitboard.lsbAt(checkers);
            let target = Bits.borL(Bitboard.between(b->tables, king, checker), checkers);
            genNonKing(b, ctx, target, moves)
        } else
            ();
        ()
    }

    def evasionRays(b: Board[r], king: Int32, sliders: Int64, attacked: Int64): Int64 \ r =
        if (sliders == 0i64) attacked
        else {
            let slider = Bitboard.lsbAt(sliders);
            let ray = Bits.bxorL(Bitboard.rays(b->tables, king, slider), Bits.bit(slider));
            evasionRays(b, king, Bits.bandL(sliders, sliders - 1i64), Bits.borL(attacked, ray))
        }

    ///
    /// Scala `private def genPawn(mask: Long, moves: MoveList): Unit`.
    ///
    /// Captures first (ascending capturer square, ascending target), then single
    /// pushes, then double pushes. `singleMoves`/`doubleMoves` are computed before
    /// `mask` is applied, because `doubleMoves` is derived from the *unmasked*
    /// `singleMoves` — masking early would lose double pushes whose intermediate
    /// square is outside the mask.
    ///
    def genPawn(b: Board[r], ctx: MoveCtx, mask: Int64, moves: MoveList[r2]): Unit \ r + r2 = {
        genPawnCaptures(b, ctx, mask, moves, Bits.bandL(us(b), b->pawns));

        let free = Bits.bnotL(b->occupied);
        let pushed =
            if (b->turn) Bits.shlL(Bits.bandL(b->white, b->pawns), 8)
            else Bits.ushrL(Bits.bandL(b->black, b->pawns), 8);
        let singleMoves = Bits.bandL(free, pushed);
        let doubleMoves =
            Bits.bandL(
                Bits.bandL(free, if (b->turn) Bits.shlL(singleMoves, 8) else Bits.ushrL(singleMoves, 8)),
                Bitboard.ranks(b->tables, if (b->turn) 3 else 4));

        genPawnPushes(b, ctx, moves, Bits.bandL(singleMoves, mask));
        genPawnDoubles(b, ctx, moves, Bits.bandL(doubleMoves, mask));
        ()
    }

    def genPawnCaptures(b: Board[r], ctx: MoveCtx, mask: Int64,
                        moves: MoveList[r2], capturers: Int64): Unit \ r + r2 =
        if (capturers == 0i64) ()
        else {
            let fromSq = Bitboard.lsbAt(capturers);
            let targets =
                Bits.bandL(
                    Bits.bandL(Bitboard.pawnAttacks(b->tables, b->turn, fromSq), them(b)),
                    mask);
            genPawnCaptureTargets(b, ctx, fromSq, moves, targets);
            genPawnCaptures(b, ctx, mask, moves, Bits.bandL(capturers, capturers - 1i64))
        }

    def genPawnCaptureTargets(b: Board[r], ctx: MoveCtx, fromSq: Int32,
                              moves: MoveList[r2], targets: Int64): Unit \ r + r2 =
        if (targets == 0i64) ()
        else {
            let toSq = Bitboard.lsbAt(targets);
            addPawnMoves(b, ctx, fromSq, true, toSq, moves);
            genPawnCaptureTargets(b, ctx, fromSq, moves, Bits.bandL(targets, targets - 1i64))
        }

    def genPawnPushes(b: Board[r], ctx: MoveCtx, moves: MoveList[r2], singleMoves: Int64): Unit \ r + r2 =
        if (singleMoves == 0i64) ()
        else {
            let toSq = Bitboard.lsbAt(singleMoves);
            let fromSq = toSq + (if (b->turn) -8 else 8);
            addPawnMoves(b, ctx, fromSq, false, toSq, moves);
            genPawnPushes(b, ctx, moves, Bits.bandL(singleMoves, singleMoves - 1i64))
        }

    def genPawnDoubles(b: Board[r], ctx: MoveCtx, moves: MoveList[r2], doubleMoves: Int64): Unit \ r + r2 =
        if (doubleMoves == 0i64) ()
        else {
            let toSq = Bitboard.lsbAt(doubleMoves);
            let fromSq = toSq + (if (b->turn) -16 else 16);
            MoveList.pushNormal(moves, ctx, Role.Pawn, fromSq, false, toSq);
            genPawnDoubles(b, ctx, moves, Bits.bandL(doubleMoves, doubleMoves - 1i64))
        }

    ///
    /// Scala `private def addPawnMoves(from, capture, to, moves): Unit`.
    ///
    /// The promotion order — queen, knight, rook, bishop — is not arbitrary: it is
    /// the order the moves land in the `MoveList`, which the encoder's rank
    /// tie-breaking depends on.
    ///
    /// The promotion arm is a *separate* def, and that is a size decision rather
    /// than a stylistic one. `MoveList.pushPromotion` reaches `@Inline`d
    /// `Move.mk`, so writing the four pushes inline here expanded `Move.mk`'s ~960
    /// bytecodes five times over and made `addPawnMoves` 2252 bytecodes — against
    /// Scala's 84, the largest method-size gap left in the port — on a function
    /// that runs once per generated pawn move, of which four fifths of the body was
    /// the arm taken only on the last rank. Splitting leaves the hot path small
    /// enough for HotSpot to inline into `genPawnPushes`/`genPawnCaptureTargets`
    /// and moves the bulk behind a branch that is almost never taken.
    def addPawnMoves(b: Board[r], ctx: MoveCtx, fromSq: Int32, capture: Bool,
                     toSq: Int32, moves: MoveList[r2]): Unit \ r + r2 =
        if (Square.rank(toSq) == (if (b->turn) 7 else 0))
            addPromotions(ctx, fromSq, capture, toSq, moves)
        else
            MoveList.pushNormal(moves, ctx, Role.Pawn, fromSq, capture, toSq)

    /// The four promotions, in the order the `MoveList` must hold them. Trailing
    /// `()` for the reason documented above `Board.put`: without it the last call
    /// becomes a heap continuation returned to the trampoline.
    def addPromotions(ctx: MoveCtx, fromSq: Int32, capture: Bool,
                      toSq: Int32, moves: MoveList[r2]): Unit \ r2 = {
        MoveList.pushPromotion(moves, ctx, fromSq, capture, toSq, Role.Queen);
        MoveList.pushPromotion(moves, ctx, fromSq, capture, toSq, Role.Knight);
        MoveList.pushPromotion(moves, ctx, fromSq, capture, toSq, Role.Rook);
        MoveList.pushPromotion(moves, ctx, fromSq, capture, toSq, Role.Bishop);
        ()
    }

    ///
    /// Scala `private def genEnPassant(moves: MoveList): Unit`.
    ///
    /// A pawn of ours that stands on a square from which *their* pawn on `epSquare`
    /// would attack is exactly a pawn that can capture en passant.
    ///
    @Inline
    def genEnPassant(b: Board[r], ctx: MoveCtx, moves: MoveList[r2]): Unit \ r + r2 =
        genEnPassantLoop(b, ctx, moves,
            Bits.bandL(
                Bits.bandL(us(b), b->pawns),
                Bitboard.pawnAttacks(b->tables, not b->turn, b->epSquare)))

    def genEnPassantLoop(b: Board[r], ctx: MoveCtx, moves: MoveList[r2], pawns: Int64): Unit \ r + r2 =
        if (pawns == 0i64) ()
        else {
            let pawn = Bitboard.lsbAt(pawns);
            MoveList.pushEnPassant(moves, ctx, pawn, b->epSquare);
            genEnPassantLoop(b, ctx, moves, Bits.bandL(pawns, pawns - 1i64))
        }

    ///
    /// Scala `private def genCastling(king: Int, moves: MoveList): Unit`.
    ///
    /// Note the rank selection: `castlingRights & RANKS(if turn then 0 else 7)` —
    /// White's rooks live on rank 0. The Scala `breakable`/`break` around the
    /// king-path scan is `kingPathIsSafe` here; a `break` skipped the `pushCastle`
    /// re-test entirely, which is `false`.
    ///
    @Inline
    def genCastling(b: Board[r], ctx: MoveCtx, king: Int32, moves: MoveList[r2]): Unit \ r + r2 =
        genCastlingLoop(b, ctx, king, moves,
            Bits.bandL(b->castlingRights, Bitboard.ranks(b->tables, if (b->turn) 0 else 7)))

    def genCastlingLoop(b: Board[r], ctx: MoveCtx, king: Int32,
                        moves: MoveList[r2], rooks: Int64): Unit \ r + r2 =
        if (rooks == 0i64) ()
        else {
            let rook = Bitboard.lsbAt(rooks);
            let path = Bits.bandL(Bitboard.between(b->tables, king, rook), b->occupied);
            if (path == 0i64) {
                let kingTo = Square.combine(if (rook < king) Square.c1() else Square.g1(), king);
                let kingPath =
                    Bits.borL(
                        Bits.borL(Bitboard.between(b->tables, king, kingTo), Bits.bit(kingTo)),
                        Bits.bit(king));
                if (kingPathIsSafe(b, king, kingPath)) MoveList.pushCastle(moves, ctx, king, rook)
                else ()
            } else ();
            genCastlingLoop(b, ctx, king, moves, Bits.bandL(rooks, rooks - 1i64))
        }

    ///
    /// The `breakable { while kingPath != 0 do ... }` scan: `true` when every square
    /// the king passes over (including its origin and destination) is unattacked
    /// with the king lifted off the board.
    ///
    def kingPathIsSafe(b: Board[r], king: Int32, kingPath: Int64): Bool \ r =
        if (kingPath == 0i64) true
        else {
            let sq = Bitboard.lsbAt(kingPath);
            if (attacksToOcc(b, sq, not b->turn, Bits.bxorL(b->occupied, Bits.bit(king))) != 0i64) false
            else kingPathIsSafe(b, king, Bits.bandL(kingPath, kingPath - 1i64))
        }

    ///
    /// Scala `private def isSafe(king: Int, move: Move, blockers: Long): Boolean`.
    ///
    /// A normal move is legal unless the moving piece is pinned against the king and
    /// leaves the pin line. An en-passant capture removes *two* pawns from one rank,
    /// so it needs a fresh slider check on the resulting occupancy. Castling is
    /// already fully validated by `genCastling`, hence `case _ => true`.
    ///
    /// The en-passant arm is a separate def purely for size. `isSafe` runs once per
    /// generated move through `MoveList.retain`, and the two magic-slider lookups
    /// below made the whole function 1185 bytecodes — far past the JIT's ~300-byte
    /// inlining budget, and therefore past the point where escape analysis can
    /// reclaim anything it allocates. En passant is a rare move; the normal arm is
    /// the one that has to be cheap. Nothing about the computation changed.
    def isSafe(b: Board[r], king: Int32, move: Move, blockers: Int64): Bool \ r = {
        let ty = Move.moveType(move);
        if (ty == Move.normal())
            not Bitboard.contains(Bits.bandL(us(b), blockers), Move.fromSq(move))
                or Bitboard.aligned(b->tables, Move.fromSq(move), Move.toSq(move), king)
        else if (ty == Move.enPassant())
            isSafeEnPassant(b, king, move)
        else
            true
    }

    /// The `case Move.EN_PASSANT` arm of `isSafe`; see the note there.
    def isSafeEnPassant(b: Board[r], king: Int32, move: Move): Bool \ r = {
        let occ0 = b->occupied;
        let occ1 = Bits.bxorL(occ0, Bits.bit(Move.fromSq(move)));
        let occ2 = Bits.bxorL(occ1, Bits.bit(Square.combine(Move.toSq(move), Move.fromSq(move))));
        let occ = Bits.borL(occ2, Bits.bit(Move.toSq(move)));
        let t = b->tables;
        Bits.bandL(
            Bits.bandL(Bitboard.rookAttacks(t, king, occ), them(b)),
            Bits.bxorL(b->rooks, b->queens)) == 0i64
        and
        Bits.bandL(
            Bits.bandL(Bitboard.bishopAttacks(t, king, occ), them(b)),
            Bits.bxorL(b->bishops, b->queens)) == 0i64
    }

}
