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
     * Apply a setting the driver may not have; see doc/internals.md#jdbc-drivers.
     */
    public static void tolerate(Setting setting) {
        try {
            setting.apply();
        } catch (SQLException ignored) {
        }
    }
}
