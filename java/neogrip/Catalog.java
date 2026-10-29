package neogrip;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Callable;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The catalog, through DatabaseMetaData.
 *
 * This is the part JDBC pays for most: one implementation instead of six
 * hand-written SQL queries against pg_catalog, information_schema, sys.objects,
 * sqlite_master, duckdb_tables() and a Mongo aggregation - each with its own
 * quirks to remember. The driver knows how its own server answers.
 */
public final class Catalog {
    private static final int LIMIT = 500;
    /** A whole schema's columns at once needs a bigger ceiling than its tables. */
    private static final int COLUMN_LIMIT = 20000;
    /**
     * However many connections a sweep is asked to use, this many at most:
     * past a handful it is waiting on the server's catalog rather than on
     * itself, and every connection taken here is one the rest of the machine
     * cannot have.
     */
    private static final int MAX_SIBLINGS = 8;

    private final Connection connection;
    /**
     * Tripped by the cancel operation. A catalog sweep has no statement to
     * cancel - DatabaseMetaData never hands one out - so a flag read between
     * calls is the only way to stop one.
     */
    private final AtomicBoolean cancelled;
    /**
     * Where a statement this class is running is published, so a cancel
     * reaches it. Only the native DDL operation ever puts one here: everything
     * else goes through DatabaseMetaData, which is the reason the flag above
     * exists at all.
     */
    private final AtomicReference<Statement> running;
    /** What this process connected with, so a sweep can open siblings of it. */
    private final String url;
    private final Properties properties;

    public Catalog(
            Connection connection,
            AtomicBoolean cancelled,
            AtomicReference<Statement> running,
            String url,
            Properties properties) {
        this.connection = connection;
        this.cancelled = cancelled;
        this.running = running;
        this.url = url == null ? "" : url;
        this.properties = properties == null ? new Properties() : properties;
    }

    private static String orNull(String value) {
        return value == null || value.isEmpty() ? null : value;
    }

    public void catalogs(StringBuilder out, Object id) throws SQLException {
        DatabaseMetaData meta = connection.getMetaData();
        List<String> names = new ArrayList<>();
        try (ResultSet rows = meta.getCatalogs()) {
            while (rows.next() && names.size() < LIMIT) {
                names.add(rows.getString("TABLE_CAT"));
            }
        } catch (SQLException ignored) {
            // Not every driver has catalogs; the schema level covers those.
        }
        if (names.isEmpty()) {
            String current = connection.getCatalog();
            if (current != null && !current.isEmpty()) {
                names.add(current);
            }
        }
        writeNames(out, id, names);
    }

    public void schemas(StringBuilder out, Object id, String catalog) throws SQLException {
        writeNames(out, id, schemaNames(connection.getMetaData(), catalog, LIMIT));
    }

    /**
     * The schemas of a catalog, each of them once.
     *
     * DuckDB reports main, information_schema and pg_catalog once per attached
     * catalog, so a database with three attached answers with main three
     * times - and the explorer draws a row per schema with a table count, so
     * the user is shown three identical schemas, two of which answer with the
     * same tables as the first. The first occurrence is the one kept, so the
     * order the driver listed them in survives.
     *
     * Names are compared exactly. An engine that tells Main from main has two
     * schemas there, and folding the case would hide one of them behind the
     * other - which is the same bug as this one, with no way to notice it.
     */
    private static List<String> schemaNames(DatabaseMetaData meta, String catalog, int limit) {
        Set<String> names = new LinkedHashSet<>();
        try (ResultSet rows = meta.getSchemas(orNull(catalog), null)) {
            // The limit bounds the distinct names rather than the rows read: a
            // name already seen is not one of the schemas the caller asked for.
            while (rows.next() && names.size() < limit) {
                names.add(rows.getString("TABLE_SCHEM"));
            }
        } catch (SQLException ignored) {
            // MySQL and SQLite have no schema layer.
        }
        return new ArrayList<>(names);
    }

    public void tables(StringBuilder out, Object id, String catalog, String schema, String pattern) throws SQLException {
        DatabaseMetaData meta = connection.getMetaData();
        String namePattern = pattern == null || pattern.isEmpty() ? "%" : "%" + pattern + "%";

        Rpc.beginResult(out, id);
        out.append("{\"rows\":[");
        int count = 0;
        // Asking for a list of types does not work across drivers: DuckDB
        // answers with "BASE TABLE", others with "TABLE", and a type the driver
        // does not recognise silently returns nothing. So everything is
        // requested and the system objects are dropped here.
        try (ResultSet rows =
                meta.getTables(orNull(catalog), orNull(literal(meta, schema)), namePattern, null)) {
            while (rows.next() && count < LIMIT) {
                String tableType = rows.getString("TABLE_TYPE");
                if (isSystem(tableType)) {
                    continue;
                }
                if (count > 0) out.append(',');
                out.append("{\"name\":");
                Json.writeString(out, String.valueOf(rows.getString("TABLE_NAME")));
                out.append(",\"kind\":");
                Json.writeString(out, kind(rows.getString("TABLE_TYPE")));
                String tableSchema = rows.getString("TABLE_SCHEM");
                if (tableSchema != null) {
                    out.append(",\"schema\":");
                    Json.writeString(out, tableSchema);
                }
                writeRemarks(out, rows);
                out.append('}');
                count++;
            }
        }
        out.append("]}}");
    }

    private static boolean isMongo(Connection connection) {
        try {
            return String.valueOf(connection.getMetaData().getDatabaseProductName()).toLowerCase().contains("mongo");
        } catch (SQLException e) {
            return false;
        }
    }

    /** How many documents to look at when working out a collection's fields. */
    private static final int SAMPLE_SIZE = 100;

    /**
     * A collection has no columns, so the fields of a sample stand in for
     * them. A field that holds different types in different documents is
     * reported once per type, which is the honest answer and the thing worth
     * knowing before writing a query against it.
     */
    private void sampleFields(StringBuilder out, Object id, String collection) throws SQLException {
        java.util.LinkedHashMap<String, String> fields = new java.util.LinkedHashMap<>();
        java.util.LinkedHashMap<String, Integer> counts = new java.util.LinkedHashMap<>();

        String script = "db." + collection + ".find({})";
        try (java.sql.Statement statement = connection.createStatement()) {
            try {
                statement.setMaxRows(SAMPLE_SIZE);
            } catch (SQLException ignored) {
                // The driver caps it itself, or not at all.
            }
            try (ResultSet rows = statement.executeQuery(script)) {
                while (rows.next()) {
                    Object value = rows.getObject(1);
                    if (!(value instanceof java.util.Map<?, ?> document)) {
                        continue;
                    }
                    for (java.util.Map.Entry<?, ?> entry : document.entrySet()) {
                        String name = String.valueOf(entry.getKey());
                        String type = bsonType(entry.getValue());
                        String key = name + "\u0000" + type;
                        fields.putIfAbsent(key, type);
                        counts.merge(key, 1, Integer::sum);
                    }
                }
            }
        }

        Rpc.beginResult(out, id);
        out.append("{\"rows\":[");
        int written = 0;
        for (java.util.Map.Entry<String, String> field : fields.entrySet()) {
            String name = field.getKey().substring(0, field.getKey().indexOf('\u0000'));
            if (written > 0) out.append(',');
            out.append("{\"name\":");
            Json.writeString(out, name);
            out.append(",\"type\":");
            Json.writeString(out, field.getValue());
            out.append(",\"nullable\":true,\"is_pk\":").append(name.equals("_id"));
            out.append(",\"count\":").append(counts.getOrDefault(field.getKey(), 0));
            out.append('}');
            written++;
        }
        out.append("]}}");
    }

    private static String bsonType(Object value) {
        if (value == null) return "null";
        if (value instanceof java.util.Map) return "object";
        if (value instanceof java.util.List) return "array";
        if (value instanceof java.util.Date) return "date";
        if (value instanceof Boolean) return "bool";
        if (value instanceof byte[]) return "binary";
        return value.getClass().getSimpleName().toLowerCase();
    }

    private static boolean isSystem(String tableType) {
        if (tableType == null) return false;
        String type = tableType.toUpperCase();
        return type.startsWith("SYSTEM") || type.equals("INDEX") || type.equals("SEQUENCE");
    }

    private static String kind(String tableType) {
        if (tableType == null) return "table";
        return switch (tableType.toUpperCase()) {
            case "VIEW" -> "view";
            case "MATERIALIZED VIEW", "MATVIEW" -> "matview";
            case "COLLECTION" -> "collection";
            case "LOCAL TEMPORARY", "GLOBAL TEMPORARY", "TEMPORARY TABLE" -> "temp";
            default -> "table";
        };
    }

    public void columns(StringBuilder out, Object id, String catalog, String schema, String table) throws SQLException {
        if (isMongo(connection)) {
            // The JDBC driver's getColumns needs the Atlas SQL schema, which a
            // plain mongod does not have; it throws rather than returning
            // nothing. Sampling documents is what a collection can answer.
            sampleFields(out, id, table);
            return;
        }

        DatabaseMetaData meta = connection.getMetaData();

        PrimaryKey primaryKey = primaryKeyOf(meta, catalog, schema, table);

        Rpc.beginResult(out, id);
        out.append("{\"rows\":[");
        try (ResultSet rows =
                meta.getColumns(orNull(catalog), orNull(literal(meta, schema)), literal(meta, table), "%")) {
            int count = 0;
            while (rows.next()) {
                if (!isRowFor(rows, "TABLE_NAME", table) || !isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                if (count > 0) out.append(',');
                writeColumn(out, rows, primaryKey.columns);
                count++;
            }
        }
        out.append("]}}");
    }

    /** One column of a getColumns row. Shared by columns, snapshot and details. */
    private static void writeColumn(StringBuilder out, ResultSet rows, Set<String> primaryKeys) throws SQLException {
        String name = rows.getString("COLUMN_NAME");
        out.append("{\"name\":");
        Json.writeString(out, String.valueOf(name));
        out.append(",\"type\":");
        Json.writeString(out, describeType(rows));
        // Not every driver fills in every optional column of the metadata
        // result; a missing one is not a reason to fail.
        out.append(",\"nullable\":").append(optionalInt(rows, "NULLABLE", DatabaseMetaData.columnNullable)
                != DatabaseMetaData.columnNoNulls);
        out.append(",\"is_pk\":").append(primaryKeys.contains(name));
        String defaultValue = optionalString(rows, "COLUMN_DEF");
        if (defaultValue != null) {
            out.append(",\"default_expr\":");
            Json.writeString(out, defaultValue);
        }
        writeRemarks(out, rows);
        // The two flags are written only when they are set, because they are
        // what the renderer appends a clause for: a false one would have it
        // asking about every ordinary column.
        if (isYes(optionalString(rows, "IS_AUTOINCREMENT"))) {
            out.append(",\"auto_increment\":true");
        }
        if (isYes(optionalString(rows, "IS_GENERATEDCOLUMN"))) {
            out.append(",\"generated\":true");
        }
        // The driver returns the columns in this order already, but a reader
        // that merged two answers - the sweep's and a later per-table pass -
        // has no other way back to the order the table declares.
        out.append(",\"position\":").append(optionalInt(rows, "ORDINAL_POSITION", 0));
        out.append('}');
    }

    /**
     * A comment, where the object has one.
     *
     * Columns and tables both carry theirs under REMARKS, and both leave it
     * out rather than write an empty string: a renderer then has one thing to
     * test instead of two.
     */
    private static void writeRemarks(StringBuilder out, ResultSet rows) {
        String remarks = orNull(optionalString(rows, "REMARKS"));
        if (remarks != null) {
            out.append(",\"remarks\":");
            Json.writeString(out, remarks);
        }
    }

    /**
     * The table's own comment, for the per-table path.
     *
     * The sweep reads this out of the getTables pass it already makes. Asking
     * for one table costs a sixth metadata call here, and without it the same
     * definition drawn from a live answer lacks a COMMENT ON that the one drawn
     * from a snapshot has -- a difference nobody would think to look for.
     *
     * The name is compared rather than trusted: getTables takes a pattern, so
     * a table called foo_bar would also be answered for by fooXbar.
     */
    private static void writeTableRemarks(
            StringBuilder out, DatabaseMetaData meta, String catalog, String schema, String table) {
        try (ResultSet rows =
                meta.getTables(orNull(catalog), orNull(literal(meta, schema)), literal(meta, table), null)) {
            while (rows.next()) {
                if (table.equals(rows.getString("TABLE_NAME"))) {
                    writeRemarks(out, rows);
                    return;
                }
            }
        } catch (SQLException ignored) {
            // A driver that will not describe the table has still described
            // its columns, which is the part this answer is for.
        }
    }

    /**
     * A name where JDBC wants a pattern.
     *
     * getColumns and getTables take patterns, not names, and an underscore in a
     * pattern matches any single character -- so asking for the columns of
     * fato_cliente is answered for fatoXcliente as well, and a definition
     * quietly lists another table's columns beside its own. On a warehouse,
     * where every name has an underscore, that is not an edge case. The
     * driver's own escape string is the documented way to say "take this
     * literally"; rows are checked against the name afterwards too, because a
     * driver is free to ignore it.
     */
    private static String literal(DatabaseMetaData meta, String name) {
        if (name == null || name.isEmpty()) {
            return name;
        }
        String escape;
        try {
            escape = meta.getSearchStringEscape();
        } catch (SQLException ignored) {
            escape = null;
        }
        if (escape == null || escape.isEmpty()) {
            return name;
        }
        StringBuilder out = new StringBuilder(name.length() + 8);
        for (int index = 0; index < name.length(); index++) {
            char character = name.charAt(index);
            if (character == '_' || character == '%' || escape.indexOf(character) >= 0) {
                out.append(escape);
            }
            out.append(character);
        }
        return out.toString();
    }

    /**
     * Whether a metadata row is really about the object that was asked for.
     *
     * A driver that reports nothing for the column is taken at its word -- an
     * engine without schemas has no TABLE_SCHEM to compare -- so this only ever
     * rejects a row that names something else.
     */
    private static boolean isRowFor(ResultSet rows, String column, String name) {
        if (name == null || name.isEmpty()) {
            return true;
        }
        try {
            String reported = rows.getString(column);
            return reported == null || name.equals(reported);
        } catch (SQLException ignored) {
            return true;
        }
    }

    /** The "YES"/"NO"/"" that JDBC uses where a boolean would have done. */
    private static boolean isYes(String value) {
        return value != null && value.equalsIgnoreCase("YES");
    }

    private static String optionalString(ResultSet rows, String column) {
        try {
            return rows.getString(column);
        } catch (SQLException e) {
            return null;
        }
    }

    private static int optionalInt(ResultSet rows, String column, int fallback) {
        try {
            int value = rows.getInt(column);
            return rows.wasNull() ? fallback : value;
        } catch (SQLException e) {
            return fallback;
        }
    }

    /** varchar(50) and numeric(10,2) read better than varchar and numeric. */
    private static String describeType(ResultSet rows) throws SQLException {
        String type = String.valueOf(optionalString(rows, "TYPE_NAME")).toLowerCase();
        int size = optionalInt(rows, "COLUMN_SIZE", 0);
        int digits = optionalInt(rows, "DECIMAL_DIGITS", -1);
        boolean hasDigits = digits >= 0;
        if (type.contains("char") || type.contains("binary")) {
            // Integer.MAX_VALUE is not a length anyone declared: it is how a
            // driver spells "unbounded". Trino reports it for every plain
            // varchar, so printing it made each one read as
            // varchar(2147483647) -- which is both wrong and unreadable.
            boolean bounded = size > 0 && size < Integer.MAX_VALUE;
            return bounded ? type + "(" + size + ")" : type;
        }
        if ((type.contains("decimal") || type.contains("numeric")) && hasDigits) {
            return type + "(" + size + "," + digits + ")";
        }
        return type;
    }

    /**
     * One column of a key, with the sequence number that is meant to order it.
     *
     * JDBC reports a key's columns as rows, and the row order is the driver's
     * business rather than the key's: KEY_SEQ is the only thing that says
     * which column comes first. A composite key read in row order renders a
     * CREATE TABLE whose key is a different key, and lines the wrong pairs up
     * when it is matched against a foreign key.
     */
    private record KeyColumn(int position, String name) {}

    /** One column of an index, which ORDINAL_POSITION orders the same way. */
    private record IndexColumn(int position, String name, String direction) {}

    /** Both ends of one column of a foreign key, which has to stay a pair. */
    private record KeyPair(int position, String here, String there) {}

    /**
     * The names of a key's columns, in the order the key declares.
     *
     * The sort is stable, so a driver that reports no sequence numbers at all
     * leaves the rows in the order it returned them - which is the best guess
     * there is, and what this did before anyone asked about KEY_SEQ.
     */
    private static Set<String> inOrder(List<KeyColumn> columns) {
        columns.sort(Comparator.comparingInt(KeyColumn::position));
        Set<String> names = new LinkedHashSet<>();
        for (KeyColumn column : columns) {
            names.add(column.name());
        }
        return names;
    }

    /**
     * A table's primary key: its columns in order, and the name the server
     * gave the constraint.
     *
     * The name matters because a definition that declares the key anonymously
     * is not the definition the server has - dropping or recreating the
     * constraint needs the name the server knows it by.
     */
    private static final class PrimaryKey {
        static final PrimaryKey NONE = new PrimaryKey(Set.of(), null);

        final Set<String> columns;
        /** PK_NAME, or null on an engine that does not name its constraints. */
        final String name;

        PrimaryKey(Set<String> columns, String name) {
            this.columns = columns;
            this.name = name;
        }

        boolean isEmpty() {
            return columns.isEmpty();
        }
    }

    private static PrimaryKey primaryKeyOf(DatabaseMetaData meta, String catalog, String schema, String table) {
        List<KeyColumn> columns = new ArrayList<>();
        String name = null;
        try (ResultSet keys = meta.getPrimaryKeys(orNull(catalog), orNull(schema), table)) {
            while (keys.next()) {
                columns.add(new KeyColumn(optionalInt(keys, "KEY_SEQ", 0), keys.getString("COLUMN_NAME")));
                if (name == null) {
                    name = orNull(optionalString(keys, "PK_NAME"));
                }
            }
        } catch (SQLException ignored) {
            // Not every driver reports keys; the column list is still useful.
        }
        return new PrimaryKey(inOrder(columns), name);
    }

    /** The constraint's name, where there is one to write. */
    private static void writePrimaryKeyName(StringBuilder out, PrimaryKey key) {
        if (key.name != null) {
            out.append(",\"primary_key_name\":");
            Json.writeString(out, key.name);
        }
    }

    /** A schema small enough that asking table by table for its keys is cheap. */
    private static final int KEY_FALLBACK_TABLES = 50;

    /**
     * Every primary key in the schema at once, by passing a null table name.
     *
     * That is more than getPrimaryKeys promises, so the answer has three
     * states, not two: a map when the driver answered, and null when it
     * refused. An empty
     * map is an answer - Trino reports no keys because it has none - and must
     * not be mistaken for a refusal, or every Trino schema would pay for a
     * per-table sweep that can only come back empty.
     */
    private static java.util.Map<String, PrimaryKey> schemaPrimaryKeys(
            DatabaseMetaData meta, String catalog, String schema) {
        java.util.Map<String, List<KeyColumn>> columns = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> names = new java.util.LinkedHashMap<>();
        try (ResultSet rows = meta.getPrimaryKeys(orNull(catalog), orNull(schema), null)) {
            while (rows.next()) {
                String table = rows.getString("TABLE_NAME");
                columns.computeIfAbsent(table, key -> new ArrayList<>())
                        .add(new KeyColumn(optionalInt(rows, "KEY_SEQ", 0), rows.getString("COLUMN_NAME")));
                String name = orNull(optionalString(rows, "PK_NAME"));
                if (name != null) {
                    names.putIfAbsent(table, name);
                }
            }
        } catch (SQLException refused) {
            return null;
        }
        // One sort per table, after the whole schema has arrived: the rows of
        // two tables' keys can be interleaved, so there is nothing to order
        // until the last of them has been read.
        java.util.Map<String, PrimaryKey> keys = new java.util.LinkedHashMap<>();
        for (java.util.Map.Entry<String, List<KeyColumn>> table : columns.entrySet()) {
            keys.put(table.getKey(), new PrimaryKey(inOrder(table.getValue()), names.get(table.getKey())));
        }
        return keys;
    }

    /**
     * One schema as the sweeps left it: its tables, their keys, and a buffer
     * of rendered columns per table.
     *
     * Every schema gets its own, because the sweeps run on several connections
     * at once and a StringBuilder two threads append to is not a buffer but a
     * race. The buffers are joined only when the file is written.
     */
    private static final class SchemaBody {
        /** What the editor looks this schema up under; empty for no schema layer. */
        final String name;
        /** What the metadata calls are filtered by, which is the same thing. */
        final String pattern;
        final java.util.LinkedHashMap<String, String> kinds = new java.util.LinkedHashMap<>();
        /** A table's comment, for the tables that have one. */
        final java.util.LinkedHashMap<String, String> remarks = new java.util.LinkedHashMap<>();
        final java.util.LinkedHashMap<String, StringBuilder> columns = new java.util.LinkedHashMap<>();
        final java.util.Map<String, TableDetails> details = new ConcurrentHashMap<>();
        java.util.Map<String, PrimaryKey> keys = new java.util.LinkedHashMap<>();
        int columnCount;

        SchemaBody(String name, String pattern) {
            this.name = name;
            this.pattern = pattern;
        }
    }

    /** What a table's index and key pass found, rendered and waiting for the file. */
    private static final class TableDetails {
        final StringBuilder indexes = new StringBuilder();
        final StringBuilder foreignKeys = new StringBuilder();
        final StringBuilder referencedBy = new StringBuilder();
        /** The primary key this pass asked for itself, which the sweep can miss. */
        PrimaryKey primaryKey = PrimaryKey.NONE;
        /** The columns again, when the sweep's is_pk flags were rendered from a key it missed. */
        StringBuilder columns;
    }

    /**
     * A whole schema - every table with every one of its columns - in two
     * round trips.
     *
     * This is where the explorer's waiting went: walking in asked for one
     * level at a time and the preview asked for one more table's columns on
     * every cursor move, so a remote engine was paying a network round trip
     * per keystroke. getColumns takes a table *pattern*, so one sweep answers
     * for the entire schema and the rest of the walk is served from the cache
     * without touching the server again.
     */
    public void snapshot(StringBuilder out, Object id, String catalog, String schema) throws SQLException {
        SchemaBody body = new SchemaBody(schema, schema);
        sweepSchema(body, connection.getMetaData(), catalog, LIMIT, COLUMN_LIMIT);

        Rpc.beginResult(out, id);
        out.append("{\"rows\":[");
        int count = 0;
        for (java.util.Map.Entry<String, String> table : body.kinds.entrySet()) {
            if (count > 0) out.append(',');
            out.append("{\"name\":");
            Json.writeString(out, table.getKey());
            out.append(",\"kind\":");
            Json.writeString(out, table.getValue());
            String remarks = body.remarks.get(table.getKey());
            if (remarks != null) {
                out.append(",\"remarks\":");
                Json.writeString(out, remarks);
            }
            out.append(",\"columns\":[");
            StringBuilder columns = body.columns.get(table.getKey());
            if (columns != null) {
                out.append(columns);
            }
            out.append("]}");
            count++;
        }
        out.append("]}}");
    }

    /**
     * The three sweeps a schema takes, against whichever connection the caller
     * is holding - the process's own, or one an introspect opened for itself.
     */
    private static void sweepSchema(
            SchemaBody body, DatabaseMetaData meta, String catalog, int tableLimit, int columnLimit)
            throws SQLException {
        try (ResultSet rows =
                meta.getTables(orNull(catalog), orNull(literal(meta, body.pattern)), "%", null)) {
            while (rows.next() && body.kinds.size() < tableLimit) {
                if (isSystem(rows.getString("TABLE_TYPE")) || !isRowFor(rows, "TABLE_SCHEM", body.pattern)) {
                    continue;
                }
                String name = rows.getString("TABLE_NAME");
                body.kinds.put(name, kind(rows.getString("TABLE_TYPE")));
                String remarks = orNull(optionalString(rows, "REMARKS"));
                if (remarks != null) {
                    body.remarks.put(name, remarks);
                }
            }
        }

        java.util.Map<String, PrimaryKey> keys = schemaPrimaryKeys(meta, catalog, body.pattern);
        if (keys == null) {
            // The driver would not answer for a whole schema. Asking per table
            // is the thing this method exists to avoid, so it is only done for
            // a schema small enough that it stays cheap; a bigger one loses
            // the key flags in the tree, and the table view still shows them.
            keys = new java.util.LinkedHashMap<>();
            if (body.kinds.size() <= KEY_FALLBACK_TABLES) {
                for (String table : body.kinds.keySet()) {
                    PrimaryKey key = primaryKeyOf(meta, catalog, body.pattern, table);
                    if (!key.isEmpty()) {
                        keys.put(table, key);
                    }
                }
            }
        }
        body.keys = keys;

        int written = 0;
        try (ResultSet rows =
                meta.getColumns(orNull(catalog), orNull(literal(meta, body.pattern)), "%", "%")) {
            while (rows.next() && written < columnLimit) {
                if (!isRowFor(rows, "TABLE_SCHEM", body.pattern)) {
                    continue;
                }
                String table = rows.getString("TABLE_NAME");
                // The sweep also answers for system objects and for anything
                // the table pass dropped; those have nowhere to go.
                if (!body.kinds.containsKey(table)) {
                    continue;
                }
                StringBuilder column = body.columns.computeIfAbsent(table, name -> new StringBuilder());
                if (column.length() > 0) {
                    column.append(',');
                }
                writeColumn(column, rows, keys.getOrDefault(table, PrimaryKey.NONE).columns);
                written++;
            }
        }
        body.columnCount = written;
    }

    /**
     * Everything the table view draws: the columns, the primary key, the
     * indexes, the foreign keys this table declares and the ones pointing back
     * at it.
     *
     * Five metadata calls, and unlike the snapshot they are per table - which
     * is affordable because this only runs for a table someone opened.
     */
    public void details(StringBuilder out, Object id, String catalog, String schema, String table) throws SQLException {
        if (isMongo(connection)) {
            // A collection has no indexes or keys to speak of through JDBC.
            sampleFields(out, id, table);
            return;
        }

        DatabaseMetaData meta = connection.getMetaData();
        PrimaryKey primaryKey = primaryKeyOf(meta, catalog, schema, table);

        Rpc.beginResult(out, id);
        out.append("{\"rows\":[");
        try (ResultSet rows =
                meta.getColumns(orNull(catalog), orNull(literal(meta, schema)), literal(meta, table), "%")) {
            int count = 0;
            while (rows.next()) {
                if (!isRowFor(rows, "TABLE_NAME", table) || !isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                if (count > 0) out.append(',');
                writeColumn(out, rows, primaryKey.columns);
                count++;
            }
        }
        out.append(']');

        out.append(",\"primary_key\":[");
        writeStrings(out, new ArrayList<>(primaryKey.columns));
        out.append(']');
        writePrimaryKeyName(out, primaryKey);
        writeTableRemarks(out, meta, catalog, schema, table);

        out.append(",\"indexes\":[");
        writeIndexes(out, meta, catalog, schema, table);
        out.append(']');

        out.append(",\"foreign_keys\":[");
        writeKeys(out, meta, catalog, schema, table, true);
        out.append(']');

        out.append(",\"referenced_by\":[");
        writeKeys(out, meta, catalog, schema, table, false);
        out.append("]}}");
    }

    /**
     * The primary key, index and foreign key pass for one table, each call
     * left to fail on its own.
     *
     * Trino throws on getIndexInfo because it has no indexes at all, so a
     * sweep of ten thousand of its tables has to finish cheaply rather than
     * fail on the first one.
     *
     * The key is asked for again here, per table, even though the schema sweep
     * already asked for all of them at once. DuckDB answers a whole-schema
     * getPrimaryKeys with an empty result rather than refusing, so the sweep
     * takes "this schema has no keys" for an answer and its per-table fallback
     * never runs - and a definition cached without its PRIMARY KEY is wrong
     * rather than merely slow. This pass is already paying for per-table
     * metadata, so one more call costs little and settles it.
     *
     * @param swept the key the schema sweep found, which stands when the
     *              per-table call finds nothing of its own.
     */
    private static TableDetails collectDetails(
            DatabaseMetaData meta, String catalog, String schema, String table, PrimaryKey swept) {
        TableDetails details = new TableDetails();
        PrimaryKey primaryKey = primaryKeyOf(meta, catalog, schema, table);
        if (primaryKey.isEmpty()) {
            // A table with no key, or a driver that would not say: either way
            // the sweep's answer is the only one there is, and believing an
            // empty answer over it would be how keys get lost.
            details.primaryKey = swept;
        } else {
            details.primaryKey = primaryKey;
            // Which columns, not in which order: the flags only say whether a
            // column is in the key, so a key the sweep found in another order
            // is not a reason to ask the server for the columns again.
            if (!primaryKey.columns.equals(swept.columns)) {
                // The columns were rendered with their is_pk flags taken from
                // the key the sweep found, so they have to be rendered again.
                details.columns = renderColumns(meta, catalog, schema, table, primaryKey.columns);
            }
        }
        writeIndexes(details.indexes, meta, catalog, schema, table);
        writeKeys(details.foreignKeys, meta, catalog, schema, table, true);
        writeKeys(details.referencedBy, meta, catalog, schema, table, false);
        return details;
    }

    /**
     * One table's columns, for the pass that found a primary key the schema
     * sweep had not.
     *
     * @return null when the driver will not answer per table, which leaves the
     *         sweep's columns in place: is_pk flags that are missing a key beat
     *         a table with no columns at all.
     */
    private static StringBuilder renderColumns(
            DatabaseMetaData meta, String catalog, String schema, String table, Set<String> primaryKeys) {
        StringBuilder columns = new StringBuilder();
        try (ResultSet rows =
                meta.getColumns(orNull(catalog), orNull(literal(meta, schema)), literal(meta, table), "%")) {
            while (rows.next()) {
                if (!isRowFor(rows, "TABLE_NAME", table) || !isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                if (columns.length() > 0) {
                    columns.append(',');
                }
                writeColumn(columns, rows, primaryKeys);
            }
        } catch (SQLException refused) {
            return null;
        }
        return columns;
    }

    private static void writeIndexes(
            StringBuilder out, DatabaseMetaData meta, String catalog, String schema, String table) {
        java.util.LinkedHashMap<String, List<IndexColumn>> indexes = new java.util.LinkedHashMap<>();
        java.util.Map<String, Boolean> unique = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> kinds = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> filters = new java.util.LinkedHashMap<>();
        // approximate=true: listing index names is not worth asking the server
        // to refresh its statistics first.
        try (ResultSet rows = meta.getIndexInfo(orNull(catalog), orNull(schema), table, false, true)) {
            while (rows.next()) {
                int type = optionalInt(rows, "TYPE", DatabaseMetaData.tableIndexOther);
                // A tableIndexStatistic row is the table's own cardinality and
                // page count rather than an index, and it is dropped on its
                // type: it usually carries no name or column either, but a
                // driver that fills those in would otherwise have the editor
                // render a statistic as something to create.
                if (type == DatabaseMetaData.tableIndexStatistic) {
                    continue;
                }
                String name = rows.getString("INDEX_NAME");
                String column = rows.getString("COLUMN_NAME");
                if (name == null || column == null) {
                    continue;
                }
                indexes.computeIfAbsent(name, key -> new ArrayList<>())
                        .add(new IndexColumn(
                                optionalInt(rows, "ORDINAL_POSITION", 0),
                                column,
                                direction(optionalString(rows, "ASC_OR_DESC"))));
                unique.putIfAbsent(name, !rows.getBoolean("NON_UNIQUE"));
                kinds.putIfAbsent(name, indexKind(type));
                String filter = orNull(optionalString(rows, "FILTER_CONDITION"));
                if (filter != null) {
                    // A partial index is a different index from the one its
                    // columns describe, so the condition is not decoration.
                    filters.putIfAbsent(name, filter);
                }
            }
        } catch (SQLException ignored) {
            // Trino and the other query engines have no indexes to report.
        }
        int count = 0;
        for (java.util.Map.Entry<String, List<IndexColumn>> index : indexes.entrySet()) {
            if (count > 0) out.append(',');
            List<IndexColumn> columns = index.getValue();
            columns.sort(Comparator.comparingInt(IndexColumn::position));
            out.append("{\"name\":");
            Json.writeString(out, index.getKey());
            out.append(",\"unique\":").append(unique.getOrDefault(index.getKey(), false));
            out.append(",\"columns\":[");
            for (int i = 0; i < columns.size(); i++) {
                if (i > 0) out.append(',');
                Json.writeString(out, String.valueOf(columns.get(i).name()));
            }
            // Written as a parallel array rather than per column, because the
            // columns are what a reader that does not care about ordering
            // already reads: a second array it can ignore beats a shape change.
            out.append("],\"order\":[");
            for (int i = 0; i < columns.size(); i++) {
                if (i > 0) out.append(',');
                Json.writeString(out, columns.get(i).direction());
            }
            out.append("],\"kind\":");
            Json.writeString(out, kinds.getOrDefault(index.getKey(), "other"));
            String filter = filters.get(index.getKey());
            if (filter != null) {
                out.append(",\"filter\":");
                Json.writeString(out, filter);
            }
            out.append('}');
            count++;
        }
    }

    /**
     * Which way an index column sorts.
     *
     * "unknown" rather than defaulting to ascending, because a driver that
     * leaves ASC_OR_DESC null has not said the index is ascending - and an
     * index rendered with the wrong direction is an index that would not be
     * used by the query it was created for.
     */
    private static String direction(String ascOrDesc) {
        if ("A".equals(ascOrDesc)) {
            return "asc";
        }
        if ("D".equals(ascOrDesc)) {
            return "desc";
        }
        return "unknown";
    }

    /** The index's structure, which decides what a renderer calls it. */
    private static String indexKind(int type) {
        return switch (type) {
            case DatabaseMetaData.tableIndexClustered -> "clustered";
            case DatabaseMetaData.tableIndexHashed -> "hashed";
            default -> "other";
        };
    }

    /**
     * Foreign keys in either direction. Which side of the metadata row is this
     * table swaps with the direction: imported keys have it as the FK side,
     * exported keys as the PK side.
     */
    private static void writeKeys(
            StringBuilder out,
            DatabaseMetaData meta,
            String catalog,
            String schema,
            String table,
            boolean imported) {
        // Both ends of a column are kept as one pair, not as two lists.
        // Built separately they were ordered separately - by whatever order the
        // driver returned the rows in, independently for each side - and a
        // two-column key could come out with its second column pointing at the
        // first column of the key it references.
        java.util.LinkedHashMap<String, List<KeyPair>> pairs = new java.util.LinkedHashMap<>();
        java.util.LinkedHashMap<String, String[]> target = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> onDelete = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> onUpdate = new java.util.LinkedHashMap<>();

        try (ResultSet rows = imported
                ? meta.getImportedKeys(orNull(catalog), orNull(schema), table)
                : meta.getExportedKeys(orNull(catalog), orNull(schema), table)) {
            while (rows.next()) {
                String name = String.valueOf(rows.getString("FK_NAME"));
                pairs.computeIfAbsent(name, key -> new ArrayList<>())
                        .add(new KeyPair(
                                optionalInt(rows, "KEY_SEQ", 0),
                                rows.getString(imported ? "FKCOLUMN_NAME" : "PKCOLUMN_NAME"),
                                rows.getString(imported ? "PKCOLUMN_NAME" : "FKCOLUMN_NAME")));
                target.putIfAbsent(name, new String[] {
                    rows.getString(imported ? "PKTABLE_SCHEM" : "FKTABLE_SCHEM"),
                    rows.getString(imported ? "PKTABLE_NAME" : "FKTABLE_NAME")
                });
                String deleteRule = rule(rows, "DELETE_RULE");
                if (deleteRule != null) {
                    onDelete.putIfAbsent(name, deleteRule);
                }
                String updateRule = rule(rows, "UPDATE_RULE");
                if (updateRule != null) {
                    onUpdate.putIfAbsent(name, updateRule);
                }
            }
        } catch (SQLException ignored) {
            // No referential metadata on this engine.
        }

        int count = 0;
        for (java.util.Map.Entry<String, List<KeyPair>> key : pairs.entrySet()) {
            if (count > 0) out.append(',');
            List<KeyPair> columns = key.getValue();
            columns.sort(Comparator.comparingInt(KeyPair::position));
            String[] other = target.getOrDefault(key.getKey(), new String[] {null, null});
            out.append("{\"name\":");
            Json.writeString(out, key.getKey());
            if (other[0] != null) {
                out.append(",\"schema\":");
                Json.writeString(out, other[0]);
            }
            out.append(",\"table\":");
            Json.writeString(out, String.valueOf(other[1]));
            out.append(",\"columns\":[");
            for (int i = 0; i < columns.size(); i++) {
                if (i > 0) out.append(',');
                Json.writeString(out, String.valueOf(columns.get(i).here()));
            }
            out.append("],\"ref_columns\":[");
            for (int i = 0; i < columns.size(); i++) {
                if (i > 0) out.append(',');
                Json.writeString(out, String.valueOf(columns.get(i).there()));
            }
            out.append(']');
            String deleteRule = onDelete.get(key.getKey());
            if (deleteRule != null) {
                out.append(",\"on_delete\":");
                Json.writeString(out, deleteRule);
            }
            String updateRule = onUpdate.get(key.getKey());
            if (updateRule != null) {
                out.append(",\"on_update\":");
                Json.writeString(out, updateRule);
            }
            out.append('}');
            count++;
        }
    }

    /**
     * A referential action, under the name the standard gives it.
     *
     * RESTRICT and NO ACTION are reported apart, even though JDBC documents
     * importedKeyRestrict as the same thing as importedKeyNoAction and keeps
     * it only for ODBC 2: the servers that accept both do not treat them as
     * the same thing, and this is reporting what the server said.
     *
     * @return null where the driver would not say which action it is, since a
     *         rendered ON DELETE that guessed is worse than no clause at all -
     *         the default is NO ACTION, and a wrong one reads as deliberate.
     */
    private static String rule(ResultSet rows, String column) {
        int value;
        try {
            value = rows.getInt(column);
            if (rows.wasNull()) {
                return null;
            }
        } catch (SQLException missing) {
            return null;
        }
        return switch (value) {
            case DatabaseMetaData.importedKeyCascade -> "cascade";
            case DatabaseMetaData.importedKeyRestrict -> "restrict";
            case DatabaseMetaData.importedKeySetNull -> "set null";
            case DatabaseMetaData.importedKeySetDefault -> "set default";
            case DatabaseMetaData.importedKeyNoAction -> "no action";
            default -> null;
        };
    }

    private static void writeStrings(StringBuilder out, List<String> values) {
        for (int i = 0; i < values.size(); i++) {
            if (i > 0) out.append(',');
            Json.writeString(out, String.valueOf(values.get(i)));
        }
    }

    /**
     * There is no portable "show me the DDL": JDBC does not have one. What it
     * does have is every piece one is written from, which is what details
     * answers with - the rendering happens in Lua, where the dialect's quoting
     * rules already live.
     */
    public void ddl(StringBuilder out, Object id, String catalog, String schema, String table) throws SQLException {
        details(out, id, catalog, schema, table);
    }

    /**
     * A definition is one row out of the server's own catalog; a statement
     * that has not produced it in this long is not going to.
     */
    private static final int DDL_TIMEOUT_SECONDS = 15;

    /**
     * Which shape of "show me this table" the server has, if it has one.
     *
     * DatabaseMetaData has no concept of a check constraint, and none of a
     * partition clause, a storage option, a collation or a trigger either - so
     * a definition rendered from metadata alone is missing whatever the server
     * would have said. Where the server will say it in one cheap statement,
     * that text is the better answer.
     */
    private enum Native {
        /** SHOW CREATE TABLE, which answers with the name first and the DDL second. */
        SHOW_CREATE_SECOND,
        /** SHOW CREATE TABLE, which answers with the DDL alone. */
        SHOW_CREATE_FIRST,
        /** sqlite_master, which keeps the text the table was created with. */
        SQLITE_MASTER,
        /** pg_catalog, where the pieces have to be put back together. */
        PG_CATALOG,
        /** No statement at all; the caller renders the definition itself. */
        NONE
    }

    /**
     * The server's own CREATE TABLE, or null.
     *
     * Null is a normal answer and not an error: most engines have no such
     * statement, a view is not a table on the ones that do, and a server that
     * refuses is still a server the editor has to show a definition for. The
     * caller renders one from the metadata in every one of those cases, so
     * failing here would only take away the better answer when it was
     * available and leave nothing in its place.
     */
    public void nativeDdl(StringBuilder out, Object id, String catalog, String schema, String table) {
        String ddl = null;
        try {
            ddl = nativeDdlText(catalog, schema, table);
        } catch (SQLException | RuntimeException refused) {
            // A driver that throws for a missing table, an unsupported
            // statement or a permission the connection does not have. The
            // RuntimeException is not defensiveness for its own sake: several
            // drivers wrap a protocol-level refusal in one.
            ddl = null;
        }
        Rpc.beginResult(out, id);
        out.append("{\"ddl\":");
        if (ddl == null) {
            out.append("null");
        } else {
            Json.writeString(out, ddl);
        }
        out.append("}}");
    }

    private String nativeDdlText(String catalog, String schema, String table) throws SQLException {
        if (orNull(table) == null) {
            return null;
        }
        try {
            return switch (nativeShape()) {
                // MySQL and MariaDB report their databases as catalogs and
                // have no schema layer, so the qualifier is whichever of the
                // two the caller filled in.
                case SHOW_CREATE_SECOND -> showCreate(
                        qualified('`', orNull(schema) != null ? schema : catalog, table), 2);
                // Trino's name has three parts, and the connection is pinned to
                // one catalog - so naming it is a check as much as a qualifier.
                case SHOW_CREATE_FIRST -> showCreate(qualified('"', catalog, schema, table), 1);
                case SQLITE_MASTER -> sqliteSql(table);
                case PG_CATALOG -> postgresDdl(schema, table);
                case NONE -> null;
            };
        } finally {
            // Cleared here rather than in each branch, so a branch that threw
            // does not leave a closed statement where a cancel would find it.
            running.set(null);
        }
    }

    private static Native shapeOf(String engine) {
        return switch (engine) {
            case "mysql", "mariadb" -> Native.SHOW_CREATE_SECOND;
            case "trino", "presto" -> Native.SHOW_CREATE_FIRST;
            case "sqlite" -> Native.SQLITE_MASTER;
            case "postgresql", "postgres" -> Native.PG_CATALOG;
            // DuckDB, SQL Server and MongoDB, and anything else that turns up:
            // none of them answers a table's definition in one statement.
            default -> Native.NONE;
        };
    }

    private Native nativeShape() {
        return shapeOf(engine());
    }

    /**
     * Which engine this is, preferring the url the driver reports over the one
     * this process was started with, and falling back to what the server calls
     * itself for a url the scheme cannot be read out of.
     */
    private String engine() {
        String jdbcUrl = url;
        try {
            String reported = connection.getMetaData().getURL();
            if (reported != null && !reported.isEmpty()) {
                jdbcUrl = reported;
            }
        } catch (SQLException ignored) {
            // The url this process was started with names the same engine.
        }
        String named = engineOf(jdbcUrl);
        if (!named.isEmpty()) {
            return named;
        }
        try {
            return String.valueOf(connection.getMetaData().getDatabaseProductName()).toLowerCase();
        } catch (SQLException ignored) {
            return "";
        }
    }

    /**
     * The scheme between jdbc: and the next colon, and nothing else of the
     * url: the rest of it can carry a file path, and a DuckDB file called
     * postgres_dump.duckdb must not be mistaken for a PostgreSQL server.
     */
    private static String engineOf(String jdbcUrl) {
        String lower = jdbcUrl.toLowerCase();
        if (!lower.startsWith("jdbc:")) {
            return "";
        }
        int end = lower.indexOf(':', "jdbc:".length());
        return end > 0 ? lower.substring("jdbc:".length(), end) : "";
    }

    /**
     * A name a statement can carry, with only the parts that were given.
     *
     * Quoting here rather than in Lua because this is the one place in this
     * file that builds a statement out of a name: the closing character is
     * doubled inside the name, which is what every one of these engines
     * accepts, so a table called `order by` or one with a quote in it names
     * itself rather than ending the identifier early.
     */
    private static String qualified(char quote, String... parts) {
        String mark = String.valueOf(quote);
        StringBuilder name = new StringBuilder();
        for (String part : parts) {
            if (orNull(part) == null) {
                continue;
            }
            if (name.length() > 0) {
                name.append('.');
            }
            name.append(quote).append(part.replace(mark, mark + mark)).append(quote);
        }
        return name.toString();
    }

    /**
     * A statement where a cancel can find it, with a ceiling on how long it
     * may run: this runs on the main connection, which is the user's, so a
     * statement that hangs here is the user's next query hanging too.
     */
    private void publish(Statement statement) {
        running.set(statement);
        try {
            statement.setQueryTimeout(DDL_TIMEOUT_SECONDS);
        } catch (SQLException unsupported) {
            // Not every driver implements the knob; the statement still runs.
        }
    }

    /**
     * @param column which column carries the text: MySQL answers with the
     *               table's name first and its definition second, Trino with
     *               the definition alone.
     */
    private String showCreate(String name, int column) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            publish(statement);
            try (ResultSet rows = statement.executeQuery("SHOW CREATE TABLE " + name)) {
                return rows.next() ? orNull(rows.getString(column)) : null;
            }
        }
    }

    private String sqliteSql(String table) throws SQLException {
        // SQLite keeps the statement it was given, so this is not a rendering
        // of the table but the text that created it, down to the comments.
        try (PreparedStatement statement =
                connection.prepareStatement("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")) {
            publish(statement);
            statement.setString(1, table);
            try (ResultSet rows = statement.executeQuery()) {
                return rows.next() ? orNull(rows.getString(1)) : null;
            }
        }
    }

    /**
     * PostgreSQL has no function that answers with a table's definition - what
     * psql prints it assembles itself out of a dozen queries - so the two
     * halves worth having are concatenated: the constraints, which is where a
     * CHECK lives and the reason to ask the server at all, and the indexes
     * that stand on their own, which pg_get_indexdef renders as statements.
     *
     * Each constraint is prefixed with its ALTER TABLE so the result is a
     * script rather than a list of fragments, and the names are bound as
     * parameters: a table name is the user's text, and the only thing worse
     * than not having the DDL is pasting a name into a statement.
     */
    private String postgresDdl(String schema, String table) throws SQLException {
        String name = qualified('"', schema, table);
        // An unnamed schema means the search path, and public is what that
        // resolves to on every PostgreSQL this is likely to meet.
        String namespace = orNull(schema) != null ? schema : "public";
        StringBuilder ddl = new StringBuilder();

        try (PreparedStatement statement = connection.prepareStatement("SELECT c.conname,"
                + " pg_catalog.pg_get_constraintdef(c.oid)"
                + " FROM pg_catalog.pg_constraint c"
                + " JOIN pg_catalog.pg_class t ON t.oid = c.conrelid"
                + " JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace"
                + " WHERE t.relname = ? AND n.nspname = ?"
                + " ORDER BY c.conname")) {
            publish(statement);
            statement.setString(1, table);
            statement.setString(2, namespace);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String definition = orNull(rows.getString(2));
                    if (definition == null) {
                        continue;
                    }
                    ddl.append("ALTER TABLE ")
                            .append(name)
                            .append(" ADD CONSTRAINT ")
                            .append(qualified('"', rows.getString(1)))
                            .append(' ')
                            .append(definition)
                            .append(";\n");
                }
            }
        }

        // Only the indexes that are not already above. A primary key or a
        // unique constraint owns an index, and the index listings show that
        // index like any other - so the constraint pass and this one would
        // each emit a statement for the same relation, which in a buffer the
        // user reads and yanks out of is not a duplicate but a mistake. The
        // oid the exclusion needs is pg_index.indexrelid, which the pg_indexes
        // view does not expose, so this asks the catalogs underneath it.
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT x.relname, pg_catalog.pg_get_indexdef(i.indexrelid)"
                        + " FROM pg_catalog.pg_index i"
                        + " JOIN pg_catalog.pg_class t ON t.oid = i.indrelid"
                        + " JOIN pg_catalog.pg_class x ON x.oid = i.indexrelid"
                        + " JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace"
                        + " WHERE t.relname = ? AND n.nspname = ?"
                        + " AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c"
                        + " WHERE c.conindid = i.indexrelid)"
                        + " ORDER BY x.relname")) {
            publish(statement);
            statement.setString(1, table);
            statement.setString(2, namespace);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String definition = orNull(rows.getString(2));
                    if (definition != null) {
                        ddl.append(definition).append(";\n");
                    }
                }
            }
        }

        // A table whose constraints and indexes are all accounted for already
        // has nothing here the metadata did not have, and an empty string
        // would have the editor show a heading over nothing.
        return ddl.length() == 0 ? null : ddl.toString();
    }

    private static void writeNames(StringBuilder out, Object id, List<String> names) {
        Rpc.beginResult(out, id);
        out.append("{\"rows\":[");
        for (int i = 0; i < names.size(); i++) {
            if (i > 0) out.append(',');
            out.append("{\"name\":");
            Json.writeString(out, String.valueOf(names.get(i)));
            out.append('}');
        }
        out.append("]}}");
    }

    /**
     * The whole catalog, written to a file instead of answered through the
     * protocol.
     *
     * The snapshot above fixed the walking for one schema; a database has
     * hundreds of them, and the explorer cannot ask for one per keystroke. So
     * every schema is swept once, written to disk, and read from there - which
     * also survives a restart, and a server that has since gone away.
     *
     * The answer is a path rather than the catalog itself because a warehouse's
     * catalog runs to hundreds of megabytes of JSON, and a line that long is
     * not a protocol message.
     */
    public void introspect(
            StringBuilder out,
            Object id,
            String catalog,
            String outFile,
            int parallelism,
            long deadlineMs,
            boolean wantDetails)
            throws SQLException, IOException {
        long start = System.currentTimeMillis();
        // No budget at all rather than one that has already run out: a caller
        // that asks for nothing wants the whole catalog, not an empty pass.
        long deadline = deadlineMs > 0 ? start + deadlineMs : Long.MAX_VALUE;
        // The flag is shared with the statement the worker may be running, so
        // a cancel sent before this request must not end it on sight.
        cancelled.set(false);

        if (outFile == null || outFile.isEmpty()) {
            Rpc.writeError(out, id, Rpc.INVALID_REQUEST, "introspect needs a file to write the catalog to", null);
            return;
        }
        if (isMongo(connection)) {
            // getColumns wants the Atlas SQL schema a plain mongod does not
            // have, and a snapshot of collections without fields would answer
            // "no fields" where the explorer has to sample documents instead.
            Rpc.writeError(
                    out,
                    id,
                    Rpc.INVALID_REQUEST,
                    "a collection catalog cannot be swept; the explorer samples documents instead",
                    null);
            return;
        }

        DatabaseMetaData meta = connection.getMetaData();
        List<SchemaBody> schemas = schemaBodies(meta, catalog);
        String label = catalog == null || catalog.isEmpty() ? currentCatalog(connection) : catalog;
        String product = product(meta);

        Path target = Path.of(outFile);
        Path temp = null;
        Pool pool = null;
        ExecutorService threads = null;
        boolean parallel = false;
        boolean partial = false;
        boolean written = false;
        int detailed = 0;
        try {
            // One schema has no concurrency in it to find, so this stage is
            // sized by how many there are.
            pool = openSiblings(meta, schemas.size(), parallelism, null);
            threads = sweepThreads(pool);
            if (pool != null) {
                parallel = true;
            }
            run(sweepTasks(schemas, pool, catalog), threads);

            if (wantDetails && !cancelled.get()) {
                int walk = 0;
                for (SchemaBody schema : schemas) {
                    walk += schema.kinds.size();
                }
                // This stage is per table, and that is where a database with
                // everything in one schema has its concurrency: MySQL has one
                // schema by definition, SQLite has none, and the common
                // Postgres database never left public - while any of them can
                // have hundreds of tables, each wanting four metadata calls.
                // Sizing this by schemas would leave all three sequential.
                int before = pool == null ? 0 : pool.size();
                pool = openSiblings(meta, walk, parallelism, pool);
                if (pool != null && pool.size() != before) {
                    // The sweeps are done with the old threads, and there are
                    // now more connections than there were of them.
                    if (threads != null) {
                        threads.shutdown();
                    }
                    threads = sweepThreads(pool);
                }
                if (pool != null) {
                    parallel = true;
                }

                AtomicBoolean ranOut = new AtomicBoolean();
                AtomicInteger done = new AtomicInteger();
                run(detailTasks(schemas, pool, catalog, deadline, ranOut, done), threads);
                partial = ranOut.get();
                detailed = done.get();
            }

            if (!cancelled.get()) {
                temp = tempBeside(target);
                boolean complete;
                try (Writer file = new BufferedWriter(
                        new OutputStreamWriter(Files.newOutputStream(temp), StandardCharsets.UTF_8))) {
                    complete = writeSnapshot(file, product, label, parallel, partial, schemas, cancelled);
                }
                if (complete) {
                    move(temp, target);
                    temp = null;
                    written = true;
                }
            }
        } finally {
            if (threads != null) {
                threads.shutdownNow();
            }
            if (pool != null) {
                pool.closeAll();
            }
            if (temp != null) {
                // The write failed or was cancelled. Nothing may be left
                // where the editor reads a finished snapshot.
                try {
                    Files.deleteIfExists(temp);
                } catch (IOException ignored) {
                    // A file in the cache directory that nobody will read.
                }
            }
        }

        // A snapshot that reached its place is an answer even if a cancel
        // arrived a moment later; nothing else can get this far unwritten.
        if (!written) {
            Rpc.writeError(out, id, Rpc.CANCELLED, "the catalog sweep was cancelled", null);
            return;
        }

        int tables = 0;
        long columns = 0;
        for (SchemaBody schema : schemas) {
            tables += schema.kinds.size();
            columns += schema.columnCount;
        }
        Rpc.beginResult(out, id);
        out.append("{\"path\":");
        Json.writeString(out, outFile);
        out.append(",\"schemas\":").append(schemas.size());
        out.append(",\"tables\":").append(tables);
        out.append(",\"columns\":").append(columns);
        out.append(",\"details\":").append(detailed);
        out.append(",\"partial\":").append(partial);
        out.append(",\"parallel\":").append(parallel);
        out.append(",\"elapsedMs\":").append(System.currentTimeMillis() - start);
        out.append("}}");
    }

    /**
     * One task per schema, each holding a connection for all three of that
     * schema's sweeps.
     */
    private List<Callable<Void>> sweepTasks(List<SchemaBody> schemas, Pool pool, String catalog) {
        List<Callable<Void>> tasks = new ArrayList<>();
        for (SchemaBody schema : schemas) {
            tasks.add(() -> {
                if (cancelled.get()) {
                    return null;
                }
                Connection held = pool == null ? connection : pool.take();
                try {
                    // Neither sweep is capped. The caps the snapshot operation
                    // uses are there because its answer has to fit on one
                    // line; this one writes to a file, so a cap would only
                    // hide tables the explorer could have had.
                    sweepSchema(schema, held.getMetaData(), catalog, Integer.MAX_VALUE, Integer.MAX_VALUE);
                } finally {
                    if (pool != null) {
                        pool.release(held);
                    }
                }
                return null;
            });
        }
        return tasks;
    }

    /** One task per table, for the pass that describes each one. */
    private List<Callable<Void>> detailTasks(
            List<SchemaBody> schemas,
            Pool pool,
            String catalog,
            long deadline,
            AtomicBoolean ranOut,
            AtomicInteger done) {
        List<Callable<Void>> tasks = new ArrayList<>();
        for (SchemaBody schema : schemas) {
            for (String table : schema.kinds.keySet()) {
                tasks.add(() -> {
                    if (cancelled.get()) {
                        return null;
                    }
                    // The sweeps always finish, because a snapshot without
                    // columns is worth nothing. The budget is spent here
                    // instead, where running out costs one table's definition
                    // and not the file.
                    if (System.currentTimeMillis() > deadline) {
                        ranOut.set(true);
                        return null;
                    }
                    Connection held = pool == null ? connection : pool.take();
                    try {
                        schema.details.put(
                                table,
                                collectDetails(
                                        held.getMetaData(),
                                        catalog,
                                        schema.pattern,
                                        table,
                                        schema.keys.getOrDefault(table, PrimaryKey.NONE)));
                        done.incrementAndGet();
                    } catch (SQLException refused) {
                        // One table the engine will not describe is no reason
                        // to lose the other ten thousand.
                    } finally {
                        if (pool != null) {
                            pool.release(held);
                        }
                    }
                    return null;
                });
            }
        }
        return tasks;
    }

    /**
     * One body per schema to sweep, in the order the driver listed them, which
     * is the order they are written in: the tasks finish out of order, so the
     * file's order has to come from somewhere that does not.
     *
     * MySQL and SQLite have no schema layer and the editor looks their tables
     * up under an empty name, so that case is a single unnamed body.
     */
    private static List<SchemaBody> schemaBodies(DatabaseMetaData meta, String catalog) {
        List<SchemaBody> bodies = new ArrayList<>();
        for (String name : schemaNames(meta, catalog, Integer.MAX_VALUE)) {
            // A schema the driver reports without a name is one the metadata
            // calls cannot be filtered by, so there is no sweeping it.
            if (name != null && !name.isEmpty()) {
                bodies.add(new SchemaBody(name, name));
            }
        }
        if (bodies.isEmpty()) {
            bodies.add(new SchemaBody("", ""));
        }
        return bodies;
    }

    /** The same string the ready line announces, so both name one server. */
    private static String product(DatabaseMetaData meta) {
        try {
            return meta.getDatabaseProductName() + " " + meta.getDatabaseProductVersion();
        } catch (SQLException ignored) {
            // A driver that cannot describe itself still has a catalog.
            return "";
        }
    }

    private static String currentCatalog(Connection connection) {
        try {
            String current = connection.getCatalog();
            return current == null ? "" : current;
        } catch (SQLException ignored) {
            // Not every driver has catalogs to be in one of.
            return "";
        }
    }

    /**
     * A sweep's own connections, handed to one task at a time.
     *
     * A queue rather than one connection per thread because the detail pass
     * has far more tasks than there are connections, and because a task that
     * fails still has to give its connection back.
     */
    private static final class Pool {
        private final List<Connection> opened = new ArrayList<>();
        /**
         * Unbounded, because a later stage tops the pool up rather than
         * replacing it: the detail pass wants more connections than the schema
         * sweeps did, and the ones already open are still good.
         */
        private final BlockingQueue<Connection> free = new LinkedBlockingQueue<>();

        /** Only ever called between stages, with every task finished. */
        void add(Connection connection) {
            opened.add(connection);
            free.add(connection);
        }

        int size() {
            return opened.size();
        }

        Connection take() throws InterruptedException {
            return free.take();
        }

        void release(Connection connection) {
            free.offer(connection);
        }

        void closeAll() {
            for (Connection connection : opened) {
                try {
                    connection.close();
                } catch (SQLException ignored) {
                    // The sweep is over either way.
                }
            }
        }
    }

    /**
     * Connections of a sweep's own, or null to stay on the process's one.
     *
     * The main connection belongs to the user's statements: a sweep that
     * borrowed it would make the next query wait for a whole catalog, which is
     * the reason this operation exists at all. Falling back to it is still a
     * correct outcome - slower, not wrong - so a server that will not hand out
     * another connection is not an error here.
     *
     * Asked once per stage, because the two stages have their work divided up
     * differently and sizing for the first would leave the second with one
     * connection on the commonest shape of database there is.
     *
     * @param work how many tasks the stage is about to run, which is what
     *             bounds the number of connections worth opening
     * @param pool what an earlier stage opened, to be topped up rather than
     *             replaced, or null when nothing is open yet
     */
    private Pool openSiblings(DatabaseMetaData meta, int work, int parallelism, Pool pool) {
        int wanted = Math.min(Math.min(Math.max(parallelism, 1), work), MAX_SIBLINGS);
        int limit = 0;
        try {
            limit = meta.getMaxConnections();
        } catch (SQLException ignored) {
            // A driver that will not say does not get to cap anything.
        }
        if (limit > 0) {
            // Zero means unknown or unlimited, not a ban on connecting.
            wanted = Math.min(wanted, limit);
        }
        int have = pool == null ? 0 : pool.size();
        // A stage with less work than the last one keeps what is open instead
        // of closing connections it would only have to reopen.
        if (wanted < 2 || wanted <= have || url.isEmpty() || isSingleConnection(meta)) {
            return pool;
        }

        Pool opened = pool == null ? new Pool() : pool;
        for (int i = have; i < wanted; i++) {
            try {
                opened.add(DriverManager.getConnection(url, properties));
            } catch (SQLException refused) {
                // A server at its connection limit, a pooler in the way, or
                // credentials good for one session at a time.
                break;
            }
        }
        if (opened.size() < 2) {
            // One sibling does nothing the main connection would not, and
            // costs the server a session to do it.
            opened.closeAll();
            return null;
        }
        return opened;
    }

    /** A thread per connection, since a task only ever waits on one. */
    private static ExecutorService sweepThreads(Pool pool) {
        if (pool == null) {
            return null;
        }
        return Executors.newFixedThreadPool(pool.size(), task -> {
            Thread thread = new Thread(task, "neogrip-sweep");
            thread.setDaemon(true);
            return thread;
        });
    }

    /**
     * Engines a second connection must not be opened against: DuckDB and
     * SQLite are single-writer files, and the MongoDB driver starts a
     * JavaScript engine per connection.
     */
    private boolean isSingleConnection(DatabaseMetaData meta) {
        String jdbcUrl = url;
        try {
            String reported = meta.getURL();
            if (reported != null && !reported.isEmpty()) {
                jdbcUrl = reported;
            }
        } catch (SQLException ignored) {
            // The url this process was started with says the same thing.
        }
        jdbcUrl = jdbcUrl.toLowerCase();
        return jdbcUrl.startsWith("jdbc:duckdb:")
                || jdbcUrl.startsWith("jdbc:sqlite:")
                || jdbcUrl.startsWith("jdbc:mongodb:");
    }

    /** Every task, on the pool's threads when there is a pool, or on this one. */
    private static void run(List<Callable<Void>> tasks, ExecutorService threads) throws SQLException {
        if (threads == null) {
            for (Callable<Void> task : tasks) {
                try {
                    task.call();
                } catch (Exception e) {
                    rethrow(e);
                }
            }
            return;
        }
        try {
            for (Future<Void> finished : threads.invokeAll(tasks)) {
                try {
                    finished.get();
                } catch (ExecutionException e) {
                    rethrow(e.getCause());
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new SQLException("interrupted while reading the catalog", e);
        }
    }

    /** A task's failure, as the type the caller already turns into an error. */
    private static void rethrow(Throwable cause) throws SQLException {
        if (cause instanceof SQLException sql) {
            throw sql;
        }
        if (cause instanceof RuntimeException runtime) {
            throw runtime;
        }
        if (cause instanceof Error error) {
            throw error;
        }
        throw new SQLException(cause == null ? "the catalog sweep failed" : String.valueOf(cause.getMessage()), cause);
    }

    /**
     * The snapshot, straight into the file.
     *
     * Nothing bigger than one table is ever held as a single string: the
     * per-schema buffers are appended to the stream in the order the schemas
     * were listed, so a catalog larger than this process's heap still gets
     * written.
     *
     * @return false when a cancel arrived mid-write, which leaves the file for
     *         the caller to delete instead of moving it into place.
     */
    private static boolean writeSnapshot(
            Writer file,
            String product,
            String catalog,
            boolean parallel,
            boolean partial,
            List<SchemaBody> schemas,
            AtomicBoolean cancelled)
            throws IOException {
        StringBuilder head = new StringBuilder();
        head.append("{\"at\":").append(System.currentTimeMillis() / 1000).append(",\"product\":");
        Json.writeString(head, product);
        head.append(",\"catalog\":");
        Json.writeString(head, catalog);
        head.append(",\"parallel\":").append(parallel);
        head.append(",\"partial\":").append(partial);
        head.append(",\"schemas\":[");
        file.append(head);

        int schemaCount = 0;
        for (SchemaBody schema : schemas) {
            if (cancelled.get()) {
                return false;
            }
            if (schemaCount > 0) {
                file.append(',');
            }
            StringBuilder open = new StringBuilder("{\"name\":");
            Json.writeString(open, schema.name);
            open.append(",\"tables\":[");
            file.append(open);
            int tableCount = 0;
            for (java.util.Map.Entry<String, String> table : schema.kinds.entrySet()) {
                if (tableCount > 0) {
                    file.append(',');
                }
                writeTable(file, schema, table.getKey(), table.getValue());
                tableCount++;
            }
            file.append("]}");
            schemaCount++;
        }
        file.append("]}");
        return true;
    }

    /**
     * One table, in the shape the table view's renderers already read.
     *
     * The index and key arrays are written empty rather than left out when the
     * detail pass did not reach this table, so a reader never has to tell a
     * missing field from a table that has no indexes: the details flag is what
     * says which of the two it is.
     *
     * Where the detail pass ran, its primary key and its columns are the ones
     * written: it asked per table, and the schema sweep's single call for all
     * of them is the one that can come back empty on an engine that does not
     * support it.
     */
    private static void writeTable(Writer file, SchemaBody schema, String table, String kind) throws IOException {
        TableDetails details = schema.details.get(table);
        StringBuilder head = new StringBuilder("{\"name\":");
        Json.writeString(head, table);
        head.append(",\"kind\":");
        Json.writeString(head, kind);
        String remarks = schema.remarks.get(table);
        if (remarks != null) {
            head.append(",\"remarks\":");
            Json.writeString(head, remarks);
        }
        head.append(",\"columns\":[");
        file.append(head);

        StringBuilder columns = details != null && details.columns != null
                ? details.columns
                : schema.columns.get(table);
        if (columns != null) {
            file.append(columns);
        }

        PrimaryKey primaryKey =
                details != null ? details.primaryKey : schema.keys.getOrDefault(table, PrimaryKey.NONE);
        StringBuilder keys = new StringBuilder("],\"primary_key\":[");
        writeStrings(keys, new ArrayList<>(primaryKey.columns));
        keys.append(']');
        writePrimaryKeyName(keys, primaryKey);
        file.append(keys);

        file.append(",\"indexes\":[");
        if (details != null) {
            file.append(details.indexes);
        }
        file.append("],\"foreign_keys\":[");
        if (details != null) {
            file.append(details.foreignKeys);
        }
        file.append("],\"referenced_by\":[");
        if (details != null) {
            file.append(details.referencedBy);
        }
        file.append("],\"details\":").append(Boolean.toString(details != null)).append('}');
    }

    /**
     * A snapshot is only ever read whole, so it is written beside its target
     * and moved onto it at the end: a crash, a cancel or a full disk then
     * leaves the previous snapshot in place instead of half of a new one.
     */
    private static Path tempBeside(Path target) throws IOException {
        Path parent = target.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        return Files.createTempFile(parent == null ? Path.of(".") : parent, ".neogrip-catalog", ".json");
    }

    private static void move(Path temp, Path target) throws IOException {
        try {
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException unsupported) {
            // Not every file system can swap a file in one step, and a reader
            // that catches the gap falls back to asking the server.
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }
}
