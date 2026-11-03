package neogrip.dataformat;

import neogrip.dataformat.csv.CsvRecordWriter;
import neogrip.dataformat.json.JsonRecordWriter;

/**
 * The formats this library writes, and the only place that maps a name to one.
 *
 * The set is closed on purpose: a format supplied from outside the library
 * would need a registry, and none is built until something needs one. Adding
 * one here is a class and a case, with nothing to change in the caller.
 */
public enum DataFormat {
    JSON,
    CSV;

    public RecordWriter writer(Appendable sink, FormatOptions options) {
        return switch (this) {
            case JSON -> new JsonRecordWriter(sink);
            case CSV -> new CsvRecordWriter(sink, options);
        };
    }
}
