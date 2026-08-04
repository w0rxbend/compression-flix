# Benchmarks: Flix port versus the original Scala

Both implementations are measured in the same JVM, in the same run, on the same
inputs, with byte-equality asserted in `@Setup` so a fork that returns a wrong
answer dies instead of publishing a fast number.

The harness lives in the full port repository, which keeps the original Scala
implementation alongside the Flix one so the two can be measured together:
<https://github.com/w0rxbend/compression> (`bash scripts/run-benchmarks.sh`).
This file is the resulting report; raw JMH JSON and per-fork logs are committed
there.

## Verdict

The port started at a uniform ~5x slower. After an optimisation campaign gated on
byte-identical output, it is **ahead on game encode and on move generation, and
still behind on everything else**. It does not beat the original outright.

| | before | after | |
|---|---|---|---|
| game encode | 5.08-5.30x | **0.818-0.877x** | faster |
| game encode allocation | 24.6-26.9x | **0.336-0.468x** | faster |
| perft depth-4 (4.1e9 nodes) | 494 s vs 161 s | **79 s vs 160.5 s** | 2.03x faster |
| game decode | 4.72-5.38x | 1.017-1.109x | still behind |
| clock encode | 4.24-4.43x | 1.266-1.349x | still behind |
| clock decode | 2.75-3.98x | 1.149-1.307x | still behind |
| cold start | 172 vs 69 ms | 76.2 vs 68.6 ms | still behind |

On game encode the port now allocates **two to three times less** than the
implementation it copies, for byte-identical output.

The honest framing is "faster than the reference implementation it copies, on
some paths" — the Scala side was never given an equivalent optimisation pass, so
this is not a claim about Flix versus Scala as languages. Caveats on individual
rows are recorded in full below.

## Full results after the optimisation campaign, 2026-08-04

Produced in one sitting by `bash scripts/run-benchmarks.sh benchmarks/run-optimised`
on the same machine, the same JVM and the same commands as the
`benchmarks/run-hw/` baseline in the section above. Raw output is committed under
`benchmarks/run-optimised/`, and **every ratio below is derived from that JSON by
`python3 scripts/compare-benchmarks.py benchmarks/run-hw benchmarks/run-optimised`**,
not transcribed. Re-run that command to re-derive this section.

### The headline, stated plainly

**The goal was to beat the Scala original. That was achieved on the game encode
path and on move generation, and not achieved anywhere else.**

| what | verdict |
|---|---|
| game **encode**, all three bands | **beats Scala**: 0.82x / 0.84x / 0.88x of its time |
| game **encode** allocation, all three bands | **beats Scala**: 0.47x / 0.41x / 0.34x of its bytes |
| perft depth-4 sweep, 4 135 458 706 nodes | **beats Scala**: 79 s against 160.5 s (**2.03x faster**) |
| game **decode** | still slower: 1.02x / 1.02x / 1.11x |
| clock **encode** | still slower: 1.35x / 1.34x / 1.27x |
| clock **decode** | still slower: 1.15x / 1.15x / 1.31x |
| all allocation except game encode | still above Scala: 1.28x-3.33x |
| cold start | still slower: 76.2 ms against 68.6 ms (1.11x, was 2.49x) |

Nine of the twelve throughput rows are still slower than the reference; the three
that are not are game encode. The port went from uniformly ~5x slower to roughly
parity, and passed the reference on one direction of one codec plus the move
generator. **That is a large win and a missed goal**, and both halves of that
sentence are load-bearing: "5x faster than it was" is not the same claim as "faster
than Scala", and only the first is true across the board.

### Fidelity — unchanged, and checked before every number here

Nothing in this campaign was allowed to change an emitted byte, and nothing did.

```
$ cd flix && flix test
Passed: 122, Failed: 0. Skipped: 4. Elapsed: 4.5s.

$ sbt difftest/test
[info] Passed: Total 25, Failed 0, Errors 0, Passed 25

$ bash scripts/perft-sweep.sh          # depth 4, the full corpus
[perft] flix  depth4 rows=6838 nodes=4135458706 checksum=8459721354967636746 mismatches=0
$ bash scripts/perft-sweep.sh --scala
[perft] scala depth4 rows=6838 nodes=4135458706 checksum=8459721354967636746 mismatches=0
```

`difftest` is the gate that matters: it compares **emitted bytes** against the
Scala original over the whole corpus. The perft checksum is move-order sensitive,
so it also rules out a reordering that identical node counts would hide.
Independently, `FlixGameBench`'s own `@Setup` byte-compares the two
implementations per game per band and kills the fork if they disagree, so no
number in this section was published by a JVM that had not first agreed with
Scala.

### Machine and toolchain

| | |
|---|---|
| CPU | `AMD Ryzen 7 5700X 8-Core Processor`, 16 logical |
| Memory | `62 GiB total, 28 GiB available` |
| CPU governor | `performance` |
| Kernel | `Linux 7.1.5-1-cachyos x86_64` |
| JVM | Oracle GraalVM 25.0.3+9.1 (`25.0.3+9-LTS-jvmci-b01`), Graal JIT |
| Flix | `0.75.1` |
| JMH | 1.37, `-t 1`, Blackhole mode `compiler` |
| Timing | `-f 2 -wi 5 -w 2s -i 5 -r 2s -t 1` |
| Allocation | `-f 1 -wi 3 -w 2s -i 5 -r 2s -t 1 -prof gc` |
| Cold start | `-f 20 -wi 0 -i 1 -bm ss` |
| Flix jar | 1 872 963 bytes, 1654 entries, from a clean `rm -rf flix/build flix/artifact` |
| Load average | 3.5 entering the sweep, 1.8-2.6 throughout — quieter than the baseline run |

The baseline in `benchmarks/run-hw/` was taken on this same machine and JVM with
these same commands, which is what makes the before/after columns comparable.

### Throughput

Flix / Scala, both implementations in the same JVM, in the same run, on the same
inputs. `before` is the `benchmarks/run-hw/` baseline.

**Game codec (us/op)**

| operation | band | Scala | Flix | **after** | before | improvement |
|---|---|---:|---:|---:|---:|---:|
| encode | short | 153.736 ± 0.597 | 125.820 ± 0.919 | **0.818x** | 5.295x | 6.47x |
| encode | median | 323.726 ± 1.469 | 273.305 ± 1.853 | **0.844x** | 5.083x | 6.02x |
| encode | long | 669.248 ± 53.509 | 587.060 ± 5.597 | **0.877x** | 5.078x | 5.79x |
| decode | short | 186.793 ± 6.005 | 189.977 ± 1.669 | **1.017x** | 5.376x | 5.29x |
| decode | median | 407.543 ± 1.271 | 415.020 ± 2.341 | **1.018x** | 4.718x | 4.63x |
| decode | long | 727.647 ± 17.810 | 807.259 ± 4.730 | **1.109x** | 4.969x | 4.48x |

**Clock codec (ns/op)**

| operation | band | Scala | Flix | **after** | before | improvement |
|---|---|---:|---:|---:|---:|---:|
| encode | short | 36.289 ± 0.092 | 48.959 ± 0.535 | **1.349x** | 4.351x | 3.23x |
| encode | median | 65.152 ± 1.395 | 87.256 ± 0.513 | **1.339x** | 4.429x | 3.31x |
| encode | long | 117.928 ± 0.208 | 149.342 ± 1.317 | **1.266x** | 4.239x | 3.35x |
| decode | short | 55.678 ± 0.230 | 64.174 ± 0.968 | **1.153x** | 2.915x | 2.53x |
| decode | median | 98.513 ± 3.193 | 113.200 ± 0.218 | **1.149x** | 2.745x | 2.39x |
| decode | long | 183.071 ± 3.982 | 239.362 ± 2.134 | **1.307x** | 3.979x | 3.04x |

### Allocation

`gc.alloc.rate.norm`, bytes per operation. Reproducible to the byte — most rows
carry an error of ±0.001 B/op — which is why this is the co-primary axis rather
than a footnote.

| benchmark | operation | band | Scala B/op | Flix B/op | **after** | before |
|---|---|---|---:|---:|---:|---:|
| Game | encode | short | 109,087 | 51,018 | **0.468x** | 25.458x |
| Game | encode | median | 216,417 | 89,145 | **0.412x** | 26.914x |
| Game | encode | long | 457,370 | 153,610 | **0.336x** | 24.605x |
| Game | decode | short | 35,409 | 110,129 | **3.110x** | 94.929x |
| Game | decode | median | 66,481 | 167,642 | **2.522x** | 84.037x |
| Game | decode | long | 130,843 | 300,347 | **2.295x** | 78.852x |
| Clock | encode | short | 136 | 208 | **1.529x** | 6.529x |
| Clock | encode | median | 176 | 248 | **1.409x** | 8.545x |
| Clock | encode | long | 256 | 328 | **1.281x** | 10.128x |
| Clock | decode | short | 128 | 200 | **1.562x** | 9.750x |
| Clock | decode | median | 160 | 232 | **1.450x** | 13.600x |
| Clock | decode | long | 216 | 720 | **3.333x** | 25.963x |

**Game encode now allocates two to three times *less* than the implementation it
is a port of** — 153 610 B/op against 457 370 on the long band — for byte-identical
output. That row was 24.6x in the other direction three rounds ago.

### Cold start

`-f 20 -wi 0 -i 1 -bm ss`, 20 forks, one shot each, no warmup. Nobody targeted
this; it improved as a side effect, because building the 88 772-entry attack table
is itself mostly `lsb` and `>>>`.

| | before | after | |
|---|---:|---:|---|
| `ColdStartFlixBench.firstEncode` | 172.346 ± 2.938 ms | **76.192 ± 0.993 ms** | 2.26x faster |
| `ColdStartScalaBench.firstEncode` | 69.128 ± 1.388 ms | 68.626 ± 1.121 ms | unchanged |
| Flix / Scala | 2.49x | **1.11x** | |

### End-to-end move generation, without JMH

`scripts/perft-sweep.sh` walks all 6838 corpus positions to depth 4 on each
implementation. It is single-threaded, runs outside any harness, and its checksum
is sensitive to move *order*, so it is the strongest correctness-plus-performance
statement in the repository.

| | nodes | checksum | before | after |
|---|---:|---|---:|---:|
| Flix | 4,135,458,706 | `8459721354967636746` | 494 s | **79 s** |
| Scala | 4,135,458,706 | `8459721354967636746` | 161 s | **160.5 s** |

**The port went from 3.07x slower to 2.03x faster on identical work**, and the
Scala side reproduced its previously committed 161 s to within 0.3% in the same
session — which is the control that says the Flix figure is a real change and not
a faster machine.

### The control that says the machine did not move

The repository's pre-existing Scala-only benchmarks contain no Flix code, so they
should not have changed at all. They did not:

| benchmark | before | after | delta |
|---|---:|---:|---:|
| `BitOpsTest.testRead` | 150.692 ± 0.897 | 149.905 ± 0.562 | -0.5% |
| `HuffmanPgnBench.decode` | 3,988.103 ± 22.083 | 4,127.937 ± 41.071 | +3.5% |
| `HuffmanPgnBench.encode` | 3,396.774 ± 27.551 | 3,450.278 ± 118.242 | +1.6% |
| `LinearEstimateTest.testEncode` | 47.945 ± 0.240 | 47.407 ± 0.858 | -1.1% |
| `LowBitTruncTest.testEncode` | 28.407 ± 0.333 | 28.339 ± 0.207 | -0.2% |
| `OverallEncodingTest.testDecode` | 185.581 ± 1.077 | 178.919 ± 0.316 | -3.6% |
| `OverallEncodingTest.testEncode` | 118.221 ± 0.242 | 118.087 ± 0.303 | -0.1% |
| `VarIntEncodingTest.testDecode` | 130.130 ± 0.776 | 130.996 ± 2.580 | +0.7% |
| `VarIntEncodingTest.testEncode` | 58.299 ± 1.241 | 58.560 ± 0.147 | +0.4% |

Every row is within ±3.6% and the signs are mixed. **The machine is the same
machine**, so the 5x-to-parity change on the Flix rows is the code, not the box.
This is also why the `before` columns above can be quoted from a run three weeks
of work earlier without apology.

### What was actually changed

Full detail is in `flix/REWRITE.md` §5.8. In descending order of measured effect:

1. **`Bitboard.lsb`/`msb` call `java.lang.Long.numberOfTrailingZeros`** instead of
   `Int64.numberOfTrailingZeros`, which is a recursive per-bit scan. This is the
   same JVM call the Scala original makes.
2. **The tail-call thunk was removed from ~20 hot defs** with a trailing `; ()`.
   Flix compiles a call to a *different* def in tail position into a heap
   continuation dispatched through a megamorphic `invokeinterface`. Worth 2.1x on
   the clock codec alone.
3. **`Tables` became a `struct` and `Move` an `Int64`.** A 15-field single-case
   enum destructure materialises all fifteen fields on every read; the packed
   `Move` deleted the last per-move heap object.
4. **The SAN matcher was rewritten flat and allocation-free**, which is where game
   encode passed Scala. It is fuzz-checked against `java.util.regex` running the
   Scala original's own pattern on 679 045 inputs.
5. **`Bits.ushr`/`ushrL` became branchless**, removing a ~50%-mispredicting branch
   from the innermost magic-bitboard lookup.
6. **~124 `@Inline` annotations** on leaf accessors, plus the boxing conversions
   (`Int64.truncateToInt32` and friends are `Long.valueOf(x).intValue()`) replaced
   by pure `java.lang` statics.

Two changes were built, measured, and **reverted** because they lost: splitting
`BitReader.readBits`/`BitWriter.writeBits` into fast and slow paths (10% *worse*
on clock decode even after the thunk was fixed), and short-circuiting
`Board.isAttacked` (unmeasurable). Both are recorded at their sites in the source
so they are not re-attempted.

### Caveats, in the order they would mislead you

- **Game decode short and median are not a tie, they are a small loss.** 1.017x
  and 1.018x, consistent across both forks (1.017/1.017 and 1.015/1.022). The
  error bars on the short band overlap, but the sign does not move, so the honest
  reading is "within about 2% and on the slow side", not "matched".
- **Game encode long has one bad fork on the *Scala* side.** Its two forks give
  0.837x and 0.921x, because Scala's fork 1 drifted from 652 to 717 us mid-run
  while Flix stayed at 583-590. The aggregate 0.877x is therefore softer than it
  looks; the conservative reading of that row is ~0.92x. Even comparing Flix's
  worst iteration (591.8) against Scala's best (638.1), Flix is still ahead.
- **The clock ratios are an upper bound on the real gap.** At 36-183 ns/op the
  JMH loop's own overhead is a meaningful share of the number, and no one has
  fixed that harness across three rounds of work. Clock is the worst ratio in the
  repository *and* the least trustworthy measurement in it. Anyone optimising it
  should re-measure with `-bm ss` or a 100x coarser workload first.
- **This is still not a language benchmark.** Both halves run on the same JVM and
  JIT. What changed is the shape of the Flix code, not Flix.
- **The comparison is now unfair in the port's favour in one respect.** The Scala
  side is untouched, decade-old, and was never given the same optimisation pass.
  The claim being made is "this port is faster than the reference implementation
  it copies", not "Flix is faster than Scala".
- **Allocation on the decode path is still 2.3-3.1x** and the clock decode long
  row is still 3.3x. The campaign did not finish; it ran out of the things that
  were both safe and measurable.

### Raw JMH output

`benchmarks/run-optimised/{timing,alloc,coldstart,scala-legacy}.{json,log}` is the
unedited `-rf json` output plus the console log of each phase, including every
individual fork and iteration behind the aggregates above, and `env.txt` records
the machine. `benchmarks/run-hw/` holds the same four phases for the baseline.
