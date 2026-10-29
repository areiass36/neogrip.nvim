package neogrip.app;

import java.sql.SQLException;
import java.util.Map;
import neogrip.db.Database;
import neogrip.db.Errors;
import neogrip.db.ReadonlyGuard;
import neogrip.rpc.RpcException;
import neogrip.rpc.RpcServer;
import neogrip.rpc.Wire;

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
                .mapException(ReadonlyGuard.Refused.class, e -> RpcException.of(Wire.READONLY_REFUSED, e))
                .mapException(SQLException.class, Errors::toRpcException)
                .drainSeconds(30)
                .build()
                .run();
    }
}
