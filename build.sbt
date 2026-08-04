// Build wiring for the Scala/JVM facade over the Flix port.
//
// The Flix implementation itself is built by the `flix` CLI, not by sbt — this
// file exists so that JVM consumers can depend on the port through an ordinary
// Scala API. The Flix project is at the repository root (`flix.toml`, `src/`,
// `test/`), so `flix build-jar` writes into `artifact/` — under a name derived from
// the clone directory, which is why nothing below hardcodes it.
//
// Upstream (original Scala implementation): https://github.com/lichess-org/compression
// Full port repository (differential tests, perft sweep, benchmarks):
//   https://github.com/w0rxbend/compression

lazy val flixJar = taskKey[File]("Build the Flix jar in artifact/ via `flix build-jar`")

ThisBuild / flixJar := {
  val log     = streams.value.log
  val flixDir = (ThisBuild / baseDirectory).value
  val artDir  = flixDir / "artifact"

  val sources = Seq("src", "test").flatMap(d => Option((flixDir / d).listFiles).getOrElse(Array.empty[File]))
  val newest  = sources.filter(_.getName.endsWith(".flix")).map(_.lastModified).foldLeft(0L)(_ max _)

  // `flix build-jar` names its output after the *enclosing directory*, not after
  // `name` in flix.toml. A clone into `compression-flix/` produces
  // `artifact/compression-flix.jar`; a clone into `foo/` produces `artifact/foo.jar`.
  // Nothing may hardcode the name, so the jar is discovered instead.
  def built(): Option[File] =
    Option(artDir.listFiles)
      .getOrElse(Array.empty[File])
      .filter(f => f.getName.endsWith(".jar") && !f.getName.endsWith("-release.jar"))
      .sortBy(-_.lastModified)
      .headOption

  val stale = built().forall(j => newest > j.lastModified)
  if (stale) {
    log.info("Running `flix build-jar` in " + flixDir)
    // Flix writes ordinary progress to stderr, so the default ProcessLogger would
    // report a successful build as a wall of [error] lines. Both streams are
    // informational; the exit code is what decides.
    val toInfo = scala.sys.process.ProcessLogger(log.info(_), log.info(_))
    val rc     = scala.sys.process.Process("flix build-jar", flixDir).!(toInfo)
    if (rc != 0) sys.error(s"`flix build-jar` failed with exit code $rc")
  }

  built().getOrElse(sys.error(s"`flix build-jar` produced no jar in $artDir"))
}

// `flix build-jar` has no test scope: it compiles every `.flix` file in the
// project, so the @Test modules land in the artifact too. This produces a stripped
// copy for publishing. See docs/REWRITE.md section 5.4.
lazy val flixReleaseJar = taskKey[File]("A copy of the Flix jar with the @Test classes removed")

ThisBuild / flixReleaseJar := {
  val log    = streams.value.log
  val source = flixJar.value
  val target = source.getParentFile / (source.getName.stripSuffix(".jar") + "-release.jar")

  if (!target.exists || source.lastModified > target.lastModified) {
    IO.copyFile(source, target)
    // `zip -d` rewrites the archive in place. A prefix glob is used rather than an
    // enumerated list of module names: enumerating silently misses a module the
    // moment someone adds one (`TestClockEncoderSelf` was missed exactly that way).
    // Flix's own stdlib has one entry matching on a suffix, `Fs/Eff$FileTest.class`;
    // anchoring the pattern to the start of the entry name leaves it untouched.
    val rc = scala.sys.process.Process(Seq("zip", "-q", "-d", target.getAbsolutePath, "Test*")).!
    // zip exits 12 ("nothing to do") when nothing matched, which is legitimate.
    if (rc != 0 && rc != 12) sys.error(s"stripping test classes from $target failed with exit code $rc")
    log.info(f"$target: ${target.length / 1048576.0}%.1f MB (from ${source.length / 1048576.0}%.1f MB)")
  } else log.debug(s"$target is up to date")

  target
}

// Flix emits its standard library into the DEFAULT package, including classes
// literally named `Object`, `String`, `Map` and `Array`. Any Scala source compiled
// with the Flix jar on its classpath resolves unqualified `String` to Flix's class
// rather than `java.lang.String`. The jar is therefore removed from every *Scala
// compile* classpath and added back at runtime only.
// Filtered by LOCATION, not by name: the jar is named after the clone directory,
// so `_.data.getName == "flix.jar"` would silently stop filtering in a clone that
// happens to be called anything else — and the failure mode is a confusing
// type error about `String`, not a missing file.
def isFlixJar(f: File): Boolean =
  f.getName.endsWith(".jar") && f.getParentFile != null && f.getParentFile.getName == "artifact"

val hideFlixJar = Seq(
  Compile / dependencyClasspath := (Compile / dependencyClasspath).value.filterNot(a => isFlixJar(a.data)),
  Test / dependencyClasspath    := (Test / dependencyClasspath).value.filterNot(a => isFlixJar(a.data))
)

val commonSettings = Seq(
  scalacOptions := Seq(
    "-encoding",
    "utf-8",
    "-explaintypes",
    "-Wunused:all",
    "-feature",
    "-language:postfixOps",
    "-indent",
    "-source:future-migration",
    "-release:21"
  )
)

lazy val root = (project in file("."))
  .settings(
    name           := "compression-flix",
    organization   := "org.lichess",
    version        := "3.2.1",
    scalaVersion   := "3.8.2",
    publish / skip := true
  )
  .aggregate(flixBridge, scalaApi, scalaApiDropin, smoke)

// The Flix jar is kept on exactly one Java-only project's classpath, so no Scala
// source in this build is ever exposed to the default-package hazard. sbt does not
// export `unmanagedJars` to dependent projects, so `scalaApi` inherits the compiled
// bridge classes and not the hazard.
lazy val flixBridge = (project in file("flix-bridge"))
  .settings(
    name             := "compression-flix-bridge",
    organization     := "org.lichess",
    version          := "3.2.1",
    autoScalaLibrary := false,
    crossPaths       := false,
    javacOptions ++= Seq("-source", "21", "-target", "21"),
    Compile / unmanagedJars += Attributed.blank(flixJar.value)
  )

// The Scala facade over the Flix port.
lazy val scalaApi = (project in file("scala-api"))
  .settings(
    commonSettings,
    name         := "compression-flix-api",
    scalaVersion := "3.8.2",
    organization := "org.lichess",
    version      := "3.2.1",
    hideFlixJar,
    // The facade needs the Flix jar to *run*, never to compile.
    Runtime / unmanagedJars += Attributed.blank(flixJar.value)
  )
  .dependsOn(flixBridge)

// Drop-in aliases: `org.lichess.compression.{clock,game}.Encoder` under the
// original package names, so an existing caller does not change its imports. A
// separate artifact because these names collide with the original library's and
// nothing may have both on one classpath.
lazy val scalaApiDropin = (project in file("scala-api-dropin"))
  .settings(
    commonSettings,
    name         := "compression-flix-api-dropin",
    scalaVersion := "3.8.2",
    organization := "org.lichess",
    version      := "3.2.1",
    hideFlixJar
  )
  .dependsOn(scalaApi)

// A runnable end-to-end check that the facade works against a real Flix jar at
// RUNTIME. `compile` cannot catch a broken runtime classpath here: the Flix jar is
// deliberately kept off every Scala compile classpath (see `hideFlixJar`), so a
// wiring mistake type-checks and then fails with NoClassDefFoundError. Not
// published.
lazy val smoke = (project in file("smoke"))
  .settings(
    commonSettings,
    name           := "compression-flix-smoke",
    scalaVersion   := "3.8.2",
    publish / skip := true,
    hideFlixJar,
    Runtime / unmanagedJars += Attributed.blank(flixJar.value)
  )
  .dependsOn(scalaApi)
