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
import java.util.concurrent.locks.ReentrantLock;
import neogrip.app.Session;
import neogrip.db.catalog.Details;
import neogrip.db.catalog.Introspect;
import neogrip.db.catalog.Listings;
import neogrip.db.catalog.NativeDdl;
import neogrip.db.catalog.Snapshot;
import neogrip.db.types.Types;
import neogrip.rpc.Notifier;
import neogrip.rpc.RpcLifecycle;

/**
 * The one object that controls the lifecycle of everything executed on the
 * database: the running-statement registry and cancellation, query timeouts,
 * and the whole transaction story - interception, the idle watchdog, rollback
 * (never commit) on shutdown. A component like any other: handlers inject it;
 * it reads the live connection from the Session when an operation arrives, so
 * it only comes alive at the first query after connect, and "not connected"
 * falls out of that accessor with no guard plumbing anywhere.
 *
 * Requests arrive each on its own thread (ADR-0028); the session lock here is
 * what serializes them onto the one connection JDBC allows. cancel never takes
 * the lock - Statement.cancel is the one JDBC call defined as safe from
 * another thread, and a cancel that queued behind the statement it should kill
 * would never kill anything. The sweep keeps its own one-at-a-time flag and,
 * as before, runs on sibling connections rather than under the lock.
 */
public final class Database implements RpcLifecycle {
    private final Session session;
    private final Notifier notifier;
    /** Fair, so queued statements keep their arrival order. */
    private final ReentrantLock sessionLock = new ReentrantLock(true);
    /** One sweep at a time: a second would double the connections it opens. */
    private final AtomicBoolean sweeping = new AtomicBoolean();

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

    public Database(Session session, Notifier notifier) {
        this.session = session;
        this.notifier = notifier;
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

    /** The serialization of the shared connection, in one place. */
    private <T> T locked(SessionCall<T> call) throws SQLException, IOException {
        sessionLock.lock();
        try {
            return call.run();
        } finally {
            sessionLock.unlock();
        }
    }

    @FunctionalInterface
    private interface SessionCall<T> {
        T run() throws SQLException, IOException;
    }

    /** The SQL-only overload, so statement callers do not declare IOException. */
    private <T> T lockedSql(SqlCall<T> call) throws SQLException {
        sessionLock.lock();
        try {
            return call.run();
        } finally {
            sessionLock.unlock();
        }
    }

    @FunctionalInterface
    private interface SqlCall<T> {
        T run() throws SQLException;
    }

    // --- statements -------------------------------------------------------

    public Optional<Types.TxState> intercept(String sql) throws SQLException {
        return lockedSql(() -> bind().transactions.intercept(sql));
    }

    public Object query(String sql, int limit, int offset, int timeoutSeconds) throws SQLException {
        return lockedSql(() -> bind().statements.query(sql, limit, offset, timeoutSeconds));
    }

    public Types.UpdateResult exec(String sql, int timeoutSeconds) throws SQLException {
        return lockedSql(() -> bind().statements.exec(sql, timeoutSeconds));
    }

    public void validate(String sql) throws SQLException {
        lockedSql(() -> {
            bind().statements.validate(sql);
            return null;
        });
    }

    public Types.ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds)
            throws SQLException, IOException {
        return locked(() -> bind().exports.export(sql, path, format, nullMarker, timeoutSeconds));
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
        return lockedSql(() -> bind().listings.catalogs());
    }

    public Types.Rows<Types.Named> schemas(String catalogName) throws SQLException {
        return lockedSql(() -> bind().listings.schemas(catalogName));
    }

    public Types.Rows<Types.TableRow> tables(String catalogName, String schema, String pattern)
            throws SQLException {
        return lockedSql(() -> bind().listings.tables(catalogName, schema, pattern));
    }

    public Types.Rows<?> columns(String catalogName, String schema, String table) throws SQLException {
        return lockedSql(() -> bind().listings.columns(catalogName, schema, table));
    }

    public Types.Rows<Types.TableWithColumns> snapshot(String catalogName, String schema) throws SQLException {
        return lockedSql(() -> bind().snapshots.snapshot(catalogName, schema));
    }

    public Object details(String catalogName, String schema, String table) throws SQLException {
        return lockedSql(() -> bind().tableDetails.details(catalogName, schema, table));
    }

    public Object ddl(String catalogName, String schema, String table) throws SQLException {
        return lockedSql(() -> bind().tableDetails.ddl(catalogName, schema, table));
    }

    public Types.Ddl nativeDdl(String catalogName, String schema, String table) {
        sessionLock.lock();
        try {
            return bind().nativeDdl.nativeDdl(catalogName, schema, table);
        } finally {
            sessionLock.unlock();
        }
    }

    public Types.IntrospectSummary introspect(
            String catalogName, String path, int parallelism, long budgetMs, boolean details)
            throws SQLException, IOException {
        if (!sweeping.compareAndSet(false, true)) {
            throw new neogrip.rpc.RpcException(
                    neogrip.rpc.Wire.INVALID_REQUEST, "a catalog sweep is already running on this connection");
        }
        try {
            // The flag is shared with a running statement's cancel, so a cancel
            // sent before this sweep must not end it on sight. The sweep runs
            // outside the session lock on purpose: it opens sibling connections
            // of its own, and holding the lock for minutes would queue every
            // statement behind it - the exact thing it exists to avoid.
            cancelled.set(false);
            return bind().introspect.introspect(catalogName, path, parallelism, budgetMs, details);
        } finally {
            sweeping.set(false);
        }
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
                .scheduleAtFixedRate(this::rollbackIfIdle, 15, 15, TimeUnit.SECONDS);
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
        // Under the session lock, where it cannot race a running statement.
        sessionLock.lock();
        try {
            open.rollback();
        } catch (SQLException ignored) {
            // The connection will report its own state on the next statement.
        } finally {
            sessionLock.unlock();
        }
        notifier.notify("status", Map.of("phase", "transaction", "message", "idle transaction rolled back"));
    }

    @Override
    public void onShutdown() {
        // Never commit on the way out (ADR-0013); this runs before the Session
        // closes the connection, because shutdown hooks fire in reverse order.
        Transactions open = transactions;
        if (open != null && open.inTransaction()) {
            sessionLock.lock();
            try {
                open.rollback();
            } catch (SQLException ignored) {
                // Shutting down anyway.
            } finally {
                sessionLock.unlock();
            }
        }
    }
}
