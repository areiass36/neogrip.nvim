package neogrip.rpc;

/**
 * The generic standard return for the handlers whose answer is polymorphic or
 * deliberately empty. A handler with one natural result type returns it
 * directly; this wrapper exists so the other handlers stay typed instead of
 * returning Object.
 */
public final class RpcResult<T> {
    private static final RpcResult<Object> EMPTY = new RpcResult<>(null);

    private final T value;

    private RpcResult(T value) {
        this.value = value;
    }

    public static <T> RpcResult<T> of(T value) {
        return new RpcResult<>(value);
    }

    /** The empty result: {} on the wire. */
    @SuppressWarnings("unchecked")
    public static <T> RpcResult<T> empty() {
        return (RpcResult<T>) EMPTY;
    }

    public T value() {
        return value;
    }
}
