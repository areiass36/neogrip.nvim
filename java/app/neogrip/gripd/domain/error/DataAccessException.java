package neogrip.gripd.domain.error;

/**
 * The work against the database failed; unchecked because a checked
 * SQLException made every caller up to the handler declare a JDBC detail, and
 * the cause is kept because the editor wants the SQLState and vendor code
 * inside it.
 */
public final class DataAccessException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    public DataAccessException(Throwable cause) {
        super(cause.getMessage(), cause);
    }
}
