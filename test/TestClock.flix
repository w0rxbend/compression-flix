///
/// Port of `src/test/scala/ClockHistoryTest.scala` (`BinaryClockHistoryTest`).
///
/// The Scala suite exercises `org.lichess.compression.clock.Encoder` through a thin
/// `clockHistory` facade that wraps `Centis`/`ByteArray` value classes; those wrappers
/// carry no behaviour beyond `flagged` (drop the last time before writing, append a
/// zero after reading), so they are inlined here rather than reproduced. Every case in
/// the suite passes `flagged = false`, so the flag never changes anything and no test
/// below models it.
///
/// The Scala assertions are of the form
/// `restored.size must_== times.size` and `a.centis must beCloseTo(c.centis +/- 4)` —
/// i.e. the round trip is only required to be accurate to four centiseconds, because
/// `LowBitTruncator` deliberately discards the low three bits of any reading at or
/// above the 1000-centi cutoff. `closeTo` below is exactly that predicate.
///
/// Those tolerance assertions are kept, but every test also pins the *exact* bytes
/// `encode` produces and the *exact* values `decode` returns. Both were obtained by
/// running the Scala original (Scala 3.8.2, JVM 25) on the same inputs and dumping the
/// result — not by observing what the Flix port does. A tolerance-only test would pass
/// for a port that was systematically off by three; the byte-exact assertions are what
/// make this a fidelity test.
///
/// Bytes are compared as unsigned `0 .. 255` so the literals read like a hex dump.
///
mod TestClock {

    /// `Centis(60 * 60 * 100)` from the Scala suite.
    def hour(): Int32 = 360000

    /// `hour * 24`.
    def day(): Int32 = 8640000

    ///
    /// specs2's `beLike`: same length, and every element within +/- 4 centis.
    ///
    def assertCloseTo(expected: List[Int32], actual: List[Int32]): Unit \ Assert =
        Assert.assertEq(expected = List.length(expected), List.length(actual));
        let bad = List.zip(expected, actual) |> List.filter(match (c, a) -> Bits.absInt(a - c) > 4);
        Assert.assertEq(expected = (Nil: List[(Int32, Int32)]), bad)

    ///
    /// One `writeSide`/`readSide` round trip, checked four ways: the caller's array is
    /// untouched, the bytes match the Scala reference, the decoded values match the
    /// Scala reference, and the decoded values are within the suite's +/- 4 tolerance
    /// of the input.
    ///
    def check(rc: Region[r],
              start: Int32,
              times: List[Int32],
              expectedBytes: List[Int32],
              expectedDecoded: List[Int32]): Unit \ (r + Assert) =
        let input = List.toArray(rc, times);
        let encoded = ClockEncoder.encode(rc, input, start);
        // `Arrays.copyOf` inside `Encoder.encode`: the argument must survive intact.
        Assert.assertEq(expected = times, Array.toList(input));
        Assert.assertEq(expected = expectedBytes,
            List.map(Bits.byteToUnsigned, Array.toList(encoded)));
        let decoded = Array.toList(ClockEncoder.decode(rc, encoded, start));
        Assert.assertEq(expected = expectedDecoded, decoded);
        assertCloseTo(times, decoded)

    ///
    /// "handle empty vectors": `writeSide(Centis(720000), Vector.empty, false).isEmpty`.
    ///
    /// The empty case is a guard on both sides — without it `writeDigits` would index
    /// `centis(-1)` and `decode` would read past the end of the buffer.
    ///
    @Test
    pub def testHandleEmptyVectors(): Unit \ Assert = region rc {
        let empty: Array[Int32, rc] = Array.empty(rc, 0);
        let encoded = ClockEncoder.encode(rc, empty, 720000);
        Assert.assertEq(expected = 0, Array.length(encoded));
        // ...and empty bytes decode back to no readings at all.
        Assert.assertEq(expected = 0, Array.length(ClockEncoder.decode(rc, encoded, 720000)))
    }

    ///
    /// "handle singleton vectors": one reading of 1234 centis against a 12345 start.
    ///
    /// A single reading is the case where `writeDigits`' loop body never runs and only
    /// the unconditional final `writeBits(centis(maxIdx), 3)` fires, so the low three
    /// bits survive and 1234 comes back exactly despite being over the cutoff.
    ///
    @Test
    pub def testHandleSingletonVectors(): Unit \ Assert = region rc {
        check(rc, 12345, 1234 :: Nil,
            3 :: 158 :: 161 :: 64 :: Nil,
            1234 :: Nil)
    }

    ///
    /// "restorable": 43 readings of a two-hour game, `21000 - 10 * t`.
    ///
    /// Note the last two readings jump back up (1000 then 20700); the linear estimator's
    /// residuals for those are large, which is what makes this case worth pinning.
    ///
    @Test
    pub def testRestorable(): Unit \ Assert = region rc {
        let times =
            21000 :: 20970 :: 20940 :: 20910 :: 20880 :: 20850 :: 20820 :: 20790 :: 20760 ::
            20730 :: 20700 :: 20670 :: 20640 :: 20610 :: 20580 :: 20550 :: 20520 :: 20490 ::
            20460 :: 20430 :: 20400 :: 20370 :: 20340 :: 20310 :: 20280 :: 20250 :: 20220 ::
            20190 :: 20160 :: 20130 :: 20100 :: 20070 :: 20040 :: 20010 :: 19980 :: 19950 ::
            19920 :: 19010 :: 17670 :: 15330 :: 14340 :: 1000 :: 20700 :: Nil;
        check(rc, hour() * 2, times,
            168 :: 105 :: 173 :: 165 :: 158 :: 182 :: 148 :: 64 :: 41 :: 173 :: 165 :: 0 ::
            65 :: 2 :: 158 :: 182 :: 148 :: 1 :: 6 :: 0 :: 65 :: 2 :: 0 :: 64 :: 61 :: 221 ::
            165 :: 0 :: 65 :: 2 :: 16 :: 64 :: 2 :: 16 :: 13 :: 204 :: 33 :: 4 :: 3 :: 19 ::
            234 :: 135 :: 195 :: 239 :: 147 :: 92 :: 63 :: 226 :: 11 :: 105 :: 194 :: 128 :: Nil,
            21003 :: 20971 :: 20939 :: 20907 :: 20883 :: 20851 :: 20819 :: 20787 :: 20763 ::
            20731 :: 20699 :: 20667 :: 20643 :: 20611 :: 20579 :: 20547 :: 20523 :: 20491 ::
            20459 :: 20427 :: 20403 :: 20371 :: 20339 :: 20307 :: 20283 :: 20251 :: 20219 ::
            20187 :: 20163 :: 20131 :: 20099 :: 20067 :: 20043 :: 20011 :: 19979 :: 19947 ::
            19923 :: 19011 :: 17667 :: 15331 :: 14339 :: 1003 :: 20700 :: Nil)
    }

    ///
    /// "restore correspondence": eight readings of a two-day correspondence game,
    /// `day * 2 - t`. The values are near 1.7e7, so the residuals stay small but the
    /// absolute clock is large — this is the case that would break if the truncation
    /// or the end-time estimate lost the high bits.
    ///
    @Test
    pub def testRestoreCorrespondence(): Unit \ Assert = region rc {
        let base = day() * 2;
        let times = List.map(t -> base - t, 118 :: 204 :: 80 :: 191 :: 75 :: 230 :: 48 :: 258 :: Nil);
        Assert.assertEq(
            expected = 17279882 :: 17279796 :: 17279920 :: 17279809 :: 17279925 :: 17279770 ::
                       17279952 :: 17279742 :: Nil,
            times);
        check(rc, base, times,
            28 :: 54 :: 222 :: 54 :: 33 :: 3 :: 33 :: 154 :: 111 :: 101 :: 240 :: Nil,
            17279883 :: 17279795 :: 17279923 :: 17279811 :: 17279923 :: 17279771 ::
            17279955 :: 17279742 :: Nil)
    }

    ///
    /// "not drift": the fixed point of repeated re-encoding.
    ///
    /// Each step appends one more reading to whatever the *previous* decode returned and
    /// re-encodes the whole history, so any lossy step would compound. The Scala suite
    /// only asserts the final vector is within +/- 4 of the input; this also pins the
    /// bytes emitted at every one of the eight steps, which is what would actually
    /// localise a regression.
    ///
    @Test
    pub def testNotDrift(): Unit \ Assert = region rc {
        let times = 5009 :: 4321 :: 2999 :: 321 :: 3044 :: 21 :: 2055 :: 77 :: Nil;
        let start = 6000;
        def loop(ends, restored, acc) = match ends {
            case Nil     => (restored, List.reverse(acc))
            case e :: es =>
                let input = List.toArray(rc, List.append(restored, e :: Nil));
                let binary = ClockEncoder.encode(rc, input, start);
                let bytes = List.map(Bits.byteToUnsigned, Array.toList(binary));
                let next = Array.toList(ClockEncoder.decode(rc, binary, start));
                loop(es, next, bytes :: acc)
        };
        let (finalRestored, steps) = loop(times, Nil, Nil);

        // Every intermediate encoding, byte for byte, from the Scala reference.
        Assert.assertEq(
            expected =
                (3 :: 119 :: 32 :: Nil) ::
                (6 :: 81 :: 214 :: 196 :: 128 :: Nil) ::
                (10 :: 4 :: 192 :: 179 :: 194 :: 224 :: Nil) ::
                (14 :: 81 :: 138 :: 70 :: 133 :: 255 :: 208 :: 128 :: Nil) ::
                (18 :: 81 :: 196 :: 107 :: 88 :: 116 :: 169 :: 146 :: 48 :: Nil) ::
                (22 :: 4 :: 192 :: 131 :: 158 :: 70 :: 238 :: 43 :: 125 :: 13 :: Nil) ::
                (26 :: 4 :: 192 :: 161 :: 129 :: 135 :: 74 :: 36 :: 222 :: 202 :: 62 :: 35 :: 120 :: Nil) ::
                (30 :: 81 :: 138 :: 70 :: 133 :: 151 :: 74 :: 238 :: 42 :: 199 :: 111 :: 24 ::
                    113 :: 13 :: 160 :: Nil) ::
                Nil,
            steps);

        // The Scala reference's final vector, exactly.
        Assert.assertEq(expected = 5011 :: 4323 :: 2995 :: 321 :: 3043 :: 21 :: 2051 :: 77 :: Nil,
            finalRestored);
        // ...and the suite's own assertion: it has not drifted more than +/- 4.
        assertCloseTo(times, finalRestored)
    }

    ///
    /// `encode` must not mutate its argument — the Scala original relies on
    /// `Arrays.copyOf`, and it is load-bearing twice over: `writeDigits` reads the
    /// *untruncated* originals after the estimators have run, and callers keep their
    /// array. Checked here on its own, on an input where all three pipeline stages
    /// (truncate, linear estimate, end-time estimate) do real work.
    ///
    @Test
    pub def testEncodeDoesNotMutateInput(): Unit \ Assert = region rc {
        let times = 29900 :: 29850 :: 29500 :: 29100 :: 28700 :: 28000 :: 27000 :: 25500 :: Nil;
        let input = List.toArray(rc, times);
        let _ = ClockEncoder.encode(rc, input, 30000);
        Assert.assertEq(expected = times, Array.toList(input));
        // Encoding twice from the same array must give the same bytes; it would not if
        // the first call had mutated it.
        let a = ClockEncoder.encode(rc, input, 30000);
        let b = ClockEncoder.encode(rc, input, 30000);
        Assert.assertEq(expected = Array.toList(a), Array.toList(b));
        Assert.assertEq(expected = times, Array.toList(input))
    }

    ///
    /// `decode` must not mutate the byte array it is handed either — `BitOps.Reader`
    /// wraps it with `ByteBuffer.wrap` and only ever reads. Decoding twice must give
    /// the same answer.
    ///
    @Test
    pub def testDecodeDoesNotMutateInput(): Unit \ Assert = region rc {
        let input = List.toArray(rc, 5009 :: 4321 :: 2999 :: 321 :: Nil);
        let encoded = ClockEncoder.encode(rc, input, 6000);
        let before = Array.toList(encoded);
        let first = Array.toList(ClockEncoder.decode(rc, encoded, 6000));
        Assert.assertEq(expected = before, Array.toList(encoded));
        let second = Array.toList(ClockEncoder.decode(rc, encoded, 6000));
        Assert.assertEq(expected = first, second)
    }
}
