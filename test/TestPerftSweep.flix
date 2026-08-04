///
/// The cheap tier of the perft sweep, run by the ordinary `flix test`.
///
/// It replays ALL 6838 corpus positions, but at depth 2 rather than depth 4:
/// 4 689 446 nodes instead of 4 135 458 706, about 1.5 s instead of about 9
/// minutes. Every position is still visited, and the move-list checksum still
/// covers every move generated at plies 1 and 2 of every position, so a change to
/// move ordering or scoring anywhere in the corpus is caught here.
///
/// The depth-4 tier is NOT a gated `@Test` — Flix 0.75.1 has no test filter and a
/// `@Skip`ped test cannot be enabled without editing the source, so a gate would
/// be unusable. The opt-in path is `bash scripts/perft-sweep.sh`.
///
/// The identical corpus, the identical checksum recurrence and the identical
/// constants are asserted on the Scala side by
/// `difftest/src/test/scala/PerftCorpusTest.scala`. The two printing the same
/// `rows/nodes/checksum` triple is the actual proof; the literal constants below
/// are only a tripwire against both sides drifting together.
///
mod TestPerftSweep {

    ///
    /// The whole corpus at depth 2, checked against the constants measured on
    /// BOTH implementations.
    ///
    /// The effects are on the signature rather than discharged in the body:
    /// a `@Test` declared `Unit \ Assert + IO` that then reads a file fails with
    /// `Type Error [E6216] Unexpected effect 'Env'`. The stdlib's `@DefaultHandler`
    /// on `Fs.FileRead.runWithIO` discharges `FileRead` at the test entry point,
    /// so no explicit `runWith` wrapper is needed (or wanted).
    ///
    @Test
    pub def testCorpusDepth2(): Unit \ Assert + IO + Fs.FileRead.FileRead =
        match PerftSweep.readCorpus(PerftSweep.defaultData()) {
            case Result.Err(msg) => Assert.fail("[perft] ${msg}")
            case Result.Ok(rows) =>
                // Row count FIRST. `Fs.FileRead.readLines` returns `Err` for a
                // missing file, and a driver that shrugged that off would report a
                // green test that had checked nothing at all.
                Assert.assertEq(expected = 6838, List.length(rows));
                let (count, nodes, checksum, _) = PerftSweep.runRows(rows, 2, false);
                println("[perft] flix depth2 rows=${count} nodes=${nodes} checksum=${checksum}");
                Assert.assertEq(expected = 6838, count);
                Assert.assertEq(expected = 4689446i64, nodes);
                Assert.assertEq(expected = -6849308306848708094i64, checksum)
        }
}
