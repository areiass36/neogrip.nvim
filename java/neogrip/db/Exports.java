package neogrip.db;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import neogrip.dataformat.DataFormat;
import neogrip.dataformat.FormatOptions;
import neogrip.dataformat.RecordWriter;
import neogrip.db.types.Types.ExportResult;

/**
 * Stream a result straight to a file - nothing held in memory - written beside
 * the target and atomically renamed into place, so a crashed export never
 * leaves a half file where the editor reads a finished one (ADR-0010).
 */
public final class Exports {
    private final Connection connection;
    private final AtomicReference<Statement> running;
    private final ReadonlyGuard guard;

    public Exports(Connection connection, AtomicReference<Statement> running, ReadonlyGuard guard) {
        this.connection = connection;
        this.running = running;
        this.guard = guard;
    }

    public ExportResult export(String sql, String path, String format, String nullMarker, int timeoutSeconds)
            throws SQLException, IOException {
        guard.refuseWrites(sql);
        DataFormat chosen = "json".equalsIgnoreCase(format) ? DataFormat.JSON : DataFormat.CSV;
        FormatOptions options = new FormatOptions(nullMarker, ',');
        long start = System.currentTimeMillis();
        long written = 0;
        Path target = Path.of(path);
        Path partial = target.resolveSibling(target.getFileName() + ".part");
        try (Statement statement =
                connection.createStatement(ResultSet.TYPE_FORWARD_ONLY, ResultSet.CONCUR_READ_ONLY)) {
            running.set(statement);
            if (timeoutSeconds > 0) {
                Statements.tolerate(() -> statement.setQueryTimeout(timeoutSeconds));
            }
            Statements.tolerate(() -> statement.setFetchSize(1000));
            try (ResultSet rows = statement.executeQuery(sql);
                    Writer file = new BufferedWriter(new OutputStreamWriter(
                            Files.newOutputStream(partial), StandardCharsets.UTF_8))) {
                written = stream(rows, chosen.writer(file, options));
            } catch (SQLException | IOException | RuntimeException e) {
                Files.deleteIfExists(partial);
                throw e;
            }
        } finally {
            running.set(null);
        }
        try {
            Files.move(partial, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException notAtomic) {
            Files.move(partial, target, StandardCopyOption.REPLACE_EXISTING);
        }
        return new ExportResult(written, path, System.currentTimeMillis() - start);
    }

    /**
     * The column labels, then every row, through whichever format was asked
     * for. One walk serves them all: before the record writer existed this
     * loop was written once per format, and the two copies had already drifted
     * apart in how they turned a value into text.
     */
    private static long stream(ResultSet rows, RecordWriter out) throws SQLException, IOException {
        try (out) {
            ResultSetMetaData meta = rows.getMetaData();
            int columnCount = meta.getColumnCount();
            List<String> names = new ArrayList<>(columnCount);
            for (int i = 1; i <= columnCount; i++) {
                names.add(meta.getColumnLabel(i));
            }
            out.header(names);

            long written = 0;
            while (rows.next()) {
                // A list per row rather than one reused: the writer is free to
                // keep what it is handed, and a row that outlives its values
                // is the kind of bug that only shows up in the last format
                // added.
                List<Object> values = new ArrayList<>(columnCount);
                for (int i = 1; i <= columnCount; i++) {
                    values.add(Values.read(rows, meta, i));
                }
                out.record(values);
                written++;
            }
            return written;
        }
    }
}
