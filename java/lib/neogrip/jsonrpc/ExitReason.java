package neogrip.jsonrpc;

/**
 * Why the read loop ended; the library never calls System.exit - it reports,
 * and {@code main} decides.
 */
public enum ExitReason {
    /** Stdin reached EOF, or the client asked the server to stop. */
    STOPPED(0),

    /** A handler refused fatally - a protocol version nothing here speaks. */
    REFUSED(1);

    private final int code;

    ExitReason(int code) {
        this.code = code;
    }

    public int code() {
        return code;
    }
}
