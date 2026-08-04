///
/// The reproducible perft sweep over the whole generated corpus.
///
/// `src/test/scala/PerftTest.scala` holds 6838 generated positions (the
/// `// gentest-N` blocks inside `batch0()..batch17()`), each with an expected
/// depth-4 node count. `tools/extract-perft-corpus.py` flattens them into
/// `flix/test/data/perft-corpus.csv`; this module replays that file through the
/// Flix `Board`, and `difftest/src/test/scala/PerftCorpusTest.scala` replays the
/// same file through the original Scala `Board`. Feeding both implementations one
/// file is what makes the comparison meaningful — neither side re-parses Scala.
///
/// Two things are checked:
///
///   * node counts, against the expected value on each row (depth 4 only — the
///     corpus only records depth-4 expectations);
///   * a checksum over the *move lists themselves*, which node counts alone
///     cannot see. Two move generators can agree on every leaf count while
///     emitting moves in a different order or with different scores, and move
///     order is load-bearing here: `Encoder` picks a move by its rank in the
///     ordered list, so a reordering silently changes the compressed bytes.
///
/// The checksum recurrence, which is duplicated verbatim in the Scala driver:
///
///     k  = (fromSq << 48) | (toSq << 40) | (score & 0xffffffff)   per move
///     h  = ((h << 5) + h) ^ k                                     per move, in generation order
///     h  = ((h << 5) + h) ^ n                                     once per node, after the move loop
///
/// `h` starts at 0 for the whole run and threads through every node of every
/// row in corpus order, so it is sensitive to move order, move contents, node
/// order and row order all at once.
///
/// Entry points:
///
///     bash scripts/perft-sweep.sh              # depth 4, the full sweep
///     bash scripts/perft-sweep.sh --quick      # depth 2
///     flix run --entrypoint PerftSweep.main
///
/// `--entrypoint` is mandatory: `main` here is MOD-SCOPED, and a bare `flix run`
/// with no top-level `main` is a silent no-op that exits 0. It is mod-scoped on
/// purpose — a top-level `main` would make `flix build-jar` emit a `Main.class`
/// and change what `java -jar flix/artifact/flix.jar` does, which sbt's `flixJar`
/// task and the differential suite both consume.
///
/// The cheap depth-2 tier runs inside the ordinary `flix test` suite; see
/// `test/TestPerftSweep.flix`.
///
mod PerftSweep {

    ///
    /// One corpus row: the 11 `Board` constructor arguments, then the depth and
    /// the expected node count at that depth.
    ///
    pub type alias Row =
        (Int64, Int64, Int64, Int64, Int64, Int64, Int64, Int64, Bool, Int32, Int64, Int32, Int64)

    /// The default corpus, relative to the Flix project root (`flix/`), which is
    /// also the working directory during `flix test`.
    pub def defaultData(): String = "test/data/perft-corpus.csv"

    // ------------------------------------------------------------------ mixing

    ///
    /// Folds one move into the running checksum.
    ///
    /// `Move.score` is an `Int32` and may be negative, so it is masked to 32 bits
    /// before being OR'd in; otherwise sign extension would overwrite the `from`
    /// and `to` fields. This is exactly what `(((long) m.score) & 0xffffffffL)`
    /// does on the Scala side.
    ///
    def mixMove(h: Int64, m: Move): Int64 = {
        let k =
            Bits.borL(
                Bits.borL(
                    Bits.shlL(Int32.toInt64(Move.fromSq(m)), 48),
                    Bits.shlL(Int32.toInt64(Move.toSq(m)), 40)),
                Bits.bandL(Int32.toInt64(Move.score(m)), 4294967295i64));
        Bits.bxorL(Bits.shlL(h, 5) + h, k)
    }

    def mixLoop(moves: MoveList[r], n: Int32, i: Int32, h: Int64): Int64 \ r =
        if (i >= n) h
        else mixLoop(moves, n, i + 1, mixMove(h, MoveList.get(moves, i)))

    // ------------------------------------------------------------------- perft

    ///
    /// Counts the leaves of the legal-move tree below `b` and threads the
    /// checksum through it. Returns `(nodes, checksum)`.
    ///
    /// The driver is deliberately the same shape as `PerftTest.perft` and
    /// `TestBoardPerft.perft`: a fresh `MoveList` per node, `Board.copy` +
    /// `Board.play` per child. A faster driver would make the timings
    /// incomparable with the Scala side.
    ///
    pub def perft(b: Board[r], depth: Int32, h0: Int64): (Int64, Int64) \ r =
        if (depth < 1) (1i64, h0)
        else region rc {
            let moves = MoveList.mkDefault(rc);
            Board.legalMoves(b, moves);
            let n = MoveList.getSize(moves);
            let hM = mixLoop(moves, n, 0, h0);
            let h1 = Bits.bxorL(Bits.shlL(hM, 5) + hM, Int32.toInt64(n));
            if (depth == 1) (Int32.toInt64(n), h1)
            else childLoop(b, moves, n, depth, 0, 0i64, h1)
        }

    def childLoop(b: Board[r], moves: MoveList[r2], n: Int32, depth: Int32, i: Int32,
            acc: Int64, h: Int64): (Int64, Int64) \ r + r2 =
        if (i >= n) (acc, h)
        else {
            let (sub, h2) = region rc {
                let child = Board.copy(rc, b);
                Board.play(child, MoveList.get(moves, i));
                perft(child, depth - 1, h)
            };
            childLoop(b, moves, n, depth, i + 1, acc + sub, h2)
        }

    // ------------------------------------------------------------------ driver

    ///
    /// Replays every row of `rows` at `depth`, threading one checksum through the
    /// whole sequence.
    ///
    /// Returns `(rows, nodes, checksum, mismatches)`. With `checkExpected`,
    /// `mismatches` counts rows whose node count differed from the corpus
    /// expectation — but only rows whose own recorded depth equals `depth`, since
    /// the corpus records a depth-4 expectation and nothing else. Without it, no
    /// comparison is made and `mismatches` is 0.
    ///
    /// `Tables`, `Psqt` and the polyglot Zobrist table are built ONCE for the whole
    /// run. Flix does not memoize a `def`, so building them per row would add
    /// ~100 ms x 6838 = 11 minutes of pure table construction.
    ///
    pub def runRows(rows: List[Row], depth: Int32, checkExpected: Bool): (Int32, Int64, Int64, Int32) \ IO =
        sweep(rows, depth, checkExpected, false)

    ///
    /// As `runRows`, but prints a progress line every 500 rows. `main` sets
    /// `progress`; the `@Test` does not, because the Flix test runner buffers a
    /// test's stdout until the test finishes, so progress there is pure noise.
    ///
    /// `IO` is on `runRows` too, and not only here, because a node-count mismatch
    /// is reported with the offending row rather than merely counted.
    ///
    pub def sweep(rows: List[Row], depth: Int32, checkExpected: Bool,
            progress: Bool): (Int32, Int64, Int64, Int32) \ IO = {
        let tables = Tables.mk();
        let psqt = Psqt.mk();
        let zob = ZobristHash.polyglot();
        rowLoop(tables, psqt, zob, rows, depth, checkExpected, progress, 0, 0i64, 0i64, 0)
    }

    def rowLoop(tables: Tables, psqt: Psqt, zob: Vector[Int32], rows: List[Row], depth: Int32,
            checkExpected: Bool, progress: Bool, count: Int32, nodes: Int64, h: Int64,
            mismatches: Int32): (Int32, Int64, Int64, Int32) \ IO =
        match rows {
            case Nil => (count, nodes, h, mismatches)
            case row :: rest =>
                let (pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr, rowDepth, expected) = row;
                let (n, h2) = region rc {
                    let b = Board.mk(rc, tables, psqt, zob, pw, kn, bi, ro, qu, ki, wh, bl, tu, ep, cr);
                    perft(b, depth, h)
                };
                // The expectation only applies at the row's OWN depth. Every row in
                // the shipped corpus is depth 4, but guarding on it here means a
                // `--quick`/`--depth 2` run cannot report spurious mismatches.
                let bad =
                    if (checkExpected and depth == rowDepth and n != expected) {
                        println("[perft] MISMATCH row ${count + 1}: expected ${expected} got ${n}");
                        1
                    } else 0;
                let count2 = count + 1;
                if (progress and Int32.remainder(count2, 500) == 0)
                    println("[perft]   ${count2} rows, ${nodes + n} nodes")
                else ();
                rowLoop(tables, psqt, zob, rest, depth, checkExpected, progress, count2, nodes + n, h2,
                        mismatches + bad)
        }

    // ------------------------------------------------------------------ parsing

    ///
    /// Parses one CSV line into a `Row`. Rejects anything that is not exactly 13
    /// comma-separated integers, so a truncated or reordered file fails loudly
    /// rather than silently sweeping fewer positions.
    ///
    pub def parseRow(line: String): Option[Row] = {
        let fields = String.splitOn(substr = ",", String.trim(line));
        if (List.length(fields) != 13) None
        else {
            let v = List.toVector(fields);
            forM (
                pw <- Int64.fromString(Vector.get(0, v));
                kn <- Int64.fromString(Vector.get(1, v));
                bi <- Int64.fromString(Vector.get(2, v));
                ro <- Int64.fromString(Vector.get(3, v));
                qu <- Int64.fromString(Vector.get(4, v));
                ki <- Int64.fromString(Vector.get(5, v));
                wh <- Int64.fromString(Vector.get(6, v));
                bl <- Int64.fromString(Vector.get(7, v));
                tu <- Int32.fromString(Vector.get(8, v));
                ep <- Int32.fromString(Vector.get(9, v));
                cr <- Int64.fromString(Vector.get(10, v));
                dp <- Int32.fromString(Vector.get(11, v));
                ex <- Int64.fromString(Vector.get(12, v))
            ) yield (pw, kn, bi, ro, qu, ki, wh, bl, tu != 0, ep, cr, dp, ex)
        }
    }

    ///
    /// Reads the corpus. Blank lines are skipped; every other line must parse.
    /// Returns `Err` with a message on a missing file or an unparseable line.
    ///
    /// `Fs.FileRead.readLines` is called directly. Do NOT reach for `Fs.ReadLines`
    /// — it has no `@DefaultHandler`, so it cannot be discharged at a `@Test`.
    ///
    pub def readCorpus(path: String): Result[String, List[Row]] \ Fs.FileRead.FileRead =
        match Fs.FileRead.readLines(path) {
            case Result.Err(e) => Result.Err("cannot read ${path}: ${e}")
            case Result.Ok(lines) =>
                let kept = List.filter(l -> not String.isEmpty(String.trim(l)), lines);
                let parsed = List.map(parseRow, kept);
                if (List.exists(Option.isEmpty, parsed))
                    Result.Err("${path}: malformed row (expected 13 comma-separated integers)")
                else Result.Ok(List.filterMap(x -> x, parsed))
        }

    ///
    /// `--shard I/N`: keep rows whose 1-based index `i` satisfies `i % N == I`.
    /// Deliberately the same rule as the shell script's `awk 'NR%N==I'`, so a shard
    /// is reproducible from either side.
    ///
    def shard(rows: List[Row], i: Int32, n: Int32): List[Row] =
        List.filterMap(p -> { let (idx, r) = p; if (Int32.remainder(idx + 1, n) == i) Some(r) else None },
                       List.zipWithIndex(rows))

    def parseShard(spec: String): Option[(Int32, Int32)] =
        match String.splitOn(substr = "/", spec) {
            case i :: n :: Nil => forM (a <- Int32.fromString(String.trim(i));
                                        b <- Int32.fromString(String.trim(n))) yield (a, b)
            case _ => None
        }

    def envOr(name: String, dflt: String): String \ Sys.Env.Env =
        Option.getWithDefault(dflt, Sys.Env.getVar(name))

    // -------------------------------------------------------------- entry point

    ///
    /// MOD-SCOPED on purpose; run it with
    ///
    ///     flix run --entrypoint PerftSweep.main -- [args]
    ///
    /// Environment:
    ///     PERFT_DATA   corpus path, default `test/data/perft-corpus.csv`
    ///     PERFT_DEPTH  search depth, default 4
    ///     PERFT_SHARD  `I/N`, keep rows where (1-based index) % N == I
    ///
    /// Exit codes: 2 if no rows were read, 1 on any node-count mismatch, else 0.
    ///
    pub def main(): Unit \ IO + Fs.FileRead.FileRead + Sys.Env.Env + Sys.Exit.Exit = {
        let path = envOr("PERFT_DATA", defaultData());
        let depth = Option.getWithDefault(4, Int32.fromString(envOr("PERFT_DEPTH", "4")));
        let shardSpec = envOr("PERFT_SHARD", "");
        match readCorpus(path) {
            case Result.Err(msg) =>
                println("[perft] ERROR ${msg}");
                Sys.Exit.exit(2)
            case Result.Ok(all) =>
                // A malformed PERFT_SHARD is an error, not a fallback to "all rows".
                // Silently sweeping 6838 rows when the caller asked for 1/8th of
                // them is precisely the kind of quiet wrong answer this whole
                // exercise exists to stamp out.
                let rows =
                    if (String.isEmpty(String.trim(shardSpec))) Some(all)
                    else Option.map(p -> { let (i, n) = p; shard(all, i, n) }, parseShard(shardSpec));
                match rows {
                    case None =>
                        println("[perft] ERROR PERFT_SHARD='${shardSpec}' is not of the form I/N");
                        Sys.Exit.exit(2)
                    case Some(rs) => runAndReport(path, rs, depth)
                }
        }
    }

    def runAndReport(path: String, rows: List[Row], depth: Int32): Unit \ IO + Sys.Exit.Exit =
        if (List.isEmpty(rows)) {
            println("[perft] ERROR ${path}: no rows");
            Sys.Exit.exit(2)
        } else {
            println("[perft] flix  depth${depth} corpus=${path} rows=${List.length(rows)}");
            let (count, nodes, checksum, mismatches) = sweep(rows, depth, true, true);
            println("[perft] flix  depth${depth} rows=${count} nodes=${nodes} "
                + "checksum=${checksum} mismatches=${mismatches}");
            if (mismatches != 0) Sys.Exit.exit(1) else ()
        }
}
