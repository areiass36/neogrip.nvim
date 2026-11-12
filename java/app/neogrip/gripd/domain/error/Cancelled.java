package neogrip.gripd.domain.error;

/**
 * The work stopped because something cancelled it, not because it failed;
 * separate from {@link RequestRefused} because a cancelled statement is not an
 * error to show.
 */
public final class Cancelled extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public Cancelled(String message) {
        super(message);
    }
}
