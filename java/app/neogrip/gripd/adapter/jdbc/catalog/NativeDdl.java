package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import neogrip.gripd.adapter.jdbc.Running;
import neogrip.gripd.contract.Contracts;

/**
 * The server's own CREATE TABLE where one statement produces it, or null -
 * a normal answer, not an error: the caller renders a definition from the
 * metadata in every null case.
 */
public final class NativeDdl {
    private final Connection connection;
    /** Where a statement is published so a cancel reaches it: the one catalog operation running SQL on the main connection. */
    private final Running running;
    private final String url;

    public NativeDdl(Connection connection, Running running, String url) {
        this.connection = connection;
        this.running = running;
        this.url = url == null ? "" : url;
    }

    /** A statement that has not produced one catalog row in this long is not going to. */
    private static final int DDL_TIMEOUT_SECONDS = 15;

    /**
     * Which shape of "show me this table" the server has: DatabaseMetaData has
     * no concept of a check constraint, a partition clause, a collation or a
     * trigger, so the server's own text is the better answer where one cheap
     * statement produces it.
     */
    private enum Native {
        /** SHOW CREATE TABLE, which answers with the name first and the DDL second. */
        SHOW_CREATE_SECOND,
        /** SHOW CREATE TABLE, which answers with the DDL alone. */
        SHOW_CREATE_FIRST,
        /** sqlite_master, which keeps the text the table was created with. */
        SQLITE_MASTER,
        /** pg_catalog, where the pieces have to be put back together. */
        PG_CATALOG,
        /** No statement at all; the caller renders the definition itself. */
        NONE
    }

    /** The server's own CREATE TABLE, or null - failing would only take away the better answer. */
    public Contracts.Ddl nativeDdl(String catalog, String schema, String table) {
        String ddl = null;
        try {
            ddl = nativeDdlText(catalog, schema, table);
        } catch (SQLException | RuntimeException refused) {
            // Several drivers wrap a protocol-level refusal in a RuntimeException.
            ddl = null;
        }
        return new Contracts.Ddl(ddl);
    }

    private String nativeDdlText(String catalog, String schema, String table) throws SQLException {
        if (Metadata.orNull(table) == null) {
            return null;
        }
        try {
            return switch (nativeShape()) {
                // Either qualifier serves MySQL and MariaDB; see doc/internals.md#schema-and-tree.
                case SHOW_CREATE_SECOND -> showCreate(
                        qualified('`', Metadata.orNull(schema) != null ? schema : catalog, table), 2);
                // Trino's name has three parts, and the connection is pinned to one catalog.
                case SHOW_CREATE_FIRST -> showCreate(qualified('"', catalog, schema, table), 1);
                case SQLITE_MASTER -> sqliteSql(table);
                case PG_CATALOG -> postgresDdl(schema, table);
                case NONE -> null;
            };
        } finally {
            // A branch that threw must not leave a closed statement where a cancel would find it.
            running.clear();
        }
    }

    private static Native shapeOf(String engine) {
        return switch (engine) {
            case "mysql", "mariadb" -> Native.SHOW_CREATE_SECOND;
            case "trino", "presto" -> Native.SHOW_CREATE_FIRST;
            case "sqlite" -> Native.SQLITE_MASTER;
            case "postgresql", "postgres" -> Native.PG_CATALOG;
            // Engines with no one-statement DDL; see doc/internals.md#schema-and-tree.
            default -> Native.NONE;
        };
    }

    private Native nativeShape() {
        return shapeOf(Metadata.engine(connection, url));
    }

    /**
     * A name a statement can carry: the closing quote is doubled inside the
     * name, so a table called `order by` or one with a quote in it names
     * itself rather than ending the identifier early.
     */
    private static String qualified(char quote, String... parts) {
        String mark = String.valueOf(quote);
        StringBuilder name = new StringBuilder();
        for (String part : parts) {
            if (Metadata.orNull(part) == null) {
                continue;
            }
            if (name.length() > 0) {
                name.append('.');
            }
            name.append(quote).append(part.replace(mark, mark + mark)).append(quote);
        }
        return name.toString();
    }

    /**
     * A statement where a cancel can find it, with a ceiling: this runs on the
     * main connection, so a hang here is the user's next query hanging too.
     */
    private void publish(Statement statement) {
        running.set(statement);
        try {
            statement.setQueryTimeout(DDL_TIMEOUT_SECONDS);
        } catch (SQLException unsupported) {
            // Not every driver implements the knob; the statement still runs.
        }
    }

    /**
     * @param column which column carries the text; see doc/internals.md#schema-and-tree.
     */
    private String showCreate(String name, int column) throws SQLException {
        try (Statement statement = connection.createStatement()) {
            publish(statement);
            try (ResultSet rows = statement.executeQuery("SHOW CREATE TABLE " + name)) {
                return rows.next() ? Metadata.orNull(rows.getString(column)) : null;
            }
        }
    }

    private String sqliteSql(String table) throws SQLException {
        // sqlite_master keeps the verbatim statement; see doc/internals.md#schema-and-tree.
        try (PreparedStatement statement =
                connection.prepareStatement("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")) {
            publish(statement);
            statement.setString(1, table);
            try (ResultSet rows = statement.executeQuery()) {
                return rows.next() ? Metadata.orNull(rows.getString(1)) : null;
            }
        }
    }

    /**
     * PostgreSQL has no function that answers a table's definition, so the two
     * halves worth having are concatenated: the constraints (where a CHECK
     * lives) and the standalone indexes pg_get_indexdef renders. The names are
     * bound as parameters: a table name is the user's text.
     */
    private String postgresDdl(String schema, String table) throws SQLException {
        String name = qualified('"', schema, table);
        // An unnamed schema means the search path, which resolves to public in practice.
        String namespace = Metadata.orNull(schema) != null ? schema : "public";
        StringBuilder ddl = new StringBuilder();

        try (PreparedStatement statement = connection.prepareStatement("SELECT c.conname,"
                + " pg_catalog.pg_get_constraintdef(c.oid)"
                + " FROM pg_catalog.pg_constraint c"
                + " JOIN pg_catalog.pg_class t ON t.oid = c.conrelid"
                + " JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace"
                + " WHERE t.relname = ? AND n.nspname = ?"
                + " ORDER BY c.conname")) {
            publish(statement);
            statement.setString(1, table);
            statement.setString(2, namespace);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String definition = Metadata.orNull(rows.getString(2));
                    if (definition == null) {
                        continue;
                    }
                    ddl.append("ALTER TABLE ")
                            .append(name)
                            .append(" ADD CONSTRAINT ")
                            .append(qualified('"', rows.getString(1)))
                            .append(' ')
                            .append(definition)
                            .append(";\n");
                }
            }
        }

        // Only the indexes not already above: a primary key or unique constraint owns an index
        // the constraint pass already emitted, and the oid the exclusion needs is
        // pg_index.indexrelid, which the pg_indexes view does not expose.
        try (PreparedStatement statement = connection.prepareStatement(
                "SELECT x.relname, pg_catalog.pg_get_indexdef(i.indexrelid)"
                        + " FROM pg_catalog.pg_index i"
                        + " JOIN pg_catalog.pg_class t ON t.oid = i.indrelid"
                        + " JOIN pg_catalog.pg_class x ON x.oid = i.indexrelid"
                        + " JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace"
                        + " WHERE t.relname = ? AND n.nspname = ?"
                        + " AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint c"
                        + " WHERE c.conindid = i.indexrelid)"
                        + " ORDER BY x.relname")) {
            publish(statement);
            statement.setString(1, table);
            statement.setString(2, namespace);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String definition = Metadata.orNull(rows.getString(2));
                    if (definition != null) {
                        ddl.append(definition).append(";\n");
                    }
                }
            }
        }

        // An empty string would have the editor show a heading over nothing.
        return ddl.length() == 0 ? null : ddl.toString();
    }
}
