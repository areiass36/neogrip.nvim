package neogrip.gripd.adapter.jdbc;

import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.Supplier;
import neogrip.gripd.domain.Notifications;

/**
 * The idle timer: a transaction idle past its window is rolled back, never
 * committed (ADR-0013), and a result nobody continues is closed (ADR-0031).
 */
final class IdleWatchdog {
    private static final long EVERY_SECONDS = 15;

    private final Supplier<ConnectionScope> scope;
    private final Session session;
    private final Notifications notifications;

    IdleWatchdog(Supplier<ConnectionScope> scope, Session session, Notifications notifications) {
        this.scope = scope;
        this.session = session;
        this.notifications = notifications;
    }

    /** A daemon timer with no stop: the process it watches is what ends it. */
    void start() {
        Executors.newSingleThreadScheduledExecutor(task -> {
                    Thread thread = new Thread(task, "neogrip-idle-watchdog");
                    thread.setDaemon(true);
                    return thread;
                })
                .scheduleAtFixedRate(this::tick, EVERY_SECONDS, EVERY_SECONDS, TimeUnit.SECONDS);
    }

    private void tick() {
        ConnectionScope current = scope.get();
        if (current == null) {
            return;
        }
        rollbackIfIdle(current);
        current.closeExpiredCursors(session.cursorIdleMs());
    }

    private void rollbackIfIdle(ConnectionScope current) {
        long idleMs = session.transactionIdleMs();
        if (idleMs <= 0
                || !current.inTransaction()
                || System.currentTimeMillis() - session.lastRequestAt() < idleMs) {
            return;
        }
        if (current.rollbackQuietly()) {
            notifications.status("transaction", "idle transaction rolled back");
        }
    }
}
