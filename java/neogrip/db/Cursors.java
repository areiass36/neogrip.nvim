package neogrip.db;

import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import neogrip.db.types.Types.QueryPage;
import neogrip.rpc.RpcException;
import neogrip.rpc.Wire;

/**
 * The open results of one connection, each under the hash its client minted
 * (ADR-0031). The hash is opaque here: this class never parses it, only keys
 * on it, which is what lets the client name a result before the first response
 * has come back and address it for cancellation.
 *
 * Insertion-ordered, so the oldest result is the one evicted when a client
 * opens more than this will keep. A client that forgets to close is the reason
 * the cap exists at all: an open ResultSet holds memory on both sides.
 */
final class Cursors {
    /**
     * Live results per connection. One grid holds one result, so a second is
     * already unusual and a fifth is a client that stopped closing.
     */
    static final int MAX_LIVE = 4;

    private final Map<String, Cursor> live = new LinkedHashMap<>();

    /**
     * The next batch of an open result. Closes it when it runs out.
     *
     * Deliberately not synchronized: the fetch inside can take as long as the
     * server takes, and a cancel naming this result has to get through the
     * monitor to reach the cursor. Holding it across the fetch would make
     * cancellation wait for the thing it is cancelling. What actually
     * serializes two batches of one result is the session lock the caller
     * already holds (ADR-0028); this monitor only guards the map.
     */
    QueryPage next(String hash, int limit) throws SQLException {
        long start = System.currentTimeMillis();
        Cursor cursor = peek(hash);
        if (cursor == null) {
            throw new RpcException(Wire.INVALID_REQUEST, "no result is open under " + describe(hash));
        }
        QueryPage page = cursor.batch(hash, limit, start);
        if (page.done()) {
            detach(hash);
            cursor.close();
        }
        return page;
    }

    /**
     * Keep a result so it can be continued. A hash that is already live is a
     * client bug and is refused rather than overwritten: overwriting would
     * leak the old cursor and cross the rows of two results in one grid.
     */
    synchronized void keep(String hash, Cursor cursor) {
        if (live.containsKey(hash)) {
            // Refused, not overwritten, and not closed here either: the cursor
            // being offered still belongs to the caller, which closes it.
            throw new RpcException(
                    Wire.INVALID_REQUEST, "a result is already open under " + describe(hash));
        }
        while (live.size() >= MAX_LIVE) {
            String oldest = live.keySet().iterator().next();
            live.remove(oldest).close();
        }
        live.put(hash, cursor);
    }

    /**
     * The open result under this hash, left in the registry. Cancellation
     * looks it up this way on purpose: it has to interrupt the cursor and then
     * wait for the session lock to close it, and holding this monitor across
     * that wait would invert the two locks.
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

    /** A hash in a message, which is a client-chosen string and may be absent. */
    private static String describe(String hash) {
        return hash == null || hash.isEmpty() ? "an unnamed result" : hash;
    }
}
