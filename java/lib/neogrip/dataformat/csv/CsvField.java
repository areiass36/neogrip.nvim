package neogrip.dataformat.csv;

/** RFC 4180 fields, for the streaming export. */
public final class CsvField {
    private CsvField() {}

    /**
     * One field, quoted when it has to be; the delimiter is a parameter
     * because a quoting rule that disagreed with the separator would write a
     * file nothing can read back.
     */
    public static String field(String value, String nullMarker, char delimiter) {
        if (value == null) {
            return nullMarker == null ? "" : nullMarker;
        }
        boolean needsQuotes = value.indexOf(delimiter) >= 0
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
