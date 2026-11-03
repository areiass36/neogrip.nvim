package neogrip.gripd.adapter.jdbc;

import java.sql.SQLException;

/** What a JDBC driver may or may not be willing to do. */
public final class Drivers {
    private Drivers() {}

    @FunctionalInterface
    public interface Setting {
        void apply() throws SQLException;
    }

    /**
     * Apply a setting the driver may not have. Not every JDBC driver
     * implements every knob - MongoDB refuses setQueryTimeout outright - and
     * a missing one is no reason to fail the query.
     */
    public static void tolerate(Setting setting) {
        try {
            setting.apply();
        } catch (SQLException ignored) {
            // The driver does not support it; the query still runs.
        }
    }
}
