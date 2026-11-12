package neogrip.gripd.domain.error;

/**
 * Nothing is open yet: the refusal every operation gets for free by reading
 * the connection through the accessor rather than guarding for it.
 */
public final class NotConnected extends RequestRefused {
    private static final long serialVersionUID = 1L;

    public NotConnected() {
        super("not connected");
    }
}
