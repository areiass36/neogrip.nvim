package neogrip.db;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.db.types.Types.Column;
import neogrip.db.types.Types.QueryPage;
import neogrip.db.types.Types.UpdateResult;

/** Running statements, and turning their results into the wire's records. */
public final class Statements {
    private final Connection connection;
    private final AtomicReference<Statement> running;
    private final ReadonlyGuard guard;

    public Statements(Connection connection, AtomicReference<Statement> running, ReadonlyGuard guard) {
        this.connection = connection;
        this.running = running;
        this.guard = guard;
    }

    /**
     * @param limit rows to return, 0 for everything. One extra is fetched to
     *              learn whether another page exists, which is cheaper than a
     *              second count(*) query.
     * @return a QueryPage, or an UpdateResult for a statement with no rows.
     */
    public Object query(String sql, int limit, int offset, int timeoutSeconds) throws SQLException {
        guard.refuseWrites(sql);
        long start = System.currentTimeMillis();
        try (Statement statement =
                connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY)) {
            running.set(statement);
            if (timeoutSeconds > 0) {
                tolerate(() -> statement.setQueryTimeout(timeoutSeconds));
            }
            if (limit > 0) {
                // The driver asks the server for this many and no more, which
                // beats rewriting the statement with a LIMIT the dialect may
                // spell differently.
                tolerate(() -> statement.setMaxRows(limit + offset + 1));
                tolerate(() -> statement.setFetchSize(Math.min(limit + 1, 1000)));
            }

            boolean hasResult = statement.execute(sql);
            if (!hasResult) {
                return new UpdateResult(statement.getUpdateCount(), System.currentTimeMillis() - start);
            }
            try (ResultSet rows = statement.getResultSet()) {
                return page(rows, limit, offset, start);
            }
        } finally {
            running.set(null);
        }
    }

    private static QueryPage page(ResultSet rows, int limit, int offset, long start) throws SQLException {
        ResultSetMetaData meta = rows.getMetaData();
        int columnCount = meta.getColumnCount();

        // The MongoDB driver answers with a single column holding a document;
        // the grid wants one column per field.
        Documents documents = Documents.detect(meta, columnCount);

        List<String> names = new ArrayList<>();
        List<String> types = new ArrayList<>();
        // Where each column came from, which is what lets a cell be followed
        // back to the row it belongs to: a foreign key in a result is only
        // useful if the editor knows which table the value is a key into. A
        // document result has no tables, so these stay empty for one.
        List<String> tables = new ArrayList<>();
        List<String> schemas = new ArrayList<>();
        if (documents == null) {
            for (int i = 1; i <= columnCount; i++) {
                final int column = i;
                names.add(meta.getColumnLabel(i));
                types.add(Values.typeName(meta, i));
                tables.add(optional(() -> meta.getTableName(column)));
                schemas.add(optional(() -> meta.getSchemaName(column)));
            }
        }

        List<List<Object>> collected = new ArrayList<>();
        int skipped = 0;
        boolean hasMore = false;
        while (rows.next()) {
            if (skipped < offset) {
                skipped++;
                continue;
            }
            if (limit > 0 && collected.size() >= limit) {
                hasMore = true;
                break;
            }
            if (documents != null) {
                collected.add(documents.row(rows, names, types));
            } else {
                List<Object> row = new ArrayList<>(columnCount);
                for (int i = 1; i <= columnCount; i++) {
                    row.add(Values.read(rows, meta, i));
                }
                collected.add(row);
            }
        }

        if (documents != null) {
            // A field missing from an earlier document has to be filled in
            // once the later ones have revealed it.
            documents.pad(collected, names.size());
        }

        // Built after the rows: a document result's names keep growing while
        // the rows are read, so only now is the column list complete.
        List<Column> columns = new ArrayList<>(names.size());
        for (int i = 0; i < names.size(); i++) {
            columns.add(new Column(
                    names.get(i),
                    types.get(i),
                    i < tables.size() ? tables.get(i) : null,
                    i < schemas.size() ? schemas.get(i) : null));
        }
        return new QueryPage(columns, collected, hasMore, System.currentTimeMillis() - start);
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
     * implements every knob - MongoDB's refuses setQueryTimeout outright - and
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

    /**
     * Read something JDBC describes as optional, and treat it as optional.
     *
     * getTableName and getSchemaName are the cases this exists for: DuckDB
     * answers both with an empty string, SQLite names the table but has no
     * schema layer to name, an expression has no table to come from on any
     * engine, and some drivers throw rather than say so. A result the user
     * asked for still has to come back.
     *
     * @return null for a value that is absent, empty or unreadable, so the
     *         record leaves the field out instead of carrying an empty name.
     */
    private static String optional(SqlText source) {
        try {
            String value = source.get();
            return value == null || value.isEmpty() ? null : value;
        } catch (SQLException | RuntimeException unsupported) {
            return null;
        }
    }

    @FunctionalInterface
    private interface SqlText {
        String get() throws SQLException;
    }

    private static boolean isShapeless(SQLException e) {
        String message = e.getMessage() == null ? "" : e.getMessage().toLowerCase(Locale.ROOT);
        return message.contains("no results were returned")
                || message.contains("statement does not produce")
                || message.contains("not return a result set");
    }
}
