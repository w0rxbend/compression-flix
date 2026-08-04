package org.lichess.compression.flix.game

import org.lichess.compression.flix.Flix

/** Game (move list) compression, backed by the Flix port.
  *
  * Signature-identical to `org.lichess.compression.game.Encoder` apart from
  * `DecodeResult.board` — see `Board` below. Output is byte-for-byte identical to
  * the original; `difftest/` asserts it over the whole `HuffmanPgnTest` corpus.
  *
  * The static tables are built lazily on first use and shared for the life of the
  * process; see `org.lichess.compression.flix.Flix`. Unlike the original, which
  * kept a `ThreadLocal[MoveList]`, this is safe to call concurrently with no
  * per-thread state: the Flix implementation allocates its scratch move list
  * inside a region, per call.
  */
object Encoder:

  /** An immutable snapshot of the decoded position — the facade's
    * `DecodeResult.board`.
    *
    * The original's `Board` is a mutable object that the move generator rewrites in
    * place. This is a value: every one of its **thirteen public fields is present**,
    * carrying the same value the original produces for the same input, and
    * `difftest`'s "expose the full decoded Board identically" example asserts all
    * thirteen over 6108 decodes.
    *
    * The field order is the original's: the eleven of its primary constructor
    * (`game/Board.scala:6-17`), then the two derived vars in declaration order
    * (`:19`, `:20`).
    *
    * The original's **methods** are not here. `roleAt`, `whiteAt`, `pieceMap`, `us`,
    * `them` and `byColor` are omitted because the nine bitboards determine piece
    * placement completely, so a caller that wants them can reconstruct them from
    * these fields. `copy`, `play`, `legalMoves`, `isCheck`, `zobristHash` and
    * `hasLegalEnPassant` drive the move generator and are deliberately not exposed:
    * this artifact is a codec, not a chess engine, and re-exporting them would mean
    * marshalling `Move`, `Role` and `MoveList` across the boundary too.
    *
    * Being a case class rather than a mutable class, reads such as `board.pawns`
    * compile unchanged against the original's source, but writes such as
    * `board.pawns = x` do not. Nothing in lila writes to a decoded board.
    *
    * @param pawns           bitboard of every pawn
    * @param knights         bitboard of every knight
    * @param bishops         bitboard of every bishop
    * @param rooks           bitboard of every rook
    * @param queens          bitboard of every queen
    * @param kings           bitboard of both kings
    * @param white           every square occupied by a white piece
    * @param black           every square occupied by a black piece
    * @param turn            `true` when White is to move
    * @param epSquare        the en passant square, or `0` for none — the only piece
    *                        of position state the bitboards do not determine
    * @param castlingRights  bitboard of rooks that still have castling rights
    * @param occupied        `white | black`
    * @param incrementalHash the full Polyglot Zobrist hash;
    *                        `DecodeResult.positionHashes` keeps only its top three
    *                        bytes
    */
  final case class Board(
      pawns: Long,
      knights: Long,
      bishops: Long,
      rooks: Long,
      queens: Long,
      kings: Long,
      white: Long,
      black: Long,
      turn: Boolean,
      epSquare: Int,
      castlingRights: Long,
      occupied: Long,
      incrementalHash: Int
  )

  /** The result of replaying `plies` half-moves out of an encoded game.
    *
    * @param pgnMoves       the SAN of each ply, check and mate suffixes included
    * @param board          see `Board` — an immutable snapshot carrying all thirteen
    *                       of the original `Board`'s public fields
    * @param halfMoveClock  plies since the last capture or pawn move
    * @param positionHashes three bytes per position, most recent first, back to the
    *                       last irreversible move
    * @param lastUci        the final move in UCI notation, or `null` when `plies` is 0
    */
  final case class DecodeResult(
      pgnMoves: Array[String],
      board: Board,
      halfMoveClock: Int,
      positionHashes: Array[Byte],
      lastUci: String
  )

  /** Compresses a game given as SAN tokens, one per ply.
    *
    * Returns `null` — as the original does — if a token cannot be parsed as SAN or
    * names no legal move in the position it arrives at. The failure is
    * all-or-nothing: nothing encoded before the bad ply is returned.
    */
  def encode(pgnMoves: Array[String]): Array[Byte] =
    Flix.codec.gameEncode(Flix.tables, pgnMoves)

  /** Replays the first `plies` half-moves of an encoded game.
    *
    * `plies` is not carried in the stream, so the caller must supply it. Asking for
    * fewer plies than were encoded is legitimate and is how the original exposes
    * intermediate positions; asking for more than the stream holds is undefined and
    * will fail rather than return a wrong answer.
    */
  def decode(input: Array[Byte], plies: Int): DecodeResult =
    val codec  = Flix.codec
    val result = codec.gameDecode(Flix.tables, input, plies)
    DecodeResult(
      pgnMoves = codec.resultPgnMoves(result),
      board = Board(
        pawns = codec.resultPawns(result),
        knights = codec.resultKnights(result),
        bishops = codec.resultBishops(result),
        rooks = codec.resultRooks(result),
        queens = codec.resultQueens(result),
        kings = codec.resultKings(result),
        white = codec.resultWhite(result),
        black = codec.resultBlack(result),
        turn = codec.resultTurn(result),
        epSquare = codec.resultEpSquare(result),
        castlingRights = codec.resultCastlingRights(result),
        occupied = codec.resultOccupied(result),
        incrementalHash = codec.resultIncrementalHash(result)
      ),
      halfMoveClock = codec.resultHalfMoveClock(result),
      positionHashes = codec.resultPositionHashes(result),
      lastUci = codec.resultLastUci(result)
    )
