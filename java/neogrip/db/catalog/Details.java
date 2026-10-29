package neogrip.db.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Set;
import java.util.ArrayList;
import java.util.List;
import neogrip.db.types.Types;

/**
 * Everything the table view draws: the columns, the primary key, the indexes,
 * the foreign keys this table declares and the ones pointing back at it. Five
 * metadata calls, and unlike the snapshot they are per table - affordable
 * because this only runs for a table someone opened.
 */
public final class Details {
    private final Connection connection;

    public Details(Connection connection) {
        this.connection = connection;
    }

    /** What a table's index and key pass found, waiting for the file. */
    static final class DetailParts {
        List<Types.IndexInfo> indexes = List.of();
        List<Types.KeyInfo> foreignKeys = List.of();
        List<Types.KeyInfo> referencedBy = List.of();
        /** The primary key this pass asked for itself, which the sweep can miss. */
        Keys.PrimaryKey primaryKey = Keys.PrimaryKey.NONE;
        /** The columns again, when the sweep's is_pk flags were built from a key it missed. */
        List<Types.ColumnRow> columns;
    }

    /**
     * Everything the table view draws: the columns, the primary key, the
     * indexes, the foreign keys this table declares and the ones pointing back
     * at it.
     *
     * Five metadata calls, and unlike the snapshot they are per table - which
     * is affordable because this only runs for a table someone opened.
     */
    public Object details(String catalog, String schema, String table) throws SQLException {
        if (MongoFields.isMongo(connection)) {
            // A collection has no indexes or keys to speak of through JDBC.
            return MongoFields.sampleFields(connection, table);
        }

        DatabaseMetaData meta = connection.getMetaData();
        Keys.PrimaryKey primaryKey = Keys.primaryKeyOf(meta, catalog, schema, table);

        List<Types.ColumnRow> columns = new ArrayList<>();
        try (ResultSet rows =
                meta.getColumns(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), Metadata.literal(meta, table), "%")) {
            while (rows.next()) {
                if (!Metadata.isRowFor(rows, "TABLE_NAME", table) || !Metadata.isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                columns.add(Metadata.columnRow(rows, primaryKey.columns));
            }
        }

        return new Types.TableDetails(
                columns,
                new ArrayList<>(primaryKey.columns),
                primaryKey.name,
                Metadata.tableRemarks(meta, catalog, schema, table),
                Keys.indexInfos(meta, catalog, schema, table),
                Keys.keyInfos(meta, catalog, schema, table, true),
                Keys.keyInfos(meta, catalog, schema, table, false));
    }

    /**
     * There is no portable "show me the DDL": JDBC does not have one. What it
     * does have is every piece one is written from, which is what details
     * answers with - the rendering happens in Lua, where the dialect's quoting
     * rules already live.
     */
    public Object ddl(String catalog, String schema, String table) throws SQLException {
        return details(catalog, schema, table);
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
    static DetailParts collectDetails(
            DatabaseMetaData meta, String catalog, String schema, String table, Keys.PrimaryKey swept) {
        DetailParts details = new DetailParts();
        Keys.PrimaryKey primaryKey = Keys.primaryKeyOf(meta, catalog, schema, table);
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
                // The columns were built with their is_pk flags taken from
                // the key the sweep found, so they have to be built again.
                details.columns = columnsOf(meta, catalog, schema, table, primaryKey.columns);
            }
        }
        details.indexes = Keys.indexInfos(meta, catalog, schema, table);
        details.foreignKeys = Keys.keyInfos(meta, catalog, schema, table, true);
        details.referencedBy = Keys.keyInfos(meta, catalog, schema, table, false);
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
    static List<Types.ColumnRow> columnsOf(
            DatabaseMetaData meta, String catalog, String schema, String table, Set<String> primaryKeys) {
        List<Types.ColumnRow> columns = new ArrayList<>();
        try (ResultSet rows =
                meta.getColumns(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), Metadata.literal(meta, table), "%")) {
            while (rows.next()) {
                if (!Metadata.isRowFor(rows, "TABLE_NAME", table) || !Metadata.isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                columns.add(Metadata.columnRow(rows, primaryKeys));
            }
        } catch (SQLException refused) {
            return null;
        }
        return columns;
    }
}
