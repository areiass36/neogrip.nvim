package neogrip.gripd.domain.error;

/**
 * A write on a read-only connection, stopped before it ran; its own type
 * because the editor says something different about it than about an error.
 */
public final class WriteRefused extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public WriteRefused(String message) {
        super(message);
    }
}
