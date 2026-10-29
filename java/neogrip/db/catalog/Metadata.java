package neogrip.db.catalog;

import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import neogrip.db.types.Types;

/**
 * The shared readers of DatabaseMetaData result sets: the hard-won quirks -
 * patterns where JDBC wants names, optional columns drivers leave out, type
 * rendering - that every catalog unit leans on.
 */
public final class Metadata {
    private Metadata() {}

    static String orNull(String value) {
        return value == null || value.isEmpty() ? null : value;
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
    static List<String> schemaNames(DatabaseMetaData meta, String catalog, int limit) {
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

    static boolean isSystem(String tableType) {
        if (tableType == null) return false;
        String type = tableType.toUpperCase();
        return type.startsWith("SYSTEM") || type.equals("INDEX") || type.equals("SEQUENCE");
    }

    static String kind(String tableType) {
        if (tableType == null) return "table";
        return switch (tableType.toUpperCase()) {
            case "VIEW" -> "view";
            case "MATERIALIZED VIEW", "MATVIEW" -> "matview";
            case "COLLECTION" -> "collection";
            case "LOCAL TEMPORARY", "GLOBAL TEMPORARY", "TEMPORARY TABLE" -> "temp";
            default -> "table";
        };
    }

    /** One column of a getColumns row. Shared by columns, snapshot and details. */
    static Types.ColumnRow columnRow(ResultSet rows, Set<String> primaryKeys) throws SQLException {
        String name = rows.getString("COLUMN_NAME");
        // The two flags ride as Boolean and only when set, because they are
        // what the renderer appends a clause for: a false one would have it
        // asking about every ordinary column. Not every driver fills in every
        // optional column of the metadata result; a missing one is not a
        // reason to fail. The position survives because a reader that merged
        // two answers - the sweep's and a later per-table pass - has no other
        // way back to the order the table declares.
        return new Types.ColumnRow(
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
     * A comment, where the object has one.
     *
     * Columns and tables both carry theirs under REMARKS, and both leave it
     * out rather than write an empty string: a renderer then has one thing to
     * test instead of two.
     */
    static String remarksOf(ResultSet rows) {
        return orNull(optionalString(rows, "REMARKS"));
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
            // A driver that will not describe the table has still described
            // its columns, which is the part this answer is for.
        }
        return null;
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
     * Whether a metadata row is really about the object that was asked for.
     *
     * A driver that reports nothing for the column is taken at its word -- an
     * engine without schemas has no TABLE_SCHEM to compare -- so this only ever
     * rejects a row that names something else.
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
}
