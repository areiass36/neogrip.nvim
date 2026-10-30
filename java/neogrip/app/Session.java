package neogrip.app;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;
import neogrip.rpc.RpcException;
import neogrip.rpc.RpcLifecycle;
import neogrip.rpc.Wire;

/**
 * Connection control and metadata, nothing else: this class does not know or
 * care who executes things on the database. It opens the one JDBC connection,
 * answers the facts about it (product, driver, capabilities, readonly, the
 * url and properties a catalog sweep needs to open siblings), tracks when the
 * last request arrived, and closes the connection on shutdown - rollback is
 * the Database's job and runs first, because shutdown hooks fire in reverse
 * registration order.
 */
public final class Session implements RpcLifecycle {
    private volatile Connection connection;
    private volatile boolean readonly;
    private volatile long transactionIdleMs;
    private volatile long cursorIdleMs;
    private volatile long lastRequestAt = System.currentTimeMillis();
    private volatile String url = "";
    private volatile Properties properties = new Properties();
    private volatile String product;
    private volatile String driver;
    private volatile Map<String, Object> capabilities = Map.of();

    /** The one connect per process; a second is a client bug, said plainly. */
    public void open(String url, Properties properties, boolean readonly, long transactionIdleSeconds,
            long cursorIdleSeconds) throws SQLException {
        if (connection != null) {
            throw new RpcException(Wire.INVALID_REQUEST, "already connected");
        }
        Connection opened = DriverManager.getConnection(url, properties);
        if (readonly) {
            try {
                opened.setReadOnly(true);
            } catch (SQLException ignored) {
                // Only a hint in some drivers; the keyword check still refuses.
            }
        }
        this.url = url;
        this.properties = properties;
        this.readonly = readonly;
        this.transactionIdleMs = transactionIdleSeconds * 1000L;
        this.cursorIdleMs = cursorIdleSeconds * 1000L;
        describe(opened);
        this.connection = opened;
    }

    private void describe(Connection opened) {
        Map<String, Object> flags = new LinkedHashMap<>();
        try {
            DatabaseMetaData meta = opened.getMetaData();
            product = meta.getDatabaseProductName() + " " + meta.getDatabaseProductVersion();
            driver = meta.getDriverName() + " " + meta.getDriverVersion();
            flags.put("schemas", supports(meta::supportsSchemasInDataManipulation));
            flags.put("catalogs", supports(meta::supportsCatalogsInDataManipulation));
            flags.put("transactions", supports(meta::supportsTransactions));
        } catch (SQLException ignored) {
            // A driver that cannot describe itself is still usable.
        }
        flags.put("sql", true);
        flags.put("cancellation", true);
        capabilities = flags;
    }

    @FunctionalInterface
    private interface SqlFlag {
        boolean get() throws SQLException;
    }

    private static boolean supports(SqlFlag flag) {
        try {
            return flag.get();
        } catch (SQLException | RuntimeException e) {
            return false;
        }
    }

    /** The live connection, or the refusal every handler gets for free. */
    public Connection connection() {
        Connection open = connection;
        if (open == null) {
            throw new RpcException(Wire.INVALID_REQUEST, "not connected");
        }
        return open;
    }

    public boolean isOpen() {
        return connection != null;
    }

    public boolean readonly() {
        return readonly;
    }

    public long transactionIdleMs() {
        return transactionIdleMs;
    }

    /** How long an open result nobody continues is kept (ADR-0031). */
    public long cursorIdleMs() {
        return cursorIdleMs;
    }

    public long lastRequestAt() {
        return lastRequestAt;
    }

    public String url() {
        return url;
    }

    public Properties properties() {
        return properties;
    }

    public String product() {
        return product;
    }

    public String driverName() {
        return driver;
    }

    public Map<String, Object> capabilities() {
        return capabilities;
    }

    @Override
    public void onRequest() {
        lastRequestAt = System.currentTimeMillis();
    }

    @Override
    public void onShutdown() {
        Connection open = connection;
        connection = null;
        if (open != null) {
            try {
                open.close();
            } catch (SQLException ignored) {
                // Shutting down anyway.
            }
        }
    }
}
