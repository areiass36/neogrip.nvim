package neogrip.rpc;

import java.lang.reflect.Method;
import java.lang.reflect.Parameter;
import java.util.List;
import java.util.Map;

/**
 * Named-parameter binding: each Java parameter is filled from the request's
 * params object under the parameter's own name, the way web frameworks bind a
 * controller's signature. Needs the compiler's -parameters flag, and says so
 * when it was forgotten. Missing values bind leniently - null, zero, false -
 * which is the contract the Lua client has always been written against.
 */
final class Binder {
    private Binder() {}

    /** At registration: fail fast, naming the method, never at request time. */
    static void validate(Method method, String wireName) {
        for (Parameter parameter : method.getParameters()) {
            if (!parameter.isNamePresent()) {
                throw new IllegalStateException(
                        wireName + ": parameter names are missing; compile with -parameters");
            }
            Class<?> type = parameter.getType();
            if (type != String.class && type != int.class && type != long.class
                    && type != boolean.class && type != Map.class && type != List.class) {
                throw new IllegalStateException(wireName + ": unsupported parameter type "
                        + type.getSimpleName() + " for '" + parameter.getName() + "'");
            }
        }
    }

    static Object[] bind(Method method, Map<?, ?> params) {
        Parameter[] parameters = method.getParameters();
        Object[] arguments = new Object[parameters.length];
        for (int i = 0; i < parameters.length; i++) {
            arguments[i] = bindOne(parameters[i], params.get(parameters[i].getName()));
        }
        return arguments;
    }

    private static Object bindOne(Parameter parameter, Object raw) {
        Class<?> type = parameter.getType();
        if (type == String.class) {
            return raw instanceof String text ? text : null;
        }
        if (type == int.class) {
            return (int) toLong(raw);
        }
        if (type == long.class) {
            return toLong(raw);
        }
        if (type == boolean.class) {
            return Boolean.TRUE.equals(raw);
        }
        if (type == Map.class) {
            return raw instanceof Map<?, ?> map ? map : Map.of();
        }
        // List, per validate().
        return raw instanceof List<?> list ? list : List.of();
    }

    private static long toLong(Object raw) {
        if (raw instanceof Long number) {
            return number;
        }
        if (raw instanceof Double number) {
            return (long) (double) number;
        }
        return 0;
    }
}
