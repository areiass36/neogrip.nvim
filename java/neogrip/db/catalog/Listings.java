package neogrip.db.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import neogrip.db.types.Types;

/** The small catalog listings: catalogs, schemas, tables, columns. */
public final class Listings {
    private final Connection connection;

    public Listings(Connection connection) {
        this.connection = connection;
    }

    public Types.Rows<Types.Named> catalogs() throws SQLException {
        DatabaseMetaData meta = connection.getMetaData();
        List<String> names = new ArrayList<>();
        try (ResultSet rows = meta.getCatalogs()) {
            while (rows.next() && names.size() < Snapshot.LIMIT) {
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
        return named(names);
    }

    public Types.Rows<Types.Named> schemas(String catalog) throws SQLException {
        return named(Metadata.schemaNames(connection.getMetaData(), catalog, Snapshot.LIMIT));
    }

    private static Types.Rows<Types.Named> named(List<String> names) {
        List<Types.Named> rows = new ArrayList<>(names.size());
        for (String name : names) {
            rows.add(new Types.Named(String.valueOf(name)));
        }
        return new Types.Rows<>(rows);
    }

    public Types.Rows<Types.TableRow> tables(String catalog, String schema, String pattern)
            throws SQLException {
        DatabaseMetaData meta = connection.getMetaData();
        String namePattern = pattern == null || pattern.isEmpty() ? "%" : "%" + pattern + "%";

        List<Types.TableRow> list = new ArrayList<>();
        // Asking for a list of types does not work across drivers: DuckDB
        // answers with "BASE TABLE", others with "TABLE", and a type the driver
        // does not recognise silently returns nothing. So everything is
        // requested and the system objects are dropped here.
        try (ResultSet rows = Metadata.listTables(
                meta, Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), namePattern)) {
            while (rows.next() && list.size() < Snapshot.LIMIT) {
                String tableType = rows.getString("TABLE_TYPE");
                if (Metadata.isSystem(tableType)) {
                    continue;
                }
                list.add(new Types.TableRow(
                        String.valueOf(rows.getString("TABLE_NAME")),
                        Metadata.kind(tableType),
                        rows.getString("TABLE_SCHEM"),
                        Metadata.remarksOf(rows)));
            }
        }
        return new Types.Rows<>(list);
    }

    public Types.Rows<?> columns(String catalog, String schema, String table) throws SQLException {
        if (MongoFields.isMongo(connection)) {
            // The JDBC driver's getColumns needs the Atlas SQL schema, which a
            // plain mongod does not have; it throws rather than returning
            // nothing. Sampling documents is what a collection can answer.
            return MongoFields.sampleFields(connection, table);
        }

        DatabaseMetaData meta = connection.getMetaData();

        Keys.PrimaryKey primaryKey = Keys.primaryKeyOf(meta, catalog, schema, table);

        List<Types.ColumnRow> list = new ArrayList<>();
        try (ResultSet rows =
                meta.getColumns(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), Metadata.literal(meta, table), "%")) {
            while (rows.next()) {
                if (!Metadata.isRowFor(rows, "TABLE_NAME", table) || !Metadata.isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                list.add(Metadata.columnRow(rows, primaryKey.columns));
            }
        }
        return new Types.Rows<>(list);
    }
}
