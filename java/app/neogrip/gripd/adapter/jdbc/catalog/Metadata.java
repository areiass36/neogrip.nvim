package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import neogrip.gripd.contract.Contracts;

/**
 * The shared readers of DatabaseMetaData result sets: the hard-won quirks -
 * patterns where JDBC wants names, optional columns drivers leave out, type
 * rendering - that every catalog unit leans on.
 */
public final class Metadata {
    private Metadata() {}

    /**
     * The order every listing answers in (ADR-0036): case-insensitive with
     * exact bytes breaking ties, so the order is total - which keyset paging
     * needs, since drivers answer in an order that can differ between two calls.
     */
    static final Comparator<String> BY_NAME =
            Comparator.nullsFirst(String.CASE_INSENSITIVE_ORDER.thenComparing(Comparator.naturalOrder()));

    static String orNull(String value) {
        return value == null || value.isEmpty() ? null : value;
    }

    /**
     * Which engine this is, preferring the url the driver reports over the one
     * this process was started with, and falling back to what the server calls
     * itself for a url the scheme cannot be read out of.
     */
    static String engine(Connection connection, String url) {
        String jdbcUrl = url == null ? "" : url;
        try {
            String reported = connection.getMetaData().getURL();
            if (reported != null && !reported.isEmpty()) {
                jdbcUrl = reported;
            }
        } catch (SQLException ignored) {
        }
        String named = schemeOf(jdbcUrl);
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
     * url; see doc/internals.md#schema-and-tree.
     */
    private static String schemeOf(String jdbcUrl) {
        String lower = jdbcUrl.toLowerCase();
        if (!lower.startsWith("jdbc:")) {
            return "";
        }
        int end = lower.indexOf(':', "jdbc:".length());
        return end > 0 ? lower.substring("jdbc:".length(), end) : "";
    }

    /**
     * The schemas of a catalog, each of them once, in {@link #BY_NAME} order
     * (ADR-0036); see doc/internals.md#schema-and-tree.
     */
    static List<String> schemaNames(DatabaseMetaData meta, String catalog, int limit) {
        Set<String> names = new LinkedHashSet<>();
        try (ResultSet rows = meta.getSchemas(orNull(catalog), null)) {
            // The limit bounds the distinct names rather than the rows read.
            while (rows.next() && names.size() < limit) {
                names.add(rows.getString("TABLE_SCHEM"));
            }
        } catch (SQLException ignored) {
            // Some engines have no schema layer; see doc/internals.md#schema-and-tree.
        }
        List<String> sorted = new ArrayList<>(names);
        sorted.sort(BY_NAME);
        return sorted;
    }

    static boolean isSystem(String tableType) {
        if (tableType == null) return false;
        String type = tableType.toUpperCase();
        return type.startsWith("SYSTEM") || type.equals("INDEX") || type.equals("SEQUENCE");
    }

    /**
     * One of three kinds and never the driver's own word (ADR-0036): a view is
     * a view however materialized, collection is a document store's, and
     * `table` covers everything else selectable.
     */
    static String kind(String tableType) {
        if (tableType == null) return "table";
        return switch (tableType.toUpperCase()) {
            case "VIEW", "MATERIALIZED VIEW", "MATVIEW", "SYSTEM VIEW" -> "view";
            // The Mongo wrapper builds its rows directly, but a driver answering getTables lands here too.
            case "COLLECTION" -> "collection";
            default -> "table";
        };
    }

    /** One column of a getColumns row. Shared by columns, snapshot and details. */
    static Contracts.ColumnRow columnRow(ResultSet rows, Set<String> primaryKeys) throws SQLException {
        String name = rows.getString("COLUMN_NAME");
        // The flags ride as Boolean and only when set, since they are what the renderer appends a
        // clause for; the position survives because a reader merging two answers has no other way
        // back to the order the table declares.
        return new Contracts.ColumnRow(
                String.valueOf(name),
                describeType(rows),
                optionalInt(rows, "NULLABLE", DatabaseMetaData.columnNullable)
                        != DatabaseMetaData.columnNoNulls,
                primaryKeys.contains(name),
                optionalString(rows, "COLUMN_DEF"),
                remarksOf(rows),
                isYes(optionalString(rows, "IS_AUTOINCREMENT")) ? Boolean.TRUE : null,
                isYes(optionalString(rows, "IS_GENERATEDCOLUMN")) ? Boolean.TRUE : null,
                optionalInt(rows, "ORDINAL_POSITION", 0));
    }

    /**
     * A REMARKS comment, left out rather than written as an empty string so a
     * renderer has one thing to test instead of two.
     */
    static String remarksOf(ResultSet rows) {
        return orNull(optionalString(rows, "REMARKS"));
    }

    /**
     * The table's own comment, worth a sixth metadata call so a live answer
     * carries the same COMMENT ON a snapshot does. The name is compared rather
     * than trusted: getTables takes a pattern, so foo_bar is also answered for
     * by fooXbar.
     */
    static String tableRemarks(
            DatabaseMetaData meta, String catalog, String schema, String table) {
        try (ResultSet rows =
                meta.getTables(orNull(catalog), orNull(literal(meta, schema)), literal(meta, table), null)) {
            while (rows.next()) {
                if (table.equals(rows.getString("TABLE_NAME"))) {
                    return remarksOf(rows);
                }
            }
        } catch (SQLException | RuntimeException ignored) {
            // A driver that will not describe the table has still described its columns.
        }
        return null;
    }

    /**
     * A name where JDBC wants a pattern: an underscore matches any single
     * character, so the columns of fato_cliente are also answered for
     * fatoXcliente. The driver's escape string says "take this literally", and
     * rows are still checked against the name because a driver is free to
     * ignore it.
     */
    static String literal(DatabaseMetaData meta, String name) {
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
     * Whether a metadata row is really about the object that was asked for;
     * this only ever rejects a row that names something else.
     */
    static boolean isRowFor(ResultSet rows, String column, String name) {
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
    static boolean isYes(String value) {
        return value != null && value.equalsIgnoreCase("YES");
    }

    static String optionalString(ResultSet rows, String column) {
        try {
            return rows.getString(column);
        } catch (SQLException e) {
            return null;
        }
    }

    static int optionalInt(ResultSet rows, String column, int fallback) {
        try {
            int value = rows.getInt(column);
            return rows.wasNull() ? fallback : value;
        } catch (SQLException e) {
            return fallback;
        }
    }

    /** varchar(50) and numeric(10,2) read better than varchar and numeric. */
    static String describeType(ResultSet rows) throws SQLException {
        String type = String.valueOf(optionalString(rows, "TYPE_NAME")).toLowerCase();
        int size = optionalInt(rows, "COLUMN_SIZE", 0);
        int digits = optionalInt(rows, "DECIMAL_DIGITS", -1);
        boolean hasDigits = digits >= 0;
        if (type.contains("char") || type.contains("binary")) {
            // Integer.MAX_VALUE is how a driver spells "unbounded"; see
            // doc/internals.md#schema-and-tree.
            boolean bounded = size > 0 && size < Integer.MAX_VALUE;
            return bounded ? type + "(" + size + ")" : type;
        }
        if ((type.contains("decimal") || type.contains("numeric")) && hasDigits) {
            return type + "(" + size + "," + digits + ")";
        }
        return type;
    }
}
