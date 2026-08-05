///
/// A fixed-capacity buffer of generated moves.
///
/// Port of `src/main/scala/game/MoveList.scala`.
///
/// # What was kept and what was dropped
///
/// The Scala class preallocates `capacity` (default 256) `Move` objects once and
/// then *recycles* them: `pushNormal` calls `buffer(size).set(...)`, overwriting
/// the object already sitting in that slot, and `swapRemove` swaps references
/// rather than shrinking, so no `Move` is ever allocated or dropped after
/// construction. That pooling is a GC optimisation, not a semantic: no code in
/// the library observes a `Move`'s identity, and the only place a `Move` outlives
/// its slot (`Encoder.decode` keeps `move` across `board.play(move)`) is safe
/// only because `legalMoves` is not called in between.
///
/// So **the pooling is dropped**, and it costs nothing to drop: `Move` is a packed
/// `Int64` (see `Move.flix`), so `Array[Move, r]` is a bare `long[]` and `push`
/// stores a value, not a reference to a heap object. The original pools because
/// its `Move` is a seven-field class; there is no object here to pool.
/// Everything that *is* semantic is preserved exactly:
///
///   * ordering is by score **descending** (`Move.lessThan`, from Scala's
///     `Integer.compare(that.score, score)`);
///   * `rank(m)` counts the moves that are strictly *less* in that order, i.e.
///     the moves with a strictly **greater** score;
///   * `selectRank` is the same quickselect with the same last-element pivot and
///     the same Lomuto partition, so it returns the same element for the same
///     input — including for the ties, which quickselect resolves by position and
///     which therefore depend on the exact swap sequence;
///   * `retain` still swap-removes and re-tests the swapped-in element in place,
///     which is what leaves the surviving moves in their characteristic
///     non-stable order.
///
/// The buffer is pre-filled with `Move.empty()` placeholders. A slot beyond
/// `size` is never read: `get` requires `i < size`, exactly as the Scala
/// `require`, and every internal read is bounded by `size`.
///
/// # Region
///
/// `MoveList` is genuinely mutable (`Board.legalMoves` fills a caller-supplied
/// list, `retain` prunes it in place), so unlike `Tables` it is a region-allocated
/// `struct` and its operations carry `\ r`. Flix requires a struct's fields to be
/// touched only inside the module named after it, so the whole API lives in
/// `mod MoveList`.
///
/// # Scoring context
///
/// Scala's `pushNormal(board, ...)` passes the whole `Board`; `Move.set` reads
/// `turn`, `pawns` and `them()` from it. Here those three, plus the attack tables
/// and the piece-square table, are passed as five leading scalars — see the note on
/// `Move.mk` in `Move.flix` for why they are not bundled into a context object and
/// not read off the `Board`:
///
/// ```flix
/// region rc {
///     let moves = MoveList.mk(rc, 256);
///     MoveList.pushNormal(moves, tables, psqt, turn, pawns, them,
///                         Role.Knight, from, capture, to);
///     ...
/// }
/// ```
///
mod MoveList {

    import java.lang.IllegalArgumentException

    ///
    /// `buffer` holds `capacity` moves; only the first `size` are live.
    ///
    pub struct MoveList[r: Region] {
        buffer: Array[Move, r],
        mut size: Int32
    }

    ///
    /// Scala `MoveList(capacity)`, default capacity 256.
    ///
    /// Use `MoveList.mk(rc, 256)` for the move generator's list and
    /// `MoveList.mk(rc, 2)` for the throwaway list in `hasLegalEnPassant`.
    ///
    pub def mk(rc: Region[r], capacity: Int32): MoveList[r] \ r =
        new MoveList @ rc { buffer = Array.empty(rc, capacity), size = 0 }

    ///
    /// Scala `MoveList()`: the default capacity of 256.
    ///
    pub def mkDefault(rc: Region[r]): MoveList[r] \ r = mk(rc, 256)

    ///
    /// Scala `def clear(): Unit = size = 0`. The buffer contents are left alone,
    /// exactly as in the original.
    ///
    pub def clear(ml: MoveList[r]): Unit \ r =
        ml->size = 0

    ///
    /// Scala `def getSize(): Int`.
    ///
    pub def getSize(ml: MoveList[r]): Int32 \ r =
        ml->size

    ///
    /// Scala `def get(i: Int): Move`, including its `require(i < size)`.
    ///
    /// The original's `require` is messageless, so it raises
    /// `IllegalArgumentException("requirement failed")`; this throws the same
    /// exception with the same message rather than `bug!`, which would raise
    /// `dev.flix.runtime.HoleError$` — a `java.lang.Error`, and therefore not
    /// caught by a caller's `catch (Exception e)`. `unsafe IO { throw ... }` is
    /// how the Flix standard library itself raises Java exceptions from a
    /// non-`IO` function (`Prelude.flix`'s `indexOutOfBounds!`), and it leaves
    /// this signature's `\ r` effect exactly as it was.
    ///
    /// The `i < 0` disjunct is deliberately kept even though Scala's `require`
    /// does not test it: on a negative index Scala falls through to an array
    /// bound while this reports the `IllegalArgumentException` earlier. That
    /// path is unreachable — the only caller indexes with a Huffman symbol in
    /// `0 .. 255` — and closing it would mean adding a branch for a case
    /// neither implementation can reach.
    ///
    @Inline
    pub def get(ml: MoveList[r], i: Int32): Move \ r =
        if (i < 0 or i >= ml->size) unsafe IO { throw new IllegalArgumentException("requirement failed") }
        else at(ml, i)

    ///
    /// An unchecked slot read, for the internals that are already bounded by
    /// `size` (Scala's `partition` indexes `buffer` directly, bypassing `get`).
    ///
    @Inline
    def at(ml: MoveList[r], i: Int32): Move \ r =
        Array.get(i, ml->buffer)

    ///
    /// Scala `def isEmpty: Boolean = size == 0`.
    ///
    @Inline
    pub def isEmpty(ml: MoveList[r]): Bool \ r =
        ml->size == 0

    ///
    /// Appends `m`. This is the shape all four Scala `pushX` methods share:
    /// `buffer(size).set(...)` followed by `size += 1`.
    ///
    @Inline
    pub def push(ml: MoveList[r], m: Move): Unit \ r = {
        Array.put(m, ml->size, ml->buffer);
        ml->size = ml->size + 1
    }

    ///
    /// Scala `pushNormal(board, role, from, capture, to)`.
    ///
    @Inline
    pub def pushNormal(ml: MoveList[r], tables: Tables[Static], psqt: Psqt, turn: Bool,
                       pawns: Int64, them: Int64, role: Role, fromSq: Int32,
                       capture: Bool, toSq: Int32): Unit \ r =
        push(ml, Move.mk(tables, psqt, turn, pawns, them, Move.normal(), role, fromSq, capture, toSq, None))

    ///
    /// Scala `pushPromotion(board, from, capture, to, promotion)`.
    ///
    /// Note the type is `NORMAL`, not something promotion-specific: that is what
    /// the original says.
    ///
    @Inline
    pub def pushPromotion(ml: MoveList[r], tables: Tables[Static], psqt: Psqt, turn: Bool,
                          pawns: Int64, them: Int64, fromSq: Int32, capture: Bool,
                          toSq: Int32, promotion: Role): Unit \ r =
        push(ml, Move.mk(tables, psqt, turn, pawns, them, Move.normal(), Role.Pawn, fromSq, capture, toSq, Some(promotion)))

    ///
    /// Scala `pushCastle(board, king, rook)`: `to` is the **rook** square, and
    /// `capture` is false even though the rook square is occupied.
    ///
    @Inline
    pub def pushCastle(ml: MoveList[r], tables: Tables[Static], psqt: Psqt, turn: Bool,
                       pawns: Int64, them: Int64, king: Int32, rook: Int32): Unit \ r =
        push(ml, Move.mk(tables, psqt, turn, pawns, them, Move.castling(), Role.King, king, false, rook, None))

    ///
    /// Scala `pushEnPassant(board, capturer, to)`: `capture` is true.
    ///
    @Inline
    pub def pushEnPassant(ml: MoveList[r], tables: Tables[Static], psqt: Psqt, turn: Bool,
                          pawns: Int64, them: Int64, capturer: Int32, toSq: Int32): Unit \ r =
        push(ml, Move.mk(tables, psqt, turn, pawns, them, Move.enPassant(), Role.Pawn, capturer, true, toSq, None))

    ///
    /// Scala `def find(predicate): Option[Move]` over the live prefix.
    ///
    /// The predicate is effect-polymorphic: `Board.isSafe` reads a mutable
    /// `Board`, so it cannot be pure.
    ///
    pub def find(ml: MoveList[r], f: Move -> Bool \ ef): Option[Move] \ r + ef =
        findLoop(ml, f, 0)

    def findLoop(ml: MoveList[r], f: Move -> Bool \ ef, i: Int32): Option[Move] \ r + ef =
        if (i >= ml->size) None
        else {
            let m = at(ml, i);
            if (f(m)) Some(m) else findLoop(ml, f, i + 1)
        }

    ///
    /// Scala `def exists(predicate): Boolean` over the live prefix.
    ///
    pub def exists(ml: MoveList[r], f: Move -> Bool \ ef): Bool \ r + ef =
        existsLoop(ml, f, 0)

    def existsLoop(ml: MoveList[r], f: Move -> Bool \ ef, i: Int32): Bool \ r + ef =
        if (i >= ml->size) false
        else if (f(at(ml, i))) true
        else existsLoop(ml, f, i + 1)

    ///
    /// Scala `def rank(move: Move): Int = buffer.view.take(size).count(_ < move)`.
    ///
    /// `_ < move` is `Ordered[Move]`, which orders by score descending, so this
    /// counts the moves whose score is strictly **greater** than `move`'s: the
    /// 0-based position of `move` in the best-first ordering. It is the value
    /// Huffman-coded by the encoder, so it must match bit for bit.
    ///
    pub def rank(ml: MoveList[r], m: Move): Int32 \ r =
        rankLoop(ml, m, 0, 0)

    def rankLoop(ml: MoveList[r], m: Move, i: Int32, acc: Int32): Int32 \ r =
        if (i >= ml->size) acc
        else rankLoop(ml, m, i + 1, if (Move.lessThan(at(ml, i), m)) acc + 1 else acc)

    ///
    /// Scala `def retain(predicate): Unit`.
    ///
    /// ```scala
    /// var i = 0
    /// while i < size do
    ///   if predicate(buffer(i)) then i += 1
    ///   else swapRemove(i)          // size -= 1; swap(i, size)
    /// ```
    ///
    /// `i` deliberately does **not** advance on removal, so the element swapped
    /// in from the end is tested next. The removed element is swapped *out* to
    /// index `size`, not overwritten.
    ///
    pub def retain(ml: MoveList[r], f: Move -> Bool \ ef): Unit \ r + ef =
        retainLoop(ml, f, 0)

    def retainLoop(ml: MoveList[r], f: Move -> Bool \ ef, i: Int32): Unit \ r + ef =
        if (i >= ml->size) ()
        else if (f(at(ml, i))) retainLoop(ml, f, i + 1)
        else {
            swapRemove(ml, i);
            retainLoop(ml, f, i)
        }

    ///
    /// Scala `private inline def swapRemove(i: Int)`.
    ///
    def swapRemove(ml: MoveList[r], i: Int32): Unit \ r = {
        ml->size = ml->size - 1;
        // The trailing `()` keeps `swap` out of tail position; see the note in
        // `mod Board`. A tail call to another def allocates a heap continuation.
        swap(ml, i, ml->size);
        ()
    }

    ///
    /// Scala `private def swap(i: Int, j: Int)` — the one primitive `swapRemove`
    /// and the quickselect's `partition` are written in terms of. Both live in
    /// this module, so this stays private, as in the original.
    ///
    @Inline
    def swap(ml: MoveList[r], i: Int32, j: Int32): Unit \ r = {
        let tmp = Array.get(i, ml->buffer);
        Array.put(Array.get(j, ml->buffer), i, ml->buffer);
        Array.put(tmp, j, ml->buffer)
    }

    ///
    /// Scala `def selectRank(rank: Int): Move`, including its `require(rank < size)`.
    ///
    /// Quickselect with the last element as pivot, partitioning **in place**, so
    /// the list is left permuted afterwards — the encoder relies on that only in
    /// so far as it re-generates the moves each ply.
    ///
    /// ```scala
    /// var left = 0; var right = size - 1
    /// while left < right do
    ///   val pivot = partition(left, right)
    ///   if pivot == rank then return buffer(rank)
    ///   if pivot < rank then left = pivot + 1 else right = pivot - 1
    /// buffer(rank)
    /// ```
    ///
    /// As in `get`, the original's `require(rank < size)` is messageless, so the
    /// failure is `IllegalArgumentException("requirement failed")` and not a
    /// `bug!`. This is the site a corrupt stream actually reaches: a Huffman
    /// symbol larger than the number of legal moves in the position.
    ///
    /// # The small-rank fast path (round 6)
    ///
    /// A *different selection algorithm* is legitimate here in a way it would not
    /// be on the encode side, and the argument is a proof rather than a
    /// measurement. `Move.score` packs five bit-disjoint fields —
    /// `(promo<<26) + (capture<<25) + (pawnDefFlag<<22) + ((512+moveValue)<<12) +
    /// (to<<6) + from`, with `512+moveValue` in `[412, 612] < 2^10` — so bits 0..11
    /// are `(to, from)`, which names a move uniquely except for promotion variants,
    /// and those differ in bits >= 26. Scores are therefore **injective within one
    /// legal move list** (checked: 0 duplicates over 206 604 lists / 5 072 212 moves
    /// in an exhaustive depth-4 walk, and 0 over the 2 054 lists the corpus decode
    /// visits). Injectivity makes the `(rank+1)`-th largest *unique*, so any correct
    /// selection returns the same `Move`, and `selectRank` has exactly one caller in
    /// the repository — `GameEncoder.decodeLoop`. Encode uses `find` + `rank`, and
    /// perft never calls it. No emitted byte can move.
    ///
    /// The permutation quickselect leaves behind is likewise unobservable: after
    /// `selectRank` the only reads of `legals` are `GameEncoder.othersLoop` (an
    /// order-independent OR-reduction over `[0, size)`) and `MoveList.isEmpty`
    /// (which reads `size`), and the next ply's `legalMoves` calls `clear`.
    ///
    /// Why it is faster: instrumented over the corpus, the Lomuto quickselect does
    /// 63.6-73.2 partition steps per ply against a mean list size of 27.1-32.9, and
    /// its inner branch is ~50% unpredictable by construction. The mean rank is
    /// 7.6-8.6 and 60-63% of ranks are below 8, so a single pass keeping the best
    /// four in four `Int64` scalars — one almost-always-taken threshold branch —
    /// serves about half of all plies with one pass and no mispredicts.
    ///
    /// The cutoff is 4 and not larger on purpose: a cutoff-8 variant needs a scratch
    /// array (+144 B per decode, against allocation rows that are also targets) and a
    /// cutoff-16 variant measured 0.988x/0.982x/0.985x, i.e. top-k-always loses.
    ///
    @Inline
    pub def selectRank(ml: MoveList[r], targetRank: Int32): Move \ r =
        if (targetRank < 0 or targetRank >= ml->size)
            unsafe IO { throw new IllegalArgumentException("requirement failed") }
        else if (targetRank < 4)
            top4Loop(ml->buffer, ml->size, 0, sentinel(), sentinel(), sentinel(), sentinel(), targetRank)
        else
            selectLoop(ml, targetRank, 0, ml->size - 1)

    ///
    /// A `Move` whose score field is `Int32.MinValue` and which therefore sorts
    /// *after* every real move under `Move.lessThan`.
    ///
    /// `lessThan(x, y)` is `y << 32 < x << 32`. `sentinel() << 32` is exactly
    /// `Int64.MinValue`, and a real move's score is in `[0, 2^29)` so its `<< 32` is
    /// non-negative; hence `lessThan(real, sentinel())` holds for every real move and
    /// a sentinel is always displaced before it can be returned. It never can be
    /// returned anyway: the guard above has already established `targetRank < size`,
    /// so at least `targetRank + 1` real moves pass through the loop.
    ///
    @Inline
    def sentinel(): Move = -2147483648i64

    ///
    /// One pass over `buffer[0, size)` keeping the four moves that sort first under
    /// `Move.lessThan` in `a <= b <= c <= d`, then returning the `target`-th.
    ///
    /// Self-tail-recursive in all five arms, so Flix compiles it to a `goto` loop;
    /// `Move.lessThan` is `@Inline` and every accumulator is an `Int64` local, so the
    /// loop allocates nothing (one `Value$` at the single exit). Contrast the path it
    /// replaces: `selectLoopOn` calls `partitionLoopOn` as a real Flix def, paying a
    /// `Result$` trampoline round trip and an `Int32` `Value$` per quickselect level.
    ///
    def top4Loop(buf: Array[Move, r], size: Int32, i: Int32,
                 a: Move, b: Move, c: Move, d: Move, target: Int32): Move \ r =
        if (i >= size)
            (if (target == 0) a else if (target == 1) b else if (target == 2) c else d)
        else {
            let v = Array.get(i, buf);
            if (not Move.lessThan(v, d))       top4Loop(buf, size, i + 1, a, b, c, d, target)
            else if (Move.lessThan(v, a))      top4Loop(buf, size, i + 1, v, a, b, c, target)
            else if (Move.lessThan(v, b))      top4Loop(buf, size, i + 1, a, v, b, c, target)
            else if (Move.lessThan(v, c))      top4Loop(buf, size, i + 1, a, b, v, c, target)
            else                               top4Loop(buf, size, i + 1, a, b, c, v, target)
        }

    ///
    /// The quickselect and its Lomuto `partition` are fused into two defs over the raw
    /// `Array[Move, r]` rather than three defs over the `MoveList` struct.
    ///
    /// Scala's `selectRank` / `partition` are two methods on one object, so the field
    /// load is free there; here `ml->buffer` was a `getfield` plus a `checkcast [J`
    /// reloaded five times per swapping iteration (once in the pivot read, twice in
    /// each `at`, twice more in `swap`), and `selectLoop -> partition -> partitionLoop`
    /// cost two `Result$` trampoline round trips per quickselect level. `partitionLoop`
    /// is the #2 frame in the port's decode profile at ~22% of samples, so both matter.
    ///
    /// The swap sequence is preserved exactly — same last-element pivot, same Lomuto
    /// scan, same `i + 1` then `swap(i, right)` — because that sequence is what resolves
    /// ties, and a different permutation would change which move a given Huffman rank
    /// names. Gated on the depth-4 perft checksum, which is move-order sensitive, as
    /// well as on `difftest`.
    ///
    /// The Scala pivot is the *reference* `buffer(right)`, but `right` is never touched
    /// by the inner loop's swaps (which only involve indices in `[left, right)`), so
    /// capturing the value is equivalent.
    ///
    def selectLoop(ml: MoveList[r], targetRank: Int32, left: Int32, right: Int32): Move \ r =
        selectLoopOn(ml->buffer, targetRank, left, right)

    def selectLoopOn(buf: Array[Move, r], targetRank: Int32, left: Int32, right: Int32): Move \ r =
        if (left < right) {
            let pivot = Array.get(right, buf);
            let i = partitionLoopOn(buf, pivot, left, right, left - 1) + 1;
            // swap(i, right)
            let tmp = Array.get(i, buf);
            Array.put(Array.get(right, buf), i, buf);
            Array.put(tmp, right, buf);
            if (i == targetRank) Array.get(targetRank, buf)
            else if (i < targetRank) selectLoopOn(buf, targetRank, i + 1, right)
            else selectLoopOn(buf, targetRank, left, i - 1)
        } else
            Array.get(targetRank, buf)

    /// The `for j <- left until right` loop; returns the final `i`.
    def partitionLoopOn(buf: Array[Move, r], pivot: Move, j: Int32, right: Int32, i: Int32): Int32 \ r =
        if (j >= right) i
        else if (Move.lessThan(Array.get(j, buf), pivot)) {
            let k = i + 1;
            // swap(k, j)
            let tmp = Array.get(k, buf);
            Array.put(Array.get(j, buf), k, buf);
            Array.put(tmp, j, buf);
            partitionLoopOn(buf, pivot, j + 1, right, k)
        } else
            partitionLoopOn(buf, pivot, j + 1, right, i)

    ///
    /// Scala `def pretty(): String` — every live move's UCI, each followed by a
    /// space (so the result has a trailing space, as in the original).
    ///
    pub def pretty(ml: MoveList[r]): String \ r =
        prettyLoop(ml, 0, "")

    def prettyLoop(ml: MoveList[r], i: Int32, acc: String): String \ r =
        if (i >= ml->size) acc
        else prettyLoop(ml, i + 1, "${acc}${Move.uci(at(ml, i))} ")

    ///
    /// The live moves, in buffer order. Not in the Scala original; it is the
    /// obvious way to iterate a `MoveList` without an index, and `Encoder.san`'s
    /// `for i <- 0 until legals.getSize()` can use either.
    ///
    pub def toList(ml: MoveList[r]): List[Move] \ r =
        toListLoop(ml, ml->size - 1, Nil)

    def toListLoop(ml: MoveList[r], i: Int32, acc: List[Move]): List[Move] \ r =
        if (i < 0) acc else toListLoop(ml, i - 1, at(ml, i) :: acc)
}
