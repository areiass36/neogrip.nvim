package neogrip.db;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.db.types.Types.Column;
import neogrip.db.types.Types.QueryPage;

/**
 * One open result: the statement, its ResultSet and everything needed to hand
 * out the next batch of rows without running the query again (ADR-0031).
 *
 * The window is why this stays bounded. With autocommit on - the default,
 * ADR-0013 - every driver in play either materialises the whole result inside
 * the driver before executeQuery returns (PostgreSQL, MySQL) or buffers it as
 * it is read, so the row count handed to the statement before execution is the
 * only lever over how much memory arrives. 1001 is 1000 rows to hand out plus
 * one that reveals the table has more; when that drains, refill() re-executes
 * and skips what was already delivered, which is the whole of ADR-0014 paging
 * reduced to a once-per-window event - five pages at the default limit of 200.
 *
 * Whether the opening execution takes the window depends on whether the client
 * named the result. A named one can be continued, so it opens with the window
 * and the next pages come out of the rows already in hand. An unnamed one - a
 * table preview, a completion sample, a probe - asks for the batch and one row
 * more, exactly as before, because pulling 1000 rows to show 5 would be a
 * straight loss.
 *
 * Not thread-safe by design: every call arrives under the session lock
 * Database holds, because reading a ResultSet is touching the connection.
 */
final class Cursor {
    /** Rows handed out per execution before a refill is needed. */
    static final int WINDOW = 1000;

    private final Connection connection;
    private final AtomicReference<Statement> running;
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

    private Cursor(Connection connection, AtomicReference<Statement> running, String sql,
            int timeoutSeconds, int fetchSize) {
        this.connection = connection;
        this.running = running;
        this.sql = sql;
        this.timeoutSeconds = timeoutSeconds;
        this.fetchSize = fetchSize;
    }

    /**
     * Run the statement and describe its result. Refusing the statement and
     * timing it belong to the caller; this only opens.
     *
     * @param limit     rows the first batch will ask for, which is also what
     *                  tells this apart from "everything": zero caps nothing.
     * @param continuable whether the client named this result and may ask for
     *                  more of it, which is what decides the opening window.
     * @return a cursor holding the statement, whether or not it had rows; the
     *         caller asks hasRows() and closes either way.
     */
    static Cursor open(Connection connection, AtomicReference<Statement> running, String sql,
            int limit, int timeoutSeconds, boolean continuable) throws SQLException {
        int fetchSize = limit > 0 ? Math.min(limit + 1, 1000) : 1000;
        Cursor cursor = new Cursor(connection, running, sql, timeoutSeconds, fetchSize);
        Statement statement =
                connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
        cursor.statement = statement;
        running.set(statement);
        // A result that can be continued opens with the whole window, because
        // the alternative was measured and is much worse: asking for the batch
        // and one row more made the second page drain the execution and refill,
        // so an expensive statement was paid twice. On a Trino GROUP BY over a
        // Delta table: first page 226s, second page 236s. Opening with the
        // window instead, the same second page costs 4ms. One that cannot be
        // continued - a preview, a sample, a probe - keeps the narrow cap, so
        // nothing pulls a thousand rows to show five.
        int opening = limit <= 0 ? 0 : continuable ? Math.max(limit, WINDOW) + 1 : limit + 1;
        cursor.prepare(statement, opening, opening);

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
            Statements.tolerate(() -> target.setQueryTimeout(timeoutSeconds));
        }
        if (maxRows > 0) {
            // The driver asks the server for this many and no more, which beats
            // rewriting the statement with a LIMIT the dialect may spell
            // differently (ADR-0014).
            Statements.tolerate(() -> target.setMaxRows(maxRows));
        }
        Statements.tolerate(() -> target.setFetchSize(fetchSize));
    }

    private void describe() throws SQLException {
        meta = rows.getMetaData();
        columnCount = meta.getColumnCount();

        // The MongoDB driver answers with a single column holding a document;
        // the grid wants one column per field.
        documents = Documents.detect(meta, columnCount);
        if (documents != null) {
            return;
        }
        for (int i = 1; i <= columnCount; i++) {
            final int column = i;
            names.add(meta.getColumnLabel(i));
            types.add(Values.typeName(meta, i));
            // Where each column came from, which is what lets a cell be
            // followed back to the row it belongs to: a foreign key in a
            // result is only useful if the editor knows which table the value
            // is a key into. A document result has no tables to name.
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
                // A field missing from an earlier document has to be filled in
                // once the later ones have revealed it.
                documents.pad(collected, names.size());
            }
            return new QueryPage(hash, announce(), collected, done, System.currentTimeMillis() - start);
        } finally {
            running.compareAndSet(statement, null);
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
     * Move onto the next row, crossing into another execution when this one
     * has handed out its whole window. Refilling here rather than only at the
     * end of a batch is what keeps the batch that straddles the window a full
     * one instead of the single row left over from the old execution.
     *
     * @return false when there is no next row anywhere
     */
    private boolean advance() throws SQLException {
        if (rows.next()) {
            fetched++;
            return true;
        }
        // The result set ran out. Short of what this execution was allowed,
        // that is the end of the table; at the cap, only the end of this
        // execution, and the next one is given the window.
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
     * Run the same statement again, skipping what was already delivered, and
     * leave it positioned on the first row past the skip. This is ADR-0014
     * paging, now paid once per window instead of once per page.
     *
     * Only ever called with nothing pending, which is what makes `delivered`
     * the right number to skip: every row read so far has been handed out.
     *
     * @return whether the re-execution still had rows to hand out
     */
    private boolean refill() throws SQLException {
        long skip = delivered;
        closeStatement();
        statement = connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY);
        running.set(statement);
        prepare(statement, (int) Math.min(Integer.MAX_VALUE, skip + WINDOW + 1), WINDOW + 1);
        rows = statement.executeQuery(sql);
        for (long i = 0; i < skip; i++) {
            if (!rows.next()) {
                // The table lost rows between the two executions, which
                // ADR-0014 already documents as the cost of not holding one
                // cursor across the whole result.
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
            Statements.tolerate(target::cancel);
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
            Statements.tolerate(open::close);
        }
        if (target != null) {
            running.compareAndSet(target, null);
            Statements.tolerate(target::close);
        }
    }

    /**
     * Read something JDBC describes as optional, and treat it as optional.
     *
     * getTableName and getSchemaName are the cases this exists for: DuckDB
     * answers both with an empty string, SQLite names the table but has no
     * schema layer to name, an expression has no table to come from on any
     * engine, and some drivers throw rather than say so.
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
