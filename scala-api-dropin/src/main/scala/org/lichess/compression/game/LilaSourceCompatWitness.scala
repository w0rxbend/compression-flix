package org.lichess.compression.game

import org.lichess.compression.game.{ Encoder, Board as JavaBoard }

/** A compile-time witness that lila's actual source shape still compiles.
  *
  * This object exists only to be compiled. It reproduces, verbatim, the way
  * lila's `modules/game/src/main/PgnStorage.scala` uses this artifact: the
  * `Board as JavaBoard` rename in the import, the nine bitboards fed to
  * `chessBoard`, and `board.castlingRights` read twice (once as `unmovedRooks`,
  * once as `castles`). If any of that stops compiling, `sbt scalaApiDropin/compile`
  * fails and the drop-in is no longer a drop-in.
  *
  * The import is the load-bearing part. `Board as JavaBoard` binds a *package-level*
  * `org.lichess.compression.game.Board`, so it cannot be satisfied by a type member
  * of `object Encoder`, however many fields that member has. Against the drop-in as
  * it stood before `Board.scala` was added next door, this file did not compile:
  *
  * {{{
  * [error] -- [E008] Not Found Error: .../LilaSourceCompatWitness.scala:3:47
  * [error] 3 |import org.lichess.compression.game.{ Encoder, Board as JavaBoard }
  * [error]   |                                               ^^^^^
  * [error]   |     value Board is not a member of org.lichess.compression.game
  * [error] -- [E006] Not Found Error: .../LilaSourceCompatWitness.scala:32:20
  * [error] 32 |  def chessBoard(b: JavaBoard): Long =
  * [error]    |                    ^^^^^^^^^
  * [error]    |                    Not found: type JavaBoard
  * }}}
  *
  * That is the evidence the drop-in was not in fact drop-in. The nine bitboards
  * below are the nine `chessBoard` arguments in lila's
  * `modules/game/src/main/PgnStorage.scala`; it reads no other field and calls no
  * method on the decoded board.
  *
  * There is no test configuration on this project on purpose. Compiling *is* the
  * assertion, so the proof runs on every build and cannot be skipped.
  */
object LilaSourceCompatWitness:

  /** lila: `chess.Board(...)` is built from all nine placement bitboards. */
  def chessBoard(b: JavaBoard): Long =
    b.occupied | b.white | b.black | b.pawns | b.knights | b.bishops | b.rooks | b.queens | b.kings

  /** lila: `unmovedRooks = UnmovedRooks(decoded.board.castlingRights)`. */
  def unmovedRooks(d: Encoder.DecodeResult): Long = d.board.castlingRights

  /** lila: `castles = Castles(decoded.board.castlingRights)`. */
  def castles(d: Encoder.DecodeResult): Long = d.board.castlingRights

  /** Forces every reference above to be type-checked rather than merely parsed. */
  def use(d: Encoder.DecodeResult): Long = chessBoard(d.board) ^ unmovedRooks(d) ^ castles(d)
