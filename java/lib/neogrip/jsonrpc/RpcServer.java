package neogrip.jsonrpc;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.lang.reflect.InvocationTargetException;
import java.nio.charset.StandardCharsets;
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

/**
 * A JSON-RPC 2.0 server over stdio, one message per line (doc/protocol.md).
 *
 * The server owns everything that is protocol and threading: framing, the
 * initialize handshake, the envelope of every result and error, the bounded
 * drain on EOF, and notifications. Handlers are plain annotated functions on
 * plain classes; this class knows nothing about what they do - it has no
 * imports from the application, which is what keeps the sidecar a program any
 * JSON-RPC client can talk to.
 *
 * Every request runs on its own virtual thread (ADR-0028), so the read loop
 * never blocks and a cancel is always answerable while a query runs. Whatever
 * must be serialized - the shared session connection - is a lock where its
 * owner lives, not a thread model here: handlers declare nothing about
 * threading.
 */
public final class RpcServer {
    /** Names the read loop answers itself, so no handler may claim them. */
    private static final Set<String> RESERVED = Set.of("initialize", "shutdown");

    private final BufferedReader in;
    private final PrintWriter out;
    private final int protocolVersion;
    private final Map<String, Object> serverInfo;
    private final Registry registry;
    private final List<RpcLifecycle> lifecycle;
    private final Map<Class<?>, Function<Throwable, RpcException>> mappers;
    private final long drainSeconds;

    private final ExecutorService requests = Executors.newVirtualThreadPerTaskExecutor();
    private boolean initialized = false;

    private RpcServer(Builder builder, Registry registry, List<RpcLifecycle> lifecycle) {
        this.in = new BufferedReader(new InputStreamReader(builder.stdin, StandardCharsets.UTF_8));
        this.out = new PrintWriter(
                new BufferedWriter(new OutputStreamWriter(builder.stdout, StandardCharsets.UTF_8)));
        this.protocolVersion = builder.protocolVersion;
        this.serverInfo = builder.serverInfo;
        this.registry = registry;
        this.lifecycle = lifecycle;
        this.mappers = builder.mappers;
        this.drainSeconds = builder.drainSeconds;
    }

    public static Builder builder() {
        return new Builder();
    }

    private synchronized void send(String line) {
        out.println(line);
        out.flush();
    }

    /** A notification to the client, callable from any thread. */
    public void notify(String method, Map<String, Object> params) {
        send(Wire.notification(method, params));
    }

    /** Blocks on the read loop until shutdown or EOF, then drains and runs the hooks. */
    public void run() throws Exception {
        String line;
        while ((line = in.readLine()) != null) {
            if (line.isBlank()) {
                continue;
            }

            Object message;
            try {
                message = JsonParser.parse(line);
            } catch (IllegalArgumentException e) {
                send(Wire.error(null, Wire.PARSE_ERROR, "line is not JSON", null));
                continue;
            }
            if (!(message instanceof Map<?, ?> frame) || !(frame.get("method") instanceof String method)) {
                // A response to a server-initiated request would land here too;
                // none exist yet, so anything without a method is invalid.
                send(Wire.error(null, Wire.INVALID_REQUEST, "expected a request object", null));
                continue;
            }
            Object id = frame.get("id");
            Map<?, ?> params = frame.get("params") instanceof Map<?, ?> map ? map : Map.of();

            if (method.equals("shutdown")) {
                break;
            }
            if (method.equals("initialize")) {
                if (!initialize(id, params)) {
                    out.flush();
                    System.exit(1);
                }
                continue;
            }
            if (!initialized) {
                // The contract: nothing but initialize before the handshake.
                send(Wire.error(id, Wire.PROTOCOL_MISMATCH, "initialize first", null));
                continue;
            }

            for (RpcLifecycle component : lifecycle) {
                component.onRequest();
            }

            Registry.Target target = registry.find(method);
            if (target == null) {
                send(Wire.error(id, Wire.METHOD_NOT_FOUND, "method not found: " + method, null));
                continue;
            }

            requests.submit(() -> handle(target, id, params));
        }

        // Work already submitted still finishes: a shutdown arriving while a
        // query is in flight should still return that query's answer.
        drain(requests);
        for (int i = lifecycle.size() - 1; i >= 0; i--) {
            lifecycle.get(i).onShutdown();
        }
        out.flush();
    }

    private boolean initialize(Object id, Map<?, ?> params) {
        long version = params.get("protocolVersion") instanceof Long value ? value : -1;
        if (version != protocolVersion) {
            send(Wire.error(
                    id,
                    Wire.PROTOCOL_MISMATCH,
                    "sidecar speaks protocol " + protocolVersion + ", client sent " + version,
                    null));
            return false;
        }
        initialized = true;
        send(Wire.result(id, Map.of("protocolVersion", (long) protocolVersion, "sidecarInfo", serverInfo)));
        return true;
    }

    /**
     * One request, end to end. The line is built whole before anything is
     * sent, so a failure can never leave half an object on the wire; and
     * nothing from params is ever echoed - the connect request carries secrets.
     */
    private void handle(Registry.Target target, Object id, Map<?, ?> params) {
        String response;
        try {
            Object result = target.method().invoke(target.instance(), Binder.bind(target.method(), params));
            if (result instanceof RpcResult<?> wrapped) {
                result = wrapped.value();
            }
            response = Wire.result(id, result);
        } catch (InvocationTargetException e) {
            response = errorLine(id, e.getCause() == null ? e : e.getCause());
        } catch (Throwable e) {
            // Throwable, not Exception: an Error leaves this thread without a
            // response, and a client with no timeout then waits forever. That
            // is not hypothetical - a class cache compiled by a newer JDK than
            // the one running made every statement hang on a LinkageError
            // instead of saying so. A request always gets an answer.
            response = errorLine(id, e);
        }
        send(response);
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
            return Wire.error(id, rpc.code(), rpc.getMessage(), rpc.data());
        }
        return Wire.error(
                id,
                Wire.INTERNAL_ERROR,
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
     * Configuration and assembly. Classes in, singletons out: every component
     * and handler class is instantiated here, each constructor parameter
     * resolved by type from the other components and the library's own
     * injectables (Notifier, Worker). Everything that can be wrong -
     * unresolvable dependency, duplicate wire name, unsupported signature,
     * a build without -parameters - fails here, naming the offender.
     */
    public static final class Builder {
        private InputStream stdin;
        private OutputStream stdout;
        private int protocolVersion = Wire.PROTOCOL_VERSION;
        private Map<String, Object> serverInfo = Map.of();
        private final List<Class<?>> componentClasses = new ArrayList<>();
        private final List<Class<?>> handlerClasses = new ArrayList<>();
        private final Map<Class<?>, Function<Throwable, RpcException>> mappers = new LinkedHashMap<>();
        private long drainSeconds = 30;

        public Builder protocolVersion(int version) {
            this.protocolVersion = version;
            return this;
        }

        public Builder io(InputStream stdin, OutputStream stdout) {
            this.stdin = stdin;
            this.stdout = stdout;
            return this;
        }

        public Builder serverInfo(Map<String, Object> info) {
            this.serverInfo = info;
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
            Registry registry = Registry.scan(handlers, RESERVED);

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
