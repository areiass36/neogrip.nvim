package neogrip.rpc;

import java.io.IOException;
import java.io.UncheckedIOException;

/**
 * A structured JSON writer over any Appendable: a StringBuilder for an in-band
 * response, a BufferedWriter for a file the sidecar streams into. Commas,
 * quoting and escaping live here and nowhere else - the hand-counted braces
 * this library replaced were the sidecar's steadiest source of almost-bugs.
 *
 * Escaping rules carried over from the previous writer: control characters are
 * escaped, and a lone surrogate is replaced rather than passed through,
 * because it would make the decoder on the other side fail.
 */
public final class JsonStream {
    private static final byte TOP = 0;
    private static final byte OBJECT_EMPTY = 1;
    private static final byte OBJECT_AFTER = 2;
    private static final byte NAME_PENDING = 3;
    private static final byte ARRAY_EMPTY = 4;
    private static final byte ARRAY_AFTER = 5;

    private final Appendable out;
    private byte[] stack = new byte[16];
    private int depth = 0;

    public JsonStream(Appendable out) {
        this.out = out;
        stack[0] = TOP;
    }

    private void append(char c) {
        try {
            out.append(c);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private void append(CharSequence text) {
        try {
            out.append(text);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private void push(byte state) {
        depth++;
        if (depth == stack.length) {
            byte[] grown = new byte[stack.length * 2];
            System.arraycopy(stack, 0, grown, 0, stack.length);
            stack = grown;
        }
        stack[depth] = state;
    }

    /** The comma-and-context step before any value, container or scalar. */
    private void beforeValue() {
        switch (stack[depth]) {
            case TOP -> {
                // One top-level value per stream; a second is a caller bug.
            }
            case NAME_PENDING -> stack[depth] = OBJECT_AFTER;
            case ARRAY_EMPTY -> stack[depth] = ARRAY_AFTER;
            case ARRAY_AFTER -> append(',');
            default -> throw new IllegalStateException("a value inside an object needs a name first");
        }
    }

    public JsonStream beginObject() {
        beforeValue();
        append('{');
        push(OBJECT_EMPTY);
        return this;
    }

    public JsonStream endObject() {
        if (stack[depth] != OBJECT_EMPTY && stack[depth] != OBJECT_AFTER) {
            throw new IllegalStateException("not inside an object");
        }
        append('}');
        depth--;
        return this;
    }

    public JsonStream beginArray() {
        beforeValue();
        append('[');
        push(ARRAY_EMPTY);
        return this;
    }

    public JsonStream endArray() {
        if (stack[depth] != ARRAY_EMPTY && stack[depth] != ARRAY_AFTER) {
            throw new IllegalStateException("not inside an array");
        }
        append(']');
        depth--;
        return this;
    }

    public JsonStream name(String key) {
        switch (stack[depth]) {
            case OBJECT_EMPTY -> stack[depth] = NAME_PENDING;
            case OBJECT_AFTER -> {
                append(',');
                stack[depth] = NAME_PENDING;
            }
            default -> throw new IllegalStateException("a name belongs inside an object");
        }
        string(key);
        append(':');
        return this;
    }

    public JsonStream value(String text) {
        beforeValue();
        if (text == null) {
            append("null");
        } else {
            string(text);
        }
        return this;
    }

    public JsonStream value(long number) {
        beforeValue();
        append(Long.toString(number));
        return this;
    }

    public JsonStream value(double number) {
        beforeValue();
        // NaN and infinity are not JSON; they go out as text so the editor can
        // still show what the database returned.
        if (Double.isNaN(number) || Double.isInfinite(number)) {
            string(String.valueOf(number));
        } else {
            append(Double.toString(number));
        }
        return this;
    }

    public JsonStream value(boolean flag) {
        beforeValue();
        append(flag ? "true" : "false");
        return this;
    }

    public JsonStream nullValue() {
        beforeValue();
        append("null");
        return this;
    }

    private void string(String value) {
        append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"' -> append("\\\"");
                case '\\' -> append("\\\\");
                case '\n' -> append("\\n");
                case '\r' -> append("\\r");
                case '\t' -> append("\\t");
                case '\b' -> append("\\b");
                case '\f' -> append("\\f");
                default -> {
                    if (c < 0x20) {
                        append(String.format("\\u%04x", (int) c));
                    } else if (Character.isSurrogate(c) && !isPaired(value, i)) {
                        append('�');
                    } else {
                        append(c);
                    }
                }
            }
        }
        append('"');
    }

    private static boolean isPaired(String value, int index) {
        char c = value.charAt(index);
        if (Character.isHighSurrogate(c)) {
            return index + 1 < value.length() && Character.isLowSurrogate(value.charAt(index + 1));
        }
        return index > 0 && Character.isHighSurrogate(value.charAt(index - 1));
    }
}
