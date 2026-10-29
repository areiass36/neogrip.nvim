package neogrip.db.catalog;

import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;

/**
 * A sweep's own connections, handed to one task at a time, so the main
 * connection stays the user's. Falling back to it is still a correct outcome -
 * slower, not wrong - so a server that will not hand out another connection is
 * not an error here.
 */
public final class SiblingPool {
    private SiblingPool() {}

    /**
     * However many connections a sweep is asked to use, this many at most:
     * past a handful it is waiting on the server's catalog rather than on
     * itself, and every connection taken here is one the rest of the machine
     * cannot have.
     */
    static final int MAX_SIBLINGS = 8;

    /**
     * A sweep's own connections, handed to one task at a time.
     *
     * A queue rather than one connection per thread because the detail pass
     * has far more tasks than there are connections, and because a task that
     * fails still has to give its connection back.
     */
    static final class Pool {
        private final List<Connection> opened = new ArrayList<>();
        /**
         * Unbounded, because a later stage tops the pool up rather than
         * replacing it: the detail pass wants more connections than the schema
         * sweeps did, and the ones already open are still good.
         */
        private final BlockingQueue<Connection> free = new LinkedBlockingQueue<>();

        /** Only ever called between stages, with every task finished. */
        void add(Connection connection) {
            opened.add(connection);
            free.add(connection);
        }

        int size() {
            return opened.size();
        }

        Connection take() throws InterruptedException {
            return free.take();
        }

        void release(Connection connection) {
            free.offer(connection);
        }

        void closeAll() {
            for (Connection connection : opened) {
                try {
                    connection.close();
                } catch (SQLException ignored) {
                    // The sweep is over either way.
                }
            }
        }
    }

    /**
     * Connections of a sweep's own, or null to stay on the process's one.
     *
     * The main connection belongs to the user's statements: a sweep that
     * borrowed it would make the next query wait for a whole catalog, which is
     * the reason this operation exists at all. Falling back to it is still a
     * correct outcome - slower, not wrong - so a server that will not hand out
     * another connection is not an error here.
     *
     * Asked once per stage, because the two stages have their work divided up
     * differently and sizing for the first would leave the second with one
     * connection on the commonest shape of database there is.
     *
     * @param work how many tasks the stage is about to run, which is what
     *             bounds the number of connections worth opening
     * @param pool what an earlier stage opened, to be topped up rather than
     *             replaced, or null when nothing is open yet
     */
    static Pool openSiblings(DatabaseMetaData meta, String url, Properties properties, int work, int parallelism, Pool pool) {
        int wanted = Math.min(Math.min(Math.max(parallelism, 1), work), MAX_SIBLINGS);
        int limit = 0;
        try {
            limit = meta.getMaxConnections();
        } catch (SQLException ignored) {
            // A driver that will not say does not get to cap anything.
        }
        if (limit > 0) {
            // Zero means unknown or unlimited, not a ban on connecting.
            wanted = Math.min(wanted, limit);
        }
        int have = pool == null ? 0 : pool.size();
        // A stage with less work than the last one keeps what is open instead
        // of closing connections it would only have to reopen.
        if (wanted < 2 || wanted <= have || url.isEmpty() || isSingleConnection(meta, url)) {
            return pool;
        }

        Pool opened = pool == null ? new Pool() : pool;
        for (int i = have; i < wanted; i++) {
            try {
                opened.add(DriverManager.getConnection(url, properties));
            } catch (SQLException refused) {
                // A server at its connection limit, a pooler in the way, or
                // credentials good for one session at a time.
                break;
            }
        }
        if (opened.size() < 2) {
            // One sibling does nothing the main connection would not, and
            // costs the server a session to do it.
            opened.closeAll();
            return null;
        }
        return opened;
    }

    /** A thread per connection, since a task only ever waits on one. */
    static ExecutorService sweepThreads(Pool pool) {
        if (pool == null) {
            return null;
        }
        return Executors.newFixedThreadPool(pool.size(), task -> {
            Thread thread = new Thread(task, "neogrip-sweep");
            thread.setDaemon(true);
            return thread;
        });
    }

    /**
     * Engines a second connection must not be opened against: DuckDB and
     * SQLite are single-writer files, and the MongoDB driver starts a
     * JavaScript engine per connection.
     */
    static boolean isSingleConnection(DatabaseMetaData meta, String url) {
        String jdbcUrl = url;
        try {
            String reported = meta.getURL();
            if (reported != null && !reported.isEmpty()) {
                jdbcUrl = reported;
            }
        } catch (SQLException ignored) {
            // The url this process was started with says the same thing.
        }
        jdbcUrl = jdbcUrl.toLowerCase();
        return jdbcUrl.startsWith("jdbc:duckdb:")
                || jdbcUrl.startsWith("jdbc:sqlite:")
                || jdbcUrl.startsWith("jdbc:mongodb:");
    }

    /** Every task, on the pool's threads when there is a pool, or on this one. */
    static void run(List<Callable<Void>> tasks, ExecutorService threads) throws SQLException {
        if (threads == null) {
            for (Callable<Void> task : tasks) {
                try {
                    task.call();
                } catch (Exception e) {
                    rethrow(e);
                }
            }
            return;
        }
        try {
            for (Future<Void> finished : threads.invokeAll(tasks)) {
                try {
                    finished.get();
                } catch (ExecutionException e) {
                    rethrow(e.getCause());
                }
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new SQLException("interrupted while reading the catalog", e);
        }
    }

    /** A task's failure, as the type the caller already turns into an error. */
    static void rethrow(Throwable cause) throws SQLException {
        if (cause instanceof SQLException sql) {
            throw sql;
        }
        if (cause instanceof RuntimeException runtime) {
            throw runtime;
        }
        if (cause instanceof Error error) {
            throw error;
        }
        throw new SQLException(cause == null ? "the catalog sweep failed" : String.valueOf(cause.getMessage()), cause);
    }
}
