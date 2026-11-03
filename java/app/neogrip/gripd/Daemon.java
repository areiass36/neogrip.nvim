package neogrip.gripd;

import java.sql.SQLException;
import neogrip.gripd.adapter.jdbc.Database;
import neogrip.gripd.adapter.jdbc.Session;
import neogrip.gripd.adapter.rpc.ErrorCodes;
import neogrip.gripd.adapter.rpc.SqlErrors;
import neogrip.gripd.adapter.rpc.StatusNotifications;
import neogrip.gripd.adapter.rpc.handler.CatalogHandlers;
import neogrip.gripd.adapter.rpc.handler.ConnectHandler;
import neogrip.gripd.adapter.rpc.handler.ControlHandlers;
import neogrip.gripd.adapter.rpc.handler.HandshakeHandler;
import neogrip.gripd.adapter.rpc.handler.StatementHandlers;
import neogrip.gripd.domain.error.Cancelled;
import neogrip.gripd.domain.error.DataAccessException;
import neogrip.gripd.domain.error.RequestRefused;
import neogrip.gripd.domain.error.WriteRefused;
import neogrip.jsonrpc.ExitReason;
import neogrip.jsonrpc.JsonRpc;
import neogrip.jsonrpc.RpcException;
import neogrip.jsonrpc.RpcServer;

/**
 * The daemon's lifecycle, as configuration: the server is built here and
 * nothing else is constructed by hand - components and handlers are classes
 * the builder instantiates, constructor-injecting each by type. The program is
 * editor-agnostic: NDJSON JSON-RPC on stdio, contract in doc/protocol.md, and
 * any client that speaks it can run this.
 */
public final class Daemon {
    private Daemon() {}

    public static void main(String[] args) throws Exception {
        ExitReason reason = RpcServer.builder()
                .io(System.in, System.out)
                .stopOn("shutdown")
                .inline("initialize")
                .components(Session.class, StatusNotifications.class, Database.class)
                .handlers(
                        HandshakeHandler.class,
                        ControlHandlers.class,
                        ConnectHandler.class,
                        StatementHandlers.class,
                        CatalogHandlers.class)
                // Every error the wire can carry is translated here and
                // nowhere else: the code that executes statements throws its
                // own exceptions and never sees an envelope (ADR-0032).
                .mapException(WriteRefused.class, e -> RpcException.of(ErrorCodes.READONLY_REFUSED, e))
                .mapException(DataAccessException.class, SqlErrors::fromFailure)
                .mapException(SQLException.class, SqlErrors::toRpcException)
                .mapException(RequestRefused.class, e -> RpcException.of(JsonRpc.INVALID_REQUEST, e))
                .mapException(Cancelled.class, e -> RpcException.of(ErrorCodes.CANCELLED, e))
                // A rejected argument - an export format this build does not
                // write, say - came from the request, so it answers as a bad
                // request rather than as an internal error.
                .mapException(IllegalArgumentException.class, e -> RpcException.of(JsonRpc.INVALID_REQUEST, e))
                .drainSeconds(30)
                .build()
                .run();

        // The library reports why it stopped and never kills the process
        // itself; a refused handshake is what this program exits non-zero for.
        if (reason != ExitReason.STOPPED) {
            System.exit(reason.code());
        }
    }
}
