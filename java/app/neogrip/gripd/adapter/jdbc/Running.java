package neogrip.gripd.adapter.jdbc;

import java.sql.SQLException;
import java.sql.Statement;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The statement currently on the shared connection, so a cancel arriving on
 * another thread can reach it.
 *
 * Statement.cancel is the one JDBC call defined as safe to make from a thread
 * other than the one running the statement, which is the whole reason this
 * exists: a cancel that had to queue behind the statement it should kill would
 * never kill anything.
 */
public final class Running {
    private final AtomicReference<Statement> current = new AtomicReference<>();

    public void set(Statement statement) {
        current.set(statement);
    }

    public void clear() {
        current.set(null);
    }

    /** Clear only if this is still the statement in hand, never somebody else's. */
    public void clearIf(Statement statement) {
        current.compareAndSet(statement, null);
    }

    /** @return whether there was something to cancel and the driver took it */
    public boolean cancel() {
        Statement statement = current.get();
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
}
