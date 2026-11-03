package neogrip.app;

import java.util.Map;
import neogrip.db.Notifications;
import neogrip.jsonrpc.Notifier;

/** The database layer's notifications, as the protocol's status frame. */
final class StatusNotifications implements Notifications {
    private final Notifier notifier;

    StatusNotifications(Notifier notifier) {
        this.notifier = notifier;
    }

    @Override
    public void status(String phase, String message) {
        notifier.notify("status", Map.of("phase", phase, "message", message));
    }
}
