package neogrip.app;

/**
 * The error codes this program defines beyond the ones JSON-RPC reserves
 * (doc/protocol.md), mirrored by the Lua side's rpc/protocol.lua.
 *
 * They live here rather than in the RPC library because a library that spelled
 * SQL_ERROR would be a library that knew this program executes SQL.
 */
public final class ErrorCodes {
    private ErrorCodes() {}

    public static final int PROTOCOL_MISMATCH = -32002;
    public static final int SQL_ERROR = -32010;
    public static final int AUTH_ERROR = -32011;
    public static final int READONLY_REFUSED = -32012;
    public static final int CANCELLED = -32013;
}
