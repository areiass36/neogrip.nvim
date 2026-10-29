package neogrip;

/**
 * The JSON-RPC envelope, mirroring doc/protocol.md and the Lua side's
 * rpc/protocol.lua. Ids are Long for client requests and String for the
 * sidecar's own ("sv-1", ...), so the two spaces cannot collide.
 */
public final class Rpc {
    private Rpc() {}

    public static final int PROTOCOL_VERSION = 1;

    public static final int PARSE_ERROR = -32700;
    public static final int INVALID_REQUEST = -32600;
    public static final int METHOD_NOT_FOUND = -32601;
    public static final int INTERNAL_ERROR = -32603;
    public static final int PROTOCOL_MISMATCH = -32002;
    public static final int SQL_ERROR = -32010;
    public static final int AUTH_ERROR = -32011;
    public static final int READONLY_REFUSED = -32012;
    public static final int CANCELLED = -32013;

    private static void writeId(StringBuilder out, Object id) {
        if (id instanceof Long || id instanceof Integer) {
            out.append(id);
        } else if (id == null) {
            out.append("null");
        } else {
            Json.writeString(out, String.valueOf(id));
        }
    }

    /** result is written through Json.writeValue: a Map, a List, a RawJson... */
    public static void writeResult(StringBuilder out, Object id, Object result) {
        out.append("{\"jsonrpc\":\"2.0\",\"id\":");
        writeId(out, id);
        out.append(",\"result\":");
        Json.writeValue(out, result == null ? new Json.RawJson("{}") : result);
        out.append('}');
    }

    public static void writeError(StringBuilder out, Object id, int code, String message, Object data) {
        out.append("{\"jsonrpc\":\"2.0\",\"id\":");
        writeId(out, id);
        out.append(",\"error\":{\"code\":").append(code).append(",\"message\":");
        Json.writeString(out, message == null ? "error" : message);
        if (data != null) {
            out.append(",\"data\":");
            Json.writeValue(out, data);
        }
        out.append("}}");
    }

    public static void writeNotification(StringBuilder out, String method, Object params) {
        out.append("{\"jsonrpc\":\"2.0\",\"method\":");
        Json.writeString(out, method);
        if (params != null) {
            out.append(",\"params\":");
            Json.writeValue(out, params);
        }
        out.append('}');
    }
}
