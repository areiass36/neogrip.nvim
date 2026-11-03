package neogrip.dataformat;

import java.io.IOException;
import java.util.List;

/**
 * A stream of records written into a sink.
 *
 * Formats differ in how a record looks in the file, not in how it is produced:
 * a header once, then one record at a time, then whatever closes the
 * structure. The export path proved it by writing that walk twice - once for
 * CSV, once for JSON - and choosing between the copies with a boolean, so a
 * third format meant a third copy.
 *
 * {@link #close()} finishes the structure - the closing bracket of a JSON
 * array, a trailing newline - and never closes the sink, which belongs to
 * whoever opened it.
 */
public interface RecordWriter extends AutoCloseable {
    /** The field names, once, before any record. */
    void header(List<String> fields) throws IOException;

    /** One record, in the order the header declared. */
    void record(List<Object> values) throws IOException;

    @Override
    void close() throws IOException;
}
