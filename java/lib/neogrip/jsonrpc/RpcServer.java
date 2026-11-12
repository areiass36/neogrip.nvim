package neogrip.jsonrpc;

import java.io.InputStream;
import java.io.OutputStream;
import java.lang.reflect.InvocationTargetException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;
import neogrip.dataformat.json.JsonParser;
import neogrip.inject.Container;
import neogrip.jsonrpc.transport.StdioTransport;
import neogrip.jsonrpc.transport.Transport;

/**
 * A JSON-RPC 2.0 server: frames in from a {@link Transport}, dispatched to
 * annotated methods, answers back out the same way. It owns no contract of
 * its own - the version, the handshake, the extra error codes and the
 * decision to exit belong to the program configured into it - and every
 * request runs on its own virtual thread (ADR-0028), so the read loop never
 * blocks and a cancel is always answerable while a query runs.
 */
public final class RpcServer {
    private final Transport transport;
    private final String stopMethod;
    private final Set<String> inline;
    private final Registry registry;
    private final List<RpcLifecycle> lifecycle;
    private final Map<Class<?>, Function<Throwable, RpcException>> mappers;
    private final long drainSeconds;

    private final ExecutorService requests = Executors.newVirtualThreadPerTaskExecutor();

    private RpcServer(Builder builder, Registry registry, List<RpcLifecycle> lifecycle) {
        this.transport = builder.transport;
        this.stopMethod = builder.stopMethod;
        this.inline = builder.inline;
        this.registry = registry;
        this.lifecycle = lifecycle;
        this.mappers = builder.mappers;
        this.drainSeconds = builder.drainSeconds;
    }

    public static Builder builder() {
        return new Builder();
    }

    private void send(String line) {
        transport.write(line);
    }

    /** A notification to the client, callable from any thread. */
    public void notify(String method, Map<String, Object> params) {
        send(Envelope.notification(method, params));
    }

    /**
     * Blocks on the read loop until the stop method or EOF, then drains and
     * runs the shutdown hooks.
     *
     * @return why it ended, for a caller that has to pick an exit code
     */
    public ExitReason run() throws Exception {
        ExitReason reason = ExitReason.STOPPED;
        String line;
        while ((line = transport.read()) != null) {
            if (line.isBlank()) {
                continue;
            }

            Object message;
            try {
                message = JsonParser.parse(line);
            } catch (IllegalArgumentException e) {
                send(Envelope.error(null, JsonRpc.PARSE_ERROR, "line is not JSON", null));
                continue;
            }
            if (!(message instanceof Map<?, ?> frame) || !(frame.get("method") instanceof String method)) {
                // No server-initiated requests exist yet, so anything without a method is invalid.
                send(Envelope.error(null, JsonRpc.INVALID_REQUEST, "expected a request object", null));
                continue;
            }
            Object id = frame.get("id");
            Map<?, ?> params = frame.get("params") instanceof Map<?, ?> map ? map : Map.of();

            if (method.equals(stopMethod)) {
                break;
            }

            // A component may refuse a request before dispatch - the handshake gate needs this.
            RpcException refusal = refuse(method);
            if (refusal != null) {
                send(Envelope.error(id, refusal.code(), refusal.getMessage(), refusal.data()));
                if (refusal.fatal()) {
                    reason = ExitReason.REFUSED;
                    break;
                }
                continue;
            }

            Registry.Target target = registry.find(method);
            if (target == null) {
                send(Envelope.error(id, JsonRpc.METHOD_NOT_FOUND, "method not found: " + method, null));
                continue;
            }

            if (inline.contains(method)) {
                // Answered before the next line is read: its effect has to hold for the frame
                // that follows, and a client is free to pipe both in at once.
                if (handle(target, id, params)) {
                    reason = ExitReason.REFUSED;
                    break;
                }
                continue;
            }

            requests.submit(() -> handle(target, id, params));
        }

        // Work already submitted still finishes: a query in flight at shutdown still answers.
        drain(requests);
        for (int i = lifecycle.size() - 1; i >= 0; i--) {
            lifecycle.get(i).onShutdown();
        }
        return reason;
    }

    /** @return the refusal a component raised for this request, or null */
    private RpcException refuse(String method) {
        for (RpcLifecycle component : lifecycle) {
            try {
                component.onRequest(method);
            } catch (RpcException refusal) {
                return refusal;
            }
        }
        return null;
    }

    /**
     * One request, end to end. The line is built whole before anything is
     * sent, so a failure can never leave half an object on the wire; and
     * nothing from params is ever echoed - the connect request carries secrets.
     *
     * @return whether the handler refused fatally, which ends the server
     */
    private boolean handle(Registry.Target target, Object id, Map<?, ?> params) {
        String response;
        boolean fatal = false;
        try {
            Object result = target.method().invoke(target.instance(), Binder.bind(target.method(), params));
            if (result instanceof RpcResult<?> wrapped) {
                result = wrapped.value();
            }
            response = Envelope.result(id, result);
        } catch (InvocationTargetException e) {
            Throwable cause = e.getCause() == null ? e : e.getCause();
            fatal = cause instanceof RpcException rpc && rpc.fatal();
            response = errorLine(id, cause);
        } catch (Throwable e) {
            // Throwable, not Exception: an Error leaving this thread without a response makes
            // the client wait forever (see doc/internals.md#gripd-process). A request always
            // gets an answer.
            response = errorLine(id, e);
        }
        send(response);
        return fatal;
    }

    private String errorLine(Object id, Throwable cause) {
        RpcException rpc = null;
        if (cause instanceof RpcException direct) {
            rpc = direct;
        } else {
            for (Map.Entry<Class<?>, Function<Throwable, RpcException>> mapper : mappers.entrySet()) {
                if (mapper.getKey().isInstance(cause)) {
                    rpc = mapper.getValue().apply(cause);
                    break;
                }
            }
        }
        if (rpc != null) {
            return Envelope.error(id, rpc.code(), rpc.getMessage(), rpc.data());
        }
        return Envelope.error(
                id,
                JsonRpc.INTERNAL_ERROR,
                cause.getClass().getSimpleName() + ": " + cause.getMessage(),
                null);
    }

    private void drain(ExecutorService service) {
        service.shutdown();
        try {
            if (!service.awaitTermination(drainSeconds, TimeUnit.SECONDS)) {
                service.shutdownNow();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            service.shutdownNow();
        }
    }

    /**
     * Configuration and assembly: every component and handler class is
     * instantiated here, constructor parameters resolved by type, and
     * everything that can be wrong - a build without -parameters included -
     * fails here, naming the offender.
     */
    public static final class Builder {
        private Transport transport;
        private String stopMethod = "shutdown";
        private Set<String> inline = Set.of();
        private final List<Class<?>> componentClasses = new ArrayList<>();
        private final List<Class<?>> handlerClasses = new ArrayList<>();
        private final Map<Class<?>, Function<Throwable, RpcException>> mappers = new LinkedHashMap<>();
        private long drainSeconds = 30;

        /** The common case: one JSON object per line over a pair of streams. */
        public Builder io(InputStream stdin, OutputStream stdout) {
            return transport(new StdioTransport(stdin, stdout));
        }

        public Builder transport(Transport transport) {
            this.transport = transport;
            return this;
        }

        /**
         * The method that ends the read loop, answered by the loop itself and
         * claimable by no handler.
         */
        public Builder stopOn(String method) {
            this.stopMethod = method;
            return this;
        }

        /**
         * Methods answered on the read thread, before the next frame is read -
         * for a handshake and little else, since anything inline cannot be
         * answered while another request is in flight.
         */
        public Builder inline(String... methods) {
            this.inline = Set.of(methods);
            return this;
        }

        public Builder components(Class<?>... classes) {
            componentClasses.addAll(List.of(classes));
            return this;
        }

        public Builder handlers(Class<?>... classes) {
            handlerClasses.addAll(List.of(classes));
            return this;
        }

        public <T extends Throwable> Builder mapException(Class<T> type, Function<T, RpcException> mapper) {
            @SuppressWarnings("unchecked")
            Function<Throwable, RpcException> widened = cause -> mapper.apply((T) cause);
            mappers.put(type, widened);
            return this;
        }

        public Builder drainSeconds(long seconds) {
            this.drainSeconds = seconds;
            return this;
        }

        public RpcServer build() {
            // The server exists after construction, but components want its
            // Notifier at construction time: it delegates through this holder,
            // filled in just below.
            RpcServer[] holder = new RpcServer[1];
            Notifier notifier = (method, params) -> holder[0].notify(method, params);

            List<Class<?>> pending = new ArrayList<>(componentClasses);
            pending.addAll(handlerClasses);
            List<Object> constructed =
                    new Container().provide(Notifier.class, notifier).construct(pending);

            // Only the handler classes are scanned; a component with an
            // annotated method is not reachable from the wire.
            List<Object> handlers = constructed.stream()
                    .filter(instance -> handlerClasses.contains(instance.getClass()))
                    .toList();
            Registry registry = Registry.scan(handlers, Set.of(stopMethod));

            List<RpcLifecycle> lifecycle = new ArrayList<>();
            for (Object instance : constructed) {
                if (instance instanceof RpcLifecycle hooks) {
                    lifecycle.add(hooks);
                }
            }

            RpcServer server = new RpcServer(this, registry, lifecycle);
            holder[0] = server;
            return server;
        }
    }
}
