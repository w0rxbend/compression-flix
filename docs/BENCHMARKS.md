# Benchmarks: Flix port versus the original Scala

Both implementations are measured in the same JVM, in the same run, on the same
inputs, with byte-equality asserted in `@Setup` so a fork that returns a wrong
answer dies instead of publishing a fast number.

The harness lives in the full port repository, which keeps the original Scala
implementation alongside the Flix one so the two can be measured together:
<https://github.com/w0rxbend/compression> (`bash scripts/run-benchmarks.sh`).
This file is the resulting report; the raw JMH JSON and per-fork logs are
committed there under `benchmarks/run-hw/`.

## Summary

| | Flix / Scala |
|---|---|
| Game codec throughput | **~5x slower** |
| Clock codec throughput | **~3-4x slower** |
| Game decode allocation | **79-95x more** |
| Game encode allocation | **~25x more** |
| Cold start | **172 ms vs 69 ms** |

The port produces byte-identical output. What it costs is throughput and, far
more sharply, allocation.

## Full results, 2026-08-04

Produced in one sitting by `bash scripts/run-benchmarks.sh`, which records the
machine, runs every phase, and writes JMH's own JSON. Raw output is committed
under `benchmarks/run-hw/`; every number below is derived from it by script, not
transcribed.

### Machine and toolchain

| | |
|---|---|
| CPU | `AMD Ryzen 7 5700X 8-Core Processor` |
| Cores | `16 logical` |
| Memory | `62 GiB total, 29 GiB available` |
| CPU governor | `performance` |
| Kernel | `Linux 7.1.5-1-cachyos x86_64 GNU/Linux` |
| JVM | Oracle GraalVM 25.0.3+9.1 (`25.0.3+9-LTS-jvmci-b01`), **Graal JIT** (`-XX:+EnableJVMCIProduct`, inherited) |
| Flix | `The Flix Programming Language 0.75.1` |
| Commit | `06d5517 (2 files dirty)` |
| JMH | 1.37, `-t 1` (single-threaded) |
| Load average | 3.1 before the first phase, 3.2-3.8 throughout — **not an idle machine**, see caveats |

### Throughput

`-f 2 -wi 5 -w 2s -i 5 -r 2s -t 1`, average time per operation. Both
implementations run in the same JVM, in the same run, on the same inputs.
`FlixGameBench`'s `@Setup` byte-compares them first, so a fork that disagrees
dies rather than publishing a fast wrong number.

**Game codec (us/op)**

| operation | band | Scala | Flix | **Flix / Scala** |
|---|---|---:|---:|---:|
| encode | short | 154.316 ± 1.623 | 817.131 ± 4.438 | **5.30x** |
| encode | median | 321.916 ± 3.712 | 1,636.166 ± 144.939 | **5.08x** |
| encode | long | 637.098 ± 11.744 | 3,235.431 ± 18.143 | **5.08x** |
| decode | short | 187.169 ± 1.835 | 1,006.194 ± 6.632 | **5.38x** |
| decode | median | 409.446 ± 3.402 | 1,931.642 ± 34.007 | **4.72x** |
| decode | long | 723.921 ± 12.858 | 3,597.366 ± 86.626 | **4.97x** |

**Clock codec (ns/op)**

| operation | band | Scala | Flix | **Flix / Scala** |
|---|---|---:|---:|---:|
| encode | short | 36.940 ± 1.354 | 160.732 ± 7.025 | **4.35x** |
| encode | median | 63.779 ± 2.125 | 282.462 ± 10.670 | **4.43x** |
| encode | long | 118.354 ± 0.321 | 501.693 ± 5.274 | **4.24x** |
| decode | short | 56.228 ± 0.268 | 163.882 ± 16.847 | **2.91x** |
| decode | median | 96.544 ± 0.349 | 265.037 ± 2.303 | **2.75x** |
| decode | long | 180.303 ± 2.538 | 717.496 ± 13.206 | **3.98x** |

### Allocation

`-prof gc`, bytes allocated per operation. This is where the gap is widest, and
throughput alone hides it.

| benchmark | operation | band | Scala B/op | Flix B/op | **ratio** |
|---|---|---|---:|---:|---:|
| Game | encode | short | 109,082 | 2,777,033 | **25.5x** |
| Game | encode | median | 216,417 | 5,824,597 | **26.9x** |
| Game | encode | long | 457,370 | 11,253,503 | **24.6x** |
| Game | decode | short | 35,410 | 3,361,388 | **94.9x** |
| Game | decode | median | 66,481 | 5,586,903 | **84.0x** |
| Game | decode | long | 130,843 | 10,317,178 | **78.9x** |
| Clock | encode | short | 136 | 888 | **6.5x** |
| Clock | encode | median | 176 | 1,504 | **8.5x** |
| Clock | encode | long | 256 | 2,593 | **10.1x** |
| Clock | decode | short | 128 | 1,248 | **9.7x** |
| Clock | decode | median | 160 | 2,176 | **13.6x** |
| Clock | decode | long | 216 | 5,608 | **26.0x** |

### Cold start

`-f 20 -wi 0 -i 1 -bm ss` — 20 forks, one shot each, no warmup. Separate classes
so neither implementation warms the JVM for the other.

| | ms/op | median | min | max | sd |
|---|---:|---:|---:|---:|---:|
| `ColdStartFlixBench.firstEncode` | **172.3 ± 2.9** | 171.5 | 165.5 | 180.4 | 3.4 |
| `ColdStartScalaBench.firstEncode` | **69.1 ± 1.4** | 69.0 | 66.7 | 74.7 | 1.6 |

### The repository's original Scala-only benchmarks, re-run here

`-f 1 -wi 3 -i 5 -t 1`. These are the benchmarks that predate the port. The
historical numbers at the top of this file never recorded which machine or JVM
produced them, which is why `REWRITE.md` lists them as not reproducible. These do.

| benchmark | this machine | historical (unknown hardware) | delta |
|---|---:|---:|---:|
| `BitOpsTest.testRead` | 150.692 ± 0.897 | 111.510 | +35% |
| `HuffmanPgnBench.decode` | 3,988.103 ± 22.083 | 3,016.751 | +32% |
| `HuffmanPgnBench.encode` | 3,396.774 ± 27.551 | 2,858.993 | +19% |
| `LinearEstimateTest.testEncode` | 47.945 ± 0.240 | 33.365 | +44% |
| `LowBitTruncTest.testEncode` | 28.407 ± 0.333 | 17.888 | +59% |
| `OverallEncodingTest.testDecode` | 185.581 ± 1.077 | 131.078 | +42% |
| `OverallEncodingTest.testEncode` | 118.221 ± 0.242 | 161.584 | -27% |
| `VarIntEncodingTest.testDecode` | 130.130 ± 0.776 | 84.395 | +54% |
| `VarIntEncodingTest.testEncode` | 58.299 ± 1.241 | 115.358 | -49% |

Units are ns/op except the two `HuffmanPgnBench` rows, which are us/op.

### What reproduces, and what does not

**The Flix/Scala ratios reproduce; the absolute numbers do not.** Against the
2026-08-03 run in the section above, on the same hardware but a busier machine:

| row | 2026-08-03 | this run |
|---|---:|---:|
| game encode, short | 5.32x | 5.30x |
| game decode, long | 4.93x | 4.97x |
| clock encode, short | 4.20x | 4.35x |
| clock decode, median | 2.74x | 2.75x |

That is the result worth carrying: **the port costs roughly 5x on the game codec
and 3-4x on the clock codec**, and that multiple is stable across runs even when
the underlying timings move. Ratios cancel machine noise; absolutes do not.

**Cold start regressed on the Flix side and only on the Flix side.** 107.6 ms on
2026-08-03 against 172.3 ms here, while Scala barely moved (67.4 -> 69.1 ms). The
distributions are tight — sd 3.4 and 1.6 over 20 forks each — so this is not
noise, and a machine-wide slowdown would have moved the Scala row too. The
likely cause is the G3 work, which added eleven `@Export`s and a drop-in `Board`,
so `Api` class initialisation now pulls in more code. **That is a hypothesis, not
a measurement** — confirming it means bisecting between `f9427ce` and `06d5517`,
which has not been done.

**The historical Scala-only numbers are 19-59% faster than this machine produces
on most rows, and slower on two.** The mixed direction rules out a simple
"this machine is slower" explanation and is consistent with different hardware,
a different JVM, or both — which is exactly the problem, since those numbers
recorded neither. The table above supersedes them for any future comparison.

### Caveats

- **The machine was not idle.** Load average ran 3.1-3.8 for the whole sweep.
  With 16 logical cores and `-t 1` the contention is modest, but it is not zero;
  treat the absolute figures as good to roughly ±10% and rely on the ratios.
  A quiet machine would tighten them.
- **This is not a language benchmark.** Flix compiles to JVM bytecode and runs on
  the same JIT as the Scala. What is being measured is the shape the port was
  forced into — region allocation, struct copying in `Board.copy`, tables threaded
  as parameters instead of static finals — not Flix as a language. A differently
  written Flix port would score differently.
- **The comparison is fair in the ways that matter and unfair in one.** Same JVM,
  same run, same inputs, byte-equality asserted before measuring. But the Scala
  side is a decade-tuned implementation and the Flix side is a first port with no
  optimisation pass; `REWRITE.md` section 5.8 lists three optimisations that were
  measured and deliberately not applied.
- **The JVM identity matters more than it looks.** `REWRITE.md` section 5.7
  measured the JIT alone moving a single score by 2x — Temurin 25.0.3 gives
  `OverallEncodingTest.testEncode` at 230.803 ns/op where GraalVM 25.0.3 gives
  117.703, and this run's 118.221 lands on the GraalVM figure. "Java 25" is
  therefore not enough to identify a result; the VM name and JVMCI state are.
  This run and the 2026-08-03 one above used the same GraalVM build on the same
  machine, which is what makes comparing them meaningful.
- `benchmarks/run-hw/*.log` holds the full JMH console output for each phase,
  including the per-fork detail behind every aggregate above.
