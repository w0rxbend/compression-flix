@main def smoke(): Unit =
  // The clock codec is deliberately lossy: LowBitTruncator drops the low three
  // bits, and for values at or above 1000 centis it does not store them at all,
  // reconstructing them as 3. So 30000 decodes as 30003 in the original too.
  val centis = Array(30000, 29000, 28500, 27000)
  val enc    = org.lichess.compression.flix.clock.Encoder.encode(centis, 30000)
  val dec    = org.lichess.compression.flix.clock.Encoder.decode(enc, 30000)
  println(s"clock: ${centis.mkString(",")} -> ${enc.length} bytes -> ${dec.mkString(",")}")
  assert(dec.length == centis.length, "clock length changed")
  assert(centis.zip(dec).forall((a, b) => math.abs(a - b) <= 8), "clock drifted beyond truncation")

  // The game codec is lossless.
  val moves = Array("e4", "e5", "Nf3", "Nc6", "Bb5")
  val genc  = org.lichess.compression.flix.game.Encoder.encode(moves)
  val gdec  = org.lichess.compression.flix.game.Encoder.decode(genc, moves.length)
  println(s"game: ${moves.mkString(" ")} -> ${genc.length} bytes -> ${gdec.pgnMoves.mkString(" ")}")
  assert(gdec.pgnMoves.sameElements(moves), "game round-trip failed")
  println("SMOKE OK")
