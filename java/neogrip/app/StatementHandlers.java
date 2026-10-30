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

    /**
     * Open a result, or continue one (ADR-0031): no `sql` is what makes this a
     * continuation of the result the client named `hash`.
     */
    @RpcMethod
    RpcResult<?> query(String hash, String sql, int limit, int timeoutSeconds) throws SQLException {
        if (sql == null) {
            return RpcResult.of(db.next(hash, limit));
        }
        // A plain BEGIN/COMMIT/ROLLBACK is a transaction command, not a query
        // (ADR-0013); everything else answers with a batch or an update count.
        var intercepted = db.intercept(sql);
        if (intercepted.isPresent()) {
            return RpcResult.of(intercepted.get());
        }
        return RpcResult.of(db.query(hash, sql, limit, timeoutSeconds));
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
