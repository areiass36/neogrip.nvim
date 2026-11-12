package neogrip.jsonrpc;

import java.lang.reflect.Method;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The wire name to Java method map, built once at startup; everything that
 * can be wrong about a method - a build without {@code -parameters} included -
 * fails here with the offender's name, not when the first request arrives.
 */
public final class Registry {
    /** One registered method: the instance to call it on, and the method. */
    public record Target(Object instance, Method method) {}

    private final Map<String, Target> methods;

    private Registry(Map<String, Target> methods) {
        this.methods = methods;
    }

    /**
     * Every {@link RpcMethod} on these instances, named by the Java method and
     * prefixed by the class's {@link RpcNamespace}.
     *
     * @param reserved names the caller handles itself and no handler may claim
     */
    public static Registry scan(List<Object> handlers, Set<String> reserved) {
        Map<String, Target> methods = new LinkedHashMap<>();
        for (Object instance : handlers) {
            RpcNamespace namespace = instance.getClass().getAnnotation(RpcNamespace.class);
            String prefix = namespace == null ? "" : namespace.value() + "/";
            for (Method method : instance.getClass().getDeclaredMethods()) {
                if (method.getAnnotation(RpcMethod.class) == null) {
                    continue;
                }
                String wireName = prefix + method.getName();
                if (reserved.contains(wireName)) {
                    throw new IllegalStateException(wireName + " is reserved by the server");
                }
                Binder.validate(method, wireName);
                if (!method.trySetAccessible()) {
                    throw new IllegalStateException("cannot access " + wireName);
                }
                if (methods.put(wireName, new Target(instance, method)) != null) {
                    throw new IllegalStateException("duplicate rpc method: " + wireName);
                }
            }
        }
        return new Registry(methods);
    }

    /** @return null when nothing is registered under this name */
    public Target find(String method) {
        return methods.get(method);
    }
}
