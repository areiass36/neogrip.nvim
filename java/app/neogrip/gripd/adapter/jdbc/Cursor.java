package neogrip.gripd.adapter.jdbc;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import neogrip.gripd.contract.Contracts.Column;
import neogrip.gripd.contract.Contracts.QueryPage;

/**
 * One open result: the statement, its ResultSet and everything needed to hand
 * out the next batch of rows without running the query again (ADR-0031).
 * With autocommit on (ADR-0013) every driver in play materialises or buffers
 * the whole result, so the row count handed to the statement before execution
 * is the only lever over memory; when the window drains, refill() re-executes
 * and skips what was delivered - ADR-0014 paging, once per window. Not
 * thread-safe by design: every call arrives under the session lock Database holds.
 */
final class Cursor {
    /** Rows handed out per execution before a refill is needed. */
    static final int WINDOW = 1000;

    private final Connection connection;
    private final Running running;
    private final String sql;
    private final int timeoutSeconds;
    private final int fetchSize;

    private Statement statement;
    private boolean hasRows;
    private ResultSet rows;
    private ResultSetMetaData meta;
    private int columnCount;
    private Documents documents;

    /** Mutated while reading a document result, which grows its own columns. */
    private final List<String> names = new ArrayList<>();
    private final List<String> types = new ArrayList<>();
    private final List<String> tables = new ArrayList<>();
    private final List<String> schemas = new ArrayList<>();

    /** Read to learn whether another row exists, delivered in the next batch. */
    private List<Object> pending;
    private long delivered;
    /** Rows read from the current execution, which is what the cap limits. */
    private long fetched;
    /** Rows the current execution was allowed; 0 when it was given no limit. */
    private long cap;
    /** How many column names the client has been told about. */
    private int announced;
    private long touchedAt = System.currentTimeMillis();
    /** Told before each execution of this statement, refills included. */
    private final Started started;

    private Cursor(Connection connection, Running running, String sql,
            int timeoutSeconds, int fetchSize, Started started) {
        this.connection = connection;
        this.running = running;
        this.sql = sql;
        this.timeoutSeconds = timeoutSeconds;
        this.fetchSize = fetchSize;
        this.started = started;
    }

    /**
     * Run the statement and describe its result. Refusing the statement and
     * timing it belong to the caller; this only opens.
     *
     * @param limit     rows the first batch will ask for, which is also what
     *                  tells this apart from "everything": zero caps nothing.
     * @param continuable whether the client named this result and may ask for
     *                  more of it, which is what decides the opening window.
     * @param started   told immediately before the statement runs, and again
     *                  before every refill (ADR-0042).
     * @return a cursor holding the statement, whether or not it had rows; the
     *         caller asks hasRows() and closes either way.
     */
    static Cursor open(Connection connection, Running running, String sql,
            int limit, int timeoutSeconds, boolean continuable, Started started) throws SQLException {
        int fetchSize = limit > 0 ? Math.min(limit + 1, 1000) : 1000;
        Cursor cursor = new Cursor(connection, running, sql, timeoutSeconds, fetchSize, started);
        Statement statement =
                connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
        cursor.statement = statement;
        running.set(statement);
        // A continuable result opens with the whole window; see doc/internals.md#runner-and-execute.
        // A result that cannot be continued keeps the narrow cap, so nothing pulls a thousand
        // rows to show five.
        int opening = limit <= 0 ? 0 : continuable ? Math.max(limit, WINDOW) + 1 : limit + 1;
        cursor.prepare(statement, opening, opening);

        // The clock the reader watches starts here, last before the blocking call (ADR-0042).
        started.now();
        if (statement.execute(sql)) {
            cursor.hasRows = true;
            cursor.rows = statement.getResultSet();
            cursor.describe();
        }
        return cursor;
    }

    /** Did the statement answer with rows, or with an update count? */
    boolean hasRows() {
        return hasRows;
    }

    /** The update count of a statement that produced no result set. */
    int updateCount() throws SQLException {
        return statement.getUpdateCount();
    }

    /**
     * @param maxRows what the server is asked for. The cap this leaves behind
     *                counts rows of this execution the cursor will actually
     *                read, which after a refill is fewer than maxRows: the
     *                skipped rows are read and thrown away first.
     */
    private void prepare(Statement target, int maxRows, long rowCap) {
        cap = rowCap;
        fetched = 0;
        if (timeoutSeconds > 0) {
            Drivers.tolerate(() -> target.setQueryTimeout(timeoutSeconds));
        }
        if (maxRows > 0) {
            // setMaxRows beats rewriting the statement with a LIMIT the dialect may spell
            // differently (ADR-0014).
            Drivers.tolerate(() -> target.setMaxRows(maxRows));
        }
        Drivers.tolerate(() -> target.setFetchSize(fetchSize));
    }

    private void describe() throws SQLException {
        meta = rows.getMetaData();
        columnCount = meta.getColumnCount();

        // The MongoDB driver answers one document column; see doc/internals.md#jdbc-drivers.
        documents = Documents.detect(meta, columnCount);
        if (documents != null) {
            return;
        }
        for (int i = 1; i <= columnCount; i++) {
            final int column = i;
            names.add(meta.getColumnLabel(i));
            types.add(Values.typeName(meta, i));
            // Where each column came from: a foreign key in a result is only useful if the
            // editor knows which table the value is a key into.
            tables.add(optional(() -> meta.getTableName(column)));
            schemas.add(optional(() -> meta.getSchemaName(column)));
        }
    }

    /**
     * The next rows, at most `limit` of them. Zero means everything, and is
     * also the only way a result finishes inside a single call.
     */
    QueryPage batch(String hash, int limit, long start) throws SQLException {
        touchedAt = System.currentTimeMillis();
        running.set(statement);
        List<List<Object>> collected = new ArrayList<>();
        try {
            if (pending != null) {
                collected.add(pending);
                pending = null;
                delivered++;
            }
            while ((limit <= 0 || collected.size() < limit) && advance()) {
                collected.add(read());
                delivered++;
            }

            boolean done = limit <= 0 || !peek();
            if (documents != null) {
                // A field missing from an earlier document is filled in once later ones reveal it.
                documents.pad(collected, names.size());
            }
            return new QueryPage(hash, announce(), collected, done, System.currentTimeMillis() - start);
        } finally {
            running.clearIf(statement);
        }
    }

    /**
     * Columns the client has not seen yet. A tabular result announces them
     * once; a document result announces again whenever reading revealed a new
     * field, because its column list is discovered rather than described.
     *
     * @return null when the client already knows them, so the field is left
     *         out of the response entirely
     */
    private List<Column> announce() {
        if (announced > 0 && announced == names.size()) {
            return null;
        }
        List<Column> columns = new ArrayList<>(names.size());
        for (int i = 0; i < names.size(); i++) {
            columns.add(new Column(
                    names.get(i),
                    types.get(i),
                    i < tables.size() ? tables.get(i) : null,
                    i < schemas.size() ? schemas.get(i) : null));
        }
        announced = names.size();
        return columns;
    }

    /**
     * Move onto the next row, refilling mid-batch so the batch that straddles
     * the window stays full instead of carrying the old execution's leftover row.
     *
     * @return false when there is no next row anywhere
     */
    private boolean advance() throws SQLException {
        if (rows.next()) {
            fetched++;
            return true;
        }
        // Short of the cap the table is over; at the cap, only this execution is.
        if (cap <= 0 || fetched < cap) {
            return false;
        }
        return refill();
    }

    /**
     * Is there another row? JDBC cannot be asked without consuming, so the row
     * read here is kept and delivered at the head of the next batch.
     */
    private boolean peek() throws SQLException {
        if (pending != null) {
            return true;
        }
        if (!advance()) {
            return false;
        }
        pending = read();
        return true;
    }

    /**
     * Run the same statement again, skipping what was already delivered
     * (ADR-0014 paging, paid once per window); only ever called with nothing
     * pending, which is what makes `delivered` the right number to skip.
     *
     * @return whether the re-execution still had rows to hand out
     */
    private boolean refill() throws SQLException {
        long skip = delivered;
        closeStatement();
        statement = connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
        running.set(statement);
        prepare(statement, (int) Math.min(Integer.MAX_VALUE, skip + WINDOW + 1), WINDOW + 1);
        // Another execution of the same statement, announced like the first (ADR-0042).
        started.now();
        rows = statement.executeQuery(sql);
        for (long i = 0; i < skip; i++) {
            if (!rows.next()) {
                // The table lost rows between the two executions - the cost ADR-0014 documents.
                return false;
            }
        }
        if (!rows.next()) {
            return false;
        }
        fetched = 1;
        return true;
    }

    private List<Object> read() throws SQLException {
        if (documents != null) {
            return documents.row(rows, names, types);
        }
        List<Object> row = new ArrayList<>(columnCount);
        for (int i = 1; i <= columnCount; i++) {
            row.add(Values.read(rows, meta, i));
        }
        return row;
    }

    long touchedAt() {
        return touchedAt;
    }

    /** Stop a fetch in flight. Safe from another thread, which is the point. */
    void interrupt() {
        Statement target = statement;
        if (target != null) {
            Drivers.tolerate(target::cancel);
        }
    }

    void close() {
        closeStatement();
    }

    private void closeStatement() {
        ResultSet open = rows;
        Statement target = statement;
        rows = null;
        if (open != null) {
            Drivers.tolerate(open::close);
        }
        if (target != null) {
            running.clearIf(target);
            Drivers.tolerate(target::close);
        }
    }

    /**
     * Read something JDBC describes as optional; see doc/internals.md#jdbc-drivers.
     *
     * @return null for a value that is absent, empty or unreadable, so the
     *         record leaves the field out instead of carrying an empty name
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
}
