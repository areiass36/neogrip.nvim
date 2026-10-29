package neogrip;

import java.util.List;
import java.util.Map;

/**
 * Just enough JSON writing for a response. Java has no JSON in its standard
 * library, and pulling in Jackson for this would mean another jar to download
 * on every machine for the sake of a few hundred lines. Reading is the same
 * story: JsonReader, beside this class.
 */
public final class Json {
    private Json() {}

    public static void writeString(StringBuilder out, String value) {
        out.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> out.append("\\\"");
                case '\\' -> out.append("\\\\");
                case '\n' -> out.append("\\n");
                case '\r' -> out.append("\\r");
                case '\t' -> out.append("\\t");
                case '\b' -> out.append("\\b");
                case '\f' -> out.append("\\f");
                default -> {
                    // Control characters have to be escaped; a lone surrogate
                    // would make the decoder on the other side fail, so it is
                    // replaced rather than passed through.
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else if (Character.isSurrogate(c) && !isPaired(value, i)) {
                        out.append('�');
                    } else {
                        out.append(c);
                    }
                }
            }
        }
        out.append('"');
    }

    private static boolean isPaired(String value, int index) {
        char c = value.charAt(index);
        if (Character.isHighSurrogate(c)) {
            return index + 1 < value.length() && Character.isLowSurrogate(value.charAt(index + 1));
        }
        return index > 0 && Character.isHighSurrogate(value.charAt(index - 1));
    }

    /** A value that is already a number, a boolean, null, or has to become a string. */
    public static void writeValue(StringBuilder out, Object value) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof Boolean || value instanceof Integer || value instanceof Long) {
            out.append(value);
        } else if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            // NaN and infinity are not JSON; they go out as text so the grid
            // can still show what the database returned.
            if (Double.isNaN(number) || Double.isInfinite(number)) {
                writeString(out, String.valueOf(value));
            } else {
                out.append(value);
            }
        } else if (value instanceof RawJson raw) {
            out.append(raw.text);
        } else if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) out.append(',');
                first = false;
                writeString(out, String.valueOf(entry.getKey()));
                out.append(':');
                writeValue(out, entry.getValue());
            }
            out.append('}');
        } else if (value instanceof List<?> list) {
            out.append('[');
            for (int i = 0; i < list.size(); i++) {
                if (i > 0) out.append(',');
                writeValue(out, list.get(i));
            }
            out.append(']');
        } else {
            writeString(out, String.valueOf(value));
        }
    }

    /** Text that is already JSON and must not be escaped again. */
    public record RawJson(String text) {}
}
