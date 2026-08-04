package org.lichess.compression.flix;

/**
 * The narrow, typed seam between JVM code in a named package and the Flix port.
 *
 * <h2>Why this interface has to exist</h2>
 *
 * Flix 0.75.1 emits every class into the <em>unnamed (default) package</em>. The
 * {@code @Export}ed entry points therefore live on a class literally called
 * {@code Api} with no package at all, and two independent JVM rules make that
 * unreachable from the Scala facade:
 *
 * <ol>
 *   <li>Neither Java nor Scala source in a <em>named</em> package can refer to a
 *       type in the unnamed package. There is no syntax for it and no import is
 *       permitted (JLS 7.5). Scala reports
 *       {@code Not found: FlixBridge} for such a reference.</li>
 *   <li>Independently, Flix emits a <em>directory</em> alongside every module
 *       class — {@code Api.class} <em>and</em> {@code Api/Def$gameEncode.class}.
 *       Scala's classpath scanner sees {@code Api} as a package, which wins over
 *       the class, so even {@code _root_.Api.newTables} fails with
 *       {@code value newTables is not a member of Api}. The same is true of
 *       {@code Object}, {@code String}, {@code Array}, {@code List}, {@code Map},
 *       {@code Set}, {@code Option} and {@code Iterator}, all of which Flix emits
 *       as both a class and a package — which is, by luck rather than design, why
 *       Scala sources compiled against the raw Flix jar are <em>not</em> shadowed
 *       the way Java sources are: the package interpretation wins, and name
 *       resolution falls through to {@code scala.*} / {@code java.lang.*}.</li>
 * </ol>
 *
 * Java, by contrast, resolves an unqualified {@code Api} to the class and can
 * call it — but only from the unnamed package, and a Java file compiled there
 * <em>is</em> exposed to hazard (2): unqualified {@code String} in such a file
 * binds to Flix's {@code String}. That is why the implementation of this
 * interface is written in Java, lives in the unnamed package, and spells every
 * JDK type out in full as {@code java.lang.String} / {@code java.lang.Object}.
 *
 * <h2>The shape that results</h2>
 *
 * The implementation class {@code LichessFlixCodec} is loaded once by name
 * through {@link #load()}. After that single reflective step, every call is an
 * ordinary {@code invokeinterface} — no per-call reflection, no method handles,
 * and no shading of the Flix jar.
 *
 * <p>All array parameters and results are the JVM arrays the Flix layer produces
 * directly: {@code Array[Int8, Static]} is a {@code byte[]},
 * {@code Array[Int32, Static]} an {@code int[]}, {@code Array[String, Static]} a
 * {@code java.lang.String[]}. Nothing is copied on the way across.
 *
 * <p>The {@code tables} and {@code result} values are opaque handles onto Flix
 * data structures. Do not inspect them; pass them straight back.
 */
public interface FlixCodec {

    /** Fully qualified name of the unnamed-package implementation class. */
    java.lang.String IMPL_CLASS_NAME = "LichessFlixCodec";

    /**
     * Loads the unnamed-package implementation.
     *
     * <p>This is the only reflective operation in the whole facade, and it happens
     * once per process. Callers should cache the result — the Scala facade holds it
     * in a {@code lazy val}.
     *
     * @throws IllegalStateException if the Flix jar (or the compiled bridge) is not
     *                               on the classpath.
     */
    static FlixCodec load() {
        try {
            return (FlixCodec) java.lang.Class
                    .forName(IMPL_CLASS_NAME, true, FlixCodec.class.getClassLoader())
                    .getDeclaredConstructor()
                    .newInstance();
        } catch (java.lang.ReflectiveOperationException e) {
            throw new java.lang.IllegalStateException(
                    "Could not load " + IMPL_CLASS_NAME + "; is flix/artifact/flix.jar on the classpath?", e);
        }
    }

    // ----------------------------------------------------------------- clock

    /** {@code org.lichess.compression.clock.Encoder.encode}. Does not modify {@code centis}. */
    byte[] clockEncode(int[] centis, int startTime);

    /** {@code org.lichess.compression.clock.Encoder.decode}. Does not modify {@code bytes}. */
    int[] clockDecode(byte[] bytes, int startTime);

    // ------------------------------------------------------------------ game

    /**
     * Builds the attack tables, piece-square table, Zobrist keys and Huffman tree.
     * Costs ~100 ms; the result must be built once per process and reused.
     */
    java.lang.Object newTables();

    /** {@code org.lichess.compression.game.Encoder.encode}. Returns {@code null} for unencodable SAN. */
    byte[] gameEncode(java.lang.Object tables, java.lang.String[] pgnMoves);

    /** {@code org.lichess.compression.game.Encoder.decode}. Returns an opaque {@code DecodeResult} handle. */
    java.lang.Object gameDecode(java.lang.Object tables, byte[] input, int plies);

    // ------------------------------------------------------ decode accessors

    /** {@code DecodeResult.pgnMoves}. */
    java.lang.String[] resultPgnMoves(java.lang.Object result);

    /** {@code DecodeResult.halfMoveClock}. */
    int resultHalfMoveClock(java.lang.Object result);

    /** {@code DecodeResult.positionHashes}. */
    byte[] resultPositionHashes(java.lang.Object result);

    /** {@code DecodeResult.lastUci}, or {@code null} when zero plies were decoded. */
    java.lang.String resultLastUci(java.lang.Object result);

    /** {@code DecodeResult.board.castlingRights}. */
    long resultCastlingRights(java.lang.Object result);

    /** {@code DecodeResult.board.turn} — {@code true} when White is to move. */
    boolean resultTurn(java.lang.Object result);

    // ------------------------------------------- the rest of the decoded board
    //
    // The original's Board is a mutable object with thirteen public fields. It
    // cannot cross the Flix export boundary — an export may only mention
    // primitives and java.lang.Object — so the thirteen come across one scalar at
    // a time and the Scala facade reassembles them into an immutable snapshot.
    // Together with the two above, these are all of them.

    /** {@code DecodeResult.board.pawns}. */
    long resultPawns(java.lang.Object result);

    /** {@code DecodeResult.board.knights}. */
    long resultKnights(java.lang.Object result);

    /** {@code DecodeResult.board.bishops}. */
    long resultBishops(java.lang.Object result);

    /** {@code DecodeResult.board.rooks}. */
    long resultRooks(java.lang.Object result);

    /** {@code DecodeResult.board.queens}. */
    long resultQueens(java.lang.Object result);

    /** {@code DecodeResult.board.kings}. */
    long resultKings(java.lang.Object result);

    /** {@code DecodeResult.board.white}. */
    long resultWhite(java.lang.Object result);

    /** {@code DecodeResult.board.black}. */
    long resultBlack(java.lang.Object result);

    /** {@code DecodeResult.board.occupied} — {@code white | black}. */
    long resultOccupied(java.lang.Object result);

    /** {@code DecodeResult.board.epSquare}, or {@code 0} when there is none. */
    int resultEpSquare(java.lang.Object result);

    /** {@code DecodeResult.board.incrementalHash} — the full Polyglot Zobrist hash. */
    int resultIncrementalHash(java.lang.Object result);
}
