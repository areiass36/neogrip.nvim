package neogrip.gripd.adapter.rpc;

import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import neogrip.gripd.domain.error.DataAccessException;
import neogrip.jsonrpc.JsonRpc;
import neogrip.jsonrpc.RpcException;

/**
 * An error the editor can point at: the SQLState, vendor code and PostgreSQL's
 * character position ride in the JSON-RPC error's data object
 * (doc/protocol.md); the position is read reflectively because reading it
 * properly would mean compiling against every driver.
 */
public final class SqlErrors {
    private SqlErrors() {}

    /**
     * A failure that came up through a port, with the driver's own exception
     * inside it.
     */
    public static RpcException fromFailure(DataAccessException failure) {
        if (failure.getCause() instanceof SQLException sql) {
            return toRpcException(sql);
        }
        // A file the export could not write, say: nothing a SQLState explains.
        Throwable cause = failure.getCause();
        return new RpcException(
                JsonRpc.INTERNAL_ERROR, cause.getClass().getSimpleName() + ": " + cause.getMessage());
    }

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
        return new RpcException(ErrorCodes.SQL_ERROR, message.trim(), data);
    }

    /** Only PostgreSQL reports this; see doc/internals.md#jdbc-drivers. */
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

    /** SQL Server's line within the batch; see doc/internals.md#jdbc-drivers. */
    private static Integer line(SQLException e) {
        try {
            Object value = e.getClass().getMethod("getLineNumber").invoke(e);
            if (value instanceof Integer line && line > 0) {
                return line;
            }
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            // Not a SQL Server error.
        }
        // MySQL spells it only in the text; see doc/internals.md#jdbc-drivers.
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
