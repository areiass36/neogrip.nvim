package neogrip.gripd.adapter.jdbc.catalog;

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
     * The order every listing answers in (ADR-0036).
     *
     * Case-insensitive because a tree reads better that way, with the exact
     * bytes breaking ties so the order is total and deterministic - which is
     * what keyset paging needs: the client echoes back the last name it saw and
     * the server resumes with this same comparator, so no name is skipped or
     * repeated. Drivers answer in whatever order their catalog tables happen to
     * have, which can differ between two calls.
     */
    static final Comparator<String> BY_NAME =
            Comparator.nullsFirst(String.CASE_INSENSITIVE_ORDER.thenComparing(Comparator.naturalOrder()));

    static String orNull(String value) {
        return value == null || value.isEmpty() ? null : value;
    }

    /**
     * The schemas of a catalog, each of them once.
     *
     * DuckDB reports main, information_schema and pg_catalog once per attached
     * catalog, so a database with three attached answers with main three
     * times - and a tree draws a row per schema, so the user is shown three
     * identical schemas, two of which answer with the same tables as the
     * first. Only the duplicates are dropped; the answer then comes back in
     * {@link #BY_NAME} order like every other listing (ADR-0036), not in the
     * order the driver happened to use.
     *
     * Names are deduplicated exactly. An engine that tells Main from main has
     * two schemas there, and folding the case would hide one of them behind the
     * other - which is the same bug as this one, with no way to notice it. The
     * ordering folds case and then breaks the tie on the exact bytes, so both
     * survive and land next to each other.
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
     * One of three kinds, and never the driver's own word (ADR-0036).
     *
     * A client draws the tree, so what it needs is a set small enough to write
     * one renderer against: a view is a view however it is materialized, a
     * collection is a document store's, and `table` is the definition of
     * everything else selectable - foreign, partitioned, temporary, an alias, a
     * sequence, and whatever a driver reports that nothing here has seen. The
     * engine's spelling is deliberately not carried alongside; the grouping is
     * the contract.
     */
    static String kind(String tableType) {
        if (tableType == null) return "table";
        return switch (tableType.toUpperCase()) {
            case "VIEW", "MATERIALIZED VIEW", "MATVIEW", "SYSTEM VIEW" -> "view";
            // The Mongo wrapper's listing builds its rows directly, but a
            // driver answering getTables with this should land here too.
            case "COLLECTION" -> "collection";
            default -> "table";
        };
    }

    /** One column of a getColumns row. Shared by columns, snapshot and details. */
    static Contracts.ColumnRow columnRow(ResultSet rows, Set<String> primaryKeys) throws SQLException {
        String name = rows.getString("COLUMN_NAME");
        // The two flags ride as Boolean and only when set, because they are
        // what the renderer appends a clause for: a false one would have it
        // asking about every ordinary column. Not every driver fills in every
        // optional column of the metadata result; a missing one is not a
        // reason to fail. The position survives because a reader that merged
        // two answers - the sweep's and a later per-table pass - has no other
        // way back to the order the table declares.
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
