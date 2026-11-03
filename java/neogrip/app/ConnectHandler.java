package neogrip.app;

import java.util.Map;
import java.util.Properties;
import neogrip.db.Database;
import neogrip.db.types.Types.ConnectResult;
import neogrip.jsonrpc.RpcException;
import neogrip.jsonrpc.RpcMethod;

/**
 * The one frame that carries secrets (ADR-0009): nothing in its params is
 * logged, echoed into a response, or written to stderr - here or anywhere.
 */
final class ConnectHandler {
    private final Database db;

    ConnectHandler(Database db) {
        this.db = db;
    }

    @RpcMethod
    ConnectResult connect(
            String url,
            Map<String, Object> properties,
            Map<String, Object> auth,
            boolean readonly,
            long transactionIdleSeconds,
            long cursorIdleSeconds) {
        Properties merged = new Properties();
        for (Map.Entry<String, Object> entry : properties.entrySet()) {
            merged.setProperty(entry.getKey(), String.valueOf(entry.getValue()));
        }

        String type = auth.get("type") instanceof String value ? value : "none";
        switch (type) {
            case "none" -> {
                // Nothing to add: a file database, or a server that trusts us.
            }
            case "password" -> {
                if (auth.get("user") instanceof String user) {
                    merged.setProperty("user", user);
                }
                if (auth.get("password") instanceof String password) {
                    merged.setProperty("password", password);
                }
            }
            case "token" -> {
                // The property both the SQL Server and the Trino drivers read
                // a bearer token from; the value came out of kvstore on the
                // Lua side.
                if (auth.get("user") instanceof String user) {
                    merged.setProperty("user", user);
                }
                if (auth.get("token") instanceof String token) {
                    merged.setProperty("accessToken", token);
                }
            }
            default -> throw new RpcException(ErrorCodes.AUTH_ERROR, "auth type not implemented yet: " + type);
        }

        return db.open(url, merged, readonly, transactionIdleSeconds, cursorIdleSeconds);
    }
}
