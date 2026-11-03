package neogrip.gripd.domain.error;

/**
 * The work against the database failed.
 *
 * Unchecked, and the reason is the signatures above it: a checked
 * SQLException made every caller up to the handler declare it, so a method
 * whose job is to answer a request was declaring a JDBC detail, and the layer
 * that owns the wire could not be reached without naming the driver's
 * exception type.
 *
 * The cause is kept because the editor wants what is inside it - the SQLState,
 * the vendor's own code and, on PostgreSQL, the character position of the
 * problem.
 */
public final class DataAccessException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public DataAccessException(Throwable cause) {
        super(cause.getMessage(), cause);
    }
}
