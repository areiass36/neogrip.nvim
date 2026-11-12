package neogrip.gripd.domain.error;

/**
 * The request cannot be served as it was asked; deliberately transport-free,
 * so the package that executes SQL never imports the protocol - the
 * translation happens once, at the edge that owns the wire.
 */
public class RequestRefused extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public RequestRefused(String message) {
        super(message);
    }
}
