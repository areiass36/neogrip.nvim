package neogrip.db;

import java.util.Locale;
import java.util.Set;

/**
 * BEGIN, COMMIT and ROLLBACK, recognised but not executed.
 *
 * They are mapped to the JDBC calls rather than passed through as text
 * (ADR-0013), because passing them through desynchronises the driver's view of
 * the transaction state. Only the plain spellings count: BEGIN TRY, savepoints
 * and anything else are statements like any other and pass untouched.
 *
 * Which spellings those are is a fact about SQL, not about JDBC, so it lives
 * here where nothing has to be open to ask.
 */
public enum TransactionCommand {
    BEGIN(Set.of("begin", "begin work", "begin tran", "begin transaction", "start transaction")),
    COMMIT(Set.of("commit", "commit work", "commit tran", "commit transaction")),
    ROLLBACK(Set.of("rollback", "rollback work", "rollback tran", "rollback transaction"));

    private final Set<String> spellings;

    TransactionCommand(Set<String> spellings) {
        this.spellings = spellings;
    }

    /** @return the command this statement is, or null when it is not one */
    public static TransactionCommand of(String sql) {
        String text = SqlText.withoutLeadingComments(sql).stripTrailing();
        if (text.endsWith(";")) {
            text = text.substring(0, text.length() - 1).stripTrailing();
        }
        String lower = text.toLowerCase(Locale.ROOT);
        for (TransactionCommand command : values()) {
            if (command.spellings.contains(lower)) {
                return command;
            }
        }
        return null;
    }
}
