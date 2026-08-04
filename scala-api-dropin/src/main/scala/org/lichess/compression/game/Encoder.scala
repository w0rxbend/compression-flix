package org.lichess.compression.game

import org.lichess.compression.flix.game.Encoder as FlixEncoder

/** Drop-in replacement for the original `org.lichess.compression.game.Encoder`,
  * backed by the Flix port.
  *
  * Same purpose as the clock drop-in next door: an existing caller of
  * `org.lichess.compression.game.Encoder` keeps its imports and its call sites. Put
  * `compression-flix-api-dropin` on the classpath *instead of* `compression`, never
  * alongside it.
  *
  * ==Why this is an adapter and no longer a type alias==
  *
  * It used to be `type DecodeResult = flix.game.Encoder.DecodeResult` plus an
  * `export`. That cannot work, for a reason that has nothing to do with how many
  * fields `Board` has. lila writes
  *
  * {{{
  * import org.lichess.compression.game.{ Encoder, Board as JavaBoard }
  * def chessBoard(b: JavaBoard) = ...
  * chessBoard(decoded.board)
  * }}}
  *
  * `Board as JavaBoard` binds `org.lichess.compression.game.Board`, a
  * '''package-level''' type. An alias declared inside `object Encoder` is a
  * different name in a different scope and does not satisfy that import at all —
  * the compiler reports `value Board is not a member of org.lichess.compression.game`.
  * Giving `decoded.board` the type that import binds needs a real package-level
  * `Board` (see `Board.scala`) and a `DecodeResult` declared here whose `board`
  * field has that type; a type alias to the facade's `DecodeResult` would keep the
  * facade's `Board`, so the adapter has to re-wrap.
  *
  * `LilaSourceCompatWitness` in this package is that import shape, compiled, so
  * `sbt scalaApiDropin/compile` is the proof rather than this paragraph.
  *
  * ==Cost==
  *
  * One extra allocation per `decode`. The arrays and strings are passed through by
  * reference; only the thirteen scalars are copied into a fresh `Board`.
  */
object Encoder:

  /** The original's `Encoder.DecodeResult`, field for field.
    *
    * `board` is the package-level [[Board]] rather than the facade's case class, so
    * that `decoded.board` has the type lila's `Board as JavaBoard` import binds.
    *
    * @param pgnMoves       the SAN of each ply, check and mate suffixes included
    * @param board          the position after `plies` half-moves
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
  def encode(pgnMoves: Array[String]): Array[Byte] = FlixEncoder.encode(pgnMoves)

  /** Replays the first `plies` half-moves of an encoded game.
    *
    * `plies` is not carried in the stream, so the caller must supply it. Asking for
    * fewer plies than were encoded is legitimate and is how the original exposes
    * intermediate positions.
    */
  def decode(input: Array[Byte], plies: Int): DecodeResult =
    val decoded = FlixEncoder.decode(input, plies)
    val fb      = decoded.board
    val board = Board(
      fb.pawns,
      fb.knights,
      fb.bishops,
      fb.rooks,
      fb.queens,
      fb.kings,
      fb.white,
      fb.black,
      fb.turn,
      fb.epSquare,
      fb.castlingRights
    )
    // `occupied` and `incrementalHash` are not constructor parameters in the
    // original either. Carry the decoded values across rather than recomputing, so
    // that `incrementalHash` is the position's real hash and not this class's `0`
    // default — see the note in `Board`'s scaladoc.
    board.occupied = fb.occupied
    board.incrementalHash = fb.incrementalHash
    DecodeResult(
      pgnMoves = decoded.pgnMoves,
      board = board,
      halfMoveClock = decoded.halfMoveClock,
      positionHashes = decoded.positionHashes,
      lastUci = decoded.lastUci
    )
