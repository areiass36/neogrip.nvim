package neogrip.gripd.adapter.rpc;

import java.util.Map;
import neogrip.gripd.domain.Notifications;
import neogrip.jsonrpc.Notifier;

/** The database layer's notifications, as the protocol's frames. */
public final class WireNotifications implements Notifications {
    private final Notifier notifier;

    public WireNotifications(Notifier notifier) {
        this.notifier = notifier;
    }

    @Override
    public void status(String phase, String message) {
        notifier.notify("status", Map.of("phase", phase, "message", message));
    }

    @Override
    public void executing(String hash) {
        notifier.notify("progress", Map.of("hash", hash, "phase", "executing"));
    }
}
