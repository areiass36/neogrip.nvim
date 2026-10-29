package neogrip.db;

/** RFC 4180 fields, for the streaming export. */
public final class Csv {
    private Csv() {}

    public static String field(String value, String nullMarker) {
        if (value == null) {
            return nullMarker == null ? "" : nullMarker;
        }
        boolean needsQuotes = value.indexOf(',') >= 0
                || value.indexOf('"') >= 0
                || value.indexOf('\n') >= 0
                || value.indexOf('\r') >= 0
                || (!value.isEmpty() && (Character.isWhitespace(value.charAt(0))
                        || Character.isWhitespace(value.charAt(value.length() - 1))));
        if (!needsQuotes) {
            return value;
        }
        return '"' + value.replace("\"", "\"\"") + '"';
    }
}
