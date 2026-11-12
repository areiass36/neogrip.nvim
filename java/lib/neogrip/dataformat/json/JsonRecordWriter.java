package neogrip.dataformat.json;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.List;
import neogrip.dataformat.RecordWriter;

/**
 * One JSON array of objects, streamed record by record so the array can be
 * larger than memory (ADR-0010); {@link JsonWriter}'s UncheckedIOException is
 * unwrapped so a caller that has to delete a half-written file sees the
 * IOException its signature declared.
 */
public final class JsonRecordWriter implements RecordWriter {
    private final Appendable sink;
    private final JsonWriter out;

    private List<String> fields = List.of();
    private boolean started;

    public JsonRecordWriter(Appendable sink) {
        this.sink = sink;
        this.out = new JsonWriter(sink);
    }

    @Override
    public void header(List<String> names) throws IOException {
        if (started) {
            throw new IllegalStateException("the header is written once, before any record");
        }
        fields = List.copyOf(names);
        try {
            out.beginArray();
        } catch (UncheckedIOException e) {
            throw e.getCause();
        }
        started = true;
    }

    @Override
    public void record(List<Object> values) throws IOException {
        if (!started) {
            throw new IllegalStateException("a record needs the header's field names first");
        }
        try {
            out.beginObject();
            for (int i = 0; i < fields.size(); i++) {
                out.name(fields.get(i));
                JsonMapper.write(out, i < values.size() ? values.get(i) : null);
            }
            out.endObject();
        } catch (UncheckedIOException e) {
            throw e.getCause();
        }
    }

    /** Closes the array and ends the file with a newline, as a text file should. */
    @Override
    public void close() throws IOException {
        if (!started) {
            return;
        }
        try {
            out.endArray();
        } catch (UncheckedIOException e) {
            throw e.getCause();
        }
        sink.append('\n');
    }
}
