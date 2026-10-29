package neogrip.rpc;

import java.util.Map;

/**
 * Server-initiated notifications, injectable into any component: the server
 * fulfils it, and a component holding one can tell the client things - the
 * idle-transaction watchdog's rollback notice, an auth flow's progress.
 */
@FunctionalInterface
public interface Notifier {
    void notify(String method, Map<String, Object> params);
}
