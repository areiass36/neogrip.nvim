package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.ConcurrentHashMap;
import neogrip.gripd.contract.Contracts;

/**
 * A whole schema in two round trips: getColumns takes a table *pattern*, so
 * one sweep answers for the entire schema - walking in level by level had a
 * remote engine paying a network round trip per keystroke.
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
     * One schema as the sweeps left it; every schema gets its own because the
     * sweeps run on several connections at once, and a StringBuilder two
     * threads append to is a race.
     */
    static final class SchemaBody {
        /** What the editor looks this schema up under; empty for no schema layer. */
        final String name;
        final String pattern;
        final java.util.LinkedHashMap<String, String> kinds = new java.util.LinkedHashMap<>();
        final java.util.LinkedHashMap<String, String> remarks = new java.util.LinkedHashMap<>();
        final java.util.LinkedHashMap<String, List<Contracts.ColumnRow>> columns = new java.util.LinkedHashMap<>();
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
            // The driver refused the whole-schema call; asking per table is only done where it
            // stays cheap - a bigger schema loses the key flags in the tree, and the table view
            // still shows them.
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
                // The sweep also answers for system objects and anything the table pass dropped.
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

    /** A whole schema - every table with every one of its columns - in two round trips. */
    public Contracts.Rows<Contracts.TableWithColumns> snapshot(String catalog, String schema) throws SQLException {
        if (MongoFields.isMongo(connection)) {
            // Collections have no columns to sweep; their fields come from sampling.
            List<Contracts.TableWithColumns> collections = new ArrayList<>();
            for (String name : MongoFields.collectionNames(connection)) {
                collections.add(new Contracts.TableWithColumns(name, "collection", null, List.of()));
            }
            collections.sort(Comparator.comparing(Contracts.TableWithColumns::name, Metadata.BY_NAME));
            return Contracts.Rows.of(collections);
        }
        SchemaBody body = new SchemaBody(schema, schema);
        sweepSchema(body, connection.getMetaData(), catalog, LIMIT, COLUMN_LIMIT);

        List<Contracts.TableWithColumns> list = new ArrayList<>(body.kinds.size());
        for (java.util.Map.Entry<String, String> table : body.kinds.entrySet()) {
            List<Contracts.ColumnRow> columns = body.columns.get(table.getKey());
            list.add(new Contracts.TableWithColumns(
                    table.getKey(),
                    table.getValue(),
                    body.remarks.get(table.getKey()),
                    columns == null ? List.of() : columns));
        }
        // Ordered by name like every other listing (ADR-0036): the driver's order left the tree
        // reshuffling on refresh. The columns inside each table keep their declared position.
        list.sort(Comparator.comparing(Contracts.TableWithColumns::name, Metadata.BY_NAME));
        return Contracts.Rows.of(list);
    }

    /**
     * One body per schema, in the order the driver listed them, since the
     * tasks finish out of order and the file's order has to come from
     * somewhere that does not; MySQL and SQLite have no schema layer, so that
     * case is a single unnamed body.
     */
    static List<SchemaBody> schemaBodies(DatabaseMetaData meta, String catalog) {
        List<SchemaBody> bodies = new ArrayList<>();
        for (String name : Metadata.schemaNames(meta, catalog, Integer.MAX_VALUE)) {
            // A schema reported without a name cannot filter the metadata calls, so there is no sweeping it.
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
