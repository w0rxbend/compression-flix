///
/// Port of `org.lichess.compression.clock.Encoder`.
///
/// The top-level clock compression API. `encode` turns a series of clock
/// readings (centiseconds remaining after each move) into a bit-packed byte
/// array; `decode` inverts it. Both need the game's `startTime` (also in
/// centiseconds) as side information — it is not stored in the stream.
///
/// The pipeline, in order, is:
///
///   1. `LowBitTruncator.truncate` — drop the low three bits of every reading.
///   2. `LinearEstimator.encode`   — replace each value by its residual against
///                                   the midpoint prediction from its neighbours.
///   3. `EndTimeEstimator.encode`  — subtract the end-time prediction from the
///                                   final value.
///   4. `BitOps` — write `length - 1` unsigned, then every residual zigzag-signed.
///   5. `LowBitTruncator.writeDigits` — append the low three bits that step 1 shed,
///                                      taken from the *original* readings.
///
/// Fidelity notes:
///
///   * Step 5 reads `centis`, not `encoded`. The Scala original relies on
///     `Arrays.copyOf` having made `encoded` a separate array so that the caller's
///     input survives steps 1-3 untouched; that copy is reproduced here with
///     `Array.copy`, and it is load-bearing twice over — once for the digits, and
///     once because callers must not observe their argument being mutated.
///   * The empty-input early return is on both sides: zero centis encode to zero
///     bytes, and zero bytes decode to zero centis. Without it `encode` would index
///     `centis(-1)` in `writeDigits`, and `decode` would read past the buffer.
///   * `decode` is *not* a total inverse of `encode`: `LowBitTruncator` deliberately
///     discards the low bits of readings at or above 10 s and reconstructs them as
///     `3`. Round-trip tests must expect `(x >> 3 << 3) | 3` for those, which is what
///     the Scala implementation also produces.
///
/// Structural differences forced by Flix:
///
///   * Flix arrays are region-allocated, so both entry points take an explicit
///     `Region[r]` for their result. `decode` uses a single region for the input
///     bytes and the output because `BitReader` wraps its byte array (it does not
///     copy it) and a struct's fields share its region parameter; `encode` can and
///     does keep the caller's input array in a region of its own.
///   * `Encoder` would collide with `game/Encoder`; all `.flix` files compile as one
///     unit and modules are global, so this one is `ClockEncoder`.
///
mod ClockEncoder {

    ///
    /// Compresses `centis` — the clock reading after each move, in centiseconds —
    /// into a byte array, given the game's starting clock `startTime`.
    ///
    /// `centis` is *not* modified: the pipeline mutates a copy.
    ///
    /// # Round 6: two independent attacks on this def, both measured, both reverted
    ///
    /// The clock-encode rows are the port's last losing timing rows and its last
    /// losing allocation rows, and round 6 built and measured both of the changes the
    /// research had ranked first for them. Neither moved a JMH row, and the reason is
    /// the same in both cases, so it is recorded here rather than re-derived.
    ///
    /// **(a) Splitting the writer half into its own `writeAll` def.** Rationale:
    /// `-Djdk.graal.TraceInlining=true` shows Graal compiling this def as its own root
    /// and then refusing four callees — `BitOps.writeUnsigned` (bci 435),
    /// `writeSignedAll`'s lifted loop (520), `LowBitTruncator.writeDigits` (604) and
    /// `BitWriter.toArray` (684) — all at *later* bcis than the estimators, i.e. the
    /// budget is spent before it reaches the writer, so the `BitWriter` struct escapes
    /// four frames and partial escape analysis cannot scalarise it. Giving the writer
    /// its own root gives it a fresh budget. A standalone probe measured 256 -> 208
    /// and 344 -> 288 B/op. **JMH measured exactly zero**, on all six clock rows and on
    /// both axes: 208/248/328 B/op before and after, 46.5/81.1/138.0 -> 46.5/81.1/138.5 ns.
    ///
    /// **(b) `@Inline` on `encode` and `decode`.** Rationale: `Api.Def$clockEncode`
    /// refuses to inline this frame (787 bytecodes; `clockDecode` 867), and `@Inline`
    /// is a *Flix*-level directive that deletes the call outright — `javap` confirms
    /// the whole `ClockEncoder/` class directory disappears from a clean build and the
    /// body reappears inside `Api/Def$clockEncode.staticApply`. A standalone
    /// `ThreadMXBean.getCurrentThreadAllocatedBytes` probe over the real facade
    /// confirms it removes a 48-byte `Value$`: Flix-minus-Scala goes 176 -> 128 B/op on
    /// all three bands, identical to the byte across three runs. **JMH again measured
    /// exactly zero** — 208/248/328 B/op both ways.
    ///
    /// The two disagree because they are measuring different compiled shapes, and the
    /// JMH one is the shape the benchmark scores. In JMH's loop Graal already inlines
    /// `Def$encode` into `Def$clockEncode` and scalarises the callee's box, so there is
    /// nothing left for `@Inline` to delete. What remains is not the codec at all:
    /// Scala's 136 B/op on the 8-reading band is exactly `int[8]` (48) + `int[10]` (56)
    /// + `byte[11]` (32), the port allocates the same three arrays, and the flat
    /// +72 B/op on every band is the `@Export` shim itself — a 24-byte
    /// `Api/Def$clockEncode` closure that flows through the `Thunk$.invoke()` loop phi
    /// where PEA cannot follow it, plus one 48-byte `Value$`. No annotation on this def
    /// can reach either. See PORTING-NOTES, "Every `@Export`ed def costs 64 bytes a
    /// call".
    ///
    pub def encode(rc: Region[r], centis: Array[Int32, r1], startTime: Int32): Array[Int8, r] \ (r + r1) =
        let numMoves = Array.length(centis);
        if (numMoves == 0)
            Array.empty(rc, 0)
        else {
            // `Arrays.copyOf(centis, centis.length)`: the estimators work in place,
            // and `writeDigits` below still needs the untruncated originals.
            let encoded = Array.copy(rc, centis);
            let truncatedStart = LowBitTruncator.truncateCenti(startTime);

            LowBitTruncator.truncate(encoded);
            LinearEstimator.encode(encoded, truncatedStart);
            EndTimeEstimator.encode(encoded, truncatedStart);

            let writer = BitWriter.mk(rc);
            BitOps.writeUnsigned(numMoves - 1, writer);
            BitOps.writeSignedAll(encoded, writer);
            LowBitTruncator.writeDigits(centis, writer);

            // `BitWriter.toArray` in tail position compiles to a heap continuation
            // (see the note above `Board.put`), which also made the trampoline site
            // inside `Api.clockEncode` bimorphic. The dead `_len` binding is what
            // takes the call out of tail position: the single-let form `let r = f(x); r`
            // does NOT, because a `let` of a tail call is still a tail call.
            let out = BitWriter.toArray(writer);
            let _len = Array.length(out);
            out
        }

    ///
    /// Inverse of `encode`. `startTime` must be the same value that was passed to
    /// `encode`; it is not recoverable from `bytes`.
    ///
    /// `bytes` is not modified, but it is *wrapped* rather than copied, exactly as
    /// `ByteBuffer.wrap` is in the original — hence the shared region.
    ///
    pub def decode(rc: Region[r], bytes: Array[Int8, r], startTime: Int32): Array[Int32, r] \ r =
        if (Array.length(bytes) == 0)
            Array.empty(rc, 0)
        else {
            let reader = BitReader.mk(rc, bytes);
            let truncatedStart = LowBitTruncator.truncateCenti(startTime);

            let numMoves = BitOps.readUnsigned(reader) + 1;
            let decoded = BitOps.readSignedArray(rc, numMoves, reader);

            EndTimeEstimator.decode(decoded, truncatedStart);
            LinearEstimator.decode(decoded, truncatedStart);
            LowBitTruncator.decode(decoded, reader);

            decoded
        }
}

///
/// Self-tests for `ClockEncoder`.
///
/// The expected byte strings below are not guesses and not "whatever the port
/// produced": each one was obtained by running the Scala original
/// (`org.lichess.compression.clock.Encoder`, scala 3.8.2, JVM 25) on the same
/// input and dumping the result. Bytes are compared as unsigned `0..255` values
/// so the literals read the way a hex dump does.
///
mod TestClockEncoderSelf {

    ///
    /// Encode, then check three things at once: the caller's array survived intact,
    /// the bytes match the Scala reference exactly, and decoding gives back the
    /// values the Scala reference decodes to.
    ///
    def check(rc: Region[r],
              startTime: Int32,
              centis: Array[Int32, r],
              expectedBytes: List[Int32],
              expectedDecoded: List[Int32]): Unit \ (r + Assert) =
        let before = Array.toList(centis);
        let encoded = ClockEncoder.encode(rc, centis, startTime);
        // `Arrays.copyOf` in the original: the argument must come back untouched.
        Assert.assertEq(expected = before, Array.toList(centis));
        Assert.assertEq(expected = expectedBytes, List.map(Bits.byteToUnsigned, Array.toList(encoded)));
        let decoded = ClockEncoder.decode(rc, encoded, startTime);
        Assert.assertEq(expected = expectedDecoded, Array.toList(decoded))

    ///
    /// Zero readings encode to zero bytes, and zero bytes decode to zero readings.
    ///
    @Test
    pub def testEmpty(): Unit \ Assert = region rc {
        let empty: Array[Int32, rc] = Array.empty(rc, 0);
        let encoded = ClockEncoder.encode(rc, empty, 18000);
        Assert.assertEq(expected = 0, Array.length(encoded));
        let decoded = ClockEncoder.decode(rc, encoded, 18000);
        Assert.assertEq(expected = 0, Array.length(decoded))
    }

    ///
    /// One move. Scala: `Encoder.encode(Array(17980), 18000) == [0x00, 0x58]`.
    ///
    @Test
    pub def testSingle(): Unit \ Assert = region rc {
        check(rc, 18000, Array#{17980} @ rc,
            0 :: 88 :: Nil,
            17980 :: Nil)
    }

    ///
    /// Four moves of a 3+0 game. Note the decoded values are *not* the inputs:
    /// every reading at or above 1000 centis loses its low three bits and gets `3`
    /// back, except the last, whose digits are always transmitted.
    ///
    @Test
    pub def testShort(): Unit \ Assert = region rc {
        check(rc, 18000, Array#{17980, 17960, 17800, 17650} @ rc,
            12 :: 8 :: 132 :: 11 :: 40 :: 80 :: Nil,
            17979 :: 17963 :: 17803 :: 17650 :: Nil)
    }

    ///
    /// Ten moves of a 5+0 game.
    ///
    @Test
    pub def testBlitz(): Unit \ Assert = region rc {
        check(rc, 30000,
            Array#{29900, 29850, 29500, 29100, 28700, 28000, 27000, 25500, 24000, 22000} @ rc,
            36 :: 95 :: 143 :: 129 :: 2 :: 45 :: 41 :: 135 :: 236 :: 30 :: 158 :: 2 :: 176 :: 192 :: Nil,
            29899 :: 29851 :: 29499 :: 29099 :: 28699 :: 28003 :: 27003 :: 25499 :: 24003 :: 22000 :: Nil)
    }

    ///
    /// A bullet game running down to zero. Everything below the 1000-centi cutoff
    /// round-trips exactly, which is the whole point of `LowBitTruncator`.
    ///
    @Test
    pub def testBulletLowEnd(): Unit \ Assert = region rc {
        check(rc, 6000,
            Array#{5900, 5700, 5000, 4000, 3000, 2000, 1500, 900, 500, 250, 120, 60, 10, 5, 0} @ rc,
            58 :: 67 :: 248 :: 122 :: 145 :: 3 :: 209 :: 244 :: 119 :: 177 :: 94 :: 210 :: 55 :: 180 ::
                4 :: 176 :: 43 :: 163 :: 145 :: 8 :: 168 :: Nil,
            5899 :: 5699 :: 5003 :: 4003 :: 3003 :: 2003 :: 1499 :: 900 :: 500 :: 250 :: 120 :: 60 ::
                10 :: 5 :: 0 :: Nil)
    }

    ///
    /// All zeros: exercises the `writeUnsigned` fast path and an all-zero payload.
    ///
    @Test
    pub def testZeros(): Unit \ Assert = region rc {
        check(rc, 0, Array#{0, 0, 0, 0} @ rc,
            12 :: 0 :: 0 :: 0 :: 0 :: 0 :: Nil,
            0 :: 0 :: 0 :: 0 :: Nil)
    }

    ///
    /// Values straddling the 1000-centi cutoff, including the asymmetry between the
    /// encoder's test (on the raw value) and the decoder's (on `value >> 3 << 3`):
    /// 1000 truncates to 125, and `125 << 3 == 1000` is not `< 1000`, so the encoder
    /// writes its digits and the decoder discards them — 1000 comes back as 1003.
    ///
    @Test
    pub def testCutoffEdge(): Unit \ Assert = region rc {
        check(rc, 1000, Array#{1007, 1000, 999, 1001, 8, 7, 0} @ rc,
            24 :: 32 :: 188 :: 63 :: 143 :: 147 :: 2 :: 182 :: 227 :: 128 :: Nil,
            1003 :: 1003 :: 999 :: 1003 :: 8 :: 7 :: 0 :: Nil)
    }

    ///
    /// `Int32.maxValue` clock values: `EndTimeEstimator` multiplies `startTime` by
    /// the move index, which overflows, and `LinearEstimator` averages a wrapping
    /// sum. Both must wrap exactly as Java does for these bytes to match.
    ///
    @Test
    pub def testOverflowingStartTime(): Unit \ Assert = region rc {
        check(rc, 2147483647, Array#{2147483647, 2147483000, 100, 0} @ rc,
            15 :: 2 :: 130 :: 255 :: 255 :: 255 :: 207 :: 92 :: 255 :: 255 :: 255 :: 63 ::
                255 :: 255 :: 255 :: 229 :: 224 :: Nil,
            2147483643 :: 2147483003 :: 100 :: 0 :: Nil)
    }

    ///
    /// Sixty moves — past the `maxIdx < 32` guard in `EndTimeEstimator`, so the
    /// end-time estimate is skipped, and long enough to fill several writer words.
    ///
    @Test
    pub def testLongGame(): Unit \ Assert = region rc {
        let centis = Array.init(rc, i -> 60000 - i * 900, 60);
        check(rc, 60000, centis,
            236 :: 98 :: 112 :: 34 :: 112 :: 0 :: 2 :: 39 :: 0 :: 0 :: 0 :: 0 :: 0 :: 50 :: 60 ::
                12 :: 44 :: 12 :: 32 :: 2 :: 192 :: 194 :: 0 :: 32 :: 2 :: 0 :: 44 :: 15 :: 35 ::
                3 :: 35 :: 0 :: 0 :: 50 :: 48 :: 0 :: 0 :: 0 :: 0 :: 0 :: 44 :: 12 :: 44 :: 12 ::
                32 :: 2 :: 192 :: 194 :: 0 :: 32 :: 2 :: 0 :: 47 :: 53 :: 160 :: Nil,
            List.map(i -> if (i == 0) 60003 else if (i == 59) 6900 else Bits.bor(Bits.shl(Bits.shr(60000 - i * 900, 3), 3), 3),
                List.range(0, 60)))
    }

    ///
    /// Round-trip property: every reading strictly below the 1000-centi cutoff is
    /// recovered exactly, and the final reading always is.
    ///
    @Test
    pub def testBelowCutoffRoundTripsExactly(): Unit \ Assert = region rc {
        let centis = Array.init(rc, i -> 999 - i * 7, 100);
        let encoded = ClockEncoder.encode(rc, centis, 1000);
        let decoded = ClockEncoder.decode(rc, encoded, 1000);
        Assert.assertEq(expected = Array.toList(centis), Array.toList(decoded))
    }
}
