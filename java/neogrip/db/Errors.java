package neogrip.db;

import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import neogrip.rpc.RpcException;
import neogrip.rpc.Wire;

/**
 * An error the editor can point at.
 *
 * JDBC gives more than a command line client does: a SQLState, the vendor's
 * own code, and - for PostgreSQL - the character position of the problem.
 * Those ride in the JSON-RPC error's data object (doc/protocol.md); this is
 * the exception mapper the server is configured with. The position is read
 * reflectively because reading it properly would mean compiling against every
 * driver.
 */
public final class Errors {
    private Errors() {}

    public static RpcException toRpcException(SQLException e) {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("state", String.valueOf(e.getSQLState()));
        data.put("vendorCode", (long) e.getErrorCode());
        Integer position = position(e);
        if (position != null) {
            // 1-based from the server, 0-based for the editor.
            data.put("position", (long) (position - 1));
        }
        Integer line = line(e);
        if (line != null) {
            data.put("line", (long) line);
        }
        String message = e.getMessage() == null ? e.toString() : e.getMessage();
        return new RpcException(Wire.SQL_ERROR, message.trim(), data);
    }

    /** PostgreSQL reports the offending character; nothing else does. */
    private static Integer position(SQLException e) {
        try {
            Object serverError = e.getClass().getMethod("getServerErrorMessage").invoke(e);
            if (serverError == null) {
                return null;
            }
            Object value = serverError.getClass().getMethod("getPosition").invoke(serverError);
            if (value instanceof Integer position && position > 0) {
                return position;
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // Not a PostgreSQL error, or a driver version without it.
        }
        return null;
    }

    /** SQL Server reports a line within the batch. */
    private static Integer line(SQLException e) {
        try {
            Object value = e.getClass().getMethod("getLineNumber").invoke(e);
            if (value instanceof Integer line && line > 0) {
                return line;
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // Not a SQL Server error.
        }
        // MySQL puts it in the text and nowhere else.
        String message = e.getMessage();
        if (message != null) {
            java.util.regex.Matcher matcher =
                    java.util.regex.Pattern.compile("at line (\\d+)").matcher(message);
            if (matcher.find()) {
                return Integer.parseInt(matcher.group(1));
            }
        }
        return null;
    }
}
