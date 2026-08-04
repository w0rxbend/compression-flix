///
/// Port of `org.lichess.compression.BitOps` (Scala) to Flix.
///
/// Every operation here must be byte-for-byte faithful to the original: this is
/// the bit-level substrate that every encoder in the library writes through.
/// All arithmetic follows Java `int` semantics (32-bit wrapping, `>>` arithmetic,
/// `>>>` logical), which is what the `Bits` module provides.
///
/// Structural differences forced by Flix, none of them observable in the output:
///
///   - Scala's `Reader`/`Writer` classes become the structs `BitReader`/`BitWriter`,
///     each in a module of its own name (a Flix struct's fields only resolve inside
///     a module with the struct's name).
///   - `java.nio.ByteBuffer` is not used. `BitReader` keeps an explicit read
///     position into an `Array[Int8, r]` and assembles big-endian ints by hand;
///     `BitWriter.toArray` fills an `Array[Int8, r]` directly.
///   - `BitMasks` is a `def` rather than a 32-entry table. `bitMask(i)` computes
///     `(1 << i) - 1`, which agrees with the table for every index the table had
///     (0..31), the only indices any caller can produce.
///   - Scala's overloads are distinct names: `writeSigned`/`writeSignedAll` and
///     `readSigned`/`readSignedArray`.
///   - `while` loops become local tail-recursive `def`s.
///
mod BitOps {

    ///
    /// `BitMasks(i)` from the Scala original: the low `i` bits set, i.e. `(1 << i) - 1`.
    ///
    /// The original is `Array.tabulate(32)(i => (1 << i) - 1)`; this is the same
    /// function without the allocation. Only `0 <= i <= 31` is ever requested:
    /// `writeBits`/`readBits` are called with at most 31 bits, and the
    /// `BitMasks(numRemainingBits)` use site is guarded by `numRemainingBits < numReqBits`.
    ///
    /// The 31-bit ceiling is not an assumption, it is a property of the call sites.
    /// Widths passed to `writeBits`/`readBits` across the whole library are: 6 and 4
    /// (`BitOps.writeUnsigned`/`readUnsigned`), 3 (`clock/LowBitTruncator`), 1 and
    /// `Huffman.CODES(i).bits` (`game/Huffman`). The widest Huffman code in
    /// `game/Huffman.scala` is 31 bits. So `i == 32` is unreachable.
    ///
    /// If it ever became reachable the behaviour would diverge: `BitMasks(32)` throws
    /// `ArrayIndexOutOfBoundsException`, whereas this returns `0` (the JVM masks the
    /// shift distance to 5 bits, so `1 << 32 == 1`). That is a lost assertion, not a
    /// silent difference in any encoded byte.
    ///
    pub def bitMask(i: Int32): Int32 = Bits.shl(1, i) - 1

    ///
    /// `writeSigned(values: Array[Int], writer)`: writes every element in order.
    ///
    pub def writeSignedAll(values: Array[Int32, r1], w: BitWriter[r2]): Unit \ (r1 + r2) =
        let len = Array.length(values);
        def loop(i) = {
            if (i < len) {
                writeSigned(Array.get(i, values), w);
                loop(i + 1)
            } else ()
        };
        loop(0)

    ///
    /// `writeSigned(n: Int, writer)`: zigzag encode, then write as unsigned.
    ///
    /// Small negative and positive numbers both become small positive numbers.
    ///
    pub def writeSigned(n: Int32, w: BitWriter[r]): Unit \ r =
        writeUnsigned(Bits.bxor(Bits.shl(n, 1), Bits.shr(n, 31)), w)

    ///
    /// `writeUnsigned(n: Int, writer)`: 6-bit head, then 4-bit continuation groups.
    ///
    pub def writeUnsigned(n: Int32, w: BitWriter[r]): Unit \ r =
        if (Bits.band(n, Bits.bnot(0x1f)) == 0)
            BitWriter.writeBits(n, 6, w)
        else {
            BitWriter.writeBits(Bits.bor(n, 0x20), 6, w);
            def loop(remaining) = {
                if (Bits.band(remaining, Bits.bnot(0x07)) != 0) {
                    BitWriter.writeBits(Bits.bor(remaining, 0x08), 4, w);
                    loop(Bits.ushr(remaining, 3))
                } else
                    // Loop terminated, so the 4th bit is 0.
                    BitWriter.writeBits(remaining, 4, w)
            };
            loop(Bits.ushr(n, 5))
        }

    ///
    /// `readUnsigned(reader)`: inverse of `writeUnsigned`.
    ///
    pub def readUnsigned(rd: BitReader[r]): Int32 \ r =
        let n = BitReader.readBits(6, rd);
        if (n > 0x1f) {
            // Scala's `while { curVal = readBits(4); curVal > 0x07 } do { ... }`,
            // a do-while whose condition performs the read.
            def loop(acc, curShift) = {
                let curVal = BitReader.readBits(4, rd);
                if (curVal > 0x07)
                    loop(Bits.bor(acc, Bits.shl(Bits.band(curVal, 0x07), curShift)), curShift + 3)
                else
                    Bits.bor(acc, Bits.shl(curVal, curShift))
            };
            loop(Bits.band(n, 0x1f), 5)
        } else
            n

    ///
    /// `readSigned(reader)`: read an unsigned value and zigzag decode it.
    ///
    pub def readSigned(rd: BitReader[r]): Int32 \ r =
        let n = readUnsigned(rd);
        Bits.bxor(Bits.ushr(n, 1), 0 - Bits.band(n, 1))

    ///
    /// `readSigned(reader, numMoves)`: read `numMoves` signed values, in order.
    ///
    /// The original uses `Array.tabulate`, which relies on left-to-right index
    /// order; an explicit ascending loop makes that guarantee local.
    ///
    pub def readSignedArray(rc: Region[r1], numMoves: Int32, rd: BitReader[r2]): Array[Int32, r1] \ (r1 + r2) =
        let out = Array.repeat(rc, numMoves, 0);
        def loop(i) = {
            if (i < numMoves) {
                Array.put(readSigned(rd), i, out);
                loop(i + 1)
            } else ()
        };
        loop(0);
        out
}

///
/// `BitOps.Reader`: a big-endian bit reader over a byte array.
///
mod BitReader {

    import java.nio.BufferUnderflowException

    ///
    /// `bytes`/`pos` replace the Scala `ByteBuffer`; `pos` is the buffer position
    /// and `Array.length(bytes) - pos` is `bb.remaining`.
    ///
    pub struct BitReader[r: Region] {
        bytes: Array[Int8, r],
        mut pos: Int32,
        mut numRemainingBits: Int32,
        mut pendingBits: Int32
    }

    ///
    /// `new Reader(bytes)`. The array is wrapped, not copied, exactly like `ByteBuffer.wrap`.
    ///
    pub def mk(rc: Region[r], bytes: Array[Int8, r]): BitReader[r] \ r =
        new BitReader @ rc { bytes = bytes, pos = 0, numRemainingBits = 0, pendingBits = 0 }

    ///
    /// `bb.remaining`.
    ///
    def remaining(rd: BitReader[r]): Int32 \ r =
        Array.length(rd->bytes) - rd->pos

    ///
    /// `bb.get() & 0xff`: consume one byte, widened *without* sign extension.
    ///
    /// The explicit bound reproduces `ByteBuffer.get`'s `BufferUnderflowException`
    /// on a truncated stream. Without it the bare `Array.get` raises
    /// `ArrayIndexOutOfBoundsException` instead, which is the same abort on the
    /// same inputs but a different type for a caller that discriminates. The
    /// guard fires only where the array access would already have thrown, so it
    /// cannot change an emitted byte. `Array.length` is `%%ARRAY_LENGTH%%`, i.e.
    /// pure and one `arraylength` instruction, so the declared `\ r` is unchanged
    /// and the cost is a length load plus a compare per input byte.
    ///
    def getUnsigned(rd: BitReader[r]): Int32 \ r =
        if (rd->pos >= Array.length(rd->bytes))
            unsafe IO { throw new BufferUnderflowException() }
        else {
            let b = Array.get(rd->pos, rd->bytes);
            rd->pos = rd->pos + 1;
            Bits.byteToUnsigned(b)
        }

    ///
    /// Refill `pendingBits`.
    ///
    /// The full case is `bb.getInt()`, big-endian. The ragged-tail case reads the
    /// fewer-than-four remaining bytes left-aligned within `numRemainingBits` bits.
    ///
    def readNext(rd: BitReader[r]): Unit \ r =
        if (remaining(rd) >= 4) {
            // bb.getInt(): big-endian, and each byte must be zero-extended before
            // being shifted into place.
            let b0 = getUnsigned(rd);
            let b1 = getUnsigned(rd);
            let b2 = getUnsigned(rd);
            let b3 = getUnsigned(rd);
            rd->pendingBits =
                Bits.bor(
                    Bits.bor(Bits.shl(b0, 24), Bits.shl(b1, 16)),
                    Bits.bor(Bits.shl(b2, 8), b3));
            rd->numRemainingBits = 32
        } else {
            let numRemainingBits = remaining(rd) * 8;
            rd->numRemainingBits = numRemainingBits;
            rd->pendingBits = Bits.shl(getUnsigned(rd), numRemainingBits - 8);
            def loop(s) = {
                if (s >= 0) {
                    rd->pendingBits = Bits.bor(rd->pendingBits, Bits.shl(getUnsigned(rd), s));
                    loop(s - 8)
                } else ()
            };
            loop(numRemainingBits - 16)
        }

    ///
    /// Read `numReqBits` bits, most significant first.
    ///
    /// When the request straddles the end of `pendingBits` the call recurses, as in
    /// the original: the low part of the result comes from a fresh word.
    ///
    pub def readBits(numReqBits: Int32, rd: BitReader[r]): Int32 \ r =
        if (rd->numRemainingBits >= numReqBits) {
            rd->numRemainingBits = rd->numRemainingBits - numReqBits;
            Bits.band(Bits.ushr(rd->pendingBits, rd->numRemainingBits), BitOps.bitMask(numReqBits))
        } else {
            let res = Bits.band(rd->pendingBits, BitOps.bitMask(rd->numRemainingBits));
            let neededBits = numReqBits - rd->numRemainingBits;
            readNext(rd);
            Bits.bor(Bits.shl(res, neededBits), readBits(neededBits, rd))
        }
}

///
/// `BitOps.Writer`: accumulates bits into 32-bit words and emits big-endian bytes.
///
mod BitWriter {

    pub struct BitWriter[r: Region] {
        rc: Region[r],
        buffer: IntArrayList[r],
        mut numRemainingBits: Int32,
        mut pendingBits: Int32
    }

    ///
    /// `new Writer()`.
    ///
    pub def mk(rc: Region[r]): BitWriter[r] \ r =
        new BitWriter @ rc {
            rc = rc,
            buffer = IntArrayList.mk(rc),
            numRemainingBits = 32,
            pendingBits = 0
        }

    ///
    /// Append the low `numBits` bits of `data`.
    ///
    pub def writeBits(data: Int32, numBits: Int32, w: BitWriter[r]): Unit \ r =
        let maskedData = Bits.band(data, BitOps.bitMask(numBits));
        w->numRemainingBits = w->numRemainingBits - numBits;
        if (w->numRemainingBits >= 0)
            w->pendingBits = Bits.bor(w->pendingBits, Bits.shl(maskedData, w->numRemainingBits))
        else {
            // Scala writes `maskedData >>> -numRemainingBits`. In this branch
            // `numRemainingBits` is already negative, so `0 - numRemainingBits` is the
            // *positive* count of bits that did not fit in the current word — the
            // shift distance is in `1 .. 31` on every reachable path and no
            // shift-distance masking is involved. (Should a caller ever pass
            // `numBits == 32` with `numRemainingBits == 0`, the distance would be 32
            // and `Bits.ushr` would still agree with Java: `Int32.logicalRightShift`
            // documents that "only the rightmost 5 bits of `dist` are considered".)
            IntArrayList.add(Bits.bor(w->pendingBits, Bits.ushr(maskedData, 0 - w->numRemainingBits)), w->buffer);
            w->numRemainingBits = w->numRemainingBits + 32;
            w->pendingBits = Bits.shl(maskedData, w->numRemainingBits)
        }

    ///
    /// Store `v` big-endian at `off`, i.e. `ByteBuffer.putInt`.
    ///
    def putInt(v: Int32, off: Int32, out: Array[Int8, r]): Unit \ r =
        Array.put(Bits.toByte(Bits.ushr(v, 24)), off, out);
        Array.put(Bits.toByte(Bits.ushr(v, 16)), off + 1, out);
        Array.put(Bits.toByte(Bits.ushr(v, 8)), off + 2, out);
        Array.put(Bits.toByte(v), off + 3, out)

    ///
    /// The encoded bytes: every buffered word, then the partial trailing word.
    ///
    /// `numPendingBytes = (39 - numRemainingBits) >> 3` is `ceil((32 - numRemainingBits) / 8)`
    /// for `numRemainingBits` in `0..32`, so it lands in `0..4`.
    ///
    pub def toArray(w: BitWriter[r]): Array[Int8, r] \ r =
        let numPendingBytes = Bits.shr(39 - w->numRemainingBits, 3);
        let numWords = IntArrayList.size(w->buffer);
        let out = Array.repeat(w->rc, 4 * numWords + numPendingBytes, 0i8);
        // buffer.writeTo(bb)
        def writeWords(i) = {
            if (i < numWords) {
                putInt(IntArrayList.get(i, w->buffer), 4 * i, out);
                writeWords(i + 1)
            } else ()
        };
        writeWords(0);
        let base = 4 * numWords;
        if (numPendingBytes == 4)
            putInt(w->pendingBits, base, out)
        else {
            def writeTail(i) = {
                if (i < numPendingBytes) {
                    Array.put(Bits.toByte(Bits.ushr(w->pendingBits, 24 - i * 8)), base + i, out);
                    writeTail(i + 1)
                } else ()
            };
            writeTail(0)
        }
        ;
        out
}

///
/// The Scala original's `private final class IntArrayList`: a growable `int[]`
/// using the OpenJDK `ArrayList` growth strategy.
///
/// Kept rather than replaced by `MutList` so that the capacity schedule — and
/// therefore every allocation the encoder performs — matches the original.
///
mod IntArrayList {

    pub struct IntArrayList[r: Region] {
        rc: Region[r],
        mut data: Array[Int32, r],
        mut index: Int32
    }

    pub def mk(rc: Region[r]): IntArrayList[r] \ r =
        new IntArrayList @ rc { rc = rc, data = Array.repeat(rc, 10, 0), index = 0 }

    ///
    /// `Arrays.copyOf(src, newLength)` for `newLength >= Array.length(src)`.
    ///
    def copyOf(src: Array[Int32, r], newLength: Int32, rc: Region[r]): Array[Int32, r] \ r =
        let dst = Array.repeat(rc, newLength, 0);
        let len = Array.length(src);
        def loop(i) = {
            if (i < len) {
                Array.put(Array.get(i, src), i, dst);
                loop(i + 1)
            } else ()
        };
        loop(0);
        dst

    pub def add(elt: Int32, l: IntArrayList[r]): Unit \ r =
        // This is the growth strategy used by OpenJDK ArrayList.
        if (l->index == Array.length(l->data))
            l->data = copyOf(l->data, l->index + Bits.shr(l->index, 1) + 5, l->rc)
        else ()
        ;
        Array.put(elt, l->index, l->data);
        l->index = l->index + 1

    pub def size(l: IntArrayList[r]): Int32 \ r = l->index

    pub def get(i: Int32, l: IntArrayList[r]): Int32 \ r = Array.get(i, l->data)

    ///
    /// `Arrays.copyOf(data, index)`.
    ///
    pub def toArray(l: IntArrayList[r]): Array[Int32, r] \ r =
        let out = Array.repeat(l->rc, l->index, 0);
        def loop(i) = {
            if (i < l->index) {
                Array.put(Array.get(i, l->data), i, out);
                loop(i + 1)
            } else ()
        };
        loop(0);
        out
}

mod TestBitOpsSelf {

    ///
    /// `bitMask` agrees with the Scala `Array.tabulate(32)(i => (1 << i) - 1)` table.
    ///
    @Test
    pub def testBitMask(): Unit \ Assert =
        Assert.assertEq(expected = 0, BitOps.bitMask(0));
        Assert.assertEq(expected = 1, BitOps.bitMask(1));
        Assert.assertEq(expected = 63, BitOps.bitMask(6));
        Assert.assertEq(expected = 0x7fffffff, BitOps.bitMask(31))

    ///
    /// Six bits in, six bits out; one word, three trailing bytes.
    ///
    @Test
    pub def testWriteReadUnsignedSmall(): Unit \ Assert = region rc {
        let w = BitWriter.mk(rc);
        BitOps.writeUnsigned(0, w);
        BitOps.writeUnsigned(31, w);
        BitOps.writeUnsigned(32, w);
        BitOps.writeUnsigned(1000000, w);
        let bytes = BitWriter.toArray(w);
        let rd = BitReader.mk(rc, bytes);
        Assert.assertEq(expected = 0, BitOps.readUnsigned(rd));
        Assert.assertEq(expected = 31, BitOps.readUnsigned(rd));
        Assert.assertEq(expected = 32, BitOps.readUnsigned(rd));
        Assert.assertEq(expected = 1000000, BitOps.readUnsigned(rd))
    }

    ///
    /// Zigzag round-trip, including values that straddle word boundaries.
    ///
    @Test
    pub def testWriteReadSigned(): Unit \ Assert = region rc {
        let values = Array#{0, -1, 1, -2, 2, 63, -64, 12345, -12345, 2147483647, -2147483648} @ rc;
        let w = BitWriter.mk(rc);
        BitOps.writeSignedAll(values, w);
        let bytes = BitWriter.toArray(w);
        let rd = BitReader.mk(rc, bytes);
        let back = BitOps.readSignedArray(rc, Array.length(values), rd);
        Assert.assertEq(expected = Array.toList(values), Array.toList(back))
    }

    ///
    /// A single 6-bit write leaves 26 remaining bits, so `(39 - 26) >> 3 == 1` byte,
    /// holding the value left-aligned in the top 6 bits.
    ///
    @Test
    pub def testToArrayRaggedTail(): Unit \ Assert = region rc {
        let w = BitWriter.mk(rc);
        BitWriter.writeBits(0x2a, 6, w);
        let bytes = BitWriter.toArray(w);
        Assert.assertEq(expected = 1, Array.length(bytes));
        // 0b101010 << 2 == 0b10101000 == 0xa8 == -88 as a signed byte.
        Assert.assertEq(expected = -88i8, Array.get(0, bytes))
    }

    ///
    /// Exactly 32 bits written: one full word, no trailing bytes.
    ///
    @Test
    pub def testToArrayWholeWord(): Unit \ Assert = region rc {
        let w = BitWriter.mk(rc);
        BitWriter.writeBits(0x12345, 20, w);
        BitWriter.writeBits(0xabc, 12, w);
        let bytes = BitWriter.toArray(w);
        Assert.assertEq(expected = 4, Array.length(bytes));
        Assert.assertEq(expected = 0x12i8, Array.get(0, bytes));
        Assert.assertEq(expected = 0x34i8, Array.get(1, bytes));
        Assert.assertEq(expected = 0x5ai8, Array.get(2, bytes));
        Assert.assertEq(expected = -68i8, Array.get(3, bytes));
        let rd = BitReader.mk(rc, bytes);
        Assert.assertEq(expected = 0x12345, BitReader.readBits(20, rd));
        Assert.assertEq(expected = 0xabc, BitReader.readBits(12, rd))
    }

    ///
    /// A read that straddles the word boundary takes the recursive path in `readBits`,
    /// and the second word here is a ragged three-byte tail.
    ///
    @Test
    pub def testReadBitsStraddlesWord(): Unit \ Assert = region rc {
        let w = BitWriter.mk(rc);
        BitWriter.writeBits(0x7ffff, 19, w);
        BitWriter.writeBits(0x15, 5, w);
        BitWriter.writeBits(0x2aaaaaa, 26, w);
        BitWriter.writeBits(0x3, 6, w);
        let bytes = BitWriter.toArray(w);
        Assert.assertEq(expected = 7, Array.length(bytes));
        let rd = BitReader.mk(rc, bytes);
        Assert.assertEq(expected = 0x7ffff, BitReader.readBits(19, rd));
        Assert.assertEq(expected = 0x15, BitReader.readBits(5, rd));
        Assert.assertEq(expected = 0x2aaaaaa, BitReader.readBits(26, rd));
        Assert.assertEq(expected = 0x3, BitReader.readBits(6, rd))
    }

    ///
    /// The `IntArrayList` growth schedule is OpenJDK's: 10, 20, 35, 57, ...
    ///
    @Test
    pub def testIntArrayListGrowth(): Unit \ Assert = region rc {
        let l = IntArrayList.mk(rc);
        def loop(i) = {
            if (i < 100) {
                IntArrayList.add(i * 7, l);
                loop(i + 1)
            } else ()
        };
        loop(0);
        Assert.assertEq(expected = 100, IntArrayList.size(l));
        Assert.assertEq(expected = 0, IntArrayList.get(0, l));
        Assert.assertEq(expected = 693, IntArrayList.get(99, l));
        Assert.assertEq(expected = 100, Array.length(IntArrayList.toArray(l)))
    }
}
