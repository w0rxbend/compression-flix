///
/// Boundary tests for `BitOps` / `BitReader` / `BitWriter`.
///
/// Every expected byte string and every expected read-back value in this file was
/// produced by running the Scala original — `org.lichess.compression.BitOps`,
/// Scala 3.8.2 on JVM 25 — over the same inputs and dumping the result. Nothing
/// here was derived from the Flix implementation, so a test passing means the port
/// agrees with the reference, not merely with itself.
///
/// Bytes are compared as unsigned `0 .. 255` so the literals read like a hex dump.
///
/// Coverage:
///
///   * `writeUnsigned`/`readUnsigned` at every varint group boundary. The encoding
///     is a 6-bit head carrying 5 payload bits plus a continuation flag, then 4-bit
///     groups carrying 3 payload bits plus a continuation flag, so the widths step
///     at `32 * 8^k - 1` -> `32 * 8^k`. All ten of those transitions are here, plus
///     values whose top bit is set (`-1`, `Int32.minValue`) which exercise the
///     `curVal << 29` shift into the sign bit on the read side.
///   * `writeSigned`/`readSigned` zigzag over negative, zero and positive values,
///     including both Int32 extremes. `Int32.minValue` is the interesting one:
///     `(n << 1) ^ (n >> 31)` relies on `n << 1` wrapping to `0`.
///   * `BitWriter.toArray` for every possible pending-byte count 0, 1, 2, 3 and 4,
///     including the `numPendingBytes == 4` `putInt` branch and the word-flush path
///     inside `writeBits`.
///   * `BitReader` over byte arrays of length 1, 2, 3, 5, 6 and 7 — i.e. every
///     ragged-tail shape `readNext` can meet — including reads that straddle the
///     boundary between a full word and the tail.
///
/// Note on unreachable widths: the Scala `BitMasks` table has 32 entries, so
/// `writeBits(_, 32)` throws `ArrayIndexOutOfBoundsException` there. No test below
/// passes 32, and the 32-bit-total cases are built from two 16-bit writes, exactly
/// as a caller would have to.
///
mod TestBitOps {

    ///
    /// The bytes a single `writeUnsigned` produces, as unsigned `0 .. 255`.
    ///
    def encUnsigned(rc: Region[r], n: Int32): List[Int32] \ r =
        let w = BitWriter.mk(rc);
        BitOps.writeUnsigned(n, w);
        List.map(Bits.byteToUnsigned, Array.toList(BitWriter.toArray(w)))

    ///
    /// The bytes a single `writeSigned` produces, as unsigned `0 .. 255`.
    ///
    def encSigned(rc: Region[r], n: Int32): List[Int32] \ r =
        let w = BitWriter.mk(rc);
        BitOps.writeSigned(n, w);
        List.map(Bits.byteToUnsigned, Array.toList(BitWriter.toArray(w)))

    ///
    /// Write `n` alone, check the bytes against the Scala reference, then read it back.
    ///
    def checkUnsigned(rc: Region[r], n: Int32, expected: List[Int32]): Unit \ (r + Assert) =
        let bytes = encUnsigned(rc, n);
        Assert.assertEq(expected = expected, bytes);
        let arr = bytesOf(rc, bytes);
        let rd = BitReader.mk(rc, arr);
        Assert.assertEq(expected = n, BitOps.readUnsigned(rd))

    ///
    /// Same for `writeSigned`/`readSigned`.
    ///
    def checkSigned(rc: Region[r], n: Int32, expected: List[Int32]): Unit \ (r + Assert) =
        let bytes = encSigned(rc, n);
        Assert.assertEq(expected = expected, bytes);
        let arr = bytesOf(rc, bytes);
        let rd = BitReader.mk(rc, arr);
        Assert.assertEq(expected = n, BitOps.readSigned(rd))

    ///
    /// Build a byte array from unsigned `0 .. 255` literals.
    ///
    def bytesOf(rc: Region[r], vals: List[Int32]): Array[Int8, r] \ r =
        List.toArray(rc, List.map(Bits.toByte, vals))

    ///
    /// `readBits` for each width in turn. Written with explicit recursion rather
    /// than `List.map` because the reads are effectful and must happen left to right.
    ///
    def readWidths(widths: List[Int32], rd: BitReader[r]): List[Int32] \ r =
        match widths {
            case Nil       => Nil
            case w :: rest =>
                let v = BitReader.readBits(w, rd);
                v :: readWidths(rest, rd)
        }

    ///
    /// `writeBits` for each `(data, numBits)` pair in turn, then `toArray`.
    ///
    def writePairs(rc: Region[r], pairs: List[(Int32, Int32)]): List[Int32] \ r =
        let w = BitWriter.mk(rc);
        def loop(ps) = match ps {
            case Nil            => ()
            case (d, n) :: rest => BitWriter.writeBits(d, n, w); loop(rest)
        };
        loop(pairs);
        List.map(Bits.byteToUnsigned, Array.toList(BitWriter.toArray(w)))

    // ------------------------------------------------------------------
    // writeUnsigned / readUnsigned: varint group boundaries
    // ------------------------------------------------------------------

    ///
    /// Below the 6-bit head's payload capacity: `n & ~0x1f == 0`, one 6-bit write,
    /// which rounds up to a single byte. 31 is the last value that fits.
    ///
    @Test
    pub def testUnsignedHeadOnly(): Unit \ Assert = region rc {
        checkUnsigned(rc, 0, 0 :: Nil);
        checkUnsigned(rc, 1, 4 :: Nil);
        checkUnsigned(rc, 30, 120 :: Nil);
        checkUnsigned(rc, 31, 124 :: Nil)
    }

    ///
    /// 32 is the first value that needs a continuation group: head becomes
    /// `n | 0x20`, then one 4-bit group. 63 is the last with `n >>> 5 == 1`.
    ///
    @Test
    pub def testUnsignedFirstGroup(): Unit \ Assert = region rc {
        checkUnsigned(rc, 32, 128 :: 64 :: Nil);
        checkUnsigned(rc, 33, 132 :: 64 :: Nil);
        checkUnsigned(rc, 63, 252 :: 64 :: Nil);
        checkUnsigned(rc, 64, 128 :: 128 :: Nil);
        checkUnsigned(rc, 255, 253 :: 192 :: Nil)
    }

    ///
    /// Each subsequent 3-bit group boundary: `32 * 8^k - 1` still fits in `k` groups,
    /// `32 * 8^k` needs `k + 1`. Ten transitions, up to `Int32.maxValue`.
    ///
    @Test
    pub def testUnsignedGroupBoundaries(): Unit \ Assert = region rc {
        // k = 1 -> 2
        checkUnsigned(rc, 256, 130 :: 4 :: Nil);
        checkUnsigned(rc, 257, 134 :: 4 :: Nil);
        checkUnsigned(rc, 2047, 255 :: 220 :: Nil);
        // k = 2 -> 3
        checkUnsigned(rc, 2048, 130 :: 32 :: 64 :: Nil);
        checkUnsigned(rc, 16383, 255 :: 253 :: 192 :: Nil);
        // k = 3 -> 4
        checkUnsigned(rc, 16384, 130 :: 34 :: 4 :: Nil);
        checkUnsigned(rc, 131071, 255 :: 255 :: 220 :: Nil);
        // k = 4 -> 5
        checkUnsigned(rc, 131072, 130 :: 34 :: 32 :: 64 :: Nil);
        checkUnsigned(rc, 1048575, 255 :: 255 :: 253 :: 192 :: Nil);
        // k = 5 -> 6
        checkUnsigned(rc, 1048576, 130 :: 34 :: 34 :: 4 :: Nil);
        checkUnsigned(rc, 8388607, 255 :: 255 :: 255 :: 220 :: Nil);
        // k = 6 -> 7
        checkUnsigned(rc, 8388608, 130 :: 34 :: 34 :: 32 :: 64 :: Nil);
        checkUnsigned(rc, 67108863, 255 :: 255 :: 255 :: 253 :: 192 :: Nil);
        // k = 7 -> 8
        checkUnsigned(rc, 67108864, 130 :: 34 :: 34 :: 34 :: 4 :: Nil);
        checkUnsigned(rc, 536870911, 255 :: 255 :: 255 :: 255 :: 220 :: Nil);
        // k = 8 -> 9
        checkUnsigned(rc, 536870912, 130 :: 34 :: 34 :: 34 :: 32 :: 64 :: Nil);
        checkUnsigned(rc, 2147483647, 255 :: 255 :: 255 :: 255 :: 252 :: 192 :: Nil)
    }

    ///
    /// Negative arguments to `writeUnsigned`. The head takes `n & 0x1f` and the
    /// continuation walks `n >>> 5` — a *logical* shift, so these are the widest
    /// encodings the format admits (nine groups, 42 bits, six bytes). On the read
    /// side the last group is shifted left by 29, which lands in the sign bit; both
    /// implementations must wrap identically for the round-trip to close.
    ///
    @Test
    pub def testUnsignedNegativeArguments(): Unit \ Assert = region rc {
        checkUnsigned(rc, -1, 255 :: 255 :: 255 :: 255 :: 253 :: 192 :: Nil);
        checkUnsigned(rc, -2147483648, 130 :: 34 :: 34 :: 34 :: 33 :: 0 :: Nil);
        checkUnsigned(rc, -16, 195 :: 255 :: 255 :: 255 :: 253 :: 192 :: Nil)
    }

    ///
    /// All of the above written into one writer, so the values straddle word and
    /// byte boundaries instead of each starting bit-aligned. 83 bytes, matching Scala.
    ///
    @Test
    pub def testUnsignedStream(): Unit \ Assert = region rc {
        let vals =
            0 :: 1 :: 30 :: 31 :: 32 :: 33 :: 63 :: 64 :: 255 :: 256 :: 257 :: 2047 :: 2048 ::
            16383 :: 16384 :: 131071 :: 131072 :: 1048575 :: 1048576 :: 8388607 :: 8388608 ::
            67108863 :: 67108864 :: 536870911 :: 536870912 :: 2147483647 :: -1 ::
            -2147483648 :: -16 :: Nil;
        let w = BitWriter.mk(rc);
        def writeAll(l) = match l {
            case Nil     => ()
            case v :: vs => BitOps.writeUnsigned(v, w); writeAll(vs)
        };
        writeAll(vals);
        let out = BitWriter.toArray(w);
        Assert.assertEq(expected = 83, Array.length(out));
        Assert.assertEq(
            expected =
                0 :: 23 :: 159 :: 128 :: 97 :: 31 :: 198 :: 2 :: 253 :: 224 :: 129 :: 134 :: 7 ::
                255 :: 120 :: 34 :: 7 :: 255 :: 247 :: 130 :: 34 :: 7 :: 255 :: 255 :: 120 :: 34 ::
                34 :: 7 :: 255 :: 255 :: 247 :: 130 :: 34 :: 34 :: 7 :: 255 :: 255 :: 255 :: 120 ::
                34 :: 34 :: 34 :: 7 :: 255 :: 255 :: 255 :: 247 :: 130 :: 34 :: 34 :: 34 :: 7 ::
                255 :: 255 :: 255 :: 255 :: 120 :: 34 :: 34 :: 34 :: 34 :: 7 :: 255 :: 255 :: 255 ::
                255 :: 243 :: 255 :: 255 :: 255 :: 255 :: 253 :: 224 :: 136 :: 136 :: 136 :: 136 ::
                76 :: 63 :: 255 :: 255 :: 255 :: 220 :: Nil,
            List.map(Bits.byteToUnsigned, Array.toList(out)));
        let rd = BitReader.mk(rc, out);
        def readAll(l) = match l {
            case Nil      => Nil
            case _ :: vs  =>
                let v = BitOps.readUnsigned(rd);
                v :: readAll(vs)
        };
        Assert.assertEq(expected = vals, readAll(vals))
    }

    // ------------------------------------------------------------------
    // writeSigned / readSigned: zigzag
    // ------------------------------------------------------------------

    ///
    /// Zigzag maps `0, -1, 1, -2, 2, ...` to `0, 1, 2, 3, 4, ...`, so tiny values of
    /// either sign stay one byte. `-16` fits (zigzag 31) but `16` does not (zigzag 32).
    ///
    @Test
    pub def testSignedSmall(): Unit \ Assert = region rc {
        checkSigned(rc, 0, 0 :: Nil);
        checkSigned(rc, -1, 4 :: Nil);
        checkSigned(rc, 1, 8 :: Nil);
        checkSigned(rc, -2, 12 :: Nil);
        checkSigned(rc, 2, 16 :: Nil);
        checkSigned(rc, 15, 120 :: Nil);
        checkSigned(rc, -15, 116 :: Nil);
        // The zigzag boundary: -16 -> 31 (one byte), 16 -> 32 (two bytes).
        checkSigned(rc, -16, 124 :: Nil);
        checkSigned(rc, 16, 128 :: 64 :: Nil)
    }

    ///
    /// The Int32 extremes. `writeSigned(Int32.minValue)` computes
    /// `(minValue << 1) ^ (minValue >> 31)` = `0 ^ -1` = `-1`, which is only correct
    /// if the left shift wraps to zero and the right shift is arithmetic.
    ///
    @Test
    pub def testSignedExtremes(): Unit \ Assert = region rc {
        checkSigned(rc, 2147483647, 251 :: 255 :: 255 :: 255 :: 253 :: 192 :: Nil);
        checkSigned(rc, -2147483648, 255 :: 255 :: 255 :: 255 :: 253 :: 192 :: Nil);
        checkSigned(rc, 1073741823, 251 :: 255 :: 255 :: 255 :: 252 :: 192 :: Nil);
        checkSigned(rc, -1073741824, 255 :: 255 :: 255 :: 255 :: 252 :: 192 :: Nil);
        checkSigned(rc, 12345, 202 :: 227 :: 4 :: Nil);
        checkSigned(rc, -12345, 198 :: 227 :: 4 :: Nil)
    }

    ///
    /// `writeSignedAll` + `readSignedArray` over the same values in one stream.
    /// This is the shape `ClockEncoder` uses.
    ///
    @Test
    pub def testSignedStream(): Unit \ Assert = region rc {
        let vals = Array#{0, -1, 1, -2, 2, 15, -15, 16, -16, 2147483647, -2147483648,
                          1073741823, -1073741824, 12345, -12345} @ rc;
        let w = BitWriter.mk(rc);
        BitOps.writeSignedAll(vals, w);
        let out = BitWriter.toArray(w);
        Assert.assertEq(expected = 34, Array.length(out));
        Assert.assertEq(
            expected =
                0 :: 16 :: 131 :: 17 :: 231 :: 96 :: 23 :: 254 :: 255 :: 255 :: 255 :: 255 ::
                127 :: 255 :: 255 :: 255 :: 255 :: 223 :: 239 :: 255 :: 255 :: 255 :: 243 ::
                255 :: 255 :: 255 :: 255 :: 252 :: 242 :: 184 :: 193 :: 198 :: 227 :: 4 :: Nil,
            List.map(Bits.byteToUnsigned, Array.toList(out)));
        let rd = BitReader.mk(rc, out);
        let back = BitOps.readSignedArray(rc, Array.length(vals), rd);
        Assert.assertEq(expected = Array.toList(vals), Array.toList(back))
    }

    // ------------------------------------------------------------------
    // BitWriter.toArray: pending-byte counts 0 .. 4
    // ------------------------------------------------------------------

    ///
    /// `numPendingBytes = (39 - numRemainingBits) >> 3`. With nothing written,
    /// `numRemainingBits == 32`, so no bytes at all come out.
    ///
    @Test
    pub def testToArrayZeroPendingBytes(): Unit \ Assert = region rc {
        Assert.assertEq(expected = Nil, writePairs(rc, Nil))
    }

    ///
    /// 1 .. 8 bits pending -> one trailing byte, the payload left-aligned in it.
    ///
    @Test
    pub def testToArrayOnePendingByte(): Unit \ Assert = region rc {
        Assert.assertEq(expected = 168 :: Nil, writePairs(rc, (0x15, 5) :: Nil));
        Assert.assertEq(expected = 195 :: Nil, writePairs(rc, (0xc3, 8) :: Nil))
    }

    ///
    /// 9 .. 16 bits pending -> two trailing bytes.
    ///
    @Test
    pub def testToArrayTwoPendingBytes(): Unit \ Assert = region rc {
        Assert.assertEq(expected = 210 :: 128 :: Nil, writePairs(rc, (0x1a5, 9) :: Nil));
        Assert.assertEq(expected = 190 :: 239 :: Nil, writePairs(rc, (0xbeef, 16) :: Nil))
    }

    ///
    /// 17 .. 24 bits pending -> three trailing bytes.
    ///
    @Test
    pub def testToArrayThreePendingBytes(): Unit \ Assert = region rc {
        Assert.assertEq(expected = 232 :: 250 :: 128 :: Nil, writePairs(rc, (0x1d1f5, 17) :: Nil));
        Assert.assertEq(expected = 222 :: 173 :: 190 :: Nil, writePairs(rc, (0xdeadbe, 24) :: Nil))
    }

    ///
    /// 25 .. 32 bits pending -> four trailing bytes. At exactly 32 the code takes the
    /// `putInt` branch instead of the byte-at-a-time loop; both must agree, so the
    /// 31-bit and 32-bit cases sit side by side here. (32 is reached with two 16-bit
    /// writes: a single `writeBits(_, 32)` indexes `BitMasks(32)` and throws in Scala.)
    ///
    @Test
    pub def testToArrayFourPendingBytes(): Unit \ Assert = region rc {
        Assert.assertEq(expected = 229 :: 127 :: 93 :: 0 :: Nil,
            writePairs(rc, (0x1cafeba, 25) :: Nil));
        Assert.assertEq(expected = 247 :: 155 :: 222 :: 36 :: Nil,
            writePairs(rc, (0x7bcdef12, 31) :: Nil));
        // putInt branch
        Assert.assertEq(expected = 18 :: 52 :: 86 :: 120 :: Nil,
            writePairs(rc, (0x1234, 16) :: (0x5678, 16) :: Nil))
    }

    ///
    /// Past 32 bits the writer flushes a full word into its `IntArrayList` and the
    /// pending count restarts. These cover: a flush with a 1-bit remainder, a flush
    /// with a whole byte remaining, two whole words with nothing pending, and a
    /// write that is itself split across the flush (20 + 20 bits).
    ///
    @Test
    pub def testToArrayAcrossWordFlush(): Unit \ Assert = region rc {
        Assert.assertEq(expected = 18 :: 52 :: 86 :: 120 :: 128 :: Nil,
            writePairs(rc, (0x1234, 16) :: (0x5678, 16) :: (1, 1) :: Nil));
        Assert.assertEq(expected = 18 :: 52 :: 86 :: 120 :: 165 :: Nil,
            writePairs(rc, (0x1234, 16) :: (0x5678, 16) :: (0xa5, 8) :: Nil));
        Assert.assertEq(expected = 18 :: 52 :: 86 :: 120 :: 11 :: 173 :: 240 :: 13 :: Nil,
            writePairs(rc, (0x1234, 16) :: (0x5678, 16) :: (0x0bad, 16) :: (0xf00d, 16) :: Nil));
        // The second write straddles the flush: 12 bits land in the outgoing word,
        // 8 in the new pending word.
        Assert.assertEq(expected = 171 :: 205 :: 239 :: 18 :: 52 :: Nil,
            writePairs(rc, (0xabcde, 20) :: (0xf1234, 20) :: Nil))
    }

    // ------------------------------------------------------------------
    // BitReader: ragged tails
    // ------------------------------------------------------------------

    ///
    /// `readNext` has two paths: a whole big-endian `getInt` when four or more bytes
    /// remain, and a left-aligned partial fill otherwise. Every tail length the
    /// partial path can see (1, 2, 3 bytes) is covered here, both as the whole input
    /// and as the tail after one full word.
    ///
    @Test
    pub def testReaderRaggedTails(): Unit \ Assert = region rc {
        // 1 byte
        Assert.assertEq(expected = 42 :: Nil,
            readWidths(6 :: Nil, BitReader.mk(rc, bytesOf(rc, 168 :: Nil))));
        Assert.assertEq(expected = 1 :: 0 :: 1 :: 0 :: 1 :: 0 :: 0 :: 0 :: Nil,
            readWidths(1 :: 1 :: 1 :: 1 :: 1 :: 1 :: 1 :: 1 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 168 :: Nil))));
        // 2 bytes
        Assert.assertEq(expected = 55 :: 42 :: 13 :: Nil,
            readWidths(6 :: 6 :: 4 :: Nil, BitReader.mk(rc, bytesOf(rc, 222 :: 173 :: Nil))));
        // 3 bytes
        Assert.assertEq(expected = 55 :: 42 :: 54 :: 62 :: Nil,
            readWidths(6 :: 6 :: 6 :: 6 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 222 :: 173 :: 190 :: Nil))));
        Assert.assertEq(expected = 6 :: 30 :: 2779 :: 14 :: Nil,
            readWidths(3 :: 5 :: 12 :: 4 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 222 :: 173 :: 190 :: Nil))))
    }

    ///
    /// Lengths 5, 6 and 7: one full `getInt` word followed by a 1-, 2- or 3-byte
    /// tail. The last two cases also make a single `readBits` straddle the boundary,
    /// which is the recursive path in `readBits` — the high bits come from the word,
    /// the low bits from the freshly refilled tail.
    ///
    @Test
    pub def testReaderWordThenRaggedTail(): Unit \ Assert = region rc {
        // 5 bytes = one word + a 1-byte tail; 6*6 + 4 = 40 bits, read exactly dry.
        Assert.assertEq(expected = 0 :: 18 :: 13 :: 5 :: 25 :: 56 :: 9 :: Nil,
            readWidths(6 :: 6 :: 6 :: 6 :: 6 :: 6 :: 4 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 1 :: 35 :: 69 :: 103 :: 137 :: Nil))));
        // 6 bytes = one word + a 2-byte tail; the 24-bit read straddles.
        Assert.assertEq(expected = 2330 :: 5 :: 6785451 :: Nil,
            readWidths(19 :: 5 :: 24 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 1 :: 35 :: 69 :: 103 :: 137 :: 171 :: Nil))));
        // 7 bytes = one word + a 3-byte tail; the 25-bit read straddles.
        Assert.assertEq(expected = 9544371 :: 25799629 :: Nil,
            readWidths(31 :: 25 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 1 :: 35 :: 69 :: 103 :: 137 :: 171 :: 205 :: Nil))));
        // All bits set: the masking in `readBits` is the only thing keeping these
        // from bleeding into each other.
        Assert.assertEq(expected = 1048575 :: 1048575 :: 65535 :: Nil,
            readWidths(20 :: 20 :: 16 :: Nil,
                BitReader.mk(rc, bytesOf(rc, 255 :: 255 :: 255 :: 255 :: 255 :: 255 :: 255 :: Nil))))
    }

    ///
    /// A writer's output fed straight back into a reader, at a length that is not a
    /// multiple of four. These four values occupy 6 + 6 + 14 + 42 = 68 bits, i.e. two
    /// full words and a 1-byte tail, so the reader takes the `getInt` path twice and
    /// then the shortest ragged path.
    ///
    @Test
    pub def testWriterReaderRaggedRoundTrip(): Unit \ Assert = region rc {
        let w = BitWriter.mk(rc);
        BitOps.writeUnsigned(31, w);
        BitOps.writeUnsigned(0, w);
        BitOps.writeUnsigned(2047, w);
        BitOps.writeUnsigned(536870912, w);
        let out = BitWriter.toArray(w);
        Assert.assertEq(expected = 9, Array.length(out));
        Assert.assertEq(
            expected = 124 :: 15 :: 253 :: 224 :: 136 :: 136 :: 136 :: 136 :: 16 :: Nil,
            List.map(Bits.byteToUnsigned, Array.toList(out)));
        let rd = BitReader.mk(rc, out);
        Assert.assertEq(expected = 31, BitOps.readUnsigned(rd));
        Assert.assertEq(expected = 0, BitOps.readUnsigned(rd));
        Assert.assertEq(expected = 2047, BitOps.readUnsigned(rd));
        Assert.assertEq(expected = 536870912, BitOps.readUnsigned(rd))
    }

    ///
    /// `bitMask(i) == (1 << i) - 1` for the whole range the Scala `BitMasks` table
    /// covered, checked against the table's own definition rather than spot values.
    ///
    @Test
    pub def testBitMaskMatchesTable(): Unit \ Assert = region rc {
        let table = Array.init(rc, i -> Bits.shl(1, i) - 1, 32);
        def loop(i) = {
            if (i < 32) {
                Assert.assertEq(expected = Array.get(i, table), BitOps.bitMask(i));
                loop(i + 1)
            } else ()
        };
        loop(0);
        Assert.assertEq(expected = 0, BitOps.bitMask(0));
        Assert.assertEq(expected = 63, BitOps.bitMask(6));
        Assert.assertEq(expected = 2147483647, BitOps.bitMask(31))
    }
}
