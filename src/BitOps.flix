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
    @Inline
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
        // Trailing `()`: see the note in `mod Board`. A tail call to another def
        // (here the lifted `loop`) is compiled to a heap continuation.
        loop(0);
        ()

    ///
    /// `writeSigned(n: Int, writer)`: zigzag encode, then write as unsigned.
    ///
    /// Small negative and positive numbers both become small positive numbers.
    ///
    pub def writeSigned(n: Int32, w: BitWriter[r]): Unit \ r = {
        writeUnsigned(Bits.bxor(Bits.shl(n, 1), Bits.shr(n, 31)), w);
        ()
    }

    ///
    /// `writeUnsigned(n: Int, writer)`: 6-bit head, then 4-bit continuation groups.
    ///
    /// Transcribed with two `writeBits` sites per `if`, exactly as the original has
    /// them. Collapsing each pair into one site with the two-armed choice moved inside
    /// the first argument — byte-identical, and it halves the number of copies an
    /// `@Inline`d `writeBits` would paste — was built and measured in round 5 as part
    /// of the `@Inline` experiment recorded above `BitWriter.writeBits`, and that
    /// experiment lost. Do not reintroduce it without reintroducing the annotation it
    /// existed to serve, and measuring both.
    pub def writeUnsigned(n: Int32, w: BitWriter[r]): Unit \ r = {
        if (Bits.band(n, Bits.bnot(0x1f)) == 0)
            BitWriter.writeBits(n, 6, w)
        else {
            BitWriter.writeBits(Bits.bor(n, 0x20), 6, w);
            def loop(remaining) = {
                if (Bits.band(remaining, Bits.bnot(0x07)) != 0) {
                    BitWriter.writeBits(Bits.bor(remaining, 0x08), 4, w);
                    loop(Bits.ushr(remaining, 3))
                } else {
                    // Loop terminated, so the 4th bit is 0.
                    BitWriter.writeBits(remaining, 4, w);
                    ()   // keeps the call out of tail position; see `mod Board`
                }
            };
            loop(Bits.ushr(n, 5))
        };
        ()
    }

    ///
    /// `readUnsigned(reader)`: inverse of `writeUnsigned`.
    ///
    @Inline
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
    /// `Array.empty`, not `Array.repeat(rc, numMoves, 0)`: the loop below writes every
    /// slot before anything reads one, and `Reflect.default()` for `Int32` is the same
    /// `0` `repeat` was filling with. This is the site where the substitution PAID —
    /// clock decode allocation on the 30-reading band went 240 -> 208 B/op against
    /// Scala's 216, flipping the last losing clock-decode row (1.111x -> 0.963x).
    /// `Array.repeat` is a real trampolined call whose callee is `newarray` +
    /// `Arrays.fill` + a 48-byte `Value$`; `Array.empty` inlines to seven bytecodes.
    ///
    /// It is NOT a universal win — see `GameEncoder.decode`, where the same
    /// substitution on `output` and `sanBuf` measured worse and was reverted. Convert
    /// one site at a time and measure it.
    pub def readSignedArray(rc: Region[r1], numMoves: Int32, rd: BitReader[r2]): Array[Int32, r1] \ (r1 + r2) =
        let out = Array.empty(rc, numMoves);
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
    @Inline
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
            // being shifted into place. Read inline rather than through four
            // `getUnsigned` calls: all four indices are in bounds by the guard above,
            // so `getUnsigned`'s `BufferUnderflowException` check is provably dead in
            // this arm, and each call was costing ~75 bytecodes of trampoline and
            // error-construction boilerplate. `rd->pos` advances in one step instead
            // of four, which nothing observes.
            let bytes = rd->bytes;
            let p = rd->pos;
            let b0 = Bits.byteToUnsigned(Array.get(p, bytes));
            let b1 = Bits.byteToUnsigned(Array.get(p + 1, bytes));
            let b2 = Bits.byteToUnsigned(Array.get(p + 2, bytes));
            let b3 = Bits.byteToUnsigned(Array.get(p + 3, bytes));
            rd->pos = p + 4;
            rd->pendingBits =
                Bits.bor(
                    Bits.bor(Bits.shl(b0, 24), Bits.shl(b1, 16)),
                    Bits.bor(Bits.shl(b2, 8), b3));
            rd->numRemainingBits = 32
        } else {
            readNextRagged(rd);
            ()   // keeps the call out of tail position; see `mod Board`
        }

    ///
    /// The fewer-than-four-remaining-bytes arm of `readNext`, in a def of its own so
    /// that `readNext` itself stays small. It runs at most once per stream, and it
    /// still reads through `getUnsigned`, which is what preserves
    /// `BufferUnderflowException` parity on a truncated input exactly.
    ///
    def readNextRagged(rd: BitReader[r]): Unit \ r =
        let numRemainingBits = remaining(rd) * 8;
        rd->numRemainingBits = numRemainingBits;
        rd->pendingBits = Bits.shl(getUnsigned(rd), numRemainingBits - 8);
        def loop(s) = {
            if (s >= 0) {
                rd->pendingBits = Bits.bor(rd->pendingBits, Bits.shl(getUnsigned(rd), s));
                loop(s - 8)
            } else ()
        };
        loop(numRemainingBits - 16);
        ()   // keeps the lifted `loop` out of tail position; see `mod Board`

    ///
    /// The next nine bits, most significant first, WITHOUT consuming them.
    ///
    /// Past the end of the stream the result is zero-padded rather than throwing:
    /// a peek is not a read, and the subsequent `skipBits` performs exactly the
    /// same bounds check the bit-at-a-time walk would have.
    ///
    @Inline
    pub def peekNine(rd: BitReader[r]): Int32 \ r =
        let nr = rd->numRemainingBits;
        if (nr >= 9)
            Bits.band(Bits.ushr(rd->pendingBits, nr - 9), 0x1ff)
        else {
            let hi = Bits.band(rd->pendingBits, BitOps.bitMask(nr));
            let need = 9 - nr;
            let p = rd->pos;
            let bs = rd->bytes;
            let n = Array.length(bs);
            let b0 = if (p < n) Bits.byteToUnsigned(Array.get(p, bs)) else 0;
            let b1 = if (p + 1 < n) Bits.byteToUnsigned(Array.get(p + 1, bs)) else 0;
            Bits.bor(Bits.shl(hi, need), Bits.ushr(Bits.bor(Bits.shl(b0, 8), b1), 16 - need))
        }

    ///
    /// Consume `n` bits and discard them. Same refill path, same
    /// `BufferUnderflowException` on a truncated stream, as `readBits`.
    ///
    /// # Round 6: the `readBits` split was tried here and REVERTED
    ///
    /// This is the one hot `BitReader` def the round-5 `@Inline` + outlined-tail
    /// transformation had not been applied to, and the mechanism is real —
    /// `Def$decodeLoop`'s bytecode has a trampolined
    /// `BitReader/Def$skipBits.staticApply` at offset 906, once per decoded ply plus
    /// once per `Huffman.read` fast path, and `@Inline` is silently ignored on a
    /// self-recursive def, so a wrapper + outlined `skipBitsSlow` does delete it.
    ///
    /// It was built and measured and it did NOT show: game decode moved
    /// 150.1/355.4/697.7 -> 143.5/359.1/700.9 us, i.e. one band better and two
    /// slightly worse, in a run whose Scala control on the improving band came in at
    /// 261 +- 776 us. That is not a result. The prior was low for a reason worth
    /// keeping: `skipBits` returns `Unit`, so it gets the free `Value$.UNIT` static
    /// and there is no 48-byte box to delete — only the `invokestatic` and its
    /// trampoline. That is the whole `readBits`-won / `writeBits`-lost asymmetry, and
    /// this def is on the `writeBits` side of it.
    ///
    /// Reverted rather than kept-because-harmless: an extra def that cannot be shown
    /// to pay is complexity, and the next person would have to re-derive why it is
    /// there. If it is retried, use `-f 2 -wi 5 -i 5`; `-i 3` cannot resolve 0.5%.
    ///
    pub def skipBits(n: Int32, rd: BitReader[r]): Unit \ r =
        if (rd->numRemainingBits >= n)
            rd->numRemainingBits = rd->numRemainingBits - n
        else {
            let needed = n - rd->numRemainingBits;
            readNext(rd);
            skipBits(needed, rd)
        }

    ///
    /// Read `numReqBits` bits, most significant first.
    ///
    /// When the request straddles the end of `pendingBits` the low part of the result
    /// comes from a fresh word, as in the original.
    ///
    /// ## Why this one IS split, when two earlier splits were reverted
    ///
    /// Splitting the straddle arm out was tried twice before and reverted twice, and
    /// the note that used to sit here forbade re-splitting. Both of those attempts
    /// kept the *call* — they moved the rare arm out so that the shared body would
    /// fit under HotSpot's `FreqInlineSize`, hoping the JIT would then inline it.
    /// Neither the mechanism nor the reasoning survives inspection: the benchmark JVM
    /// runs Graal as its top tier (`UseJVMCICompiler = true`), where `FreqInlineSize`
    /// is a C2 flag that is never consulted, so both were tuned against a threshold
    /// that is not in force.
    ///
    /// This split is a different change in kind: `@Inline` **deletes the call**. Flix's
    /// inliner is unconditional, so the fast arm — two field reads, a subtract, a
    /// store, a shift and an and — is pasted into every call site and no
    /// `BitReader/Def$readBits` class is emitted at all. That removes, per call, one
    /// `invokestatic`, ~50 bytecodes of `Thunk$`/`Suspension$` trampoline, and the
    /// 48-byte `dev.flix.runtime.Value$` that every value-returning Flix def allocates.
    /// None of that depends on a JIT inlining decision going a particular way.
    ///
    /// The straddle arm is out of line *and* rewritten as a self-tail-recursive
    /// accumulator loop, which Flix compiles to `goto`. The original recursed inside
    /// `Bits.bor(Bits.shl(res, needed), readBits(needed, rd))` — not tail position —
    /// so every word straddle paid a real call, a trampoline and a `Value$`. The two
    /// forms compute the same value:
    ///
    ///     original:  R(n)  =  res <<  (n - nr)  |  R(n - nr)
    ///     here:      acc'  =  (acc << nr) | res,  and the final word contributes
    ///                         (acc' << needed) | bits
    ///
    /// Expanding either to depth k gives the same sum of shifted pieces; the port's
    /// differential over the corpus and `difftest` both gate it. `readNext` is called
    /// at exactly the same points, so `BufferUnderflowException` parity on a truncated
    /// stream is unchanged.
    ///
    @Inline
    pub def readBits(numReqBits: Int32, rd: BitReader[r]): Int32 \ r =
        if (rd->numRemainingBits >= numReqBits) {
            rd->numRemainingBits = rd->numRemainingBits - numReqBits;
            // `Bits.shr`, not `ushr`, and it is an identity on this arm rather than a
            // slip. After the update the shift distance is `nr' = nr - numReqBits` and
            // the mask keeps the low `numReqBits` bits, so distance + width = `nr`,
            // which is at most 32. An arithmetic shift differs from a logical one only
            // in bits `32 - nr'` upwards, and the mask reaches only bit
            // `numReqBits - 1 <= 32 - nr' - 1`, so the difference is always masked
            // away. `Bits.ushr` is the branchless five-operation formula (Flix has no
            // `>>>`), so this removes four operations from the hottest arm of the
            // hottest def on both decode paths.
            Bits.band(Bits.shr(rd->pendingBits, rd->numRemainingBits), BitOps.bitMask(numReqBits))
        } else
            readBitsStraddle(numReqBits, rd, 0)

    ///
    /// The straddle arm of `readBits`, as a loop. Precondition, established by the
    /// caller and re-established by the recursive call: `rd->numRemainingBits < numReqBits`.
    ///
    /// `acc` carries the bits already consumed from earlier words, most significant
    /// first; the final word's contribution is appended by the same fast-arm
    /// expression `readBits` uses, and the `Bits.shr` identity argument above holds
    /// here for the same reason (distance + width = `numRemainingBits` <= 32).
    ///
    def readBitsStraddle(numReqBits: Int32, rd: BitReader[r], acc: Int32): Int32 \ r =
        let nr = rd->numRemainingBits;
        let res = Bits.band(rd->pendingBits, BitOps.bitMask(nr));
        let neededBits = numReqBits - nr;
        readNext(rd);
        let acc1 = Bits.bor(Bits.shl(acc, nr), res);
        if (rd->numRemainingBits >= neededBits) {
            rd->numRemainingBits = rd->numRemainingBits - neededBits;
            Bits.bor(
                Bits.shl(acc1, neededBits),
                Bits.band(Bits.shr(rd->pendingBits, rd->numRemainingBits), BitOps.bitMask(neededBits)))
        } else
            readBitsStraddle(neededBits, rd, acc1)
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
    /// Both arms are kept in one body and there is deliberately NO `@Inline` here, and
    /// that is now a five-times-measured decision. `@Inline` is what won the symmetric
    /// change on `BitReader.readBits` in round 5 — 25-32% off all three clock decode
    /// rows, because deleting the call also deletes the 48-byte `dev.flix.runtime.Value$`
    /// that a value-returning Flix def allocates. `writeBits` returns `Unit`, so it gets
    /// the free `Value$.UNIT` static and there is no box to win back; only the
    /// `invokestatic` and its trampoline are on offer, and pasting a 400-bytecode body
    /// into every write site costs more than they are worth. Measured, all on the same
    /// machine in the same sitting, against a 46.34/82.02/141.86 ns baseline:
    ///
    ///   * `@Inline` + flush arm outlined + the two `writeUnsigned` sites unified:
    ///     47.25/86.83/149.22 ns.
    ///   * `@Inline` + both arms in the body + unified sites + `IntArrayList.add`'s
    ///     growth through `java.util.Arrays.copyOf` (so the pasted body is a leaf with
    ///     no trampoline at all): 47.39/85.80/150.16 ns.
    ///
    /// The two agree, which rules out the outlined flush call as the cause and leaves
    /// the annotation itself. Earlier rounds also measured and reverted: dropping
    /// `@Inline` from `IntArrayList.add`, and outlining only its growth branch. The
    /// `Arrays.copyOf` in `add` is all that survives of this line of attack.
    ///
    pub def writeBits(data: Int32, numBits: Int32, w: BitWriter[r]): Unit \ r =
        let maskedData = Bits.band(data, BitOps.bitMask(numBits));
        w->numRemainingBits = w->numRemainingBits - numBits;
        if (w->numRemainingBits >= 0)
            w->pendingBits = Bits.bor(w->pendingBits, Bits.shl(maskedData, w->numRemainingBits))
        else {
            // Scala writes `maskedData >>> -numRemainingBits`. In this branch
            // `numRemainingBits` is already negative, so `0 - numRemainingBits` is the
            // *positive* count of bits that did not fit in the current word — the shift
            // distance is in `1 .. 31` on every reachable path and no shift-distance
            // masking is involved. (Should a caller ever pass `numBits == 32` with
            // `numRemainingBits == 0`, the distance would be 32 and `Bits.ushr` would
            // still agree with Java: `Int32.logicalRightShift` documents that "only the
            // rightmost 5 bits of `dist` are considered".)
            //
            // `Bits.shr` would be an identity here rather than a slip — `maskedData` is
            // `data & bitMask(numBits)` and `bitMask(n)` is `(1 << n) - 1`, which for
            // every `n` a call site can produce lies in `0 .. 2^31-1`, and `>>` and
            // `>>>` agree on a non-negative `int` at every distance — and it is ~12
            // bytecodes cheaper. Round 4 measured that substitution ALONE and it lost
            // (clock encode median 81.2 -> 88.1 ns), which is why the note used to say
            // `ushr` stays. It is back, and for a reason round 4 did not have: those 12
            // bytecodes are part of getting this whole def under Graal's
            // `MaximumInliningSize` of 300 while it is a LEAF. At 407 bytecodes, with 83
            // of them `Thunk$`/`Suspension$` boilerplate, no threshold was in reach and
            // the substitution was pure noise.
            IntArrayList.add(Bits.bor(w->pendingBits, Bits.shr(maskedData, 0 - w->numRemainingBits)), w->buffer);
            w->numRemainingBits = w->numRemainingBits + 32;
            w->pendingBits = Bits.shl(maskedData, w->numRemainingBits)
        }

    ///
    /// Store `v` big-endian at `off`, i.e. `ByteBuffer.putInt`.
    ///
    /// This is four narrowings and four stores where the original does one unaligned
    /// store with a BSWAP, and `Bits.toByte` is not free either — Flix has no primitive
    /// narrowing operation at all, so it forces the value into `Integer`'s small cache
    /// to keep the box free. Rewriting the whole-word part of `toArray` to write through
    /// a real `java.nio.ByteBuffer.wrap(out)` was tried in round 5 and **must not be
    /// retried in that form**: `ByteBuffer.putInt` is not one of the `java.lang` statics
    /// Flix treats as pure, so it needs an `unsafe IO { ... }` block — and that block
    /// makes the expression *pure*, whereupon Flix deletes it as dead code, because its
    /// result is unused. The port compiled, `flix check` was clean, and 42 tests failed
    /// with every whole-word byte zero and only the ragged tail written. There is no
    /// way to keep the write without also consuming its value in something that drives
    /// control flow, which is a silent-wrong-answer shape one refactor away from firing
    /// again. If this is ever worth revisiting it needs a genuinely `\ IO` seam, not an
    /// `unsafe` block.
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
        let out = Array.empty(w->rc, 4 * numWords + numPendingBytes);
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

    import java.util.Arrays

    pub struct IntArrayList[r: Region] {
        rc: Region[r],
        mut data: Array[Int32, r],
        mut index: Int32
    }

    pub def mk(rc: Region[r]): IntArrayList[r] \ r =
        new IntArrayList @ rc { rc = rc, data = Array.empty(rc, 10), index = 0 }

    ///
    /// `@Inline` here is a MEASURED decision and it looks wrong from bytecode size
    /// alone. Flix's inliner is unconditional, so the annotation pastes this whole
    /// body — growth branch, `copyOf` call and its `Thunk$`/`Suspension$`/
    /// `UnhandledEffectError$` boilerplate — into `BitWriter.writeBits`, which takes
    /// `writeBits` to 407 bytecodes, well over HotSpot's `FreqInlineSize` of 325.
    /// Dropping the annotation does exactly what it promises: `writeBits` becomes
    /// 235 bytecodes and therefore inlinable. It was built, gated and measured, and
    /// it LOST — clock encode went 1.319/1.255/1.194x -> 1.255/1.393/1.337x, i.e. a
    /// small win on the 8-reading band and a large loss on the 16- and 30-reading
    /// ones, where the buffer actually grows and the real call to `add` is paid once
    /// per 32 bits written. Reverted. This is the same trap as the `readBits` /
    /// `writeBits` split recorded above `BitReader.readBits`: crossing
    /// `FreqInlineSize` is necessary for HotSpot to inline, not sufficient for it to
    /// pay. Do not remove this annotation without re-measuring the clock rows.
    ///
    @Inline
    pub def add(elt: Int32, l: IntArrayList[r]): Unit \ r =
        // This is the growth strategy used by OpenJDK ArrayList, and the grow itself is
        // `java.util.Arrays.copyOf` — literally the call the Scala original makes.
        //
        // The Flix `copyOf` that used to be here (an `Array.repeat` plus an
        // element-at-a-time loop, so three passes where one intrinsic would do) was
        // replaced for a second reason as well. `add` is `@Inline`d into
        // `BitWriter.writeBits`, which is itself `@Inline`d into every write site, and a
        // call to another Flix def carries ~50-85 bytecodes of `Thunk$`/`Suspension$`/
        // `UnhandledEffectError$` trampoline *at the call site* — 83 of `writeBits`'s
        // 407 bytecodes were that boilerplate. A `java.*` static compiles to a bare
        // `invokestatic`, so this arm carries none of it and the whole of `writeBits`
        // stays a leaf worth pasting. That is also why the two earlier attempts to
        // shrink `writeBits` failed: the first made `add` a real call (measured LOSS,
        // clock encode 1.319/1.255/1.194x -> 1.255/1.393/1.337x) and the second outlined
        // only this branch into another Flix def, which brought the same boilerplate
        // back at the new call site (407 -> 351, no measurable effect).
        //
        // `index` is bound once rather than re-read. Flix emits a `getfield` per
        // mention — the original spelling produced five of them, two of which were
        // back-to-back loads of the same field in the growth test — and this body is
        // `@Inline`d into `BitWriter.writeBits`, where every bytecode counts against
        // Graal's `MaximumInliningSize`. The re-read of `l->data` after the growth is
        // deliberate and load-bearing: it is what makes the store go to the new array.
        let idx = l->index;
        if (idx == Array.length(l->data))
            l->data = unchecked_cast(
                Arrays.copyOf(l->data, idx + Bits.shr(idx, 1) + 5) as Array[Int32, r] \ r)
        else ()
        ;
        Array.put(elt, idx, l->data);
        l->index = idx + 1

    @Inline
    pub def size(l: IntArrayList[r]): Int32 \ r = l->index

    @Inline
    pub def get(i: Int32, l: IntArrayList[r]): Int32 \ r = Array.get(i, l->data)

    ///
    /// `Arrays.copyOf(data, index)`.
    ///
    pub def toArray(l: IntArrayList[r]): Array[Int32, r] \ r =
        let out = Array.empty(l->rc, l->index);
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
