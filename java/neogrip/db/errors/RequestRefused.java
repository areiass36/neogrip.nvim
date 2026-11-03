package neogrip.db.errors;

/**
 * The request cannot be served as it was asked, and the message says why: a
 * result named twice, a sweep already running, a catalog that has no columns
 * to sweep.
 *
 * Unchecked and transport-free on purpose. Database code used to build the
 * JSON-RPC envelope's error code itself, which is how a package that executes
 * SQL came to import the protocol; the translation now happens once, at the
 * edge that owns the wire.
 */
public class RequestRefused extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public RequestRefused(String message) {
        super(message);
    }
}
