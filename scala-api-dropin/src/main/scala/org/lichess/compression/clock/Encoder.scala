package org.lichess.compression.clock

/** Drop-in alias for the Flix-backed clock codec.
  *
  * This object exists so that code already written against the original
  * `org.lichess.compression.clock.Encoder` can switch to the Flix implementation
  * without touching a single line — same package, same object, same signatures.
  *
  * Put `compression-flix-api-dropin` on the classpath *instead of* `compression`,
  * never alongside it: both define this fully qualified name and whichever comes
  * first on the classpath silently wins.
  */
object Encoder:
  export org.lichess.compression.flix.clock.Encoder.{encode, decode}
