package neogrip.db.errors;

/**
 * A write on a read-only connection, stopped before it ran.
 *
 * Its own type rather than a refusal like any other, because the editor says
 * something different about it: the connection is marked read-only on purpose,
 * and nothing about the statement itself is wrong.
 */
public final class WriteRefused extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public WriteRefused(String message) {
        super(message);
    }
}
