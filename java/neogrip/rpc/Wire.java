package neogrip.rpc;

/**
 * The protocol constants and the envelope, mirroring doc/protocol.md and the
 * Lua side's rpc/protocol.lua. Only this class spells "jsonrpc": results and
 * errors alike are enveloped here and nowhere else.
 */
public final class Wire {
    private Wire() {}

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

    /** One response line. A null value is the empty result, {}. */
    public static String result(Object id, Object value) {
        StringBuilder line = new StringBuilder();
        JsonStream out = new JsonStream(line);
        out.beginObject().name("jsonrpc").value("2.0").name("id");
        JsonCodec.write(out, id);
        out.name("result");
        if (value == null) {
            out.beginObject().endObject();
        } else {
            JsonCodec.write(out, value);
        }
        out.endObject();
        return line.toString();
    }

    public static String error(Object id, int code, String message, Object data) {
        StringBuilder line = new StringBuilder();
        JsonStream out = new JsonStream(line);
        out.beginObject().name("jsonrpc").value("2.0").name("id");
        JsonCodec.write(out, id);
        out.name("error").beginObject();
        out.name("code").value(code);
        out.name("message").value(message == null ? "error" : message);
        if (data != null) {
            out.name("data");
            JsonCodec.write(out, data);
        }
        out.endObject().endObject();
        return line.toString();
    }

    public static String notification(String method, Object params) {
        StringBuilder line = new StringBuilder();
        JsonStream out = new JsonStream(line);
        out.beginObject().name("jsonrpc").value("2.0").name("method").value(method);
        if (params != null) {
            out.name("params");
            JsonCodec.write(out, params);
        }
        out.endObject();
        return line.toString();
    }
}
