package neogrip.rpc;

/**
 * The statement worker lane, injectable: work submitted here is serialized
 * with the handlers that run on "worker", which is how a background job - the
 * idle-transaction watchdog - touches the connection without racing a running
 * statement for it.
 */
@FunctionalInterface
public interface Worker {
    void submit(Runnable task);
}
