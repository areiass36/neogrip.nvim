package neogrip;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

/**
 * The sidecar: one of these runs per database connection, and stays alive.
 *
 * Starting a JVM per query was measured in the predecessor and does not work:
 * the DuckDB driver unpacks a native library every time (~2.5 s) and the
 * MongoDB driver starts a JavaScript engine (~12 s on the first query). Alive,
 * the same queries take 1-2 ms and ~300 ms. Keeping the process also gives
 * real cancellation (Statement.cancel reaches the server) and one connection
 * instead of one per statement.
 *
 * The wire is JSON-RPC 2.0, one object per line (doc/protocol.md). Requests
 * are read on the main thread and run on a single worker, so a cancel can be
 * read while a query is still running, and two statements never touch the
 * connection at once. The argv carries nothing database-related: connection
 * parameters, secrets included, arrive in the connect request (ADR-0009), and
 * none of them is ever echoed into a response, an exception or stderr.
 *
 * Shutdown is the shutdown notification or EOF on stdin - EOF detects every
 * way the editor can die, including a hard kill, the moment the pipe closes
 * (ADR-0003). In-flight work is drained, bounded, before exit.
 */
public final class Main {
    private final PrintWriter out;
    private final ExecutorService worker = Executors.newSingleThreadExecutor(task -> {
        Thread thread = new Thread(task, "neogrip-worker");
        thread.setDaemon(true);
        return thread;
    });
    private final AtomicReference<java.sql.Statement> running = new AtomicReference<>();
    /** A catalog sweep has no statement to cancel, so a cancel reaches it as a flag. */
    private final AtomicBoolean cancelled = new AtomicBoolean();
    /** The worker methods that exist; catalog ones join with the schema phase. */
    private static final java.util.Set<String> STATEMENT_METHODS =
            java.util.Set.of("query", "exec", "validate", "export");
    private boolean initialized = false;
    /** Set by connect, on the worker; read only on the worker after that. */
    private Connection connection;
    private Queries queries;

    public static void main(String[] args) throws Exception {
        BufferedReader input =
                new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        PrintWriter out = new PrintWriter(
                new BufferedWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8)));
        new Main(out).loop(input);
    }

    private Main(PrintWriter out) {
        this.out = out;
    }

    private synchronized void send(String line) {
        out.println(line);
        out.flush();
    }

    private void loop(BufferedReader input) throws Exception {
        String line;
        while ((line = input.readLine()) != null) {
            if (line.isBlank()) continue;

            Object message;
            try {
                message = JsonReader.parse(line);
            } catch (IllegalArgumentException e) {
                StringBuilder response = new StringBuilder();
                Rpc.writeError(response, null, Rpc.PARSE_ERROR, "line is not JSON", null);
                send(response.toString());
                continue;
            }
            if (!(message instanceof Map<?, ?> frame) || !(frame.get("method") instanceof String method)) {
                // A response to a sidecar-initiated request also lands here;
                // none exist yet, so anything without a method is invalid.
                StringBuilder response = new StringBuilder();
                Rpc.writeError(response, null, Rpc.INVALID_REQUEST, "expected a request object", null);
                send(response.toString());
                continue;
            }
            Object id = frame.get("id");
            Object rawParams = frame.get("params");
            Map<?, ?> params = rawParams instanceof Map<?, ?> map ? map : Map.of();

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
                StringBuilder response = new StringBuilder();
                Rpc.writeError(response, id, Rpc.PROTOCOL_MISMATCH, "initialize first", null);
                send(response.toString());
                continue;
            }

            // The read-thread methods: always answerable, even mid-query.
            switch (method) {
                case "ping" -> {
                    StringBuilder response = new StringBuilder();
                    Rpc.writeResult(response, id, null);
                    send(response.toString());
                    continue;
                }
                case "cancel" -> {
                    cancelled.set(true);
                    java.sql.Statement statement = running.get();
                    boolean stopped = false;
                    if (statement != null) {
                        try {
                            statement.cancel();
                            stopped = true;
                        } catch (SQLException ignored) {
                            // Some drivers refuse; killing the process is the fallback.
                        }
                    }
                    StringBuilder response = new StringBuilder();
                    Rpc.writeResult(response, id, Map.of("cancelled", stopped));
                    send(response.toString());
                    continue;
                }
                default -> worker.submit(() -> handle(id, method, params));
            }
        }

        // Work already submitted still finishes: a shutdown arriving while a
        // query is in flight should still return that query's answer.
        cancelled.set(true);
        drain(worker);
        if (connection != null) {
            try {
                // Never commit on the way out (ADR-0013); rollback is a no-op
                // under autocommit and the right answer under a transaction.
                if (!connection.getAutoCommit()) {
                    connection.rollback();
                }
            } catch (SQLException ignored) {
                // Shutting down anyway.
            }
            try {
                connection.close();
            } catch (SQLException ignored) {
                // Shutting down anyway.
            }
        }
    }

    private boolean initialize(Object id, Map<?, ?> params) {
        long version = params.get("protocolVersion") instanceof Long value ? value : -1;
        StringBuilder response = new StringBuilder();
        if (version != Rpc.PROTOCOL_VERSION) {
            Rpc.writeError(
                    response,
                    id,
                    Rpc.PROTOCOL_MISMATCH,
                    "sidecar speaks protocol " + Rpc.PROTOCOL_VERSION + ", client sent " + version,
                    null);
            send(response.toString());
            return false;
        }
        initialized = true;
        Rpc.writeResult(
                response,
                id,
                Map.of(
                        "protocolVersion",
                        (long) Rpc.PROTOCOL_VERSION,
                        "sidecarInfo",
                        Map.of("java", System.getProperty("java.version"))));
        send(response.toString());
        return true;
    }

    private static void drain(ExecutorService service) {
        service.shutdown();
        try {
            if (!service.awaitTermination(30, TimeUnit.SECONDS)) {
                service.shutdownNow();
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            service.shutdownNow();
        }
    }

    private void handle(Object id, String method, Map<?, ?> params) {
        StringBuilder response = new StringBuilder();
        try {
            if (method.equals("connect")) {
                connect(response, id, params);
            } else if (!STATEMENT_METHODS.contains(method)) {
                // Unknown beats unconnected: the method will not exist later
                // either, and the client should learn that first.
                Rpc.writeError(response, id, Rpc.METHOD_NOT_FOUND, "method not found: " + method, null);
            } else if (queries == null) {
                Rpc.writeError(response, id, Rpc.INVALID_REQUEST, "not connected", null);
            } else {
                switch (method) {
                    case "query" -> queries.query(
                            response,
                            id,
                            string(params, "sql"),
                            integer(params, "limit", 0),
                            integer(params, "offset", 0),
                            integer(params, "timeoutSeconds", 0));
                    case "exec" -> queries.exec(
                            response, id, string(params, "sql"), integer(params, "timeoutSeconds", 0));
                    case "validate" -> queries.validate(response, id, string(params, "sql"));
                    case "export" -> queries.export(
                            response,
                            id,
                            string(params, "sql"),
                            string(params, "path"),
                            string(params, "format"),
                            string(params, "nullMarker"),
                            integer(params, "timeoutSeconds", 0));
                    default -> throw new IllegalStateException("unreachable: " + method);
                }
            }
        } catch (Queries.Refused e) {
            response.setLength(0);
            Rpc.writeError(response, id, Rpc.READONLY_REFUSED, e.getMessage(), null);
        } catch (SQLException e) {
            // Whatever was written before the failure is half an object; the
            // error has to replace it, not follow it, or the line is not JSON.
            response.setLength(0);
            Errors.write(response, id, e);
        } catch (Exception e) {
            response.setLength(0);
            Rpc.writeError(
                    response,
                    id,
                    Rpc.INTERNAL_ERROR,
                    e.getClass().getSimpleName() + ": " + e.getMessage(),
                    null);
        }
        send(response.toString());
    }

    /**
     * The one frame that carries secrets (ADR-0009): nothing in it is logged,
     * echoed into a response, or written to stderr.
     */
    private void connect(StringBuilder response, Object id, Map<?, ?> params) throws SQLException {
        if (connection != null) {
            Rpc.writeError(response, id, Rpc.INVALID_REQUEST, "already connected", null);
            return;
        }
        String url = string(params, "url");
        Properties properties = new Properties();
        if (params.get("properties") instanceof Map<?, ?> extra) {
            for (Map.Entry<?, ?> entry : extra.entrySet()) {
                properties.setProperty(String.valueOf(entry.getKey()), String.valueOf(entry.getValue()));
            }
        }
        Map<?, ?> auth = params.get("auth") instanceof Map<?, ?> map ? map : Map.of();
        String type = auth.get("type") instanceof String value ? value : "none";
        switch (type) {
            case "none" -> {
                // Nothing to add: a file database, or a server that trusts us.
            }
            case "password" -> {
                if (auth.get("user") instanceof String user) {
                    properties.setProperty("user", user);
                }
                if (auth.get("password") instanceof String password) {
                    properties.setProperty("password", password);
                }
            }
            default -> {
                Rpc.writeError(
                        response, id, Rpc.AUTH_ERROR, "auth type not implemented yet: " + type, null);
                return;
            }
        }

        boolean readonly = Boolean.TRUE.equals(auth.get("readonly"))
                || Boolean.TRUE.equals(params.get("readonly"));
        connection = DriverManager.getConnection(url, properties);
        if (readonly) {
            try {
                connection.setReadOnly(true);
            } catch (SQLException ignored) {
                // Only a hint in some drivers; the keyword check still refuses.
            }
        }
        queries = new Queries(connection, running, readonly);

        Map<String, Object> result = new LinkedHashMap<>();
        Map<String, Object> capabilities = new LinkedHashMap<>();
        try {
            DatabaseMetaData meta = connection.getMetaData();
            result.put("product", meta.getDatabaseProductName() + " " + meta.getDatabaseProductVersion());
            result.put("driver", meta.getDriverName() + " " + meta.getDriverVersion());
            capabilities.put("schemas", supports(meta::supportsSchemasInDataManipulation));
            capabilities.put("catalogs", supports(meta::supportsCatalogsInDataManipulation));
            capabilities.put("transactions", supports(meta::supportsTransactions));
        } catch (SQLException ignored) {
            // A driver that cannot describe itself is still usable.
        }
        capabilities.put("sql", true);
        capabilities.put("cancellation", true);
        result.put("capabilities", capabilities);
        Rpc.writeResult(response, id, result);
    }

    @FunctionalInterface
    private interface SqlFlag {
        boolean get() throws SQLException;
    }

    private static boolean supports(SqlFlag flag) {
        try {
            return flag.get();
        } catch (SQLException | RuntimeException e) {
            return false;
        }
    }

    private static String string(Map<?, ?> params, String key) {
        Object value = params.get(key);
        return value instanceof String text ? text : "";
    }

    private static int integer(Map<?, ?> params, String key, int fallback) {
        Object value = params.get(key);
        if (value instanceof Long number) {
            return (int) (long) number;
        }
        if (value instanceof Double number) {
            return (int) (double) number;
        }
        return fallback;
    }
}
