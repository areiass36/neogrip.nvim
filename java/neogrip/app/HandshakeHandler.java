package neogrip.app;

import java.util.Map;
import neogrip.jsonrpc.RpcException;
import neogrip.jsonrpc.RpcLifecycle;
import neogrip.jsonrpc.RpcMethod;

/**
 * The handshake: an ordinary annotated method, plus the gate that refuses
 * everything arriving before it.
 *
 * It is a handler rather than something the server does, because the version,
 * the facts about this runtime and the decision that a mismatch is fatal are
 * all this program's, not the library's. The server answers it on the read
 * thread (configured inline), so the gate is already open by the time the
 * frame after it is read - which matters, because a client may pipe the
 * handshake and its first request in together.
 */
final class HandshakeHandler implements RpcLifecycle {
    private static final String METHOD = "initialize";

    private final Map<String, Object> info = Map.of("java", System.getProperty("java.version"));

    private volatile boolean done;

    @RpcMethod
    Map<String, Object> initialize(long protocolVersion) {
        if (protocolVersion != Protocol.VERSION) {
            // Fatal: a client speaking another contract cannot be served, and
            // a process left up would have it waiting on a session that is
            // never going to work.
            throw RpcException.fatal(
                    ErrorCodes.PROTOCOL_MISMATCH,
                    "sidecar speaks protocol " + Protocol.VERSION + ", client sent " + protocolVersion);
        }
        done = true;
        return Map.of("protocolVersion", (long) Protocol.VERSION, "sidecarInfo", info);
    }

    @Override
    public void onRequest(String method) {
        if (!done && !method.equals(METHOD)) {
            throw new RpcException(ErrorCodes.PROTOCOL_MISMATCH, "initialize first");
        }
    }
}
