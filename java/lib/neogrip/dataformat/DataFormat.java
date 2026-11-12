package neogrip.dataformat;

import java.util.Arrays;
import java.util.Locale;
import java.util.stream.Collectors;
import neogrip.dataformat.csv.CsvRecordWriter;
import neogrip.dataformat.json.JsonRecordWriter;

/**
 * The formats this library writes, and the only place that maps a name to
 * one; the set is deliberately closed until something needs a registry.
 */
public enum DataFormat {
    JSON,
    CSV;

    /**
     * The format under this name; an unknown one is refused rather than
     * defaulted, because the export this library replaced read every name that
     * was not "json" as CSV, so a typo wrote a CSV file under a .json name.
     */
    public static DataFormat of(String name) {
        for (DataFormat format : values()) {
            if (format.name().equalsIgnoreCase(name)) {
                return format;
            }
        }
        throw new IllegalArgumentException("unknown format '" + name + "'; this writes " + known());
    }

    /** The names, for an error message that cannot drift from the enum. */
    public static String known() {
        return Arrays.stream(values())
                .map(format -> format.name().toLowerCase(Locale.ROOT))
                .collect(Collectors.joining(", "));
    }

    public RecordWriter writer(Appendable sink, FormatOptions options) {
        return switch (this) {
            case JSON -> new JsonRecordWriter(sink);
            case CSV -> new CsvRecordWriter(sink, options);
        };
    }
}
