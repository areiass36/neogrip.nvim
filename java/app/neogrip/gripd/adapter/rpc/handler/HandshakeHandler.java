package neogrip.gripd.adapter.rpc.handler;

import java.util.Map;
import neogrip.gripd.adapter.rpc.ErrorCodes;
import neogrip.gripd.adapter.rpc.Protocol;
import neogrip.jsonrpc.RpcException;
import neogrip.jsonrpc.RpcLifecycle;
import neogrip.jsonrpc.RpcMethod;

/**
 * The handshake, plus the gate that refuses everything arriving before it;
 * answered on the read thread so the gate is open by the time the next frame
 * is read, since a client may pipe the handshake and its first request together.
 */
public final class HandshakeHandler implements RpcLifecycle {
    private static final String METHOD = "initialize";

    private final Map<String, Object> info = Map.of("java", System.getProperty("java.version"));

    private volatile boolean done;

    @RpcMethod
    Map<String, Object> initialize(long protocolVersion) {
        if (protocolVersion != Protocol.VERSION) {
            // Fatal: a process left up would have the client waiting on a session that can never work.
            throw RpcException.fatal(
                    ErrorCodes.PROTOCOL_MISMATCH,
                    "gripd speaks protocol " + Protocol.VERSION + ", client sent " + protocolVersion);
        }
        done = true;
        return Map.of("protocolVersion", (long) Protocol.VERSION, "gripdInfo", info);
    }

    @Override
    public void onRequest(String method) {
        if (!done && !method.equals(METHOD)) {
            throw new RpcException(ErrorCodes.PROTOCOL_MISMATCH, "initialize first");
        }
    }
}
