package org.lichess.compression.game

/** Drop-in replacement for the original `org.lichess.compression.game.Board`.
  *
  * ==Why this class exists==
  *
  * `Encoder.decode` hands back a `DecodeResult` whose `board` field the caller
  * reads. lila writes
  *
  * {{{
  * import org.lichess.compression.game.{ Encoder, Board as JavaBoard }
  * }}}
  *
  * and that import binds a '''package-level''' type. A type member of
  * `object Encoder` cannot satisfy it, however many fields that member has, which
  * is why the drop-in stopped being a type alias — see `Encoder.scala` next door.
  * `LilaSourceCompatWitness` in this package compiles that exact import shape so
  * the guarantee is checked by the build rather than asserted in a comment.
  *
  * ==What it carries==
  *
  * All thirteen public fields of the original, with the original's names, types,
  * declaration order and default values: nine bitboards, `turn`, `epSquare`,
  * `castlingRights` and `incrementalHash`. Values obtained from `Encoder.decode`
  * are asserted byte-identical to the original implementation's over the whole
  * decode corpus by `difftest`.
  *
  * ==`incrementalHash` on a hand-built board is 0==
  *
  * '''This is the one behavioural difference and it is deliberate.''' The original
  * computes the field in its constructor:
  *
  * {{{
  * var incrementalHash: Int = ZobristHash.hashPieces(this) ^ ZobristHash.hashTurn(this)
  * }}}
  *
  * (`src/main/scala/game/Board.scala:20`). Reproducing that here would mean
  * shipping `ZobristHash`, which forces `Bitboard`'s static initialiser — an
  * 88772-entry attack table plus two 64x64 tables — i.e. a second copy of the very
  * engine this artifact replaces. So a `Board` '''you''' construct has
  * `incrementalHash == 0`; only a `Board` that came out of `Encoder.decode` carries
  * the real hash, because that value is computed inside the Flix port and copied
  * across. If you construct boards yourself and rely on the hash, you want the
  * original artifact, not this one.
  *
  * ==What is not provided==
  *
  * The original's methods are absent: `play`, `legalMoves`, `isCheck`,
  * `zobristHash`, `hasLegalEnPassant`, `roleAt` and `pieceMap`, along with
  * `whiteAt`, `us`, `them` and `byColor`. The first five are the move generator,
  * which this artifact does not ship. The rest are pure functions of the nine
  * bitboards and are cheaper for a caller to recompute than for this class to
  * carry — `roleAt`, for instance, is a five-way test against `pawns`, `knights`,
  * `bishops`, `rooks` and `queens`.
  *
  * `Role`, `Piece`, `Move`, `MoveList` and `Bitboard` are likewise not declared in
  * this package. Only `Board` and the two `Encoder`s are.
  *
  * @param pawns          bitboard of every pawn
  * @param knights        bitboard of every knight
  * @param bishops        bitboard of every bishop
  * @param rooks          bitboard of every rook
  * @param queens         bitboard of every queen
  * @param kings          bitboard of both kings
  * @param white          every square occupied by a white piece
  * @param black          every square occupied by a black piece
  * @param turn           `true` when White is to move
  * @param epSquare       the en passant square, or `0` for none
  * @param castlingRights bitboard of rooks that still have castling rights
  */
final class Board(
    var pawns: Long = 0xff00000000ff00L,
    var knights: Long = 0x4200000000000042L,
    var bishops: Long = 0x2400000000000024L,
    var rooks: Long = 0x8100000000000081L,
    var queens: Long = 0x800000000000008L,
    var kings: Long = 0x1000000000000010L,
    var white: Long = 0xffffL,
    var black: Long = 0xffff000000000000L,
    var turn: Boolean = true,
    var epSquare: Int = 0,
    var castlingRights: Long = 0x8100000000000081L
):
  /** `white | black`, exactly as the original derives it. */
  var occupied: Long = white | black

  /** The full Polyglot Zobrist hash — but see the class scaladoc: this is `0` on a
    * board you constructed, and only meaningful on one from `Encoder.decode`.
    */
  var incrementalHash: Int = 0

  /** A deep copy, carrying all thirteen fields including the two derived ones.
    *
    * Same contract as the original's `copy()`: the two `var`s that are not
    * constructor parameters are assigned afterwards rather than recomputed, so a
    * decoded board's `incrementalHash` survives the copy.
    */
  def copy(): Board =
    val board =
      Board(pawns, knights, bishops, rooks, queens, kings, white, black, turn, epSquare, castlingRights)
    board.occupied = occupied
    board.incrementalHash = incrementalHash
    board
