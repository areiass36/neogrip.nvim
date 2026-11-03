package neogrip.gripd.adapter.jdbc;

import java.sql.Connection;
import java.sql.SQLException;
import java.util.Optional;
import neogrip.gripd.contract.Contracts.TxState;
import neogrip.gripd.domain.TransactionCommand;

/**
 * The JDBC side of a transaction command: {@link TransactionCommand} says what
 * a statement is, this makes the call it maps to (ADR-0013).
 */
public final class Transactions {
    private final Connection connection;

    public Transactions(Connection connection) {
        this.connection = connection;
    }

    /** @return the resulting state, or empty when this was not a transaction command */
    public Optional<TxState> intercept(String sql) throws SQLException {
        TransactionCommand command = TransactionCommand.of(sql);
        if (command == null) {
            return Optional.empty();
        }
        boolean open = false;
        switch (command) {
            case BEGIN -> {
                connection.setAutoCommit(false);
                open = true;
            }
            case COMMIT -> {
                connection.commit();
                connection.setAutoCommit(true);
            }
            case ROLLBACK -> {
                connection.rollback();
                connection.setAutoCommit(true);
            }
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
