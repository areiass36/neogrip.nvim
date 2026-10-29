package neogrip.rpc;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.RecordComponent;
import java.util.List;
import java.util.Map;

/**
 * The one serializer: scalars, Map, List, and records - reflectively, with the
 * components in declaration order, null components left out (which is how the
 * wire's optional fields behave), and @Json wire names honoured. A record on
 * the wire must be public, or its accessors are not callable from here; the
 * error says so by name.
 */
public final class JsonCodec {
    private JsonCodec() {}

    public static void write(JsonStream out, Object value) {
        if (value == null) {
            out.nullValue();
        } else if (value instanceof String text) {
            out.value(text);
        } else if (value instanceof Boolean flag) {
            out.value((boolean) flag);
        } else if (value instanceof Integer || value instanceof Long
                || value instanceof Short || value instanceof Byte) {
            out.value(((Number) value).longValue());
        } else if (value instanceof Double || value instanceof Float) {
            out.value(((Number) value).doubleValue());
        } else if (value instanceof Map<?, ?> map) {
            out.beginObject();
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                out.name(String.valueOf(entry.getKey()));
                write(out, entry.getValue());
            }
            out.endObject();
        } else if (value instanceof List<?> list) {
            out.beginArray();
            for (Object element : list) {
                write(out, element);
            }
            out.endArray();
        } else if (value instanceof Record record) {
            writeRecord(out, record);
        } else {
            // The previous writer's fallback: whatever it is, it reads as text.
            out.value(String.valueOf(value));
        }
    }

    private static void writeRecord(JsonStream out, Record record) {
        out.beginObject();
        for (RecordComponent component : record.getClass().getRecordComponents()) {
            Object value;
            try {
                value = component.getAccessor().invoke(record);
            } catch (IllegalAccessException e) {
                throw new IllegalStateException(
                        "record " + record.getClass().getName() + " must be public to go on the wire", e);
            } catch (InvocationTargetException e) {
                throw new IllegalStateException(
                        "reading " + record.getClass().getName() + "." + component.getName(), e.getCause());
            }
            if (value == null) {
                continue;
            }
            Json name = component.getAnnotation(Json.class);
            out.name(name != null ? name.value() : component.getName());
            write(out, value);
        }
        out.endObject();
    }
}
