package neogrip.db;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.Locale;
import java.util.Optional;
import neogrip.db.types.Types.TxState;

/**
 * BEGIN, COMMIT and ROLLBACK are mapped to the JDBC calls rather than passed
 * through as text (ADR-0013): passing them through desynchronises the driver's
 * view of the transaction state. Only the plain spellings are intercepted -
 * BEGIN TRY, savepoints and anything else pass untouched.
 */
public final class Transactions {
    private final Connection connection;

    public Transactions(Connection connection) {
        this.connection = connection;
    }

    public Optional<TxState> intercept(String sql) throws SQLException {
        String text = ReadonlyGuard.stripLeadingComments(sql).stripTrailing();
        if (text.endsWith(";")) {
            text = text.substring(0, text.length() - 1).stripTrailing();
        }
        String lower = text.toLowerCase(Locale.ROOT);
        boolean open;
        if (lower.equals("begin") || lower.equals("begin work") || lower.equals("begin tran")
                || lower.equals("begin transaction") || lower.equals("start transaction")) {
            connection.setAutoCommit(false);
            open = true;
        } else if (lower.equals("commit") || lower.equals("commit work") || lower.equals("commit tran")
                || lower.equals("commit transaction")) {
            connection.commit();
            connection.setAutoCommit(true);
            open = false;
        } else if (lower.equals("rollback") || lower.equals("rollback work") || lower.equals("rollback tran")
                || lower.equals("rollback transaction")) {
            connection.rollback();
            connection.setAutoCommit(true);
            open = false;
        } else {
            return Optional.empty();
        }
        return Optional.of(new TxState(open));
    }

    /** Is a transaction open on the shared connection? For the idle watchdog. */
    public boolean inTransaction() {
        try {
            return !connection.getAutoCommit();
        } catch (SQLException e) {
            return false;
        }
    }

    /** Roll an idle transaction back - never commit (ADR-0013). */
    public void rollback() throws SQLException {
        connection.rollback();
        connection.setAutoCommit(true);
    }
}
