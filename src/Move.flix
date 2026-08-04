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
/// `Psqt.mk()` builds it; a Flix `def` is not memoized, so calling `mk` per scored
/// move would rebuild all 384 elements every time. Build it once and hold it, the
/// same discipline `Bitboard.Tables` uses.
///
/// It is a `type alias` for the vector itself and not a one-field wrapper enum.
/// That wrapper was measured: Flix compiles `let Psqt.Psqt(v) = p` into a full
/// destructure plus a provably dead `MatchError$` branch, ~95 bytecodes, and
/// `Move.mk` did four of them per generated move. The alias erases completely, so
/// `Psqt.at` is one `Vector.get`.
///
/// The values are transcribed verbatim, including the deliberate asymmetries in
/// the original (pawn `21` on e4, pawn `-31` on d2/e2, knight `11` on f3,
/// queen `-5` on h4). They are not typos and must not be "fixed": they exist to
/// break ties between otherwise mirror-image moves, and changing one changes the
/// move ranking and therefore the compressed output.
///
pub type alias Psqt = Vector[Int32]

mod Psqt {

    ///
    /// Builds the piece-square table. Pure; call once per process and hold it.
    ///
    pub def mk(): Psqt = Vector#{
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
    }

    ///
    /// `Move.PSQT(roleIndex)(sq)`.
    ///
    @Inline
    pub def at(p: Psqt, roleIndex: Int32, sq: Int32): Int32 =
        Vector.get(roleIndex * 64 + sq, p)
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
    case MoveCtx(Tables[Static], Psqt, Bool, Int64, Int64)
}

mod MoveCtx {

    ///
    /// Bundles the scoring inputs. Pure.
    ///
    pub def mk(tables: Tables[Static], psqt: Psqt, turn: Bool, pawns: Int64, them: Int64): MoveCtx =
        MoveCtx.MoveCtx(tables, psqt, turn, pawns, them)

    /// The attack tables.
    @Inline
    pub def tables(c: MoveCtx): Tables[Static] =
        let MoveCtx.MoveCtx(t, _, _, _, _) = c;
        t

    /// The piece-square table.
    @Inline
    pub def psqt(c: MoveCtx): Psqt =
        let MoveCtx.MoveCtx(_, p, _, _, _) = c;
        p

    /// Scala `board.turn`.
    @Inline
    pub def turn(c: MoveCtx): Bool =
        let MoveCtx.MoveCtx(_, _, b, _, _) = c;
        b

    /// Scala `board.pawns`.
    @Inline
    pub def pawns(c: MoveCtx): Int64 =
        let MoveCtx.MoveCtx(_, _, _, p, _) = c;
        p

    /// Scala `board.them()`.
    @Inline
    pub def them(c: MoveCtx): Int64 =
        let MoveCtx.MoveCtx(_, _, _, _, x) = c;
        x
}

///
/// A move: `type`, `role`, `from`, `capture`, `to`, `promotion`, `score` — the
/// seven fields of the Scala class, packed into one `Int64`.
///
/// # Why a packed word and not an enum
///
/// This was `enum Move { case Move(Int32, Role, Int32, Bool, Int32, Option[Role],
/// Int32) }`, and that cost two heap objects per generated move: a 48-byte
/// `Tag$Int32$Obj$Int32$Bool$Int32$Obj$Int32` and the 48-byte `Value$` that
/// `Move.mk` returned it in. The Tag is written into `MoveList.buffer`, so it
/// provably escapes and no JIT can remove it. At the corpus's ~27-33 legal moves
/// per ply that was roughly half of everything the game codec allocated — against
/// a Scala original that allocates *no* moves at all, because it preallocates 256
/// and recycles them.
///
/// Packing gets the same effect without the pooling: `MoveList.buffer` becomes a
/// bare `long[]`, a move is a value, and every field read that used to be a
/// seven-field destructure (plus a dead `MatchError$` branch — `Move.isZeroing`
/// was 392 bytecodes for one line of source) is now a shift and a mask.
///
/// # Layout
///
/// ```
///   bits  0..31  score      Int32, signed; read back with `Bits.toInt`
///   bits 32..33  type       0 NORMAL, 1 EN_PASSANT, 2 CASTLING
///   bits 34..36  role       `Role.index`, 0..5
///   bits 37..42  from       0..63
///   bit     43   capture
///   bits 44..49  to         0..63
///   bits 50..52  promotion  0 = none, otherwise `Role.index + 1`
/// ```
///
/// 53 bits used, 11 spare.
///
/// Keeping `score` in the **low** 32 bits is what makes the ordering safe. It is
/// the only signed field, and `Bits.toInt` is exactly Java's `(int)` narrowing,
/// so `Move.lessThan` compares the identical signed 32-bit value it compared
/// before — no assumption about the score's range is involved. That matters
/// because `lessThan` feeds `MoveList.rank`, which decides the Huffman symbol
/// actually written to the stream.
///
/// `Move.empty()` is `0i64`, which unpacks to exactly the old
/// `Move.Move(0, Role.Pawn, 0, false, 0, None, 0)` placeholder.
///
/// This is a `type alias`, so `Move` and `Int64` are interchangeable to the type
/// checker. That is a real loss of safety and it is the price of the
/// representation; the compensation is that no signature in the port changed.
/// `Order` is still deliberately not available: the Scala `Ordered[Move]` orders
/// by score *descending*, which the derived `Int64` order would not reproduce.
/// Use `Move.compare` / `Move.lessThan`, never `<` on a `Move`.
///
pub type alias Move = Int64

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
    pub def empty(): Move = 0i64

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
    @Inline
    pub def mk(ctx: MoveCtx, moveType: Int32, role: Role, fromSq: Int32, capture: Bool,
               toSq: Int32, promotion: Option[Role]): Move = {
        // ONE destructure, not five accessor calls. Flix materialises every field
        // of a single-case enum on every destructure and appends a provably dead
        // `MatchError$`/`ReifiedSourceLocation$` branch, so the five `@Inline`d
        // `MoveCtx.*` accessors plus the two inside `pieceValue` expanded to eight
        // copies of the same five field loads — about half of this function's
        // 2233 bytecodes, on a function called once per generated move.
        let MoveCtx.MoveCtx(tables, psqt, turn, pawns, them) = ctx;
        let defendingPawns =
            Bits.bandL(
                Bits.bandL(
                    Bitboard.pawnAttacks(tables, turn, toSq),
                    pawns),
                them);
        let roleIndex = Role.index(role);
        let moveValue =
            pieceValue(psqt, turn, roleIndex, toSq) - pieceValue(psqt, turn, roleIndex, fromSq);
        // `promotion` is matched once, into the packed representation's code
        // (`0` for none, `Role.index + 1` otherwise); the score's `promotion.index`
        // is then `promotionCode - 1`.
        let promotionCode = match promotion {
            case None    => 0
            case Some(p) => Role.index(p) + 1
        };
        let promotionTerm = if (promotionCode == 0) 0 else Bits.shl(promotionCode - 1, 26);
        let captureTerm = if (capture) Bits.shl(1, 25) else 0;
        let defenceTerm = Bits.shl(if (defendingPawns == 0i64) 6 else 5 - roleIndex, 22);
        // Scala/Java: `+` binds tighter than `<<`, so this is `(512 + moveValue) << 12`.
        let valueTerm = Bits.shl(512 + moveValue, 12);
        let score = promotionTerm + captureTerm + defenceTerm + valueTerm + Bits.shl(toSq, 6) + fromSq;
        pack(moveType, roleIndex, fromSq, capture, toSq, promotionCode, score)
    }

    ///
    /// Assembles the packed word. See the layout table on `Move`.
    ///
    /// Every widening is `Bits.toLongU` (`Integer.toUnsignedLong`), not
    /// `Int32.toInt64` — the latter is `Integer.valueOf(x).longValue()` and would
    /// allocate an `Integer` per move for any score outside the `Integer` cache,
    /// which is most of them.
    ///
    @Inline
    def pack(moveType: Int32, roleIndex: Int32, fromSq: Int32, capture: Bool,
             toSq: Int32, promotionCode: Int32, score: Int32): Move = {
        let lo = Bits.borL(Bits.toLongU(score), Bits.shlL(Bits.toLongU(moveType), 32));
        let mid = Bits.borL(Bits.shlL(Bits.toLongU(roleIndex), 34), Bits.shlL(Bits.toLongU(fromSq), 37));
        let hi = Bits.borL(if (capture) Bits.shlL(1i64, 43) else 0i64, Bits.shlL(Bits.toLongU(toSq), 44));
        Bits.borL(Bits.borL(lo, mid), Bits.borL(hi, Bits.shlL(Bits.toLongU(promotionCode), 50)))
    }

    ///
    /// One packed field: `(int) (m >>> shift) & mask`.
    ///
    @Inline
    def field(m: Move, shift: Int32, mask: Int32): Int32 =
        Bits.band(Bits.toInt(Bits.ushrL(m, shift)), mask)

    ///
    /// Scala `private def pieceValue(board, role, square)`:
    /// `PSQT(role.index)(if board.turn then Square.mirror(square) else square)`.
    ///
    /// Note the mirror is applied when it is *White* to move, which is what the
    /// original says: the tables are written from Black's point of view.
    ///
    @Inline
    def pieceValue(psqt: Psqt, turn: Bool, roleIndex: Int32, square: Int32): Int32 =
        Psqt.at(psqt, roleIndex, if (turn) Square.mirror(square) else square)

    /// Scala `move.type`. Compare against `Move.normal()`/`enPassant()`/`castling()`.
    @Inline
    pub def moveType(m: Move): Int32 = field(m, 32, 0x3)

    ///
    /// Scala `move.role.index`: the role as its dense `0..5` index.
    ///
    /// This is what the packed word actually stores, so a site that only compares
    /// roles — `Board.playNormal`'s three tests, `Move.isZeroing`, the encoder's
    /// find predicate — should use this and not `role`, which has to run
    /// `Role.ofIndex`'s six-way switch to hand back a `Role` that is then compared
    /// straight back to a constant.
    ///
    @Inline
    pub def roleIndex(m: Move): Int32 = field(m, 34, 0x7)

    /// Scala `move.role`.
    @Inline
    pub def role(m: Move): Role = Role.ofIndex(roleIndex(m))

    /// Scala `move.from`.
    @Inline
    pub def fromSq(m: Move): Int32 = field(m, 37, 0x3f)

    /// Scala `move.capture`.
    @Inline
    pub def capture(m: Move): Bool = field(m, 43, 0x1) != 0

    /// Scala `move.to`.
    @Inline
    pub def toSq(m: Move): Int32 = field(m, 44, 0x3f)

    ///
    /// The promotion as a small code: `0` for none, otherwise `Role.index + 1`.
    ///
    /// This is what the hot paths compare — `Board.playNormal` on every played
    /// move, `GameEncoder.encodeOne`'s find predicate on every candidate — because
    /// `promotion` below has to allocate a `Some` to answer the same question.
    ///
    @Inline
    pub def promotionCode(m: Move): Int32 = field(m, 50, 0x7)

    /// Scala `move.promotion`, with `null` spelled `None`.
    @Inline
    pub def promotion(m: Move): Option[Role] = {
        let c = promotionCode(m);
        if (c == 0) None else Some(Role.ofIndex(c - 1))
    }

    ///
    /// Scala `move.score`, the move-ordering key computed by `mk`.
    ///
    /// `Bits.toInt` is Java's `(int)` narrowing, so this is the same signed 32-bit
    /// value the enum field held — which is what keeps `lessThan`, and therefore
    /// the Huffman rank written to the stream, bit-identical.
    ///
    @Inline
    pub def score(m: Move): Int32 = Bits.toInt(m)

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
    /// Compared as `y << 32 < x << 32` rather than `score(y) < score(x)`. `m << 32`
    /// is exactly `(long) (int) m * 2^32`, and multiplying by a positive constant
    /// preserves signed order, so the two are equivalent for **every** pair of
    /// `Int64`s — no assumption about the score's range is involved, which matters
    /// because this feeds `MoveList.rank` and therefore the Huffman symbol written
    /// to the stream. The shift form is two `lshl` where `score` is two `land` plus
    /// two `Long.hashCode`. This runs O(n) times per encoded ply in
    /// `MoveList.rankLoop` and O(n log n) times per decoded ply in
    /// `MoveList.partitionLoop`. Checked against `score(y) < score(x)` over 900 000
    /// random full-range pairs (including bit 63 set) plus an adversarial grid.
    ///
    @Inline
    pub def lessThan(x: Move, y: Move): Bool = Bits.shlL(y, 32) < Bits.shlL(x, 32)

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
    @Inline
    pub def isZeroing(m: Move): Bool =
        capture(m) or roleIndex(m) == Role.index(Role.Pawn)

    ///
    /// Scala `def isIrreversible: Boolean = isZeroing || type == Move.CASTLING`.
    ///
    @Inline
    pub def isIrreversible(m: Move): Bool =
        isZeroing(m) or moveType(m) == castling()
}
