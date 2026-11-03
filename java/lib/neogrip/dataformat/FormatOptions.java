package neogrip.dataformat;

/**
 * What a format needs beyond the records themselves: the text that stands for
 * NULL, and the field delimiter.
 *
 * A null marker is normalized to the empty string, because no marker and a
 * null marker mean the same thing to every reader on the other side; the
 * delimiter is carried rather than assumed so the quoting rule and the
 * separator can never disagree about which character they are talking about.
 */
public record FormatOptions(String nullMarker, char delimiter) {
    public FormatOptions {
        nullMarker = nullMarker == null ? "" : nullMarker;
    }

    public static FormatOptions defaults() {
        return new FormatOptions("", ',');
    }
}
