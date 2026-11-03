package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import neogrip.gripd.contract.Contracts;

/** The small catalog listings: catalogs, schemas, tables, columns. */
public final class Listings {
    private final Connection connection;

    public Listings(Connection connection) {
        this.connection = connection;
    }

    public Contracts.Rows<Contracts.Named> catalogs() throws SQLException {
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
        names.sort(Metadata.BY_NAME);
        return named(names);
    }

    public Contracts.Rows<Contracts.Named> schemas(String catalog) throws SQLException {
        return named(Metadata.schemaNames(connection.getMetaData(), catalog, Snapshot.LIMIT));
    }

    private static Contracts.Rows<Contracts.Named> named(List<String> names) {
        List<Contracts.Named> rows = new ArrayList<>(names.size());
        for (String name : names) {
            rows.add(new Contracts.Named(String.valueOf(name)));
        }
        return new Contracts.Rows<>(rows);
    }

    public Contracts.Rows<Contracts.TableRow> tables(String catalog, String schema, String pattern)
            throws SQLException {
        if (MongoFields.isMongo(connection)) {
            List<Contracts.TableRow> collections = new ArrayList<>();
            String needle = pattern == null ? "" : pattern.toLowerCase(java.util.Locale.ROOT);
            for (String name : MongoFields.collectionNames(connection)) {
                if (needle.isEmpty() || name.toLowerCase(java.util.Locale.ROOT).contains(needle)) {
                    collections.add(new Contracts.TableRow(name, "collection", null, null));
                }
            }
            collections.sort(Comparator.comparing(Contracts.TableRow::name, Metadata.BY_NAME));
            return new Contracts.Rows<>(collections);
        }
        DatabaseMetaData meta = connection.getMetaData();
        String namePattern = pattern == null || pattern.isEmpty() ? "%" : "%" + pattern + "%";

        List<Contracts.TableRow> list = new ArrayList<>();
        // Asking for a list of types does not work across drivers: DuckDB
        // answers with "BASE TABLE", others with "TABLE", and a type the driver
        // does not recognise silently returns nothing. So everything is
        // requested and the system objects are dropped here.
        try (ResultSet rows =
                meta.getTables(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), namePattern, null)) {
            while (rows.next() && list.size() < Snapshot.LIMIT) {
                String tableType = rows.getString("TABLE_TYPE");
                if (Metadata.isSystem(tableType)) {
                    continue;
                }
                list.add(new Contracts.TableRow(
                        String.valueOf(rows.getString("TABLE_NAME")),
                        Metadata.kind(tableType),
                        rows.getString("TABLE_SCHEM"),
                        Metadata.remarksOf(rows)));
            }
        }
        list.sort(Comparator.comparing(Contracts.TableRow::name, Metadata.BY_NAME));
        return new Contracts.Rows<>(list);
    }

    /**
     * Columns are deliberately not sorted: they have a declared position, and
     * the order a table was defined in is information the editor shows.
     */
    public Contracts.Rows<?> columns(String catalog, String schema, String table) throws SQLException {
        if (MongoFields.isMongo(connection)) {
            // The JDBC driver's getColumns needs the Atlas SQL schema, which a
            // plain mongod does not have; it throws rather than returning
            // nothing. Sampling documents is what a collection can answer.
            return MongoFields.sampleFields(connection, table);
        }

        DatabaseMetaData meta = connection.getMetaData();

        Keys.PrimaryKey primaryKey = Keys.primaryKeyOf(meta, catalog, schema, table);

        List<Contracts.ColumnRow> list = new ArrayList<>();
        try (ResultSet rows =
                meta.getColumns(Metadata.orNull(catalog), Metadata.orNull(Metadata.literal(meta, schema)), Metadata.literal(meta, table), "%")) {
            while (rows.next()) {
                if (!Metadata.isRowFor(rows, "TABLE_NAME", table) || !Metadata.isRowFor(rows, "TABLE_SCHEM", schema)) {
                    continue;
                }
                list.add(Metadata.columnRow(rows, primaryKey.columns));
            }
        }
        return new Contracts.Rows<>(list);
    }
}
