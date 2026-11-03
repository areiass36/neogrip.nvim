package neogrip.gripd.adapter.jdbc;

import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.Supplier;
import neogrip.gripd.domain.Notifications;

/**
 * The timer that looks after what nobody is using any more.
 *
 * An idle open transaction holds locks on the server, so one that has seen no
 * request for its window is rolled back - never committed (ADR-0013) - and the
 * editor is told why its session is suddenly clean. An open result nobody
 * continues is memory held on both sides, so one untouched for its window is
 * closed (ADR-0031).
 *
 * The checks are cheap and run on a daemon thread; the work they lead to goes
 * through the lane, where it cannot race a statement for the connection.
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
