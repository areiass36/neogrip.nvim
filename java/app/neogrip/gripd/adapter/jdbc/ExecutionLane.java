package neogrip.gripd.adapter.jdbc;

import java.io.IOException;
import java.sql.SQLException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.locks.ReentrantLock;
import java.util.function.Supplier;

/**
 * The one lane onto the shared connection (ADR-0028): the lock is fair so
 * statements keep arrival order, and cancellation deliberately bypasses it -
 * through {@link Running} or the sweep flag - because a cancel that queued
 * would wait for the thing it was sent to stop.
 */
public final class ExecutionLane {
    private final ReentrantLock lock = new ReentrantLock(true);
    private final Running running = new Running();

    /** A catalog sweep has no statement to cancel, so a cancel reaches it as a flag. */
    private final AtomicBoolean sweepCancelled = new AtomicBoolean();

    @FunctionalInterface
    public interface Call<T> {
        T run() throws SQLException, IOException;
    }

    @FunctionalInterface
    public interface SqlCall<T> {
        T run() throws SQLException;
    }

    public <T> T serialize(Call<T> call) throws SQLException, IOException {
        lock.lock();
        try {
            return call.run();
        } finally {
            lock.unlock();
        }
    }

    /** The SQL-only overload, so statement callers do not declare IOException. */
    public <T> T serializeSql(SqlCall<T> call) throws SQLException {
        lock.lock();
        try {
            return call.run();
        } finally {
            lock.unlock();
        }
    }

    /** For the work that touches the connection and declares no exception. */
    public <T> T serializeValue(Supplier<T> work) {
        lock.lock();
        try {
            return work.get();
        } finally {
            lock.unlock();
        }
    }

    /** For the work that touches the connection but reports nothing back. */
    public void serializeQuietly(Runnable work) {
        lock.lock();
        try {
            work.run();
        } finally {
            lock.unlock();
        }
    }

    public Running running() {
        return running;
    }

    public AtomicBoolean sweepCancelled() {
        return sweepCancelled;
    }
}
