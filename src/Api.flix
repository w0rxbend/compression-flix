///
/// The JVM-facing surface of the library.
///
/// Everything in this module is `@Export`ed, which in Flix 0.75.1 means it is
/// compiled to a `public static final` method on a class called `Api` in the
/// **default (unnamed) package**. That placement, and the very small set of types
/// an export may mention, dictate the whole shape of this file:
///
///   1. An exported signature may only use `Bool`, `Char`, `Int8`, `Int16`,
///      `Int32`, `Int64`, `Float32`, `Float64` and `java.lang.Object`. Arrays,
///      `String`, enums, structs, `Option` and tuples are *not* exportable, so
///      everything else crosses the boundary as an `Object` and is
///      `unchecked_cast` back on entry. `Array[Int8, Static]` is a Java `byte[]`,
///      `Array[Int32, Static]` an `int[]`, `Array[String, Static]` a
///      `java.lang.String[]`, and Flix `String` *is* `java.lang.String`.
///   2. There are no zero-argument exports (`Unit` is not an exportable parameter
///      type), which is why `newTables` takes an ignored `Int32`.
///   3. Flix has no memoization and no global mutable state, so the ~100 ms of
///      precomputed tables cannot hide behind a zero-argument `def` — it would be
///      rebuilt per call. `newTables` hands the caller an opaque handle to a
///      `GameTables` and every game entry point takes it back. Callers must build
///      it **once per process** and cache it; the Scala facade uses a `lazy val`.
///      The clock codec needs no tables at all, so its two entry points do not
///      take a handle.
///   4. `Static` is the only region whose values can outlive the call, so every
///      array handed back to Java is allocated there. Touching `Static` costs
///      `\ IO`, which is why most of these are `\ IO` and the two that are not
///      (`newTables`, `resultHalfMoveClock`) must *not* declare it — Flix rejects
///      an unused effect.
///
/// Nothing here adds behaviour. Each function is marshalling plus a single call
/// into `ClockEncoder` or `GameEncoder`; the byte-for-byte fidelity to
/// `org.lichess.compression` lives in those modules, not this one.
///
/// ## Failure signalling
///
/// The Scala original returns `null` from `game.Encoder.encode` for an
/// unencodable SAN token, and `DecodeResult.lastUci` is `null` before the first
/// move. Flix has no null literal, but a genuine Java `null` is obtainable:
/// `Array.empty(Static, 1)` compiles to `new Object[1]`, whose single slot is
/// null, so `Array.get(0, ...)` yields it. `nullObject` below does exactly that
/// and is what keeps the facade's signatures identical to the original's.
///
/// ## Consuming this from Java or Scala
///
/// Flix emits its entire standard library into the default package too — 145
/// top-level classes including `Object`, `String`, `Array`, `Map`, `Set`, `List`,
/// `Option`, `Iterator`, `Assert`, `Probe` and `Main`. Any source compiled with
/// the raw jar on its classpath can have an unqualified name captured by one of
/// them. Write `java.lang.Object` and `java.lang.String` in full, keep the jar off
/// downstream classpaths, and let the Scala facade in `scala-api/` be the only
/// thing that ever names `Api`.
///
mod Api {

    import java.lang.Object
    import java.lang.NegativeArraySizeException

    ///
    /// A genuine Java `null` as an `Object`.
    ///
    /// `Array.empty` is `new Object[1]` — every slot starts null — so reading slot
    /// zero produces the real thing rather than a sentinel the caller has to know
    /// about.
    ///
    def nullObject(): Object \ IO =
        let holder: Array[Object, Static] = Array.empty(Static, 1);
        Array.get(0, holder)

    // ------------------------------------------------------------------ tables

    ///
    /// Builds the four precomputed tables the game codec needs — attack tables,
    /// piece-square table, Polyglot Zobrist keys and the Huffman tree — and returns
    /// them as an opaque handle.
    ///
    /// Costs ~100 ms and allocates ~700 KB. **Call once per process** and pass the
    /// same handle to every `gameEncode` / `gameDecode`; there is no memoization
    /// behind it. The argument is ignored and exists only because Flix has no
    /// zero-argument exports.
    ///
    /// The handle is opaque: its only valid use is as the first argument to
    /// `gameEncode` and `gameDecode`.
    ///
    @Export
    pub def newTables(_unused: Int32): Object =
        unchecked_cast(GameTables.mk() as Object)

    // ------------------------------------------------------------------- clock

    ///
    /// `org.lichess.compression.clock.Encoder.encode(int[] centis, int startTime)`.
    ///
    /// `centis` is a Java `int[]` of clock readings in centiseconds, one per move;
    /// `startTime` is the game's initial clock, also in centiseconds, and is not
    /// stored in the stream — `clockDecode` needs the same value back.
    ///
    /// Returns a Java `byte[]`. The input array is *not* modified.
    ///
    @Export
    pub def clockEncode(centis: Object, startTime: Int32): Object \ IO =
        let input: Array[Int32, Static] = unchecked_cast(centis as Array[Int32, Static]);
        unchecked_cast(ClockEncoder.encode(Static, input, startTime) as Object)

    ///
    /// `org.lichess.compression.clock.Encoder.decode(byte[] bytes, int startTime)`.
    ///
    /// `bytes` is a Java `byte[]` produced by `clockEncode` and `startTime` must be
    /// the value that was passed to it. Returns a Java `int[]`.
    ///
    /// The input is wrapped, not copied — exactly as `ByteBuffer.wrap` is in the
    /// original — but it is only ever read.
    ///
    /// Not a total inverse: `LowBitTruncator` deliberately discards the low three
    /// bits of readings at or above 1000 centis and restores them as `3`.
    ///
    @Export
    pub def clockDecode(bytes: Object, startTime: Int32): Object \ IO =
        let input: Array[Int8, Static] = unchecked_cast(bytes as Array[Int8, Static]);
        unchecked_cast(ClockEncoder.decode(Static, input, startTime) as Object)

    // -------------------------------------------------------------------- game

    ///
    /// `org.lichess.compression.game.Encoder.encode(String[] pgnMoves)`.
    ///
    /// `tables` is a handle from `newTables`; `pgnMoves` is a Java `String[]` of SAN
    /// tokens ("e4", "Nf3", "O-O", "exd5", "b8=Q"), one per ply.
    ///
    /// Returns a Java `byte[]`, or `null` if a token cannot be parsed as SAN or
    /// names no legal move — the same `null` the Scala original returns, and with
    /// the same all-or-nothing behaviour: nothing encoded before the bad ply
    /// survives.
    ///
    @Export
    pub def gameEncode(tables: Object, pgnMoves: Object): Object \ IO =
        let gt: GameTables = unchecked_cast(tables as GameTables);
        let moves: Array[String, Static] = unchecked_cast(pgnMoves as Array[String, Static]);
        match GameEncoder.encode(gt, Array.toVector(moves)) {
            case None      => nullObject()
            case Some(out) => unchecked_cast(Vector.toArray(Static, out) as Object)
        }

    ///
    /// `org.lichess.compression.game.Encoder.decode(byte[] input, int plies)`.
    ///
    /// `tables` is a handle from `newTables`, `input` a Java `byte[]` from
    /// `gameEncode`, and `plies` the number of half-moves to replay — which the
    /// stream does not carry, so the caller must know it. Decoding fewer plies than
    /// were encoded is legitimate and is how the original exposes intermediate
    /// positions.
    ///
    /// Returns an opaque handle to the equivalent of Scala's `DecodeResult`; read
    /// it with the `result*` functions below. A corrupt stream aborts rather than
    /// returning a bad result, and aborts with the same exception type the
    /// original raises: `IllegalArgumentException("requirement failed")` for a
    /// Huffman symbol that names no legal move, `BufferUnderflowException` for a
    /// stream that ends early, and — from the guard below —
    /// `NegativeArraySizeException` for a negative `plies`, which the original
    /// gets from `Array.ofDim[String](plies)` (`game/Encoder.scala:79`). The
    /// message is the number, as Java's is. The guard lives here rather than in
    /// `GameEncoder.decode` because the parity contract is a property of the JVM
    /// boundary and this module is not on the byte-critical path.
    ///
    @Export
    pub def gameDecode(tables: Object, input: Object, plies: Int32): Object \ IO =
        if (plies < 0) throw new NegativeArraySizeException(Int32.toString(plies)) else ();
        let gt: GameTables = unchecked_cast(tables as GameTables);
        let bytes: Array[Int8, Static] = unchecked_cast(input as Array[Int8, Static]);
        unchecked_cast(GameEncoder.decode(Static, gt, Array.toVector(bytes), plies) as Object)

    // --------------------------------------------------------- decode accessors

    ///
    /// Scala `DecodeResult.pgnMoves`: the replayed SAN tokens as a Java `String[]`
    /// of length `plies`, check and mate suffixes included.
    ///
    @Export
    pub def resultPgnMoves(result: Object): Object \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        unchecked_cast(Vector.toArray(Static, DecodeResult.pgnMoves(r)) as Object)

    ///
    /// Scala `DecodeResult.halfMoveClock`: plies since the last pawn move or
    /// capture.
    ///
    /// Pure — it only reads an already-materialised field — so it must not declare
    /// `\ IO`, which Flix would reject as unused.
    ///
    @Export
    pub def resultHalfMoveClock(result: Object): Int32 =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        DecodeResult.halfMoveClock(r)

    ///
    /// Scala `DecodeResult.positionHashes`: three bytes per position, most recent
    /// first, back to the last irreversible move. A Java `byte[]`.
    ///
    @Export
    pub def resultPositionHashes(result: Object): Object \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        unchecked_cast(Vector.toArray(Static, DecodeResult.positionHashes(r)) as Object)

    ///
    /// Scala `DecodeResult.lastUci`: the final move in UCI notation ("e2e4",
    /// "e7e8q", "e1h1" for castling), or `null` when `plies` is 0.
    ///
    @Export
    pub def resultLastUci(result: Object): Object \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        match DecodeResult.lastUci(r) {
            case None      => nullObject()
            case Some(uci) => unchecked_cast(uci as Object)
        }

    ///
    /// Scala `DecodeResult.board.castlingRights`: a bitboard of the squares still
    /// occupied by rooks that have castling rights.
    ///
    /// One of the thirteen `result*` accessors that between them expose every public
    /// field of the decoded `Board` — see the block comment below.
    ///
    @Export
    pub def resultCastlingRights(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.castlingRights(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.turn`: `true` when White is to move.
    ///
    @Export
    pub def resultTurn(result: Object): Bool \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.turn(DecodeResult.board(r))

    // ----------------------------------------------------- the rest of the board
    //
    // The `Board` itself is not exportable — an export may only mention primitives
    // and `java.lang.Object` — so its thirteen public fields cross the boundary one
    // scalar at a time. Those thirteen are the whole of the original's `Board`
    // state: nine bitboards, `turn`, `epSquare`, `castlingRights` and
    // `incrementalHash`. The Scala facade reassembles them into an immutable
    // snapshot, and `difftest` asserts all thirteen against the original over the
    // full decode corpus.
    //
    // Two constraints shape every one of these:
    //
    //   * They read a `mut` struct field, which costs `\ r`. The board inside a
    //     `DecodeResult` lives in `Static` — `gameDecode` calls
    //     `GameEncoder.decode(Static, ...)` — so `\ r` is `\ IO` and every accessor
    //     must declare it. Omitting it is Type Error E6469, "unable to unify the
    //     effect formulas". `resultHalfMoveClock` is the counterexample: it only
    //     destructures an enum, which is pure, so declaring `\ IO` there would be
    //     Type Error E6217, "unused effect".
    //   * `Static` is the region of global lifetime. There is no lexical scope for a
    //     `Board[Static]` to escape from, and Flix regions are a static discipline
    //     that frees nothing, so the board behind the handle is an ordinary
    //     GC-rooted JVM object and stays readable for as long as the caller holds
    //     the handle. Reading it after `gameDecode` has returned is exactly what
    //     `resultCastlingRights` above has always done.
    //
    // The board's `roleAt`, `whiteAt`, `pieceMap`, `us`, `them` and `byColor` are
    // deliberately absent: all six are functions of the nine bitboards and are
    // cheaper for the caller to recompute than to marshal. `copy`, `play`,
    // `legalMoves`, `isCheck`, `zobristHash` and `hasLegalEnPassant` need the move
    // generator and are not part of this seam at all.

    ///
    /// Scala `DecodeResult.board.pawns`.
    ///
    @Export
    pub def resultPawns(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.pawns(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.knights`.
    ///
    @Export
    pub def resultKnights(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.knights(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.bishops`.
    ///
    @Export
    pub def resultBishops(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.bishops(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.rooks`.
    ///
    @Export
    pub def resultRooks(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.rooks(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.queens`.
    ///
    @Export
    pub def resultQueens(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.queens(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.kings`.
    ///
    @Export
    pub def resultKings(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.kings(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.white`: every square occupied by a white piece.
    ///
    /// The Flix accessor is `Board.whitePieces` — one of the two name skews in this
    /// file.
    ///
    @Export
    pub def resultWhite(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.whitePieces(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.black`: every square occupied by a black piece.
    ///
    /// Named `Board.blackPieces` on the Flix side, for the same reason as
    /// `resultWhite`.
    ///
    @Export
    pub def resultBlack(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.blackPieces(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.occupied`: `white | black`, maintained
    /// incrementally rather than recomputed.
    ///
    @Export
    pub def resultOccupied(result: Object): Int64 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.occupied(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.epSquare`: the square a pawn may be captured on en
    /// passant, or `0` for none.
    ///
    /// The one piece of position state the nine bitboards do *not* determine, which
    /// is why it is exported even though nothing in this repository reads it today.
    ///
    @Export
    pub def resultEpSquare(result: Object): Int32 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.epSquare(DecodeResult.board(r))

    ///
    /// Scala `DecodeResult.board.incrementalHash`: the Polyglot Zobrist hash of the
    /// position, updated move by move rather than recomputed.
    ///
    /// `DecodeResult.positionHashes` carries only the top three bytes of this, so
    /// this accessor is the only way to see the low byte.
    ///
    @Export
    pub def resultIncrementalHash(result: Object): Int32 \ IO =
        let r: DecodeResult[Static] = unchecked_cast(result as DecodeResult[Static]);
        Board.incrementalHash(DecodeResult.board(r))
}
