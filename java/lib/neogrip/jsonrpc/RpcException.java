package neogrip.jsonrpc;

/**
 * How a handler refuses: throw this and the server writes the error envelope.
 * Nothing else in handler or database code ever touches an envelope.
 */
public final class RpcException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final int code;
    private final transient Object data;
    private final boolean fatal;

    public RpcException(int code, String message) {
        this(code, message, null, false);
    }

    public RpcException(int code, String message, Object data) {
        this(code, message, data, false);
    }

    private RpcException(int code, String message, Object data, boolean fatal) {
        super(message);
        this.code = code;
        this.data = data;
        this.fatal = fatal;
    }

    public static RpcException of(int code, Throwable cause) {
        return new RpcException(code, cause.getMessage());
    }

    /**
     * A refusal the session cannot continue past: the client gets its error
     * and the server stops - at once for an inline-answered request, otherwise
     * when the read loop next comes round, because interrupting a blocked read
     * is not reliable on every platform.
     */
    public static RpcException fatal(int code, String message) {
        return new RpcException(code, message, null, true);
    }

    public int code() {
        return code;
    }

    public Object data() {
        return data;
    }

    public boolean fatal() {
        return fatal;
    }
}
