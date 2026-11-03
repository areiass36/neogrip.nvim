package neogrip.jsonrpc;

import neogrip.dataformat.json.JsonMapper;
import neogrip.dataformat.json.JsonWriter;

/**
 * The JSON-RPC 2.0 envelope, and the only class that spells "jsonrpc":
 * results, errors and notifications are all built here, so a handler never
 * holds one and the hand-counted braces this replaced cannot come back.
 */
public final class Envelope {
    private Envelope() {}

    /** One response line. A null value is the empty result, {}. */
    public static String result(Object id, Object value) {
        StringBuilder line = new StringBuilder();
        JsonWriter out = new JsonWriter(line);
        out.beginObject().name("jsonrpc").value("2.0").name("id");
        JsonMapper.write(out, id);
        out.name("result");
        if (value == null) {
            out.beginObject().endObject();
        } else {
            JsonMapper.write(out, value);
        }
        out.endObject();
        return line.toString();
    }

    public static String error(Object id, int code, String message, Object data) {
        StringBuilder line = new StringBuilder();
        JsonWriter out = new JsonWriter(line);
        out.beginObject().name("jsonrpc").value("2.0").name("id");
        JsonMapper.write(out, id);
        out.name("error").beginObject();
        out.name("code").value(code);
        out.name("message").value(message == null ? "error" : message);
        if (data != null) {
            out.name("data");
            JsonMapper.write(out, data);
        }
        out.endObject().endObject();
        return line.toString();
    }

    public static String notification(String method, Object params) {
        StringBuilder line = new StringBuilder();
        JsonWriter out = new JsonWriter(line);
        out.beginObject().name("jsonrpc").value("2.0").name("method").value(method);
        if (params != null) {
            out.name("params");
            JsonMapper.write(out, params);
        }
        out.endObject();
        return line.toString();
    }
}
