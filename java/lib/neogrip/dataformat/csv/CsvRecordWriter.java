package neogrip.dataformat.csv;

import java.io.IOException;
import java.util.List;
import neogrip.dataformat.FormatOptions;
import neogrip.dataformat.RecordWriter;

/**
 * RFC 4180 rows: the header line, then one line per record, each field quoted
 * by {@link CsvField} when it has to be. A line is built whole before it
 * reaches the sink, which is also what keeps a failure mid-record from leaving
 * half a line in the file.
 */
public final class CsvRecordWriter implements RecordWriter {
    private final Appendable sink;
    private final FormatOptions options;

    public CsvRecordWriter(Appendable sink, FormatOptions options) {
        this.sink = sink;
        this.options = options;
    }

    @Override
    public void header(List<String> fields) throws IOException {
        line(fields);
    }

    @Override
    public void record(List<Object> values) throws IOException {
        line(values);
    }

    /** Nothing to finish: every record already ended with its newline. */
    @Override
    public void close() throws IOException {
        // Deliberately empty. CSV has no closing structure.
    }

    private void line(List<?> cells) throws IOException {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < cells.size(); i++) {
            if (i > 0) {
                text.append(options.delimiter());
            }
            Object cell = cells.get(i);
            text.append(CsvField.field(
                    cell == null ? null : String.valueOf(cell), options.nullMarker(), options.delimiter()));
        }
        text.append('\n');
        sink.append(text);
    }
}
