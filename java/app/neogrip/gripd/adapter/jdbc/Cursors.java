package neogrip.gripd.adapter.jdbc;

import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import neogrip.gripd.domain.error.RequestRefused;
import neogrip.gripd.contract.Contracts.QueryPage;

/**
 * The open results of one connection, keyed by the opaque hash the client
 * minted (ADR-0031); deliberately uncapped, reclaimed only by close, the idle
 * sweep, cancel or shutdown (ADR-0041).
 */
final class Cursors {
    private final Map<String, Cursor> live = new LinkedHashMap<>();

    /**
     * The next batch of an open result, closed when it runs out; deliberately
     * not synchronized so a cancel can reach the cursor mid-fetch - the
     * caller's session lock already serializes batches (ADR-0028).
     */
    QueryPage next(String hash, int limit) throws SQLException {
        long start = System.currentTimeMillis();
        Cursor cursor = peek(hash);
        if (cursor == null) {
            throw new RequestRefused("no result is open under " + describe(hash));
        }
        QueryPage page = cursor.batch(hash, limit, start);
        if (page.done()) {
            detach(hash);
            cursor.close();
        }
        return page;
    }

    /**
     * Keep a result so it can be continued; a hash already live is refused
     * rather than overwritten, which would leak the old cursor and cross the
     * rows of two results in one grid.
     */
    synchronized void keep(String hash, Cursor cursor) {
        if (live.containsKey(hash)) {
            // Not closed here: the offered cursor still belongs to the caller.
            throw new RequestRefused("a result is already open under " + describe(hash));
        }
        live.put(hash, cursor);
    }

    /**
     * The open result under this hash, left in the registry so cancellation
     * can interrupt it without holding this monitor across the session lock.
     */
    synchronized Cursor peek(String hash) {
        return hash == null ? null : live.get(hash);
    }

    /** Take a result out of the registry without closing it. */
    synchronized Cursor detach(String hash) {
        return hash == null ? null : live.remove(hash);
    }

    /**
     * Results untouched for longer than the window, taken out of the registry
     * for the caller to close under the session lock.
     */
    synchronized List<Cursor> expired(long idleMs) {
        List<Cursor> gone = new ArrayList<>();
        if (idleMs <= 0) {
            return gone;
        }
        long now = System.currentTimeMillis();
        live.values().removeIf(cursor -> {
            if (now - cursor.touchedAt() < idleMs) {
                return false;
            }
            gone.add(cursor);
            return true;
        });
        return gone;
    }

    synchronized List<Cursor> drain() {
        List<Cursor> all = new ArrayList<>(live.values());
        live.clear();
        return all;
    }

    private static String describe(String hash) {
        return hash == null || hash.isEmpty() ? "an unnamed result" : hash;
    }
}
