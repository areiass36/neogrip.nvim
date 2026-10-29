package neogrip.db;

import java.io.IOException;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.app.Session;
import neogrip.db.catalog.Details;
import neogrip.db.catalog.Introspect;
import neogrip.db.catalog.Listings;
import neogrip.db.catalog.NativeDdl;
import neogrip.db.catalog.Snapshot;
import neogrip.db.types.Types;
import neogrip.rpc.Notifier;
import neogrip.rpc.RpcLifecycle;
import neogrip.rpc.Worker;

/**
 * The one object that controls the lifecycle of everything executed on the
 * database: the running-statement registry and cancellation, query timeouts,
 * and the whole transaction story - interception, the idle watchdog, rollback
 * (never commit) on shutdown. A component like any other: handlers inject it;
 * it reads the live connection from the Session when an operation arrives, so
 * it only comes alive at the first query after connect, and "not connected"
 * falls out of that accessor with no guard plumbing anywhere.
 */
public final class Database implements RpcLifecycle {
    private final Session session;
    private final Notifier notifier;
    /** The statement worker lane: the watchdog's rollback runs there, where it cannot race a statement. */
    private final Worker worker;

    private final AtomicReference<Statement> running = new AtomicReference<>();
    /** A catalog sweep has no statement to cancel, so a cancel reaches it as a flag. */
    private final AtomicBoolean cancelled = new AtomicBoolean();

    private volatile Connection bound;
    private volatile Statements statements;
    private volatile Exports exports;
    private volatile Transactions transactions;
    private volatile Listings listings;
    private volatile Snapshot snapshots;
    private volatile Details tableDetails;
    private volatile NativeDdl nativeDdl;
    private volatile Introspect introspect;

    public Database(Session session, Notifier notifier, Worker worker) {
        this.session = session;
        this.notifier = notifier;
        this.worker = worker;
        startTransactionWatchdog();
    }

    /** The units, bound to the live connection the first time it is used. */
    private synchronized Database bind() {
        Connection connection = session.connection();
        if (connection != bound) {
            ReadonlyGuard guard = new ReadonlyGuard(session.readonly());
            statements = new Statements(connection, running, guard);
            exports = new Exports(connection, running, guard);
            transactions = new Transactions(connection);
            listings = new Listings(connection);
            snapshots = new Snapshot(connection);
            tableDetails = new Details(connection);
            nativeDdl = new NativeDdl(connection, running, session.url());
            // The url and the properties go with it so a catalog sweep can
            // open connections of its own rather than take this one.
            introspect = new Introspect(connection, cancelled, session.url(), session.properties());
            bound = connection;
        }
        return this;
    }

    // --- statements -------------------------------------------------------

    public Optional<Types.TxState> intercept(String sql) throws SQLException {
        return bind().transactions.intercept(sql);
    }

    public Object query(String sql, int limit, int offset, int timeoutSeconds) throws SQLException {
        return bind().statements.query(sql, limit, offset, timeoutSeconds);
    }

    public Types.UpdateResult exec(String sql, int timeoutSeconds) throws SQLException {
        return bind().statements.exec(sql, timeoutSeconds);
    }

    public void validate(String sql) throws SQLException {
        bind().statements.validate(sql);
    }

    public Types.ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds)
            throws SQLException, IOException {
        return bind().exports.export(sql, path, format, nullMarker, timeoutSeconds);
    }

    /**
     * Stop whatever runs. Handled on the read lane, so it is answerable while
     * the worker is busy; the flag reaches a catalog sweep, which has no
     * statement to cancel.
     */
    public boolean cancel() {
        cancelled.set(true);
        Statement statement = running.get();
        if (statement == null) {
            return false;
        }
        try {
            statement.cancel();
            return true;
        } catch (SQLException refused) {
            // Some drivers refuse; killing the process is the fallback.
            return false;
        }
    }

    // --- catalog ----------------------------------------------------------

    public Types.Rows<Types.Named> catalogs() throws SQLException {
        return bind().listings.catalogs();
    }

    public Types.Rows<Types.Named> schemas(String catalogName) throws SQLException {
        return bind().listings.schemas(catalogName);
    }

    public Types.Rows<Types.TableRow> tables(String catalogName, String schema, String pattern)
            throws SQLException {
        return bind().listings.tables(catalogName, schema, pattern);
    }

    public Types.Rows<?> columns(String catalogName, String schema, String table) throws SQLException {
        return bind().listings.columns(catalogName, schema, table);
    }

    public Types.Rows<Types.TableWithColumns> snapshot(String catalogName, String schema) throws SQLException {
        return bind().snapshots.snapshot(catalogName, schema);
    }

    public Object details(String catalogName, String schema, String table) throws SQLException {
        return bind().tableDetails.details(catalogName, schema, table);
    }

    public Object ddl(String catalogName, String schema, String table) throws SQLException {
        return bind().tableDetails.ddl(catalogName, schema, table);
    }

    public Types.Ddl nativeDdl(String catalogName, String schema, String table) {
        return bind().nativeDdl.nativeDdl(catalogName, schema, table);
    }

    public Types.IntrospectSummary introspect(
            String catalogName, String path, int parallelism, long budgetMs, boolean details)
            throws SQLException, IOException {
        // The flag is shared with a running statement's cancel, so a cancel
        // sent before this sweep must not end it on sight.
        cancelled.set(false);
        return bind().introspect.introspect(catalogName, path, parallelism, budgetMs, details);
    }

    // --- the idle-transaction watchdog (ADR-0013) -------------------------

    /**
     * An idle open transaction holds locks, so one that has seen no request
     * for the configured window is rolled back - never committed - and the
     * editor is told. The check itself is cheap and runs on a timer; the
     * rollback runs on the worker lane, where it cannot race a statement for
     * the connection.
     */
    private void startTransactionWatchdog() {
        Executors.newSingleThreadScheduledExecutor(task -> {
                    Thread thread = new Thread(task, "neogrip-tx-watchdog");
                    thread.setDaemon(true);
                    return thread;
                })
                .scheduleAtFixedRate(() -> worker.submit(this::rollbackIfIdle), 15, 15, TimeUnit.SECONDS);
    }

    private void rollbackIfIdle() {
        Transactions open = transactions;
        long idleMs = session.transactionIdleMs();
        if (open == null
                || idleMs <= 0
                || !open.inTransaction()
                || System.currentTimeMillis() - session.lastRequestAt() < idleMs) {
            return;
        }
        try {
            open.rollback();
        } catch (SQLException ignored) {
            // The connection will report its own state on the next statement.
        }
        notifier.notify("status", Map.of("phase", "transaction", "message", "idle transaction rolled back"));
    }

    @Override
    public void onShutdown() {
        // Never commit on the way out (ADR-0013); this runs before the Session
        // closes the connection, because shutdown hooks fire in reverse order.
        Transactions open = transactions;
        if (open != null && open.inTransaction()) {
            try {
                open.rollback();
            } catch (SQLException ignored) {
                // Shutting down anyway.
            }
        }
    }
}
