package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.function.Function;
import neogrip.gripd.contract.Contracts;

/** The small catalog listings: catalogs, schemas, tables, columns. */
public final class Listings {
    /**
     * How many names a listing answers at once (ADR-0038).
     *
     * A ceiling on what is sent and not on what exists: before paging, a
     * schema with six hundred tables answered five hundred of them and said
     * nothing about the rest, which in a tree reads as missing data.
     */
    static final int PAGE = 500;

    private final Connection connection;

    public Listings(Connection connection) {
        this.connection = connection;
    }

    /**
     * One page of an ordered listing: what sorts after `after`, at most
     * `limit` of it.
     *
     * Keyset rather than offset, and stateless because of it: the client sends
     * back the last name it received and this resumes with the comparator the
     * list was ordered by, so nothing is skipped or repeated even if the
     * catalog changed between two pages.
     */
    private static <T> Contracts.Rows<T> page(
            List<T> ordered, Function<T, String> name, String after, int limit) {
        int size = limit > 0 ? limit : PAGE;
        boolean resuming = after != null && !after.isEmpty();
        List<T> out = new ArrayList<>(Math.min(size, ordered.size()));
        boolean more = false;
        for (T item : ordered) {
            if (resuming && Metadata.BY_NAME.compare(name.apply(item), after) <= 0) {
                continue;
            }
            if (out.size() == size) {
                more = true;
                break;
            }
            out.add(item);
        }
        return new Contracts.Rows<>(out, more ? Boolean.TRUE : null);
    }

    public Contracts.Rows<Contracts.Named> catalogs(String after, int limit) throws SQLException {
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
        return page(named(names), Contracts.Named::name, after, limit);
    }

    public Contracts.Rows<Contracts.Named> schemas(String catalog, String after, int limit)
            throws SQLException {
        // Every name, because the page is cut here: a cap inside the read would
        // make the last page depend on which names the driver answered first.
        List<String> names = Metadata.schemaNames(connection.getMetaData(), catalog, Integer.MAX_VALUE);
        return page(named(names), Contracts.Named::name, after, limit);
    }

    private static List<Contracts.Named> named(List<String> names) {
        List<Contracts.Named> rows = new ArrayList<>(names.size());
        for (String name : names) {
            rows.add(new Contracts.Named(String.valueOf(name)));
        }
        return rows;
    }

    public Contracts.Rows<Contracts.TableRow> tables(
            String catalog, String schema, String pattern, String after, int limit) throws SQLException {
        if (MongoFields.isMongo(connection)) {
            List<Contracts.TableRow> collections = new ArrayList<>();
            String needle = pattern == null ? "" : pattern.toLowerCase(java.util.Locale.ROOT);
            for (String name : MongoFields.collectionNames(connection)) {
                if (needle.isEmpty() || name.toLowerCase(java.util.Locale.ROOT).contains(needle)) {
                    collections.add(new Contracts.TableRow(name, "collection", null, null));
                }
            }
            collections.sort(Comparator.comparing(Contracts.TableRow::name, Metadata.BY_NAME));
            return page(collections, Contracts.TableRow::name, after, limit);
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
            while (rows.next()) {
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
        return page(list, Contracts.TableRow::name, after, limit);
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
        return Contracts.Rows.of(list);
    }
}
