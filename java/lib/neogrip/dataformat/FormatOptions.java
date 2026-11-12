package neogrip.dataformat;

/**
 * What a format needs beyond the records themselves: the text that stands for
 * NULL (normalized to the empty string) and the field delimiter, carried so
 * the quoting rule and the separator can never disagree.
 */
public record FormatOptions(String nullMarker, char delimiter) {
    public FormatOptions {
        nullMarker = nullMarker == null ? "" : nullMarker;
    }

    public static FormatOptions defaults() {
        return new FormatOptions("", ',');
    }
}
