package neogrip.db.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import neogrip.db.types.Types;

/**
 * A whole schema - every table with every one of its columns - in two round
 * trips. This is where the explorer's waiting went: walking in asked for one
 * level at a time and the preview asked for one more table's columns on every
 * cursor move, so a remote engine was paying a network round trip per
 * keystroke. getColumns takes a table *pattern*, so one sweep answers for the
 * entire schema and the rest of the walk is served from the cache without
 * touching the server again.
 */
public final class Snapshot {
    private final Connection connection;

    public Snapshot(Connection connection) {
        this.connection = connection;
    }

    static final int LIMIT = 500;

    /** A whole schema's columns at once needs a bigger ceiling than its tables. */
    static final int COLUMN_LIMIT = 20000;

    /**
     * One schema as the sweeps left it: its tables, their keys, and a buffer
     * of rendered columns per table.
     *
     * Every schema gets its own, because the sweeps run on several connections
     * at once and a StringBuilder two threads append to is not a buffer but a
     * race. The buffers are joined only when the file is written.
     */
    static final class SchemaBody {
        /** What the editor looks this schema up under; empty for no schema layer. */
        final String name;
        /** What the metadata calls are filtered by, which is the same thing. */
        final String pattern;
        final java.util.LinkedHashMap<String, String> kinds = new java.util.LinkedHashMap<>();
        /** A table's comment, for the tables that have one. */
        final java.util.LinkedHashMap<String, String> remarks = new java.util.LinkedHashMap<>();
        final java.util.LinkedHashMap<String, List<Types.ColumnRow>> columns = new java.util.LinkedHashMap<>();
        final java.util.Map<String, Details.DetailParts> details = new ConcurrentHashMap<>();
        java.util.Map<String, Keys.PrimaryKey> keys = new java.util.LinkedHashMap<>();
        int columnCount;

        SchemaBody(String name, String pattern) {
            this.name = name;
            this.pattern = pattern;
        }
    }

    /**
     * The three sweeps a schema takes, against whichever connection the caller
     * is holding - the process's own, or one an introspect opened for itself.
     */
    static void sweepSchema(
            SchemaBody body, DatabaseMetaData meta, String catalog, int tableLimit, int columnLimit)
            throws SQLException {
        try (ResultSet rows =
                meta.getTables(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, body.pattern)), "%", null)) {
            while (rows.next() && body.kinds.size() < tableLimit) {
                if (Metadata.isSystem(rows.getString("TABLE_TYPE")) || !Metadata.isRowFor(rows, "TABLE_SCHEM", body.pattern)) {
                    continue;
                }
                String name = rows.getString("TABLE_NAME");
                body.kinds.put(name, Metadata.kind(rows.getString("TABLE_TYPE")));
                String remarks = Metadata.orNull(Metadata.optionalString(rows, "REMARKS"));
                if (remarks != null) {
                    body.remarks.put(name, remarks);
                }
            }
        }

        java.util.Map<String, Keys.PrimaryKey> keys = Keys.schemaPrimaryKeys(meta, catalog, body.pattern);
        if (keys == null) {
            // The driver would not answer for a whole schema. Asking per table
            // is the thing this method exists to avoid, so it is only done for
            // a schema small enough that it stays cheap; a bigger one loses
            // the key flags in the tree, and the table view still shows them.
            keys = new java.util.LinkedHashMap<>();
            if (body.kinds.size() <= Keys.KEY_FALLBACK_TABLES) {
                for (String table : body.kinds.keySet()) {
                    Keys.PrimaryKey key = Keys.primaryKeyOf(meta, catalog, body.pattern, table);
                    if (!key.isEmpty()) {
                        keys.put(table, key);
                    }
                }
            }
        }
        body.keys = keys;

        int written = 0;
        try (ResultSet rows =
                meta.getColumns(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, body.pattern)), "%", "%")) {
            while (rows.next() && written < columnLimit) {
                if (!Metadata.isRowFor(rows, "TABLE_SCHEM", body.pattern)) {
                    continue;
                }
                String table = rows.getString("TABLE_NAME");
                // The sweep also answers for system objects and for anything
                // the table pass dropped; those have nowhere to go.
                if (!body.kinds.containsKey(table)) {
                    continue;
                }
                body.columns
                        .computeIfAbsent(table, name -> new ArrayList<>())
                        .add(Metadata.columnRow(rows, keys.getOrDefault(table, Keys.PrimaryKey.NONE).columns));
                written++;
            }
        }
        body.columnCount = written;
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
    public Types.Rows<Types.TableWithColumns> snapshot(String catalog, String schema) throws SQLException {
        SchemaBody body = new SchemaBody(schema, schema);
        sweepSchema(body, connection.getMetaData(), catalog, LIMIT, COLUMN_LIMIT);

        List<Types.TableWithColumns> list = new ArrayList<>(body.kinds.size());
        for (java.util.Map.Entry<String, String> table : body.kinds.entrySet()) {
            List<Types.ColumnRow> columns = body.columns.get(table.getKey());
            list.add(new Types.TableWithColumns(
                    table.getKey(),
                    table.getValue(),
                    body.remarks.get(table.getKey()),
                    columns == null ? List.of() : columns));
        }
        return new Types.Rows<>(list);
    }

    /**
     * One body per schema to sweep, in the order the driver listed them, which
     * is the order they are written in: the tasks finish out of order, so the
     * file's order has to come from somewhere that does not.
     *
     * MySQL and SQLite have no schema layer and the editor looks their tables
     * up under an empty name, so that case is a single unnamed body.
     */
    static List<SchemaBody> schemaBodies(DatabaseMetaData meta, String catalog) {
        List<SchemaBody> bodies = new ArrayList<>();
        for (String name : Metadata.schemaNames(meta, catalog, Integer.MAX_VALUE)) {
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
}
