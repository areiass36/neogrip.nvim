package neogrip.db.catalog;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.db.types.Types;

/**
 * The server's own CREATE TABLE, where one statement produces it, or null.
 * Null is a normal answer and not an error: most engines have no such
 * statement, a view is not a table on the ones that do, and the caller renders
 * a definition from the metadata in every one of those cases.
 */
public final class NativeDdl {
    private final Connection connection;
    /**
     * Where a statement this class runs is published, so a cancel reaches it:
     * the one catalog operation that runs SQL on the main connection.
     */
    private final AtomicReference<Statement> running;
    /** What this process connected with, which names the engine. */
    private final String url;

    public NativeDdl(Connection connection, AtomicReference<Statement> running, String url) {
        this.connection = connection;
        this.running = running;
        this.url = url == null ? "" : url;
    }

    /**
     * A definition is one row out of the server's own catalog; a statement
     * that has not produced it in this long is not going to.
     */
    private static final int DDL_TIMEOUT_SECONDS = 15;

    /**
     * Which shape of "show me this table" the server has, if it has one.
     *
     * DatabaseMetaData has no concept of a check constraint, and none of a
     * partition clause, a storage option, a collation or a trigger either - so
     * a definition rendered from metadata alone is missing whatever the server
     * would have said. Where the server will say it in one cheap statement,
     * that text is the better answer.
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

    /**
     * The server's own CREATE TABLE, or null.
     *
     * Null is a normal answer and not an error: most engines have no such
     * statement, a view is not a table on the ones that do, and a server that
     * refuses is still a server the editor has to show a definition for. The
     * caller renders one from the metadata in every one of those cases, so
     * failing here would only take away the better answer when it was
     * available and leave nothing in its place.
     */
    public Types.Ddl nativeDdl(String catalog, String schema, String table) {
        String ddl = null;
        try {
            ddl = nativeDdlText(catalog, schema, table);
        } catch (SQLException | RuntimeException refused) {
            // A driver that throws for a missing table, an unsupported
            // statement or a permission the connection does not have. The
            // RuntimeException is not defensiveness for its own sake: several
            // drivers wrap a protocol-level refusal in one.
            ddl = null;
        }
        return new Types.Ddl(ddl);
    }

    private String nativeDdlText(String catalog, String schema, String table) throws SQLException {
        if (Metadata.orNull(table) == null) {
            return null;
        }
        try {
            return switch (nativeShape()) {
                // MySQL and MariaDB report their databases as catalogs and
                // have no schema layer, so the qualifier is whichever of the
                // two the caller filled in.
                case SHOW_CREATE_SECOND -> showCreate(
                        qualified('`', Metadata.orNull(schema) != null ? schema : catalog, table), 2);
                // Trino's name has three parts, and the connection is pinned to
                // one catalog - so naming it is a check as much as a qualifier.
                case SHOW_CREATE_FIRST -> showCreate(qualified('"', catalog, schema, table), 1);
                case SQLITE_MASTER -> sqliteSql(table);
                case PG_CATALOG -> postgresDdl(schema, table);
                case NONE -> null;
            };
        } finally {
            // Cleared here rather than in each branch, so a branch that threw
            // does not leave a closed statement where a cancel would find it.
            running.set(null);
        }
    }

    private static Native shapeOf(String engine) {
        return switch (engine) {
            case "mysql", "mariadb" -> Native.SHOW_CREATE_SECOND;
            case "trino", "presto" -> Native.SHOW_CREATE_FIRST;
            case "sqlite" -> Native.SQLITE_MASTER;
            case "postgresql", "postgres" -> Native.PG_CATALOG;
            // DuckDB, SQL Server and MongoDB, and anything else that turns up:
            // none of them answers a table's definition in one statement.
            default -> Native.NONE;
        };
    }

    private Native nativeShape() {
        return shapeOf(engine());
    }

    /**
     * Which engine this is, preferring the url the driver reports over the one
     * this process was started with, and falling back to what the server calls
     * itself for a url the scheme cannot be read out of.
     */
    private String engine() {
        String jdbcUrl = url;
        try {
            String reported = connection.getMetaData().getURL();
            if (reported != null && !reported.isEmpty()) {
                jdbcUrl = reported;
            }
        } catch (SQLException ignored) {
            // The url this process was started with names the same engine.
        }
        String named = engineOf(jdbcUrl);
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
     * url: the rest of it can carry a file path, and a DuckDB file called
     * postgres_dump.duckdb must not be mistaken for a PostgreSQL server.
     */
    private static String engineOf(String jdbcUrl) {
        String lower = jdbcUrl.toLowerCase();
        if (!lower.startsWith("jdbc:")) {
            return "";
        }
        int end = lower.indexOf(':', "jdbc:".length());
        return end > 0 ? lower.substring("jdbc:".length(), end) : "";
    }

    /**
     * A name a statement can carry, with only the parts that were given.
     *
     * Quoting here rather than in Lua because this is the one place in this
     * file that builds a statement out of a name: the closing character is
     * doubled inside the name, which is what every one of these engines
     * accepts, so a table called `order by` or one with a quote in it names
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
     * A statement where a cancel can find it, with a ceiling on how long it
     * may run: this runs on the main connection, which is the user's, so a
     * statement that hangs here is the user's next query hanging too.
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
     * @param column which column carries the text: MySQL answers with the
     *               table's name first and its definition second, Trino with
     *               the definition alone.
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
        // SQLite keeps the statement it was given, so this is not a rendering
        // of the table but the text that created it, down to the comments.
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
     * PostgreSQL has no function that answers with a table's definition - what
     * psql prints it assembles itself out of a dozen queries - so the two
     * halves worth having are concatenated: the constraints, which is where a
     * CHECK lives and the reason to ask the server at all, and the indexes
     * that stand on their own, which pg_get_indexdef renders as statements.
     *
     * Each constraint is prefixed with its ALTER TABLE so the result is a
     * script rather than a list of fragments, and the names are bound as
     * parameters: a table name is the user's text, and the only thing worse
     * than not having the DDL is pasting a name into a statement.
     */
    private String postgresDdl(String schema, String table) throws SQLException {
        String name = qualified('"', schema, table);
        // An unnamed schema means the search path, and public is what that
        // resolves to on every PostgreSQL this is likely to meet.
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

        // Only the indexes that are not already above. A primary key or a
        // unique constraint owns an index, and the index listings show that
        // index like any other - so the constraint pass and this one would
        // each emit a statement for the same relation, which in a buffer the
        // user reads and yanks out of is not a duplicate but a mistake. The
        // oid the exclusion needs is pg_index.indexrelid, which the pg_indexes
        // view does not expose, so this asks the catalogs underneath it.
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

        // A table whose constraints and indexes are all accounted for already
        // has nothing here the metadata did not have, and an empty string
        // would have the editor show a heading over nothing.
        return ddl.length() == 0 ? null : ddl.toString();
    }
}
