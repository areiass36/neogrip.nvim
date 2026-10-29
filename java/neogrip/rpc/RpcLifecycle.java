package neogrip.rpc;

/**
 * Optional hooks a component may implement. onRequest runs on the read thread
 * for every request frame; onShutdown runs after the EOF drain, in reverse
 * registration order - the component registered last cleans up first.
 */
public interface RpcLifecycle {
    default void onRequest() {}

    default void onShutdown() {}
}
