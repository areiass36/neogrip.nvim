package neogrip.app;

import java.util.Map;
import neogrip.db.Database;
import neogrip.rpc.RpcMethod;

/** The read-lane methods: answerable even while the worker runs a statement. */
final class ControlHandlers {
    private final Database db;

    ControlHandlers(Database db) {
        this.db = db;
    }

    @RpcMethod(lane = "read")
    Map<String, Object> ping() {
        return Map.of();
    }

    @RpcMethod(lane = "read")
    Map<String, Object> cancel() {
        return Map.of("cancelled", db.cancel());
    }
}
