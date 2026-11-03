package neogrip.db;

import java.io.IOException;
import java.sql.SQLException;
import java.util.Optional;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;
import neogrip.db.catalog.Details;
import neogrip.db.catalog.Introspect;
import neogrip.db.catalog.Listings;
import neogrip.db.catalog.NativeDdl;
import neogrip.db.catalog.Snapshot;
import neogrip.db.errors.NotConnected;
import neogrip.db.errors.RequestRefused;
import neogrip.db.types.Types;
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
    public Types.ConnectResult open(
            String url,
            Properties properties,
            boolean readonly,
            long transactionIdleSeconds,
            long cursorIdleSeconds)
            throws SQLException {
        session.open(url, properties, readonly, transactionIdleSeconds, cursorIdleSeconds);
        scope = new ConnectionScope(session, lane);
        return new Types.ConnectResult(session.product(), session.driverName(), session.capabilities());
    }

    private ConnectionScope scope() {
        ConnectionScope current = scope;
        if (current == null) {
            throw new NotConnected();
        }
        return current;
    }

    // --- statements -------------------------------------------------------

    public Optional<Types.TxState> intercept(String sql) throws SQLException {
        Transactions transactions = scope().transactions();
        return lane.serializeSql(() -> transactions.intercept(sql));
    }

    public Object query(String hash, String sql, int limit, int timeoutSeconds) throws SQLException {
        Statements statements = scope().statements();
        return lane.serializeSql(() -> statements.query(hash, sql, limit, timeoutSeconds));
    }

    /** The next batch of an open result (ADR-0031). */
    public Types.QueryPage next(String hash, int limit) throws SQLException {
        Statements statements = scope().statements();
        return lane.serializeSql(() -> statements.next(hash, limit));
    }

    public Types.UpdateResult exec(String sql, int timeoutSeconds) throws SQLException {
        Statements statements = scope().statements();
        return lane.serializeSql(() -> statements.exec(sql, timeoutSeconds));
    }

    public void validate(String sql) throws SQLException {
        Statements statements = scope().statements();
        lane.serializeSql(() -> {
            statements.validate(sql);
            return null;
        });
    }

    public Types.ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds)
            throws SQLException, IOException {
        Exports exports = scope().exports();
        return lane.serialize(() -> exports.export(sql, path, format, nullMarker, timeoutSeconds));
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

    public Types.Rows<Types.Named> catalogs() throws SQLException {
        Listings listings = scope().listings();
        return lane.serializeSql(listings::catalogs);
    }

    public Types.Rows<Types.Named> schemas(String catalogName) throws SQLException {
        Listings listings = scope().listings();
        return lane.serializeSql(() -> listings.schemas(catalogName));
    }

    public Types.Rows<Types.TableRow> tables(String catalogName, String schema, String pattern)
            throws SQLException {
        Listings listings = scope().listings();
        return lane.serializeSql(() -> listings.tables(catalogName, schema, pattern));
    }

    public Types.Rows<?> columns(String catalogName, String schema, String table) throws SQLException {
        Listings listings = scope().listings();
        return lane.serializeSql(() -> listings.columns(catalogName, schema, table));
    }

    public Types.Rows<Types.TableWithColumns> snapshot(String catalogName, String schema) throws SQLException {
        Snapshot snapshots = scope().snapshots();
        return lane.serializeSql(() -> snapshots.snapshot(catalogName, schema));
    }

    public Object details(String catalogName, String schema, String table) throws SQLException {
        Details details = scope().details();
        return lane.serializeSql(() -> details.details(catalogName, schema, table));
    }

    public Object ddl(String catalogName, String schema, String table) throws SQLException {
        Details details = scope().details();
        return lane.serializeSql(() -> details.ddl(catalogName, schema, table));
    }

    public Types.Ddl nativeDdl(String catalogName, String schema, String table) {
        NativeDdl ddl = scope().nativeDdl();
        return lane.serializeValue(() -> ddl.nativeDdl(catalogName, schema, table));
    }

    public Types.IntrospectSummary introspect(
            String catalogName, String path, int parallelism, long budgetMs, boolean details)
            throws SQLException, IOException {
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
            return sweep.introspect(catalogName, path, parallelism, budgetMs, details);
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
