package neogrip.db;

import java.sql.Connection;
import neogrip.db.catalog.Details;
import neogrip.db.catalog.Introspect;
import neogrip.db.catalog.Listings;
import neogrip.db.catalog.NativeDdl;
import neogrip.db.catalog.Snapshot;

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
    private final Statements statements;
    private final Cursors cursors;
    private final Exports exports;
    private final Transactions transactions;
    private final Listings listings;
    private final Snapshot snapshots;
    private final Details details;
    private final NativeDdl nativeDdl;
    private final Introspect introspect;

    ConnectionScope(Session session, ExecutionLane lane) {
        Connection connection = session.connection();
        ReadonlyGuard guard = new ReadonlyGuard(session.readonly());
        this.cursors = new Cursors();
        this.statements = new Statements(connection, lane.running(), guard, cursors);
        this.exports = new Exports(connection, lane.running(), guard);
        this.transactions = new Transactions(connection);
        this.listings = new Listings(connection);
        this.snapshots = new Snapshot(connection);
        this.details = new Details(connection);
        this.nativeDdl = new NativeDdl(connection, lane.running(), session.url());
        // The url and the properties go with it so a catalog sweep can open
        // connections of its own rather than take this one.
        this.introspect = new Introspect(connection, lane.sweepCancelled(), session.url(), session.properties());
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

    Introspect introspect() {
        return introspect;
    }
}
