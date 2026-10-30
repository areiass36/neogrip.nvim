package neogrip.app;

import java.util.Map;
import neogrip.db.Database;
import neogrip.rpc.RpcMethod;

/** ping and cancel: answerable while a statement runs, because neither takes the session lock. */
final class ControlHandlers {
    private final Database db;

    ControlHandlers(Database db) {
        this.db = db;
    }

    @RpcMethod
    Map<String, Object> ping() {
        return Map.of();
    }

    /**
     * Stop what is running, or - given the hash of an open result - stop and
     * close that one result (ADR-0031).
     */
    @RpcMethod
    Map<String, Object> cancel(String hash) {
        return Map.of("cancelled", db.cancel(hash));
    }
}
