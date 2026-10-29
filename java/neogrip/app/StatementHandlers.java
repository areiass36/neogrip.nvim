package neogrip.app;

import java.io.IOException;
import java.sql.SQLException;
import neogrip.db.Database;
import neogrip.db.types.Types.ExportResult;
import neogrip.db.types.Types.UpdateResult;
import neogrip.rpc.RpcMethod;
import neogrip.rpc.RpcResult;

/** The statements, on the worker lane: one at a time on the shared connection. */
final class StatementHandlers {
    private final Database db;

    StatementHandlers(Database db) {
        this.db = db;
    }

    @RpcMethod
    RpcResult<?> query(String sql, int limit, int offset, int timeoutSeconds) throws SQLException {
        // A plain BEGIN/COMMIT/ROLLBACK is a transaction command, not a query
        // (ADR-0013); everything else answers with a page or an update count.
        var intercepted = db.intercept(sql);
        if (intercepted.isPresent()) {
            return RpcResult.of(intercepted.get());
        }
        return RpcResult.of(db.query(sql, limit, offset, timeoutSeconds));
    }

    @RpcMethod
    RpcResult<?> exec(String sql, int timeoutSeconds) throws SQLException {
        var intercepted = db.intercept(sql);
        if (intercepted.isPresent()) {
            return RpcResult.of(intercepted.get());
        }
        return RpcResult.of(db.exec(sql, timeoutSeconds));
    }

    @RpcMethod
    RpcResult<UpdateResult> validate(String sql) throws SQLException {
        db.validate(sql);
        return RpcResult.empty();
    }

    @RpcMethod
    ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds)
            throws SQLException, IOException {
        return db.export(sql, path, format, nullMarker, timeoutSeconds);
    }
}
