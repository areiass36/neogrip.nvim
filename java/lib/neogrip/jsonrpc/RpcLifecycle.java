package neogrip.jsonrpc;

/**
 * Optional hooks a component may implement.
 *
 * onRequest runs on the read thread for every request frame, before dispatch,
 * and may throw {@link RpcException} to refuse the request without it ever
 * reaching a handler - which is how a handshake gate says "not before I have
 * run". onShutdown runs after the EOF drain, in reverse registration order:
 * the component registered last cleans up first.
 */
public interface RpcLifecycle {
    default void onRequest(String method) {}

    default void onShutdown() {}
}
