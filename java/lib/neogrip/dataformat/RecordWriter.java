package neogrip.dataformat;

import java.io.IOException;
import java.util.List;

/**
 * A stream of records written into a sink - the export path once wrote this
 * walk twice, as CSV and JSON copies chosen by a boolean. {@link #close()}
 * finishes the structure and never closes the sink, which belongs to whoever
 * opened it.
 */
public interface RecordWriter extends AutoCloseable {
    /** The field names, once, before any record. */
    void header(List<String> fields) throws IOException;

    /** One record, in the order the header declared. */
    void record(List<Object> values) throws IOException;

    @Override
    void close() throws IOException;
}
