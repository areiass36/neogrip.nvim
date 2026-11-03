package neogrip.gripd.domain.error;

/**
 * The work stopped because something cancelled it, not because it failed.
 *
 * Separate from {@link RequestRefused} because the editor reads it
 * differently: a cancelled statement is not an error to show, it is a thing
 * the user asked for.
 */
public final class Cancelled extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public Cancelled(String message) {
        super(message);
    }
}
