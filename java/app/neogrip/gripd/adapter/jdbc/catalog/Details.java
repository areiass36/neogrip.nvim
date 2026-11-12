package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.Set;
import java.util.ArrayList;
import java.util.List;
import neogrip.gripd.contract.Contracts;

/**
 * Everything the table view draws, in five per-table metadata calls -
 * affordable because this only runs for a table someone opened.
 */
public final class Details {
    private final Connection connection;

    public Details(Connection connection) {
        this.connection = connection;
    }

    /** What a table's index and key pass found, waiting for the file. */
    static final class DetailParts {
        List<Contracts.IndexInfo> indexes = List.of();
        List<Contracts.KeyInfo> foreignKeys = List.of();
        List<Contracts.KeyInfo> referencedBy = List.of();
        /** The primary key this pass asked for itself, which the sweep can miss. */
        Keys.PrimaryKey primaryKey = Keys.PrimaryKey.NONE;
        /** The columns again, when the sweep's is_pk flags were built from a key it missed. */
        List<Contracts.ColumnRow> columns;
    }

    public Object details(String catalog, String schema, String table) throws SQLException {
        if (MongoFields.isMongo(connection)) {
            // A collection has no indexes or keys to speak of through JDBC.
            return MongoFields.sampleFields(connection, table);
        }

        DatabaseMetaData meta = connection.getMetaData();
        Keys.PrimaryKey primaryKey = Keys.primaryKeyOf(meta, catalog, schema, table);

        List<Contracts.ColumnRow> columns = new ArrayList<>();
        try (ResultSet rows =
                meta.getColumns(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), Metadata.literal(meta, table), "%")) {
            while (rows.next()) {
                if (!Metadata.isRowFor(rows, "TABLE_NAME", table) || !Metadata.isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                columns.add(Metadata.columnRow(rows, primaryKey.columns));
            }
        }

        return new Contracts.TableDetails(
                columns,
                new ArrayList<>(primaryKey.columns),
                primaryKey.name,
                Metadata.tableRemarks(meta, catalog, schema, table),
                Keys.indexInfos(meta, catalog, schema, table),
                Keys.keyInfos(meta, catalog, schema, table, true),
                Keys.keyInfos(meta, catalog, schema, table, false));
    }

    /**
     * JDBC has no portable "show me the DDL", so this answers with the pieces
     * one is written from; the rendering happens in Lua, where the dialect's
     * quoting rules already live.
     */
    public Object ddl(String catalog, String schema, String table) throws SQLException {
        return details(catalog, schema, table);
    }

    /**
     * The primary key, index and foreign key pass for one table, each call
     * left to fail on its own, and the key asked for again per table; see
     * doc/internals.md#schema-and-tree.
     *
     * @param swept the key the schema sweep found, which stands when the
     *              per-table call finds nothing of its own.
     */
    static DetailParts collectDetails(
            DatabaseMetaData meta, String catalog, String schema, String table, Keys.PrimaryKey swept) {
        DetailParts details = new DetailParts();
        Keys.PrimaryKey primaryKey = Keys.primaryKeyOf(meta, catalog, schema, table);
        if (primaryKey.isEmpty()) {
            // Believing an empty per-table answer over the sweep's is how keys get lost.
            details.primaryKey = swept;
        } else {
            details.primaryKey = primaryKey;
            // The sweep's columns carry is_pk flags from its key, so a different key means rebuilding them;
            // order alone does not, since the flags only say whether a column is in the key.
            if (!primaryKey.columns.equals(swept.columns)) {
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
     * @return null when the driver will not answer per table: is_pk flags
     *         missing a key beat a table with no columns at all.
     */
    static List<Contracts.ColumnRow> columnsOf(
            DatabaseMetaData meta, String catalog, String schema, String table, Set<String> primaryKeys) {
        List<Contracts.ColumnRow> columns = new ArrayList<>();
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
