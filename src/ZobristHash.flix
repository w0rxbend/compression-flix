///
/// Zobrist (Polyglot) hashing of a chess position.
///
/// Port of `src/main/scala/game/ZobristHash.scala`.
///
/// # Exposed signatures (read this if you are wiring up `Board`)
///
/// ```flix
/// ZobristHash.polyglot(): Vector[Int32]                                  // the 781-entry table
/// ZobristHash.key(t: Vector[Int32], i: Int32): Int32                     // POLYGLOT(i)
/// ZobristHash.turnKey(t: Vector[Int32]): Int32                           // POLYGLOT(780)
///
/// ZobristHash.hashPiece(t, square: Int32, color: Bool, role: Role): Int32
/// ZobristHash.hashCastling(t, castlingRights: Int64): Int32
/// ZobristHash.hashTurn(t, turn: Bool): Int32
/// ZobristHash.hashEnPassant(t, hasLegalEnPassant: Bool, epSquare: Int32): Int32
///
/// ZobristHash.hashPieces(t, occupied: Int64,
///                        whiteAt: Int32 -> Bool \ ef,
///                        roleAt:  Int32 -> Role \ ef): Int32 \ ef
///
/// ZobristHash.hashBoard(t, occupied: Int64,
///                       whiteAt: Int32 -> Bool \ ef,
///                       roleAt:  Int32 -> Role \ ef,
///                       castlingRights: Int64, turn: Bool,
///                       hasLegalEnPassant: Bool, epSquare: Int32): Int32 \ ef
/// ```
///
/// # Structural differences forced by Flix, none of them observable in the output
///
///   - **No `Board` parameter.** `Board` is owned by another file and did not exist
///     when this was written, so each function takes exactly the pieces of board
///     state it reads. `hashPieces`/`hashBoard` take the two per-square accessors
///     (`whiteAt`, `roleAt`) as effect-polymorphic functions, so a `Board` living in
///     a region `r` can pass `sq -> Board.whiteAt(sq, b)` and the call is `\ r`.
///     The Scala member `board.zobristHash()` is `incrementalHash ^ hashCastling ^
///     hashEnPassant` and stays in `Board`; nothing here needs to change for it.
///
///   - **The table is a `Vector[Int32]`, not `Vector[Int64]`.** The Scala original
///     is `val POLYGLOT: Array[Int]` and every hash value is a Java `int`: these are
///     the top 24 bits of the standard Polyglot 64-bit keys, already truncated in the
///     original. Widening them to `Int64` would change the type of every hash the
///     library computes and stores. All 781 entries are in `0x000000..0xffffff`, so
///     they are positive `Int32` literals and the `^` chain is plain 32-bit XOR.
///
///   - **No global mutable state / no memoization** (see PORTING-NOTES.md): a
///     top-level `def` is re-evaluated on every call, so `polyglot()` allocates the
///     781-element vector each time it is invoked. Call it **once**, store the
///     result (e.g. as an immutable `Vector[Int32]` field on `Board`, or thread it
///     from the API layer), and pass it in. Do not call `polyglot()` inside a loop.
///
///   - **`Bitboard.lsb`/`Bitboard.contains` come from `src/Bitboard.flix`.** They
///     were briefly duplicated here as private one-liners while `Bitboard.flix` did
///     not exist; the duplicates have been removed so there is one definition of
///     each in the program and no chance of a behavioural fork. `Bitboard.lsb` adds
///     the Scala `assert(b != 0)` guard as a `bug!`, which `hashPieces` never trips
///     because its loop guard already excludes zero.
///
///   - **`while` becomes a local tail-recursive `def`**, and the mutable `hash` /
///     `occupied` become accumulator parameters. `occupied &= occupied - 1L`
///     (clear lowest set bit) is preserved exactly.
///
///   - Scala's `assert(b != 0)` inside `Bitboard.lsb` is kept (as a `bug!`) but is
///     unreachable from here: `hashPieces` only calls it on a non-zero word, by
///     construction of the loop guard.
///
mod ZobristHash {

    ///
    /// `ZobristHash.hashBoard(board)`.
    ///
    /// Scala:
    /// ```scala
    /// hashPieces(board) ^ hashCastling(board) ^ hashTurn(board) ^ hashEnPassant(board)
    /// ```
    /// The XOR order is irrelevant to the result but is kept as written.
    ///
    pub def hashBoard(
        t: Vector[Int32],
        occupied: Int64,
        whiteAt: Int32 -> Bool \ ef,
        roleAt: Int32 -> Role \ ef,
        castlingRights: Int64,
        turn: Bool,
        hasLegalEnPassant: Bool,
        epSquare: Int32
    ): Int32 \ ef =
        let h1 = hashPieces(t, occupied, whiteAt, roleAt);
        let h2 = hashCastling(t, castlingRights);
        let h3 = hashTurn(t, turn);
        let h4 = hashEnPassant(t, hasLegalEnPassant, epSquare);
        Bits.bxor(Bits.bxor(Bits.bxor(h1, h2), h3), h4)

    ///
    /// `ZobristHash.hashPieces(board)`: XOR of the piece key of every occupied square.
    ///
    /// Scala:
    /// ```scala
    /// var hash = 0
    /// var occupied = board.occupied
    /// while occupied != 0 do
    ///   val sq = Bitboard.lsb(occupied)
    ///   hash ^= hashPiece(sq, board.whiteAt(sq), board.roleAt(sq))
    ///   occupied &= occupied - 1L
    /// hash
    /// ```
    ///
    /// `whiteAt` and `roleAt` are only ever applied to squares that are set in
    /// `occupied`, so `roleAt` never has to model Scala's `null` return.
    ///
    pub def hashPieces(
        t: Vector[Int32],
        occupied: Int64,
        whiteAt: Int32 -> Bool \ ef,
        roleAt: Int32 -> Role \ ef
    ): Int32 \ ef = {
        def loop(hash, remaining) = {
            if (remaining != 0i64) {
                let sq = Bitboard.lsb(remaining);
                let h = Bits.bxor(hash, hashPiece(t, sq, whiteAt(sq), roleAt(sq)));
                loop(h, Bits.bandL(remaining, remaining - 1i64))
            } else
                hash
        };
        loop(0, occupied)
    }

    ///
    /// `ZobristHash.hashPiece(square, color, role)`.
    ///
    /// Scala:
    /// ```scala
    /// val index = role.index * 2 + (if color then 1 else 0)
    /// POLYGLOT(64 * index + square)
    /// ```
    /// `color` is `true` for white, as everywhere else in the library.
    ///
    pub def hashPiece(t: Vector[Int32], square: Int32, color: Bool, role: Role): Int32 =
        let index = Role.index(role) * 2 + (if (color) 1 else 0);
        key(t, 64 * index + square)

    ///
    /// `ZobristHash.hashCastling(board)`.
    ///
    /// Scala:
    /// ```scala
    /// if Bitboard.contains(cr, Square.H1) then hash ^= POLYGLOT(768)
    /// if Bitboard.contains(cr, Square.A1) then hash ^= POLYGLOT(768 + 1)
    /// if Bitboard.contains(cr, Square.H8) then hash ^= POLYGLOT(768 + 2)
    /// if Bitboard.contains(cr, Square.A8) then hash ^= POLYGLOT(768 + 3)
    /// ```
    /// The H1/A1/H8/A8 order matters only in that each square maps to its own key.
    ///
    pub def hashCastling(t: Vector[Int32], castlingRights: Int64): Int32 = {
        let h0 = 0;
        let h1 = if (Bitboard.contains(castlingRights, Square.h1())) Bits.bxor(h0, key(t, 768)) else h0;
        let h2 = if (Bitboard.contains(castlingRights, Square.a1())) Bits.bxor(h1, key(t, 768 + 1)) else h1;
        let h3 = if (Bitboard.contains(castlingRights, Square.h8())) Bits.bxor(h2, key(t, 768 + 2)) else h2;
        let h4 = if (Bitboard.contains(castlingRights, Square.a8())) Bits.bxor(h3, key(t, 768 + 3)) else h3;
        h4
    }

    ///
    /// `ZobristHash.hashTurn(board)`: `if board.turn then POLYGLOT(780) else 0`.
    ///
    /// `turn == true` means white to move.
    ///
    pub def hashTurn(t: Vector[Int32], turn: Bool): Int32 =
        if (turn) key(t, 780) else 0

    ///
    /// `ZobristHash.hashEnPassant(board)`.
    ///
    /// Scala:
    /// ```scala
    /// if board.hasLegalEnPassant() then POLYGLOT(772 + Square.file(board.epSquare)) else 0
    /// ```
    /// The caller supplies `board.hasLegalEnPassant()` (which needs move generation,
    /// hence lives on `Board`) and `board.epSquare`. When the flag is `false` the
    /// `epSquare` argument is not read, matching Scala's short-circuit.
    ///
    pub def hashEnPassant(t: Vector[Int32], hasLegalEnPassant: Bool, epSquare: Int32): Int32 =
        if (hasLegalEnPassant) key(t, 772 + Square.file(epSquare)) else 0

    ///
    /// `POLYGLOT(780)`, the side-to-move key.
    ///
    /// `Board.play` ends with `this.incrementalHash ^= ZobristHash.POLYGLOT(780)`;
    /// this is that constant, named.
    ///
    pub def turnKey(t: Vector[Int32]): Int32 = key(t, 780)

    ///
    /// `POLYGLOT(i)`.
    ///
    /// Out-of-range `i` aborts, exactly as the Scala array access throws
    /// `ArrayIndexOutOfBoundsException`.
    ///
    pub def key(t: Vector[Int32], i: Int32): Int32 = Vector.get(i, t)

    ///
    /// The number of entries in `POLYGLOT`: 781.
    ///
    /// 768 piece-square keys (12 piece kinds x 64 squares), 4 castling keys
    /// (768..771), 8 en-passant file keys (772..779), 1 turn key (780).
    ///
    pub def size(): Int32 = 781

    ///
    /// The Polyglot random table, `val POLYGLOT: Array[Int]` in the Scala original.
    ///
    /// 781 entries, transcribed mechanically from
    /// `src/main/scala/game/ZobristHash.scala` (parsed out of the Scala literal and
    /// re-emitted, not typed by hand) and verified element-by-element against it.
    /// The layout below is 10 per line, the same as the Scala source, so the two can
    /// be diffed directly.
    ///
    /// These are `Int`, not `Long`: the upstream Polyglot keys are 64-bit and lichess
    /// keeps only their top 24 bits. Every value is in `0x000000..0xffffff`.
    ///
    /// Re-evaluated on every call (Flix has no `@Memoize`). Call once and thread the
    /// result; see the module header.
    ///
    pub def polyglot(): Vector[Int32] = Vector#{
        0x9d3924, 0x2af739, 0x44db01, 0x9c15f7, 0x758344, 0x3290ac, 0x0fbbad, 0xe83a90, 0x0d7e76, 0x1a0838,
        0x9605d5, 0xd021ff, 0x40bdf1, 0x011355, 0x5db483, 0x239f8b, 0x05d1a1, 0x679f84, 0x7449bb, 0x7d11cd,
        0x82c770, 0xf3218f, 0x331478, 0x4bb38d, 0xaa649c, 0x8dbd98, 0x87d207, 0x19f3c7, 0xb4ab30, 0x7b0500,
        0xc9452c, 0x24aa6c, 0x4c9f34, 0x14a68f, 0xa71b9b, 0x03488b, 0x637b2b, 0x09d1bc, 0x357566, 0x735e2b,
        0x187270, 0x1fcbac, 0xd310a7, 0xbf983f, 0x9f74d1, 0x51ebdc, 0x5c82c5, 0xfcf7fe, 0x3253a7, 0x8c74c3,
        0xb9bc6c, 0x7ef48f, 0x11d505, 0x6568fc, 0x4de0b0, 0x96d693, 0x42e240, 0x6d2bdc, 0x42880b, 0x5f0f4a,
        0x39f890, 0x93c5b5, 0x63dc35, 0xec16ca, 0x5355f9, 0x07fb9f, 0x509341, 0x7bcbc3, 0x19fc8a, 0x637a77,
        0x8249a4, 0x79ad69, 0x14acba, 0xf145b6, 0xdabf2a, 0x24c3c9, 0xbb6e29, 0x0ce26c, 0xa49cd1, 0xe99d66,
        0x27e6ad, 0x8535f0, 0x54b3f4, 0x72b12c, 0xee954d, 0x9a85ac, 0x70ac4c, 0xf9b89d, 0x87b3e2, 0xa366e5,
        0xae4a93, 0x1920c0, 0x87bf02, 0x092237, 0xff07f6, 0x8de8dc, 0x9c1633, 0xb3f22c, 0x390e5f, 0x5bfea5,
        0x1e1032, 0x9a74ac, 0x4f80f7, 0x6304d0, 0x2171e6, 0x5b9b63, 0x506aac, 0x1881af, 0x650308, 0xdfd395,
        0xef927d, 0x7b32f7, 0xb9fd76, 0x05a7e8, 0xb5889c, 0x4a750a, 0xcf464c, 0xf53863, 0x3c79a0, 0xede6c8,
        0x799e81, 0x86536b, 0x97d737, 0xa24663, 0x043fca, 0x920e44, 0x70eb09, 0x73a192, 0x56436c, 0xefac4b,
        0xbb2157, 0x45f200, 0x930f80, 0xff6712, 0xae623f, 0xdd2c5b, 0x7eed12, 0x22fe54, 0xc91800, 0x808bd6,
        0xdec468, 0x1bede3, 0x435396, 0xaa969b, 0xa87832, 0x65942c, 0xded2d6, 0x21f085, 0xb41593, 0x91b859,
        0x10cff3, 0x28aed1, 0xc5cc1d, 0x5648f6, 0x2d2550, 0x9bc5a3, 0xef2f05, 0xaf2042, 0x480412, 0xaef3af,
        0x19afe5, 0x525938, 0xf4f076, 0x113796, 0xbce5d2, 0x9da424, 0x066f70, 0x4dc4de, 0x51039a, 0xc07a3f,
        0xb46ee9, 0xb3819a, 0x21a007, 0x2df16f, 0x763c4a, 0xf793c4, 0xd7288e, 0xde336a, 0x0bf692, 0x2c604a,
        0x4850e7, 0xcfc447, 0xb05ca3, 0x9ae182, 0xa4fc4b, 0xe75517, 0x69b97d, 0xf9b5b7, 0xfc6a82, 0x9c684c,
        0x8ec97d, 0x6703df, 0xc547f5, 0x78e376, 0xfe9a44, 0x08bd35, 0x9315e5, 0x94061b, 0xdf1d9f, 0x3bba57,
        0xd2b7ad, 0xf7a255, 0xd7f4f2, 0xd95be8, 0x336f52, 0xa74049, 0xa2f61b, 0x4f2a5c, 0x87d380, 0x16b9f7,
        0x7ba248, 0xf3a678, 0x39b0bf, 0xfcaf55, 0x18fcf6, 0x4c0563, 0x40e087, 0x8cffa9, 0x68ca39, 0x7a1ee9,
        0x9d1d60, 0x3810e3, 0x32095b, 0x35cab6, 0xa90b24, 0x77a225, 0x513e5e, 0x4361c0, 0xd941ac, 0x528f7c,
        0x52ab92, 0x9d1dfa, 0x722ff1, 0x1d1260, 0x7a249a, 0x04208f, 0x5a110c, 0x0cd9a4, 0x56fd23, 0x284c84,
        0x04feab, 0x742e1e, 0x9a9632, 0x881b82, 0x506e67, 0xb0183d, 0x0ed9b9, 0x5e11e8, 0xf67864, 0x1b85d4,
        0xdab9fe, 0x0d151d, 0xa865a5, 0x93c425, 0x99e7af, 0x48cbff, 0x7f9b6a, 0x58627e, 0x2cd16e, 0xd363ef,
        0x0ce2a3, 0x1a804a, 0x907f30, 0x501f65, 0x37624a, 0x957baf, 0x3a6c27, 0xd49503, 0x088e04, 0xf943ae,
        0x6c3b8e, 0x364f6f, 0xd60f6d, 0x56963b, 0x16f50e, 0xef1955, 0x565601, 0xecb539, 0xbac7a9, 0xb344c4,
        0x65d349, 0xb4b81b, 0xb42206, 0x071582, 0x7a13f1, 0xbc4097, 0x59b978, 0x99170a, 0x6f4233, 0x325928,
        0xd0e436, 0x565c31, 0x30f561, 0xd873db, 0x7bd94e, 0xc7d9f1, 0x947ae0, 0xc8c938, 0x3a9bf5, 0xd9a11f,
        0x0fd220, 0xb3f256, 0xb03031, 0x35dd37, 0xe9f608, 0xebfafa, 0x9255ab, 0xb9ab4c, 0x693501, 0xc62c58,
        0xcd454f, 0xbbe83f, 0xdc842b, 0xba8914, 0xa3bc94, 0xe9f676, 0x09c7e5, 0x852f54, 0x8107fc, 0x098954,
        0x23b70e, 0xc330de, 0x4715ed, 0xa8d7e4, 0x0572b9, 0xb57d2e, 0xe8d9ec, 0x2fe4b1, 0x11317b, 0x7fbf21,
        0x1725ca, 0x964e91, 0x3e2b8b, 0xbe7444, 0xf85b2b, 0x49353f, 0x1dd01a, 0x1fca8a, 0xfc7c95, 0x18a6a9,
        0xcccb70, 0x3bdbb9, 0xaa70b5, 0xe94c39, 0xb7a0b1, 0xd4dba8, 0x2e18bc, 0x2de096, 0xb9c11d, 0x64972d,
        0x94628d, 0xdbc0d2, 0xd2733c, 0x7e75d9, 0x6ced19, 0x97fcaa, 0x7b7749, 0x8547ed, 0x79999c, 0xcffe19,
        0x829626, 0x92fae2, 0x63e22c, 0xc678b6, 0x587388, 0x0981dc, 0x9f6578, 0x9ff38f, 0xe479ee, 0xe7f28e,
        0x56c074, 0x5544f7, 0x7b3f01, 0x121536, 0x7f5126, 0x7a7695, 0x3d5774, 0x8a1b08, 0x7b4a38, 0x950113,
        0x4da897, 0x3bc36e, 0x5d0a12, 0x7f9d1a, 0xda3a36, 0xdcdd7d, 0x368333, 0xce6834, 0xab9090, 0x43954b,
        0xb438c2, 0x10dcd7, 0xdbc27a, 0x9b3cdb, 0xb67b78, 0xbfced1, 0xa9119b, 0x1fff7a, 0xac12fb, 0xaf08da,
        0x1b0cab, 0xb559eb, 0xc37b45, 0xc3a9dc, 0xf3b8b6, 0x9fc477, 0x67378d, 0x6dd856, 0xa319ce, 0x073973,
        0x8a8e84, 0xe1925c, 0x74c04b, 0x4dda48, 0x9d266d, 0x7440fb, 0x133285, 0xd6bf7b, 0x4838d6, 0x1e1523,
        0x8f8419, 0x72c883, 0xd7a023, 0x94ebc8, 0x9fc10d, 0xde68a2, 0xa44cfe, 0x9d1d84, 0x51d2b1, 0x2fd7e4,
        0x65ca5b, 0xdd69a0, 0x604d51, 0x73aa8a, 0x1a8c1e, 0xaac40a, 0x764dbe, 0x1e99b9, 0x2c5e9d, 0x3a938f,
        0x26e6db, 0x469356, 0xc8763c, 0x3f6c6a, 0x7f7cc3, 0x9bfb22, 0x89039d, 0x8fe88b, 0xa09e8c, 0xfa7e39,
        0xd6b6d0, 0xdfea21, 0xb67c1f, 0xca1e37, 0x1cfc8b, 0xd18d85, 0x4ed0fe, 0xe4dbf0, 0x1761f9, 0x53898e,
        0x734de8, 0x2680b1, 0x298af2, 0x7983ee, 0x66c1a2, 0x9e17e4, 0xedb454, 0x50b704, 0x4cc317, 0x66b483,
        0x219b97, 0x261e4e, 0x1fe2cc, 0xd7504d, 0xb9571f, 0x1ddc03, 0xcf3f46, 0xf4f5d0, 0x38b652, 0x36f60e,
        0xeb3593, 0x9c4cd6, 0xaf0c31, 0x258e5a, 0x8b889d, 0xf4d145, 0xd4347f, 0xe699ed, 0x2472f6, 0xc2a1e7,
        0xab4f64, 0x637675, 0xa59e0b, 0x116d00, 0x2cf9c8, 0x0b090a, 0xabeedd, 0x58efc1, 0xc6e57a, 0x2eab8c,
        0x14a195, 0x7c0828, 0xd74bbe, 0x804456, 0xebe9ea, 0x03219a, 0x49787f, 0xa1e930, 0x5b45e5, 0xb49c3b,
        0xd4490a, 0x12a8f2, 0x001f83, 0x1877b5, 0xa2853b, 0x993e1d, 0xb35980, 0x252f59, 0xd23c8e, 0x1bda04,
        0x21e0bd, 0x3b097a, 0x8d14de, 0xf95cff, 0x387170, 0xca672b, 0x64c8e5, 0x241260, 0x106c09, 0x7fba19,
        0x7884d9, 0x0647df, 0x63573f, 0x4fc8e9, 0x1db956, 0xb8d912, 0xa2ebee, 0xd9f1f3, 0xefed53, 0x2e6d02,
        0xa9aa4d, 0xb64be8, 0x70cb6a, 0x98f076, 0xbf8447, 0x94c325, 0x3e003e, 0xb925a6, 0x61bdd1, 0xbf8d51,
        0x240ab5, 0xfc8761, 0xef02cd, 0xa1082c, 0x8215e5, 0xd39bb9, 0x273825, 0x61cf4f, 0x1b6bac, 0x758f45,
        0x959f58, 0xb063e9, 0x60e8ed, 0x7b6497, 0xfd080d, 0x8c90fd, 0x106f72, 0x797603, 0xa4ec01, 0x733ea7,
        0xb4d8f7, 0x9e21f4, 0x9d765e, 0xd30c08, 0x5d9433, 0x1a4e48, 0x6ffe73, 0xddf957, 0x64d0e2, 0x08dd9b,
        0x087e79, 0xe328e2, 0x1c2559, 0x720bf5, 0xb0774d, 0x443f64, 0x4112cf, 0xd813f2, 0x660d32, 0x59ac2c,
        0xe84696, 0x93b633, 0xc0c0f5, 0xcaf21e, 0x572777, 0x506c11, 0xd83cc2, 0x4a29c6, 0xed2df2, 0xb5635c,
        0x22af00, 0x52e762, 0x9aeba3, 0x944f6d, 0x6c47be, 0x6ad047, 0xa5b1cf, 0x7c45d8, 0x5092ef, 0x9338e6,
        0x455a4b, 0x6b02e6, 0x6b17b2, 0xd1e0cc, 0xde0c89, 0x50065e, 0x9c1169, 0x78edef, 0x6dc93d, 0xee97f4,
        0x32ab0e, 0x3a6853, 0x31865c, 0x67fef9, 0x1f2b1d, 0xb69e38, 0xaa9119, 0xf43c73, 0xfb4a3d, 0x3550c2,
        0x371f77, 0x6bfa9a, 0xcd04f3, 0xe32735, 0x9f9150, 0x049a7f, 0xfcb6be, 0x08de8a, 0x8f9887, 0xb5b407,
        0x230e34, 0x43ed7f, 0x3a88a0, 0x21874b, 0x1bdea1, 0x53c065, 0xe34a1d, 0xd6b04d, 0x5e9027, 0x2c046f,
        0xb10bb4, 0x3fa9dd, 0x0e09b8, 0x10e8b3, 0x9eedec, 0xd4c718, 0x81536d, 0x91b534, 0xec8177, 0x190e71,
        0xb592bf, 0x89c350, 0xac042e, 0xb49b52, 0xfb152f, 0x3e666e, 0x3b544e, 0xe805a1, 0x24b33c, 0xe74733,
        0x0a804d, 0x57e330, 0x4ae7d6, 0x2d8d54, 0xd1e649, 0x8a328a, 0x07a3ae, 0x84547d, 0x990a98, 0x1a4ff1,
        0xf6f7fd, 0x30c05b, 0x8d2636, 0x46c9fe, 0xccec0a, 0x4e9d28, 0x19ebb0, 0x4659d2, 0x963ef2, 0x74f851,
        0x5a0f54, 0x037270, 0xc7f6aa, 0x352787, 0x9853ea, 0xabbdcd, 0xcf05da, 0x49cad4, 0x7a4c10, 0xd9e92a,
        0x13ae97, 0x730499, 0x4e4b70, 0xff5772, 0x55b634, 0xb86222, 0xcac09a, 0xdaf8e9, 0xb5fdfc, 0x310cb3,
        0xe87fbb, 0x2102ae, 0xf8549e, 0x07a69a, 0xc4c118, 0xf9f489, 0x1af3db, 0xf5b4b0, 0x962ace, 0x046e3e,
        0xf05d12, 0x964781, 0x9c2ed4, 0x522e23, 0x177e00, 0x2bc60a, 0x222bbf, 0x486289, 0x7dc778, 0x8af387,
        0x1fab64, 0xe4d942, 0x9da058, 0x24c0e3, 0x233003, 0xd586bd, 0x5e5637, 0x7eba72, 0x0a56a5, 0xd79476,
        0x9e4c12, 0x17efee, 0x1d95b0, 0x93cbe0, 0x65fa4f, 0xd5f9e8, 0xc2b5a0, 0x593002, 0xce2f86, 0x7ca972,
        0x278533, 0xc61bb3, 0x150f36, 0x9f6a41, 0x64a53d, 0x142de4, 0x0c3352, 0x0a9c32, 0xe6c421, 0x71f1ce,
        0xf1bcc3, 0xe728e8, 0x96fbf8, 0x81a154, 0x5fa786, 0x56986e, 0x917f1d, 0xd20d8c, 0x31d71d, 0xf165b5,
        0xa57e63, 0x1ef6e6, 0x70cc73, 0xe21a6b, 0x003a93, 0x1c99de, 0xcf3145, 0xd0e442, 0x77c621, 0x67a34d,
        0xf8d626
    }
}

///
/// Self-checks for the transcription and for the small amount of logic above.
///
mod TestZobristHashSelf {

    ///
    /// The table has exactly 781 entries.
    ///
    @Test
    pub def testPolyglotSize(): Unit \ Assert =
        Assert.assertEq(expected = ZobristHash.size(), Vector.length(ZobristHash.polyglot()))

    ///
    /// Spot checks at the two ends and at the three region boundaries.
    ///
    @Test
    pub def testPolyglotBoundaryValues(): Unit \ Assert = {
        let t = ZobristHash.polyglot();
        Assert.assertEq(expected = 0x9d3924, ZobristHash.key(t, 0));
        Assert.assertEq(expected = 0xd20d8c, ZobristHash.key(t, 767));   // last piece-square key
        Assert.assertEq(expected = 0x31d71d, ZobristHash.key(t, 768));   // first castling key
        Assert.assertEq(expected = 0x1ef6e6, ZobristHash.key(t, 771));   // last castling key
        Assert.assertEq(expected = 0x70cc73, ZobristHash.key(t, 772));   // en-passant file a
        Assert.assertEq(expected = 0x67a34d, ZobristHash.key(t, 779));   // en-passant file h
        Assert.assertEq(expected = 0xf8d626, ZobristHash.key(t, 780));   // turn key
        Assert.assertEq(expected = ZobristHash.key(t, 780), ZobristHash.turnKey(t))
    }

    ///
    /// Every entry fits in 24 bits and is non-negative, as in the Scala source.
    ///
    @Test
    pub def testPolyglotRange(): Unit \ Assert =
        Assert.assertTrue(
            Vector.forAll(v -> v >= 0 and v <= 0xffffff, ZobristHash.polyglot())
        )

    ///
    /// `hashPiece` indexes `64 * (role.index * 2 + color) + square`.
    ///
    @Test
    pub def testHashPieceIndex(): Unit \ Assert = {
        let t = ZobristHash.polyglot();
        // black pawn on a1: index = 0 * 2 + 0 = 0, entry 0
        Assert.assertEq(expected = ZobristHash.key(t, 0), ZobristHash.hashPiece(t, 0, false, Role.Pawn));
        // white pawn on a1: index = 1, entry 64
        Assert.assertEq(expected = ZobristHash.key(t, 64), ZobristHash.hashPiece(t, 0, true, Role.Pawn));
        // white king on h8: index = 5 * 2 + 1 = 11, entry 64 * 11 + 63 = 767
        Assert.assertEq(expected = ZobristHash.key(t, 767), ZobristHash.hashPiece(t, 63, true, Role.King))
    }

    ///
    /// The default castling rights (`0x8100000000000081L`, all four corners) XOR all
    /// four castling keys; the empty rights hash to 0.
    ///
    @Test
    pub def testHashCastling(): Unit \ Assert = {
        let t = ZobristHash.polyglot();
        let all = Bits.bxor(Bits.bxor(Bits.bxor(
            ZobristHash.key(t, 768), ZobristHash.key(t, 769)), ZobristHash.key(t, 770)), ZobristHash.key(t, 771));
        // 0x8100000000000081L. Flix rejects hex literals above the signed maximum,
        // so the four-corner mask has to be written in signed decimal.
        Assert.assertEq(expected = all, ZobristHash.hashCastling(t, -9151314442816847743i64));
        Assert.assertEq(expected = 0, ZobristHash.hashCastling(t, 0i64));
        Assert.assertEq(expected = ZobristHash.key(t, 768), ZobristHash.hashCastling(t, Bits.bit(7)))
    }

    ///
    /// `hashTurn` / `hashEnPassant`.
    ///
    @Test
    pub def testHashTurnAndEnPassant(): Unit \ Assert = {
        let t = ZobristHash.polyglot();
        Assert.assertEq(expected = ZobristHash.key(t, 780), ZobristHash.hashTurn(t, true));
        Assert.assertEq(expected = 0, ZobristHash.hashTurn(t, false));
        Assert.assertEq(expected = 0, ZobristHash.hashEnPassant(t, false, 20));
        // e3 = square 20, file 4 -> POLYGLOT(776)
        Assert.assertEq(expected = ZobristHash.key(t, 776), ZobristHash.hashEnPassant(t, true, 20))
    }

    ///
    /// `hashPieces` over the standard starting position, reconstructed from the
    /// `Board` default bitboards, equals the XOR of the 32 individual piece keys.
    ///
    @Test
    pub def testHashPiecesStartingPosition(): Unit \ Assert = {
        let t = ZobristHash.polyglot();
        let pawns = 0x00ff00000000ff00i64;
        let knights = 0x4200000000000042i64;
        let bishops = 0x2400000000000024i64;
        let rooks = -9151314442816847743i64;   // 0x8100000000000081L
        let queens = 0x0800000000000008i64;
        let kings = 0x1000000000000010i64;
        let white = 0x000000000000ffffi64;
        let black = -281474976710656i64;       // 0xffff000000000000L
        let occupied = Bits.borL(white, black);
        let has = (b, sq) -> Bits.bandL(b, Bits.bit(sq)) != 0i64;
        let roleAt = sq ->
            if (has(pawns, sq)) Role.Pawn
            else if (has(knights, sq)) Role.Knight
            else if (has(bishops, sq)) Role.Bishop
            else if (has(rooks, sq)) Role.Rook
            else if (has(queens, sq)) Role.Queen
            else Role.King;
        let whiteAt = sq -> has(white, sq);
        // the six role boards partition `occupied`, so the `else Role.King` above is total
        let byRole = Bits.borL(Bits.borL(Bits.borL(pawns, knights), Bits.borL(bishops, rooks)),
                               Bits.borL(queens, kings));
        Assert.assertEq(expected = occupied, byRole);
        let expected = List.range(0, 64) |> List.foldLeft((acc, sq) ->
            if (has(occupied, sq)) Bits.bxor(acc, ZobristHash.hashPiece(t, sq, whiteAt(sq), roleAt(sq))) else acc,
            0);
        Assert.assertEq(expected = expected, ZobristHash.hashPieces(t, occupied, whiteAt, roleAt))
    }
}
