package neogrip.jsonrpc;

/**
 * The error codes JSON-RPC 2.0 reserves for itself, the only codes this
 * library knows; everything an application refuses with is that application's
 * own code and lives with it.
 */
public final class JsonRpc {
    private JsonRpc() {}

    public static final int PARSE_ERROR = -32700;
    public static final int INVALID_REQUEST = -32600;
    public static final int METHOD_NOT_FOUND = -32601;
    public static final int INTERNAL_ERROR = -32603;
}
