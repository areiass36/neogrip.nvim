package neogrip;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.UncheckedIOException;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.db.types.Types.Column;
import neogrip.db.types.Types.ExportResult;
import neogrip.db.types.Types.QueryPage;
import neogrip.db.types.Types.TxState;
import neogrip.db.types.Types.UpdateResult;
import neogrip.rpc.JsonCodec;
import neogrip.rpc.JsonStream;

/** Running statements, and turning their results into the wire's records. */
public final class Queries {
    private final Connection connection;
    private final AtomicReference<Statement> running;
    private final boolean readonly;

    public Queries(Connection connection, AtomicReference<Statement> running, boolean readonly) {
        this.connection = connection;
        this.running = running;
        this.readonly = readonly;
    }

    /** Thrown instead of running a write on a readonly connection (ADR-0016). */
    public static final class Refused extends RuntimeException {
        private static final long serialVersionUID = 1L;

        Refused(String message) {
            super(message);
        }
    }

    private static final Set<String> WRITE_KEYWORDS = Set.of(
            "insert", "update", "delete", "merge", "replace", "upsert",
            "create", "alter", "drop", "truncate", "grant", "revoke",
            "call", "exec", "execute");

    /**
     * The second readonly layer: the Lua classifier refuses first, this
     * catches what it missed, and setReadOnly - only a hint in some drivers -
     * is the third. A heuristic on the first keyword is enough for a layer
     * that only ever errs on the side of refusing.
     */
    private void refuseWrites(String sql) {
        if (!readonly) {
            return;
        }
        String text = stripLeadingComments(sql);
        int end = 0;
        while (end < text.length() && Character.isLetter(text.charAt(end))) end++;
        String keyword = text.substring(0, end).toLowerCase(Locale.ROOT);
        if (WRITE_KEYWORDS.contains(keyword)) {
            throw new Refused("the connection is read-only; refusing this " + keyword);
        }
    }

    /**
     * BEGIN, COMMIT and ROLLBACK are mapped to the JDBC calls rather than
     * passed through as text (ADR-0013): passing them through desynchronises
     * the driver's view of the transaction state. Only the plain spellings are
     * intercepted - BEGIN TRY, savepoints and anything else pass untouched.
     */
    public Optional<TxState> transaction(String sql) throws SQLException {
        String text = stripLeadingComments(sql).stripTrailing();
        if (text.endsWith(";")) {
            text = text.substring(0, text.length() - 1).stripTrailing();
        }
        String lower = text.toLowerCase(Locale.ROOT);
        boolean open;
        if (lower.equals("begin") || lower.equals("begin work") || lower.equals("begin tran")
                || lower.equals("begin transaction") || lower.equals("start transaction")) {
            connection.setAutoCommit(false);
            open = true;
        } else if (lower.equals("commit") || lower.equals("commit work") || lower.equals("commit tran")
                || lower.equals("commit transaction")) {
            connection.commit();
            connection.setAutoCommit(true);
            open = false;
        } else if (lower.equals("rollback") || lower.equals("rollback work") || lower.equals("rollback tran")
                || lower.equals("rollback transaction")) {
            connection.rollback();
            connection.setAutoCommit(true);
            open = false;
        } else {
            return Optional.empty();
        }
        return Optional.of(new TxState(open));
    }

    private static String stripLeadingComments(String sql) {
        String text = sql;
        while (true) {
            text = text.stripLeading();
            if (text.startsWith("--")) {
                int end = text.indexOf('\n');
                if (end < 0) return "";
                text = text.substring(end + 1);
            } else if (text.startsWith("/*")) {
                int end = text.indexOf("*/");
                if (end < 0) return "";
                text = text.substring(end + 2);
            } else {
                return text;
            }
        }
    }

    /** Is a transaction open on the shared connection? For the idle watchdog. */
    public boolean inTransaction() {
        try {
            return !connection.getAutoCommit();
        } catch (SQLException e) {
            return false;
        }
    }

    /** Roll an idle transaction back - never commit (ADR-0013). */
    public void rollbackIdle() throws SQLException {
        connection.rollback();
        connection.setAutoCommit(true);
    }

    /**
     * @param limit rows to return, 0 for everything. One extra is fetched to
     *              learn whether another page exists, which is cheaper than a
     *              second count(*) query.
     * @return a QueryPage, or an UpdateResult for a statement with no rows.
     */
    public Object query(String sql, int limit, int offset, int timeoutSeconds) throws SQLException {
        refuseWrites(sql);
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
        refuseWrites(sql);
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
    private static void tolerate(SqlAction action) {
        try {
            action.run();
        } catch (SQLException ignored) {
            // The driver does not support it; the query still runs.
        }
    }

    @FunctionalInterface
    private interface SqlAction {
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

    /**
     * Stream a result straight to a file - nothing held in memory - written
     * beside the target and atomically renamed into place, so a crashed export
     * never leaves a half file where the editor reads a finished one
     * (ADR-0010).
     */
    public ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds)
            throws SQLException, IOException {
        refuseWrites(sql);
        long start = System.currentTimeMillis();
        long written = 0;
        Path target = Path.of(path);
        Path partial = target.resolveSibling(target.getFileName() + ".part");
        boolean json = "json".equalsIgnoreCase(format);
        try (Statement statement =
                connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY)) {
            running.set(statement);
            if (timeoutSeconds > 0) {
                tolerate(() -> statement.setQueryTimeout(timeoutSeconds));
            }
            tolerate(() -> statement.setFetchSize(1000));
            try (ResultSet rows = statement.executeQuery(sql);
                    Writer file = new BufferedWriter(new OutputStreamWriter(
                            Files.newOutputStream(partial), StandardCharsets.UTF_8))) {
                written = json ? exportJson(rows, file) : exportCsv(rows, file, nullMarker);
            } catch (SQLException | IOException | RuntimeException e) {
                Files.deleteIfExists(partial);
                throw e;
            }
        } finally {
            running.set(null);
        }
        try {
            Files.move(partial, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException notAtomic) {
            Files.move(partial, target, StandardCopyOption.REPLACE_EXISTING);
        }
        return new ExportResult(written, path, System.currentTimeMillis() - start);
    }

    private static long exportCsv(ResultSet rows, Writer file, String nullMarker)
            throws SQLException, IOException {
        ResultSetMetaData meta = rows.getMetaData();
        int columnCount = meta.getColumnCount();
        long written = 0;
        for (int i = 1; i <= columnCount; i++) {
            if (i > 1) file.write(',');
            file.write(Csv.field(meta.getColumnLabel(i), nullMarker));
        }
        file.write('\n');
        while (rows.next()) {
            for (int i = 1; i <= columnCount; i++) {
                if (i > 1) file.write(',');
                Object value = Values.read(rows, meta, i);
                file.write(Csv.field(value == null ? null : String.valueOf(value), nullMarker));
            }
            file.write('\n');
            written++;
        }
        return written;
    }

    /**
     * One JSON array of objects, keyed by column label, streamed row by row
     * through the same structured writer the in-band results use.
     */
    private static long exportJson(ResultSet rows, Writer file) throws SQLException, IOException {
        ResultSetMetaData meta = rows.getMetaData();
        int columnCount = meta.getColumnCount();
        String[] names = new String[columnCount];
        for (int i = 1; i <= columnCount; i++) {
            names[i - 1] = meta.getColumnLabel(i);
        }
        long written = 0;
        JsonStream out = new JsonStream(file);
        try {
            out.beginArray();
            while (rows.next()) {
                out.beginObject();
                for (int i = 1; i <= columnCount; i++) {
                    out.name(names[i - 1]);
                    JsonCodec.write(out, Values.read(rows, meta, i));
                }
                out.endObject();
                written++;
            }
            out.endArray();
        } catch (UncheckedIOException e) {
            throw e.getCause();
        }
        file.write('\n');
        return written;
    }
}
