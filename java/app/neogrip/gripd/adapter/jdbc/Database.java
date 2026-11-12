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
 * What the handlers ask to have something done on the database: the
 * {@link ExecutionLane} serializes the shared connection, a
 * {@link ConnectionScope} holds everything bound to it, and this class picks
 * the one out of the other. Reading the scope before taking the lane refuses
 * a pre-connect request at once instead of queueing it behind a statement.
 */
public final class Database implements RpcLifecycle {
    private final Session session;
    private final ExecutionLane lane = new ExecutionLane();
    /** Retained, not only handed to the watchdog: a statement reports itself. */
    private final Notifications notifications;

    /** One sweep at a time: a second would double the connections it opens. */
    private final AtomicBoolean sweeping = new AtomicBoolean();

    /** None until connect succeeds, and then one for the life of the process. */
    private volatile ConnectionScope scope;

    public Database(Session session, Notifications notifications) {
        this.session = session;
        this.notifications = notifications;
        new IdleWatchdog(() -> scope, session, notifications).start();
    }

    /**
     * Open the connection and bind everything that runs on it; the two steps
     * live together so neither can be forgotten or done in the wrong order.
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
        scope = new ConnectionScope(session, lane, notifications);
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
     * The one place a SQLException becomes something the rest of the program
     * can carry without declaring it (ADR-0032).
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
     * Stop and close one open result (ADR-0031): the cancel takes no lock -
     * Statement.cancel is safe from another thread - and only the close that
     * follows waits for the connection, which costs nothing since every
     * request runs on its own virtual thread (ADR-0028).
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
            // A cancel sent before this sweep must not end it on sight; the sweep runs outside
            // the lane on purpose, since holding the lock for minutes would queue every
            // statement behind it.
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

        // Every open result goes before the connection does.
        current.closeAllCursors();

        // Never commit on the way out (ADR-0013); this runs before the Session closes the
        // connection, because shutdown hooks fire in reverse order.
        if (current.inTransaction()) {
            current.rollbackQuietly();
        }
    }
}
