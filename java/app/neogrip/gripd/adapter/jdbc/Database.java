package neogrip.gripd.adapter.jdbc;

import java.io.IOException;
import java.sql.SQLException;
import java.util.Optional;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;
import neogrip.gripd.adapter.export.Exports;
import neogrip.gripd.adapter.jdbc.catalog.Counts;
import neogrip.gripd.adapter.jdbc.catalog.Details;
import neogrip.gripd.adapter.jdbc.catalog.Introspect;
import neogrip.gripd.adapter.jdbc.catalog.Listings;
import neogrip.gripd.adapter.jdbc.catalog.NativeDdl;
import neogrip.gripd.adapter.jdbc.catalog.Snapshot;
import neogrip.gripd.contract.Contracts;
import neogrip.gripd.domain.Notifications;
import neogrip.gripd.domain.error.DataAccessException;
import neogrip.gripd.domain.error.NotConnected;
import neogrip.gripd.domain.error.RequestRefused;
import neogrip.jsonrpc.RpcLifecycle;

/**
 * What the handlers ask to have something done on the database.
 *
 * It owns no mechanism of its own any more: the {@link ExecutionLane} puts
 * requests through the shared connection one at a time, a
 * {@link ConnectionScope} holds everything bound to that connection, and this
 * class is what picks the one out of the other. What is left here is the
 * one-sweep-at-a-time rule and the end of the connection's life; the idle
 * transaction and the abandoned result are the watchdog's business.
 *
 * Reading the scope before taking the lane means a request that arrives before
 * connect is refused at once instead of queueing behind a statement it has
 * nothing to do with.
 */
public final class Database implements RpcLifecycle {
    private final Session session;
    private final ExecutionLane lane = new ExecutionLane();

    /** One sweep at a time: a second would double the connections it opens. */
    private final AtomicBoolean sweeping = new AtomicBoolean();

    /** None until connect succeeds, and then one for the life of the process. */
    private volatile ConnectionScope scope;

    public Database(Session session, Notifications notifications) {
        this.session = session;
        new IdleWatchdog(() -> scope, session, notifications).start();
    }

    /**
     * Open the connection and bind everything that runs on it.
     *
     * The two steps live together so they cannot be done in the wrong order,
     * or one of them forgotten: a scope without a connection has nothing to
     * execute on, and a connection without a scope is what the lazy bind this
     * replaced existed to paper over.
     */
    public Contracts.ConnectResult open(
            String url,
            Properties properties,
            boolean readonly,
            long transactionIdleSeconds,
            long cursorIdleSeconds) {
        try {
            session.open(url, properties, readonly, transactionIdleSeconds, cursorIdleSeconds);
        } catch (SQLException e) {
            throw new DataAccessException(e);
        }
        scope = new ConnectionScope(session, lane);
        return new Contracts.ConnectResult(session.product(), session.driverName(), session.capabilities());
    }

    private ConnectionScope scope() {
        ConnectionScope current = scope;
        if (current == null) {
            throw new NotConnected();
        }
        return current;
    }

    /**
     * Work on the connection, with the driver's exception translated on the
     * way out.
     *
     * Everything below this line speaks JDBC and nothing above it has to: this
     * is the one place a SQLException becomes something the rest of the
     * program can carry without declaring it (ADR-0032).
     */
    private <T> T onConnection(ExecutionLane.SqlCall<T> call) {
        try {
            return lane.serializeSql(call);
        } catch (SQLException e) {
            throw new DataAccessException(e);
        }
    }

    /** The same, for the work that also writes a file (ADR-0010). */
    private <T> T onConnectionWritingFiles(ExecutionLane.Call<T> call) {
        try {
            return lane.serialize(call);
        } catch (SQLException | IOException e) {
            throw new DataAccessException(e);
        }
    }

    // --- statements -------------------------------------------------------

    public Optional<Contracts.TxState> intercept(String sql) {
        Transactions transactions = scope().transactions();
        return onConnection(() -> transactions.intercept(sql));
    }

    public Object query(String hash, String sql, int limit, int timeoutSeconds) {
        Statements statements = scope().statements();
        return onConnection(() -> statements.query(hash, sql, limit, timeoutSeconds));
    }

    /** The next batch of an open result (ADR-0031). */
    public Contracts.QueryPage next(String hash, int limit) {
        Statements statements = scope().statements();
        return onConnection(() -> statements.next(hash, limit));
    }

    public Contracts.UpdateResult exec(String sql, int timeoutSeconds) {
        Statements statements = scope().statements();
        return onConnection(() -> statements.exec(sql, timeoutSeconds));
    }

    public void validate(String sql) {
        Statements statements = scope().statements();
        onConnection(() -> {
            statements.validate(sql);
            return null;
        });
    }

    public Contracts.ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds) {
        Exports exports = scope().exports();
        return onConnectionWritingFiles(() -> exports.export(sql, path, format, nullMarker, timeoutSeconds));
    }

    /**
     * Stop and close one open result (ADR-0031).
     *
     * The cancel itself takes no lock - Statement.cancel is the one JDBC call
     * defined as safe from another thread - and only the close that follows
     * waits for the connection to be free, because closing a ResultSet is
     * touching it. Waiting here costs nothing structural: every request runs on
     * its own virtual thread (ADR-0028), so the read loop is never what waits.
     */
    public boolean cancel(String hash) {
        if (hash == null || hash.isEmpty()) {
            return cancel();
        }
        ConnectionScope current = scope;
        Cursor cursor = current == null ? null : current.cursors().peek(hash);
        if (cursor == null) {
            return false;
        }
        cursor.interrupt();
        lane.serializeQuietly(() -> {
            current.cursors().detach(hash);
            cursor.close();
        });
        return true;
    }

    /**
     * Stop whatever runs. Answerable while a statement is busy because it
     * never takes the lane; the flag is what reaches a catalog sweep, which
     * has no statement to cancel.
     */
    public boolean cancel() {
        lane.sweepCancelled().set(true);
        return lane.running().cancel();
    }

    // --- catalog ----------------------------------------------------------

    public Contracts.Rows<Contracts.Named> catalogs(String after, int limit) {
        Listings listings = scope().listings();
        return onConnection(() -> listings.catalogs(after, limit));
    }

    public Contracts.Rows<Contracts.Named> schemas(String catalogName, String after, int limit) {
        Listings listings = scope().listings();
        return onConnection(() -> listings.schemas(catalogName, after, limit));
    }

    public Contracts.Rows<Contracts.TableRow> tables(
            String catalogName, String schema, String pattern, String after, int limit) {
        Listings listings = scope().listings();
        return onConnection(() -> listings.tables(catalogName, schema, pattern, after, limit));
    }

    public Contracts.Rows<?> columns(String catalogName, String schema, String table) {
        Listings listings = scope().listings();
        return onConnection(() -> listings.columns(catalogName, schema, table));
    }

    public Contracts.Rows<Contracts.TableWithColumns> snapshot(String catalogName, String schema) {
        Snapshot snapshots = scope().snapshots();
        return onConnection(() -> snapshots.snapshot(catalogName, schema));
    }

    public Object details(String catalogName, String schema, String table) {
        Details details = scope().details();
        return onConnection(() -> details.details(catalogName, schema, table));
    }

    public Object ddl(String catalogName, String schema, String table) {
        Details details = scope().details();
        return onConnection(() -> details.ddl(catalogName, schema, table));
    }

    /** Approximate row counts for a namespace, cheap or absent (ADR-0038). */
    public Contracts.Counts counts(String catalogName, String schema) {
        Counts estimates = scope().counts();
        return onConnection(() -> estimates.counts(catalogName, schema));
    }

    public Contracts.Ddl nativeDdl(String catalogName, String schema, String table) {
        NativeDdl ddl = scope().nativeDdl();
        return lane.serializeValue(() -> ddl.nativeDdl(catalogName, schema, table));
    }

    public Contracts.IntrospectSummary introspect(
            String catalogName,
            String schema,
            String path,
            int parallelism,
            long budgetMs,
            boolean details) {
        Introspect sweep = scope().introspect();
        if (!sweeping.compareAndSet(false, true)) {
            throw new RequestRefused("a catalog sweep is already running on this connection");
        }
        try {
            // The flag is shared with a running statement's cancel, so a cancel
            // sent before this sweep must not end it on sight. The sweep runs
            // outside the lane on purpose: it opens sibling connections of its
            // own, and holding the lock for minutes would queue every statement
            // behind it - the exact thing it exists to avoid.
            lane.sweepCancelled().set(false);
            return sweep.introspect(catalogName, schema, path, parallelism, budgetMs, details);
        } catch (SQLException | IOException e) {
            throw new DataAccessException(e);
        } finally {
            sweeping.set(false);
        }
    }

    @Override
    public void onShutdown() {
        ConnectionScope current = scope;
        if (current == null) {
            return;
        }

        // Every open result goes before the connection does, which is the
        // other reason this hook has to run before the Session one.
        current.closeAllCursors();

        // Never commit on the way out (ADR-0013); this runs before the Session
        // closes the connection, because shutdown hooks fire in reverse order.
        if (current.inTransaction()) {
            current.rollbackQuietly();
        }
    }
}
