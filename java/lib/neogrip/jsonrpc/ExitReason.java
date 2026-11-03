package neogrip.jsonrpc;

/**
 * Why the read loop ended, for the program that has to pick an exit code.
 *
 * The library does not call System.exit: killing the host process is not a
 * library's decision, and a server embedded in something larger would be
 * killing its host. It reports, and {@code main} decides.
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
