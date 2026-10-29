package neogrip.rpc;

/**
 * How a handler refuses: throw this and the server writes the error envelope.
 * Nothing else in handler or database code ever touches an envelope.
 */
public final class RpcException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    private final int code;
    private final transient Object data;

    public RpcException(int code, String message) {
        this(code, message, null);
    }

    public RpcException(int code, String message, Object data) {
        super(message);
        this.code = code;
        this.data = data;
    }

    public static RpcException of(int code, Throwable cause) {
        return new RpcException(code, cause.getMessage());
    }

    public int code() {
        return code;
    }

    public Object data() {
        return data;
    }
}
