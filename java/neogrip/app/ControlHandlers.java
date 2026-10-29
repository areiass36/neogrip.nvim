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

    @RpcMethod
    Map<String, Object> cancel() {
        return Map.of("cancelled", db.cancel());
    }
}
