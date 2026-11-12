package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import neogrip.gripd.adapter.jdbc.Drivers;
import neogrip.gripd.adapter.jdbc.Running;
import neogrip.gripd.contract.Contracts;

/**
 * Approximate row counts, cheaply or not at all: engines with a catalog
 * estimate answer a whole namespace in one statement, the rest answer nothing
 * rather than having count(*) run on their behalf (ADR-0038), and nothing
 * here fails the request.
 */
public final class Counts {
    /** A catalog read that has not answered in this long is not an estimate worth waiting for. */
    private static final int TIMEOUT_SECONDS = 10;

    private final Connection connection;
    private final Running running;
    private final String url;

    public Counts(Connection connection, Running running, String url) {
        this.connection = connection;
        this.running = running;
        this.url = url;
    }

    public Contracts.Counts counts(String catalog, String schema) {
        Map<String, Long> estimates = new LinkedHashMap<>();
        // Either qualifier serves MySQL and MariaDB; see doc/internals.md#schema-and-tree.
        String qualifier = Metadata.orNull(schema) != null ? schema : catalog;
        try {
            switch (Metadata.engine(connection, url)) {
                case "postgresql" -> read(estimates, POSTGRES, qualifier);
                case "mysql", "mariadb" -> read(estimates, MYSQL, qualifier);
                case "sqlserver" -> read(estimates, SQLSERVER, qualifier);
                default -> {
                    // Some engines keep no row estimate; see doc/internals.md#schema-and-tree.
                }
            }
        } catch (SQLException | RuntimeException refused) {
            // A decoration nobody can produce is not an error.
        }
        return new Contracts.Counts(estimates);
    }

    /**
     * Never-analysed tables are left out along with views and foreign tables;
     * see doc/internals.md#schema-and-tree.
     */
    private static final String POSTGRES =
            """
            select c.relname, c.reltuples::bigint as estimate
              from pg_class c
              join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = ? and c.relkind in ('r', 'p', 'm') and c.reltuples >= 0
            """;

    /** An estimate or exact by storage engine; see doc/internals.md#schema-and-tree. */
    private static final String MYSQL =
            """
            select table_name, table_rows
              from information_schema.tables
             where table_schema = ? and table_rows is not null
            """;

    /**
     * Rows are counted once across the heap and the clustered index; see
     * doc/internals.md#schema-and-tree.
     */
    private static final String SQLSERVER =
            """
            select t.name, sum(p.row_count) as estimate
              from sys.tables t
              join sys.dm_db_partition_stats p on p.object_id = t.object_id
             where p.index_id in (0, 1) and schema_name(t.schema_id) = ?
             group by t.name
            """;

    private void read(Map<String, Long> into, String sql, String qualifier) throws SQLException {
        if (Metadata.orNull(qualifier) == null) {
            return;
        }
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            running.set(statement);
            Drivers.tolerate(() -> statement.setQueryTimeout(TIMEOUT_SECONDS));
            statement.setString(1, qualifier);
            try (ResultSet rows = statement.executeQuery()) {
                while (rows.next()) {
                    String name = rows.getString(1);
                    long estimate = rows.getLong(2);
                    if (name != null && !rows.wasNull()) {
                        into.put(name, estimate);
                    }
                }
            }
        } finally {
            running.clear();
        }
    }
}
