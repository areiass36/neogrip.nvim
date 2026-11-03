package neogrip.db.errors;

/**
 * Nothing is open yet.
 *
 * Its own type, and its own message in one place, because it is the refusal
 * every operation gets for free by reading the connection through the accessor
 * rather than guarding for it.
 */
public final class NotConnected extends RequestRefused {
    private static final long serialVersionUID = 1L;

    public NotConnected() {
        super("not connected");
    }
}
