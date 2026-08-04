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
/// and the piece-square table, are bundled in a `MoveCtx` (see `Move.flix`) which
/// the caller builds once per `legalMoves` call:
///
/// ```flix
/// region rc {
///     let moves = MoveList.mk(rc, 256);
///     let ctx   = MoveCtx.mk(tables, psqt, turn, pawns, them);
///     MoveList.pushNormal(moves, ctx, Role.Knight, from, capture, to);
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
        new MoveList @ rc { buffer = Array.repeat(rc, capacity, Move.empty()), size = 0 }

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
    pub def pushNormal(ml: MoveList[r], ctx: MoveCtx, role: Role, fromSq: Int32,
                       capture: Bool, toSq: Int32): Unit \ r =
        push(ml, Move.mk(ctx, Move.normal(), role, fromSq, capture, toSq, None))

    ///
    /// Scala `pushPromotion(board, from, capture, to, promotion)`.
    ///
    /// Note the type is `NORMAL`, not something promotion-specific: that is what
    /// the original says.
    ///
    @Inline
    pub def pushPromotion(ml: MoveList[r], ctx: MoveCtx, fromSq: Int32, capture: Bool,
                          toSq: Int32, promotion: Role): Unit \ r =
        push(ml, Move.mk(ctx, Move.normal(), Role.Pawn, fromSq, capture, toSq, Some(promotion)))

    ///
    /// Scala `pushCastle(board, king, rook)`: `to` is the **rook** square, and
    /// `capture` is false even though the rook square is occupied.
    ///
    @Inline
    pub def pushCastle(ml: MoveList[r], ctx: MoveCtx, king: Int32, rook: Int32): Unit \ r =
        push(ml, Move.mk(ctx, Move.castling(), Role.King, king, false, rook, None))

    ///
    /// Scala `pushEnPassant(board, capturer, to)`: `capture` is true.
    ///
    @Inline
    pub def pushEnPassant(ml: MoveList[r], ctx: MoveCtx, capturer: Int32, toSq: Int32): Unit \ r =
        push(ml, Move.mk(ctx, Move.enPassant(), Role.Pawn, capturer, true, toSq, None))

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
    @Inline
    pub def selectRank(ml: MoveList[r], targetRank: Int32): Move \ r =
        if (targetRank < 0 or targetRank >= ml->size)
            unsafe IO { throw new IllegalArgumentException("requirement failed") }
        else
            selectLoop(ml, targetRank, 0, ml->size - 1)

    def selectLoop(ml: MoveList[r], targetRank: Int32, left: Int32, right: Int32): Move \ r =
        if (left < right) {
            let p = partition(ml, left, right);
            if (p == targetRank) at(ml, targetRank)
            else if (p < targetRank) selectLoop(ml, targetRank, p + 1, right)
            else selectLoop(ml, targetRank, left, p - 1)
        } else
            at(ml, targetRank)

    ///
    /// Scala `private def partition(left, right): Int` — the Lomuto scheme.
    ///
    /// The Scala pivot is the *reference* `buffer(right)`, but `right` is never
    /// touched by the inner loop's swaps (which only involve indices in
    /// `[left, right)`), so capturing the value here is equivalent.
    ///
    def partition(ml: MoveList[r], left: Int32, right: Int32): Int32 \ r = {
        let pivot = at(ml, right);
        let i = partitionLoop(ml, pivot, left, right, left - 1) + 1;
        swap(ml, i, right);
        i
    }

    /// The `for j <- left until right` loop; returns the final `i`.
    def partitionLoop(ml: MoveList[r], pivot: Move, j: Int32, right: Int32, i: Int32): Int32 \ r =
        if (j >= right) i
        else if (Move.lessThan(at(ml, j), pivot)) {
            swap(ml, i + 1, j);
            partitionLoop(ml, pivot, j + 1, right, i + 1)
        } else
            partitionLoop(ml, pivot, j + 1, right, i)

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
