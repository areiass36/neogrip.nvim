package neogrip.jsonrpc;

/**
 * The error codes JSON-RPC 2.0 reserves for itself, which are the only codes
 * this library knows.
 *
 * Everything an application refuses with - a SQL error, an expired token, a
 * read-only connection - is that application's own code and lives with the
 * application. A library that spelled those would be a library that knew what
 * the program does.
 */
public final class JsonRpc {
    private JsonRpc() {}

    public static final int PARSE_ERROR = -32700;
    public static final int INVALID_REQUEST = -32600;
    public static final int METHOD_NOT_FOUND = -32601;
    public static final int INTERNAL_ERROR = -32603;
}
