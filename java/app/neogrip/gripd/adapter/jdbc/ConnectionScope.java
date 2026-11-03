package neogrip.gripd.adapter.jdbc;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.List;
import neogrip.gripd.adapter.export.Exports;
import neogrip.gripd.adapter.jdbc.catalog.Counts;
import neogrip.gripd.adapter.jdbc.catalog.Details;
import neogrip.gripd.adapter.jdbc.catalog.Introspect;
import neogrip.gripd.adapter.jdbc.catalog.Listings;
import neogrip.gripd.adapter.jdbc.catalog.NativeDdl;
import neogrip.gripd.adapter.jdbc.catalog.Snapshot;
import neogrip.gripd.domain.ReadonlyPolicy;

/**
 * Everything bound to one open connection, built once when it opens.
 *
 * What this replaced was ten volatile fields and a lazy bind() that compared
 * the live connection against the one it had last seen - on every single
 * operation, to answer a question that can only change once, because there is
 * one connection per process (ADR-0003). The scope is built when connect
 * succeeds and handed over whole; before that there is none, and asking for
 * one is what refuses a statement sent before connect.
 */
public final class ConnectionScope {
    private final ExecutionLane lane;
    private final Statements statements;
    private final Cursors cursors;
    private final Exports exports;
    private final Transactions transactions;
    private final Listings listings;
    private final Snapshot snapshots;
    private final Details details;
    private final NativeDdl nativeDdl;
    private final Counts counts;
    private final Introspect introspect;

    ConnectionScope(Session session, ExecutionLane lane) {
        this.lane = lane;
        Connection connection = session.connection();
        ReadonlyPolicy guard = new ReadonlyPolicy(session.readonly());
        this.cursors = new Cursors();
        this.statements = new Statements(connection, lane.running(), guard, cursors);
        this.exports = new Exports(connection, lane.running(), guard);
        this.transactions = new Transactions(connection);
        this.listings = new Listings(connection);
        this.snapshots = new Snapshot(connection);
        this.details = new Details(connection);
        this.nativeDdl = new NativeDdl(connection, lane.running(), session.url());
        this.counts = new Counts(connection, lane.running(), session.url());
        // The url and the properties go with it so a catalog sweep can open
        // connections of its own rather than take this one.
        this.introspect = new Introspect(connection, lane.sweepCancelled(), session.url(), session.properties());
    }

    /** Is a transaction open on this connection? */
    boolean inTransaction() {
        return transactions.inTransaction();
    }

    /**
     * Roll back through the lane, where it cannot race a statement.
     *
     * @return whether it went through; a failure needs no report of its own,
     *     because the connection says so itself on the next statement
     */
    boolean rollbackQuietly() {
        try {
            lane.serializeSql(() -> {
                transactions.rollback();
                return null;
            });
            return true;
        } catch (SQLException ignored) {
            return false;
        }
    }

    /** Results untouched for longer than the window, taken out and closed. */
    void closeExpiredCursors(long idleMs) {
        List<Cursor> expired = cursors.expired(idleMs);
        if (expired.isEmpty()) {
            return;
        }
        lane.serializeQuietly(() -> expired.forEach(Cursor::close));
    }

    /** Every open result, on the way out. */
    void closeAllCursors() {
        lane.serializeQuietly(() -> cursors.drain().forEach(Cursor::close));
    }

    Statements statements() {
        return statements;
    }

    Cursors cursors() {
        return cursors;
    }

    Exports exports() {
        return exports;
    }

    Transactions transactions() {
        return transactions;
    }

    Listings listings() {
        return listings;
    }

    Snapshot snapshots() {
        return snapshots;
    }

    Details details() {
        return details;
    }

    NativeDdl nativeDdl() {
        return nativeDdl;
    }

    Counts counts() {
        return counts;
    }

    Introspect introspect() {
        return introspect;
    }
}
