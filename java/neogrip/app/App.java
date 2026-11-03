package neogrip.app;

import java.sql.SQLException;
import java.util.Map;
import neogrip.db.Database;
import neogrip.db.ReadonlyGuard;
import neogrip.db.errors.Cancelled;
import neogrip.db.errors.RequestRefused;
import neogrip.jsonrpc.RpcException;
import neogrip.jsonrpc.RpcServer;
import neogrip.jsonrpc.Wire;

/**
 * The sidecar's lifecycle, as configuration: the server is built here and
 * nothing else is constructed by hand - components and handlers are classes
 * the builder instantiates, constructor-injecting each by type. The program is
 * editor-agnostic: NDJSON JSON-RPC on stdio, contract in doc/protocol.md, and
 * any client that speaks it can run this.
 */
public final class App {
    private App() {}

    public static void main(String[] args) throws Exception {
        RpcServer.builder()
                .protocolVersion(Wire.PROTOCOL_VERSION)
                .io(System.in, System.out)
                .serverInfo(Map.of("java", System.getProperty("java.version")))
                .components(Session.class, Database.class)
                .handlers(
                        ControlHandlers.class,
                        ConnectHandler.class,
                        StatementHandlers.class,
                        CatalogHandlers.class)
                // Every error the wire can carry is translated here and
                // nowhere else: the code that executes statements throws its
                // own exceptions and never sees an envelope (ADR-0032).
                .mapException(ReadonlyGuard.Refused.class, e -> RpcException.of(Wire.READONLY_REFUSED, e))
                .mapException(SQLException.class, SqlErrors::toRpcException)
                .mapException(RequestRefused.class, e -> RpcException.of(Wire.INVALID_REQUEST, e))
                .mapException(Cancelled.class, e -> RpcException.of(Wire.CANCELLED, e))
                // A rejected argument - an export format this build does not
                // write, say - came from the request, so it answers as a bad
                // request rather than as an internal error.
                .mapException(IllegalArgumentException.class, e -> RpcException.of(Wire.INVALID_REQUEST, e))
                .drainSeconds(30)
                .build()
                .run();
    }
}
