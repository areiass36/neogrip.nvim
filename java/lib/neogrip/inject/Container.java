package neogrip.inject;

import java.lang.reflect.Constructor;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Classes in, singletons out: each class instantiated once, constructor
 * parameters resolved by assignability from what is already built; everything
 * wrong is wrong at construction time and names the offender, and
 * {@link #construct} returns construction order because a caller running
 * lifecycle hooks needs to know who came first.
 */
public final class Container {
    private final Map<Class<?>, Object> instances = new LinkedHashMap<>();

    /** An instance built elsewhere, offered under the type it is wanted as. */
    public <T> Container provide(Class<T> type, T instance) {
        instances.put(type, instance);
        return this;
    }

    /**
     * Instantiate every class, in whatever order their dependencies allow.
     *
     * @return the instances, in construction order
     */
    public List<Object> construct(List<Class<?>> classes) {
        List<Class<?>> remaining = new ArrayList<>(classes);
        List<Object> constructed = new ArrayList<>();
        while (!remaining.isEmpty()) {
            boolean progressed = false;
            for (Class<?> type : new ArrayList<>(remaining)) {
                Object instance = tryConstruct(type);
                if (instance != null) {
                    if (instances.put(type, instance) != null) {
                        throw new IllegalStateException("two components of type " + type.getName());
                    }
                    constructed.add(instance);
                    remaining.remove(type);
                    progressed = true;
                }
            }
            if (!progressed) {
                // Everything left wants something nothing provides, or wants each other.
                List<String> names = remaining.stream().map(Class::getName).toList();
                throw new IllegalStateException("cannot construct " + names + ": missing dependency or a cycle");
            }
        }
        return constructed;
    }

    /** @return null when a dependency is not available yet, not when it is missing for good */
    private Object tryConstruct(Class<?> type) {
        Constructor<?>[] constructors = type.getDeclaredConstructors();
        if (constructors.length != 1) {
            throw new IllegalStateException(type.getName() + " must have exactly one constructor");
        }
        Constructor<?> constructor = constructors[0];
        Class<?>[] wanted = constructor.getParameterTypes();
        Object[] arguments = new Object[wanted.length];
        for (int i = 0; i < wanted.length; i++) {
            Object resolved = resolve(wanted[i]);
            if (resolved == null) {
                return null;
            }
            arguments[i] = resolved;
        }
        if (!constructor.trySetAccessible()) {
            throw new IllegalStateException("cannot access the constructor of " + type.getName());
        }
        try {
            return constructor.newInstance(arguments);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("constructing " + type.getName(), e);
        }
    }

    private Object resolve(Class<?> wanted) {
        Object exact = instances.get(wanted);
        if (exact != null) {
            return exact;
        }
        for (Object candidate : instances.values()) {
            if (wanted.isInstance(candidate)) {
                return candidate;
            }
        }
        return null;
    }
}
