package neogrip.db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.db.types.Types.QueryPage;
import neogrip.db.types.Types.UpdateResult;

/** Running statements, and turning their results into the wire records. */
public final class Statements {
    private final Connection connection;
    private final AtomicReference<Statement> running;
    private final ReadonlyGuard guard;
    private final Cursors cursors;

    public Statements(Connection connection, AtomicReference<Statement> running, ReadonlyGuard guard,
            Cursors cursors) {
        this.connection = connection;
        this.running = running;
        this.guard = guard;
        this.cursors = cursors;
    }

    /**
     * Open a result and answer its first batch (ADR-0031).
     *
     * @param hash  the name the client gave this result, under which the
     *              cursor is kept so the client can continue it. Without one,
     *              nothing is kept and `done` only reports whether more rows
     *              exist - which is what a client that never continues wants.
     * @param limit rows in this batch, 0 for everything in one answer.
     * @return a QueryPage, or an UpdateResult for a statement with no rows.
     */
    public Object query(String hash, String sql, int limit, int timeoutSeconds) throws SQLException {
        guard.refuseWrites(sql);
        long start = System.currentTimeMillis();
        boolean named = hash != null && !hash.isEmpty();
        Cursor cursor = Cursor.open(connection, running, sql, limit, timeoutSeconds, named);
        // Registration is tracked rather than inferred from `named`: a hash
        // that is already live is refused, and detaching it on the way out
        // would then take somebody else's cursor out of the registry without
        // closing it - a leak caused by the client bug that was refused.
        boolean registered = false;
        boolean keep = false;
        try {
            if (!cursor.hasRows()) {
                return new UpdateResult(cursor.updateCount(), System.currentTimeMillis() - start);
            }
            if (named) {
                // Registered before the first row is read, so a cancel naming
                // this hash can reach the statement while it is still running.
                cursors.keep(hash, cursor);
                registered = true;
            }
            QueryPage page = cursor.batch(hash, limit, start);
            keep = registered && !page.done();
            return page;
        } finally {
            if (!keep) {
                if (registered) {
                    cursors.detach(hash);
                }
                cursor.close();
            }
        }
    }

    /** The next batch of a result already open under this hash. */
    public QueryPage next(String hash, int limit) throws SQLException {
        return cursors.next(hash, limit);
    }

    public UpdateResult exec(String sql, int timeoutSeconds) throws SQLException {
        guard.refuseWrites(sql);
        long start = System.currentTimeMillis();
        try (Statement statement = connection.createStatement()) {
            running.set(statement);
            if (timeoutSeconds > 0) {
                tolerate(() -> statement.setQueryTimeout(timeoutSeconds));
            }
            boolean hasResult = statement.execute(sql);
            int updated = hasResult ? -1 : statement.getUpdateCount();
            return new UpdateResult(updated, System.currentTimeMillis() - start);
        } finally {
            running.set(null);
        }
    }

    /**
     * Check a statement without running it.
     *
     * Preparing it is enough: the driver sends the text to the server, which
     * parses it, resolves the names and describes the result. Syntax errors
     * and unknown columns come back here, and nothing is executed - no
     * rolled-back transaction, no triggers, none of the games the command line
     * clients needed.
     */
    public void validate(String sql) throws SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            running.set(statement);
            // Asking for the shape of the result forces the describe on the
            // drivers that would otherwise prepare lazily.
            try {
                statement.getMetaData();
            } catch (SQLException e) {
                // Some statements have no result shape (INSERT without
                // RETURNING); that is not a validation failure.
                if (!isShapeless(e)) {
                    throw e;
                }
            }
        } finally {
            running.set(null);
        }
    }

    /**
     * Apply a setting the driver may not have. Not every JDBC driver
     * implements every knob - MongoDB refuses setQueryTimeout outright - and
     * a missing one is no reason to fail the query.
     */
    static void tolerate(SqlAction action) {
        try {
            action.run();
        } catch (SQLException ignored) {
            // The driver does not support it; the query still runs.
        }
    }

    @FunctionalInterface
    interface SqlAction {
        void run() throws SQLException;
    }

    private static boolean isShapeless(SQLException e) {
        String message = e.getMessage() == null ? "" : e.getMessage().toLowerCase(Locale.ROOT);
        return message.contains("no results were returned")
                || message.contains("statement does not produce")
                || message.contains("not return a result set");
    }
}
