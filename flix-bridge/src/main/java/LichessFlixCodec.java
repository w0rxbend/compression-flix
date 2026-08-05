import org.lichess.compression.flix.FlixCodec;

/**
 * The unnamed-package half of the bridge: the only source file in this repository
 * that is allowed to name Flix's {@code Api} class.
 *
 * <p>It has to live in the unnamed package because that is where Flix 0.75.1 puts
 * {@code Api}, and no named-package source can refer to a type there. It is Java
 * rather than Scala because Scala cannot name unnamed-package types at all, in
 * either direction.
 *
 * <p><b>Every JDK type below is written out as {@code java.lang.X} on purpose.</b>
 * This file is compiled with the Flix jar on its classpath, and Flix emits classes
 * called {@code Object}, {@code String}, {@code Array}, {@code Map}, {@code Set},
 * {@code List}, {@code Option}, {@code Iterator}, {@code Assert} and ~135 more
 * into the unnamed package. For a source file that is <em>itself</em> in the
 * unnamed package those are in scope and outrank {@code java.lang}, so a bare
 * {@code String} here silently means Flix's {@code String}. A {@code main(String[])}
 * written that way compiles and then fails to launch, because the JVM is looking
 * for {@code main([Ljava/lang/String;)V}. Do not "tidy up" the qualifiers.
 *
 * <p>Going the other way is safe and needs no qualification: this file imports
 * {@link FlixCodec} from a named package normally.
 *
 * <p>There is no logic here. Every method is one call into {@code Api} plus the
 * cast from {@code java.lang.Object} that the Flix export layer's type
 * restrictions force. Fidelity lives in the Flix modules.
 */
public final class LichessFlixCodec implements FlixCodec {

    /** Invoked reflectively by {@link FlixCodec#load()}; there is no other constructor. */
    public LichessFlixCodec() {}

    // ----------------------------------------------------------------- clock

    @Override
    public byte[] clockEncode(int[] centis, int startTime) {
        return (byte[]) Api.clockEncode(centis, startTime);
    }

    @Override
    public int[] clockDecode(byte[] bytes, int startTime) {
        return (int[]) Api.clockDecode(bytes, startTime);
    }

    // ------------------------------------------------------------------ game

    @Override
    public java.lang.Object newTables() {
        // The ignored int is there because Flix has no zero-argument exports.
        return Api.newTables(0);
    }

    @Override
    public byte[] gameEncode(java.lang.Object tables, java.lang.String[] pgnMoves) {
        // Flix returns a genuine null (not a sentinel) for unencodable SAN, so the
        // cast is null-safe and the null propagates to the caller unchanged.
        return (byte[]) Api.gameEncode(tables, pgnMoves);
    }

    @Override
    public java.lang.Object gameDecode(java.lang.Object tables, byte[] input, int plies) {
        return Api.gameDecode(tables, input, plies);
    }

    // ------------------------------------------------------ decode accessors

    @Override
    public java.lang.String[] resultPgnMoves(java.lang.Object result) {
        return (java.lang.String[]) Api.resultPgnMoves(result);
    }

    @Override
    public int resultHalfMoveClock(java.lang.Object result) {
        return Api.resultHalfMoveClock(result);
    }

    @Override
    public byte[] resultPositionHashes(java.lang.Object result) {
        return (byte[]) Api.resultPositionHashes(result);
    }

    @Override
    public java.lang.String resultLastUci(java.lang.Object result) {
        return (java.lang.String) Api.resultLastUci(result);
    }

    @Override
    public long resultCastlingRights(java.lang.Object result) {
        return Api.resultCastlingRights(result);
    }

    @Override
    public boolean resultTurn(java.lang.Object result) {
        return Api.resultTurn(result);
    }

    // ------------------------------------------- the rest of the decoded board

    @Override
    public long resultPawns(java.lang.Object result) {
        return Api.resultPawns(result);
    }

    @Override
    public long resultKnights(java.lang.Object result) {
        return Api.resultKnights(result);
    }

    @Override
    public long resultBishops(java.lang.Object result) {
        return Api.resultBishops(result);
    }

    @Override
    public long resultRooks(java.lang.Object result) {
        return Api.resultRooks(result);
    }

    @Override
    public long resultQueens(java.lang.Object result) {
        return Api.resultQueens(result);
    }

    @Override
    public long resultKings(java.lang.Object result) {
        return Api.resultKings(result);
    }

    @Override
    public long resultWhite(java.lang.Object result) {
        return Api.resultWhite(result);
    }

    @Override
    public long resultBlack(java.lang.Object result) {
        return Api.resultBlack(result);
    }

    @Override
    public long resultOccupied(java.lang.Object result) {
        return Api.resultOccupied(result);
    }

    @Override
    public int resultEpSquare(java.lang.Object result) {
        return Api.resultEpSquare(result);
    }

    @Override
    public int resultIncrementalHash(java.lang.Object result) {
        return Api.resultIncrementalHash(result);
    }

    @Override
    public boolean resultInto(java.lang.Object result, long[] longs, java.lang.Object[] refs) {
        return Api.resultInto(result, longs, refs);
    }
}
