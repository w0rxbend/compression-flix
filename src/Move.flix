///
/// A generated chess move, and the move-ordering score the encoder ranks by.
///
/// Port of `src/main/scala/game/Move.scala`.
///
/// # Mutable class -> immutable value
///
/// The Scala `Move` is a mutable class whose `set(...)` overwrites all seven
/// fields in place; `MoveList` preallocates 256 of them and recycles them. Here
/// `Move` is an immutable single-case enum and `Move.mk(...)` is the `set`
/// method turned into a constructor. That is safe: nothing in the port observes
/// object identity, and dropping the pooling can only make aliasing *less*
/// surprising (the Scala `Encoder` holds a `Move` across a `board.play(move)`,
/// which happens to be sound only because `legalMoves` is not called in between).
/// See `MoveList.flix` for the rest of that argument.
///
/// # Why `Move.mk` does not take a `Board`
///
/// Scala's `set` takes the whole `Board` but reads exactly three things from it —
/// `board.turn`, `board.pawns` and `board.them()` — plus the `Bitboard` attack
/// tables. Those three plus the tables and the piece-square table are bundled
/// into `MoveCtx`, which is constant for the whole of one `Board.legalMoves`
/// call, so a caller builds it once per move generation:
///
/// ```flix
/// let ctx = MoveCtx.mk(tables, psqt, turn, pawns, them);
/// let m   = Move.mk(ctx, Move.normal(), Role.Knight, from, capture, to, None);
/// ```
///
/// `Board` may of course wrap that in a helper; the contract this file fixes is
/// the five values in `MoveCtx` and the argument order of `Move.mk`.
///
/// # Fidelity notes
///
///   * `type` stays an `Int32` with the three `Move.normal()/enPassant()/castling()`
///     constants rather than becoming an ADT, because `Encoder.san` switches on it
///     and `isIrreversible` compares it; keeping the Scala representation keeps the
///     two ports textually comparable.
///   * `promotion: Role | null` becomes `Option[Role]`. `null` is `None`.
///   * The Scala fields `from` and `to` are `fromSq` and `toSq` here, because
///     **`from` is a reserved word in Flix 0.75.1**: `pub def from(m: Move)` fails
///     with "'from' is a keyword" (verified by compile failure). `to` is not
///     reserved, but is renamed to match.
///   * The score expression is transcribed operator for operator. Scala's `<<`
///     binds *looser* than `+` (its first character `<` puts it in a lower
///     precedence class), exactly as in Java, so `512 + moveValue << 12` is
///     `(512 + moveValue) << 12`; the parenthesisation here is explicit.
///   * All arithmetic is 32-bit wrapping `Int32`, matching Java `int`.
///

///
/// The piece-square table, `Move.PSQT` in Scala: six 64-entry tables indexed by
/// `Role.index`, flattened to one 384-entry vector indexed `roleIndex * 64 + sq`.
///
/// It is an enum rather than a bare `def` returning a `Vector#{...}` literal
/// because a Flix `def` is not memoized: a literal would rebuild all 384 elements
/// on every single scored move. Build it once with `Psqt.mk()` and hold it, the
/// same discipline `Bitboard.Tables` uses.
///
/// The values are transcribed verbatim, including the deliberate asymmetries in
/// the original (pawn `21` on e4, pawn `-31` on d2/e2, knight `11` on f3,
/// queen `-5` on h4). They are not typos and must not be "fixed": they exist to
/// break ties between otherwise mirror-image moves, and changing one changes the
/// move ranking and therefore the compressed output.
///
pub enum Psqt {
    case Psqt(Vector[Int32])
}

mod Psqt {

    ///
    /// Builds the piece-square table. Pure; call once per process and hold it.
    ///
    pub def mk(): Psqt = Psqt.Psqt(Vector#{
        // PAWN (Role.index 0)
        0, 0, 0, 0, 0, 0, 0, 0,
        50, 50, 50, 50, 50, 50, 50, 50,
        10, 10, 20, 30, 30, 20, 10, 10,
        5, 5, 10, 25, 25, 10, 5, 5,
        0, 0, 0, 20, 21, 0, 0, 0,
        5, -5, -10, 0, 0, -10, -5, 5,
        5, 10, 10, -31, -31, 10, 10, 5,
        0, 0, 0, 0, 0, 0, 0, 0,
        // KNIGHT (Role.index 1)
        -50, -40, -30, -30, -30, -30, -40, -50,
        -40, -20, 0, 0, 0, 0, -20, -40,
        -30, 0, 10, 15, 15, 10, 0, -30,
        -30, 5, 15, 20, 20, 15, 5, -30,
        -30, 0, 15, 20, 20, 15, 0, -30,
        -30, 5, 10, 15, 15, 11, 5, -30,
        -40, -20, 0, 5, 5, 0, -20, -40,
        -50, -40, -30, -30, -30, -30, -40, -50,
        // BISHOP (Role.index 2)
        -20, -10, -10, -10, -10, -10, -10, -20,
        -10, 0, 0, 0, 0, 0, 0, -10,
        -10, 0, 5, 10, 10, 5, 0, -10,
        -10, 5, 5, 10, 10, 5, 5, -10,
        -10, 0, 10, 10, 10, 10, 0, -10,
        -10, 10, 10, 10, 10, 10, 10, -10,
        -10, 5, 0, 0, 0, 0, 5, -10,
        -20, -10, -10, -10, -10, -10, -10, -20,
        // ROOK (Role.index 3)
        0, 0, 0, 0, 0, 0, 0, 0,
        5, 10, 10, 10, 10, 10, 10, 5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5,
        0, 0, 0, 5, 5, 0, 0, 0,
        // QUEEN (Role.index 4)
        -20, -10, -10, -5, -5, -10, -10, -20,
        -10, 0, 0, 0, 0, 0, 0, -10,
        -10, 0, 5, 5, 5, 5, 0, -10,
        -5, 0, 5, 5, 5, 5, 0, -5,
        0, 0, 5, 5, 5, 5, 0, -5,
        -10, 5, 5, 5, 5, 5, 0, -10,
        -10, 0, 5, 0, 0, 0, 0, -10,
        -20, -10, -10, -5, -5, -10, -10, -20,
        // KING (Role.index 5)
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -30, -40, -40, -50, -50, -40, -40, -30,
        -20, -30, -30, -40, -40, -30, -30, -20,
        -10, -20, -20, -20, -20, -20, -20, -10,
        20, 20, 0, 0, 0, 0, 20, 20,
        0, 30, 10, 0, 0, 10, 30, 0
    })

    ///
    /// `Move.PSQT(roleIndex)(sq)`.
    ///
    pub def at(p: Psqt, roleIndex: Int32, sq: Int32): Int32 =
        let Psqt.Psqt(v) = p;
        Vector.get(roleIndex * 64 + sq, v)
}

///
/// Everything `Move.set` reads out of the `Board`, plus the two static tables.
///
/// Fields, in order:
///
/// ```
///   0  tables   the `Bitboard` attack tables (for `Bitboard.pawnAttacks`)
///   1  psqt     the piece-square table
///   2  turn     Scala `board.turn`   -- true = white to move
///   3  pawns    Scala `board.pawns`  -- all pawns of both colours
///   4  them     Scala `board.them()` -- every piece of the side NOT to move
/// ```
///
/// All five are constant across one `Board.legalMoves` call, so build one
/// `MoveCtx` per move generation and reuse it for every push.
///
pub enum MoveCtx {
    case MoveCtx(Tables, Psqt, Bool, Int64, Int64)
}

mod MoveCtx {

    ///
    /// Bundles the scoring inputs. Pure.
    ///
    pub def mk(tables: Tables, psqt: Psqt, turn: Bool, pawns: Int64, them: Int64): MoveCtx =
        MoveCtx.MoveCtx(tables, psqt, turn, pawns, them)

    /// The attack tables.
    pub def tables(c: MoveCtx): Tables =
        let MoveCtx.MoveCtx(t, _, _, _, _) = c;
        t

    /// The piece-square table.
    pub def psqt(c: MoveCtx): Psqt =
        let MoveCtx.MoveCtx(_, p, _, _, _) = c;
        p

    /// Scala `board.turn`.
    pub def turn(c: MoveCtx): Bool =
        let MoveCtx.MoveCtx(_, _, b, _, _) = c;
        b

    /// Scala `board.pawns`.
    pub def pawns(c: MoveCtx): Int64 =
        let MoveCtx.MoveCtx(_, _, _, p, _) = c;
        p

    /// Scala `board.them()`.
    pub def them(c: MoveCtx): Int64 =
        let MoveCtx.MoveCtx(_, _, _, _, x) = c;
        x
}

///
/// A move: `type`, `role`, `from`, `capture`, `to`, `promotion`, `score`, in the
/// field order of the Scala class.
///
/// `Eq` is derived (structural), which is *not* the Scala class's reference
/// equality; nothing in the port relies on `Move` identity, and `Encoder` only
/// ever compares individual fields. `Order` is deliberately NOT derived: the
/// Scala `Ordered[Move]` orders by score *descending*, which no structural
/// derivation would reproduce. Use `Move.compare` / `Move.lessThan`.
///
pub enum Move with Eq, ToString {
    case Move(Int32, Role, Int32, Bool, Int32, Option[Role], Int32)
}

mod Move {

    /// Scala `Move.NORMAL`.
    pub def normal(): Int32 = 0

    /// Scala `Move.EN_PASSANT`.
    pub def enPassant(): Int32 = 1

    /// Scala `Move.CASTLING`.
    pub def castling(): Int32 = 2

    ///
    /// The Scala `Move()` default: type 0, `from`/`to`/`score` 0, not a capture,
    /// no promotion. Scala leaves `role` and `promotion` `null`; there is no null
    /// here, so `role` is `Role.Pawn`.
    ///
    /// This exists only to fill the preallocated `MoveList` buffer. A slot is
    /// never read before it has been written (`MoveList.get` requires `i < size`),
    /// so the placeholder role is never observed.
    ///
    pub def empty(): Move = Move.Move(0, Role.Pawn, 0, false, 0, None, 0)

    ///
    /// The Scala `Move.set(board, type, role, from, capture, to, promotion)`,
    /// as a constructor. Computes the move-ordering score exactly as Scala does.
    ///
    /// ```scala
    /// val defendingPawns = Bitboard.pawnAttacks(board.turn, to) & board.pawns & board.them()
    /// val moveValue      = pieceValue(board, role, to) - pieceValue(board, role, from)
    /// this.score = (if promotion == null then 0 else promotion.index << 26) +
    ///   (if capture then 1 << 25 else 0) +
    ///   ((if defendingPawns == 0 then 6 else 5 - role.index) << 22) +
    ///   (512 + moveValue << 12) +
    ///   (to << 6) +
    ///   from
    /// ```
    ///
    pub def mk(ctx: MoveCtx, moveType: Int32, role: Role, fromSq: Int32, capture: Bool,
               toSq: Int32, promotion: Option[Role]): Move = {
        let defendingPawns =
            Bits.bandL(
                Bits.bandL(
                    Bitboard.pawnAttacks(MoveCtx.tables(ctx), MoveCtx.turn(ctx), toSq),
                    MoveCtx.pawns(ctx)),
                MoveCtx.them(ctx));
        let moveValue = pieceValue(ctx, role, toSq) - pieceValue(ctx, role, fromSq);
        let promotionTerm = match promotion {
            case None    => 0
            case Some(p) => Bits.shl(Role.index(p), 26)
        };
        let captureTerm = if (capture) Bits.shl(1, 25) else 0;
        let defenceTerm = Bits.shl(if (defendingPawns == 0i64) 6 else 5 - Role.index(role), 22);
        // Scala/Java: `+` binds tighter than `<<`, so this is `(512 + moveValue) << 12`.
        let valueTerm = Bits.shl(512 + moveValue, 12);
        let score = promotionTerm + captureTerm + defenceTerm + valueTerm + Bits.shl(toSq, 6) + fromSq;
        Move.Move(moveType, role, fromSq, capture, toSq, promotion, score)
    }

    ///
    /// Scala `private def pieceValue(board, role, square)`:
    /// `PSQT(role.index)(if board.turn then Square.mirror(square) else square)`.
    ///
    /// Note the mirror is applied when it is *White* to move, which is what the
    /// original says: the tables are written from Black's point of view.
    ///
    def pieceValue(ctx: MoveCtx, role: Role, square: Int32): Int32 =
        Psqt.at(
            MoveCtx.psqt(ctx),
            Role.index(role),
            if (MoveCtx.turn(ctx)) Square.mirror(square) else square)

    /// Scala `move.type`. Compare against `Move.normal()`/`enPassant()`/`castling()`.
    pub def moveType(m: Move): Int32 =
        let Move.Move(x, _, _, _, _, _, _) = m;
        x

    /// Scala `move.role`.
    pub def role(m: Move): Role =
        let Move.Move(_, x, _, _, _, _, _) = m;
        x

    /// Scala `move.from`.
    pub def fromSq(m: Move): Int32 =
        let Move.Move(_, _, x, _, _, _, _) = m;
        x

    /// Scala `move.capture`.
    pub def capture(m: Move): Bool =
        let Move.Move(_, _, _, x, _, _, _) = m;
        x

    /// Scala `move.to`.
    pub def toSq(m: Move): Int32 =
        let Move.Move(_, _, _, _, x, _, _) = m;
        x

    /// Scala `move.promotion`, with `null` spelled `None`.
    pub def promotion(m: Move): Option[Role] =
        let Move.Move(_, _, _, _, _, x, _) = m;
        x

    /// Scala `move.score`, the move-ordering key computed by `mk`.
    pub def score(m: Move): Int32 =
        let Move.Move(_, _, _, _, _, _, x) = m;
        x

    ///
    /// Scala `override def compare(that) = Integer.compare(that.score, score)`:
    /// higher score sorts first. Returns the Java sign convention (`-1`/`0`/`1`).
    ///
    pub def compare(x: Move, y: Move): Int32 = {
        let a = score(y);
        let b = score(x);
        if (a < b) -1 else if (a == b) 0 else 1
    }

    ///
    /// Scala `x < y` on `Ordered[Move]`, i.e. `x.compare(y) < 0`, i.e.
    /// `y.score < x.score`: `x` outranks `y`.
    ///
    pub def lessThan(x: Move, y: Move): Bool = score(y) < score(x)

    ///
    /// Scala `def uci(): String`.
    ///
    /// The castling special case is the interesting part: internally a castling
    /// move is stored king-square -> *rook*-square, but UCI wants king -> C1/G1
    /// (on the mover's own rank). `Square.combine(a, b)` takes the file of `a` and
    /// the rank of `b`, so `combine(C1 or G1, from)` puts the C/G file on the
    /// king's rank, giving c1/g1 or c8/g8. Queenside is detected by
    /// `to < from`, `to` being the rook square.
    ///
    /// Scala builds this with a `StringBuilder` sized 4 or 5; the size hint has no
    /// observable effect, so this is plain interpolation. The promotion suffix is
    /// the role symbol lowercased, exactly as in the original.
    ///
    pub def uci(m: Move): String = {
        let f = fromSq(m);
        let toSquare =
            if (moveType(m) == castling())
                Square.combine(if (toSq(m) < f) Square.c1() else Square.g1(), f)
            else
                toSq(m);
        let fromFile = Int32.truncateToChar(Square.file(f) + Char.toBmpCodePoint('a'));
        let fromRank = Int32.truncateToChar(Square.rank(f) + Char.toBmpCodePoint('1'));
        let toFile   = Int32.truncateToChar(Square.file(toSquare) + Char.toBmpCodePoint('a'));
        let toRank   = Int32.truncateToChar(Square.rank(toSquare) + Char.toBmpCodePoint('1'));
        let suffix = match promotion(m) {
            case None    => ""
            case Some(p) => String.toLowerCase(Role.symbol(p))
        };
        "${fromFile}${fromRank}${toFile}${toRank}${suffix}"
    }

    ///
    /// Scala `def isZeroing: Boolean = capture || role == Role.PAWN`.
    ///
    pub def isZeroing(m: Move): Bool =
        capture(m) or role(m) == Role.Pawn

    ///
    /// Scala `def isIrreversible: Boolean = isZeroing || type == Move.CASTLING`.
    ///
    pub def isIrreversible(m: Move): Bool =
        isZeroing(m) or moveType(m) == castling()
}
