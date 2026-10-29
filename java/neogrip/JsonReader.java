package neogrip;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A recursive-descent JSON parser, because requests are JSON now (ADR-0002)
 * and the no-dependency rule still holds (ADR-0004).
 *
 * Shapes map to plain Java: object to LinkedHashMap (key order preserved),
 * array to ArrayList, string to String, number to Long when it is integral and
 * fits, otherwise Double, plus Boolean and null. Malformed input throws
 * IllegalArgumentException naming the position; the caller decides whether
 * that is a protocol error or a driver banner to skip.
 */
public final class JsonReader {
    private final String text;
    private int position;

    private JsonReader(String text) {
        this.text = text;
    }

    public static Object parse(String text) {
        JsonReader reader = new JsonReader(text);
        reader.skipWhitespace();
        Object value = reader.value();
        reader.skipWhitespace();
        if (reader.position != text.length()) {
            throw reader.error("trailing characters");
        }
        return value;
    }

    private Object value() {
        char c = peek();
        return switch (c) {
            case '{' -> object();
            case '[' -> array();
            case '"' -> string();
            case 't', 'f' -> bool();
            case 'n' -> nullLiteral();
            default -> number();
        };
    }

    private Map<String, Object> object() {
        expect('{');
        Map<String, Object> map = new LinkedHashMap<>();
        skipWhitespace();
        if (peek() == '}') {
            position++;
            return map;
        }
        while (true) {
            skipWhitespace();
            String key = string();
            skipWhitespace();
            expect(':');
            skipWhitespace();
            map.put(key, value());
            skipWhitespace();
            char c = next();
            if (c == '}') return map;
            if (c != ',') throw error("expected ',' or '}'");
        }
    }

    private List<Object> array() {
        expect('[');
        List<Object> list = new ArrayList<>();
        skipWhitespace();
        if (peek() == ']') {
            position++;
            return list;
        }
        while (true) {
            skipWhitespace();
            list.add(value());
            skipWhitespace();
            char c = next();
            if (c == ']') return list;
            if (c != ',') throw error("expected ',' or ']'");
        }
    }

    private String string() {
        expect('"');
        StringBuilder out = new StringBuilder();
        while (true) {
            char c = next();
            if (c == '"') return out.toString();
            if (c != '\\') {
                out.append(c);
                continue;
            }
            char escape = next();
            switch (escape) {
                case '"' -> out.append('"');
                case '\\' -> out.append('\\');
                case '/' -> out.append('/');
                case 'b' -> out.append('\b');
                case 'f' -> out.append('\f');
                case 'n' -> out.append('\n');
                case 'r' -> out.append('\r');
                case 't' -> out.append('\t');
                case 'u' -> out.append(unicode());
                default -> throw error("unknown escape '\\" + escape + "'");
            }
        }
    }

    private char unicode() {
        if (position + 4 > text.length()) {
            throw error("truncated \\u escape");
        }
        String hex = text.substring(position, position + 4);
        position += 4;
        try {
            return (char) Integer.parseInt(hex, 16);
        } catch (NumberFormatException e) {
            throw error("bad \\u escape '" + hex + "'");
        }
    }

    private Object number() {
        int start = position;
        if (peek() == '-') position++;
        while (position < text.length() && Character.isDigit(text.charAt(position))) position++;
        boolean integral = true;
        if (position < text.length() && text.charAt(position) == '.') {
            integral = false;
            position++;
            while (position < text.length() && Character.isDigit(text.charAt(position))) position++;
        }
        if (position < text.length() && (text.charAt(position) == 'e' || text.charAt(position) == 'E')) {
            integral = false;
            position++;
            if (position < text.length() && (text.charAt(position) == '+' || text.charAt(position) == '-')) {
                position++;
            }
            while (position < text.length() && Character.isDigit(text.charAt(position))) position++;
        }
        String token = text.substring(start, position);
        if (token.isEmpty() || token.equals("-")) {
            throw error("expected a value");
        }
        if (integral) {
            try {
                return Long.parseLong(token);
            } catch (NumberFormatException tooBig) {
                // Falls through: a number beyond long still parses as double.
            }
        }
        try {
            return Double.parseDouble(token);
        } catch (NumberFormatException e) {
            throw error("bad number '" + token + "'");
        }
    }

    private Boolean bool() {
        if (text.startsWith("true", position)) {
            position += 4;
            return Boolean.TRUE;
        }
        if (text.startsWith("false", position)) {
            position += 5;
            return Boolean.FALSE;
        }
        throw error("expected a value");
    }

    private Object nullLiteral() {
        if (text.startsWith("null", position)) {
            position += 4;
            return null;
        }
        throw error("expected a value");
    }

    private void skipWhitespace() {
        while (position < text.length()) {
            char c = text.charAt(position);
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return;
            position++;
        }
    }

    private char peek() {
        if (position >= text.length()) {
            throw error("unexpected end of input");
        }
        return text.charAt(position);
    }

    private char next() {
        char c = peek();
        position++;
        return c;
    }

    private void expect(char wanted) {
        char c = next();
        if (c != wanted) {
            throw error("expected '" + wanted + "'");
        }
    }

    private IllegalArgumentException error(String message) {
        return new IllegalArgumentException("json: " + message + " at " + position);
    }
}
