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
 * How many rows a set has, approximately and cheaply - or nothing at all.
 *
 * The number decorates a node in a tree somebody else draws, so it has to cost
 * less than the walk that shows it. Every engine here that keeps an estimate in
 * its own catalog answers for a whole namespace in one statement, which is why
 * this takes a namespace and not a set. The engines that keep no estimate
 * answer with nothing rather than having `count(*)` run on their behalf
 * (ADR-0038): a client that gets no number shows no number, which is better
 * than a client that waits.
 *
 * Nothing here fails the request. An estimate is a decoration, and a server
 * that will not produce one - a permission the connection lacks, a catalog view
 * an old version does not have - has still answered the question that matters.
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
        // MySQL and MariaDB report their databases as catalogs and have no
        // schema layer, so the qualifier is whichever of the two was filled in.
        String qualifier = Metadata.orNull(schema) != null ? schema : catalog;
        try {
            switch (Metadata.engine(connection, url)) {
                case "postgresql" -> read(estimates, POSTGRES, qualifier);
                case "mysql", "mariadb" -> read(estimates, MYSQL, qualifier);
                case "sqlserver" -> read(estimates, SQLSERVER, qualifier);
                default -> {
                    // sqlite, duckdb, trino and the Mongo wrapper keep no row
                    // estimate; the only way to a number there is counting.
                }
            }
        } catch (SQLException | RuntimeException refused) {
            // Said above: a decoration nobody can produce is not an error.
        }
        return new Contracts.Counts(estimates);
    }

    /**
     * reltuples is what the planner uses, and it is -1 on a table that has
     * never been analysed (PostgreSQL 14 and up) - which is not an estimate, so
     * those are left out. Views and foreign tables have no estimate either.
     */
    private static final String POSTGRES =
            """
            select c.relname, c.reltuples::bigint as estimate
              from pg_class c
              join pg_namespace n on n.oid = c.relnamespace
             where n.nspname = ? and c.relkind in ('r', 'p', 'm') and c.reltuples >= 0
            """;

    /** table_rows is an estimate on InnoDB and exact on MyISAM; a view has none. */
    private static final String MYSQL =
            """
            select table_name, table_rows
              from information_schema.tables
             where table_schema = ? and table_rows is not null
            """;

    /**
     * index_id 0 and 1 are the heap and the clustered index: the rows, counted
     * once. The column is row_count - sys.partitions is the view with a column
     * called rows, and dm_db_partition_stats is not it.
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
