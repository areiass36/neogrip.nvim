package neogrip.db;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.UncheckedIOException;
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
import java.util.concurrent.atomic.AtomicReference;
import neogrip.db.types.Types.ExportResult;
import neogrip.rpc.JsonCodec;
import neogrip.rpc.JsonStream;

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
        long start = System.currentTimeMillis();
        long written = 0;
        Path target = Path.of(path);
        Path partial = target.resolveSibling(target.getFileName() + ".part");
        boolean json = "json".equalsIgnoreCase(format);
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
                written = json ? exportJson(rows, file) : exportCsv(rows, file, nullMarker);
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

    private static long exportCsv(ResultSet rows, Writer file, String nullMarker)
            throws SQLException, IOException {
        ResultSetMetaData meta = rows.getMetaData();
        int columnCount = meta.getColumnCount();
        long written = 0;
        for (int i = 1; i <= columnCount; i++) {
            if (i > 1) file.write(',');
            file.write(Csv.field(meta.getColumnLabel(i), nullMarker));
        }
        file.write('\n');
        while (rows.next()) {
            for (int i = 1; i <= columnCount; i++) {
                if (i > 1) file.write(',');
                Object value = Values.read(rows, meta, i);
                file.write(Csv.field(value == null ? null : String.valueOf(value), nullMarker));
            }
            file.write('\n');
            written++;
        }
        return written;
    }

    /**
     * One JSON array of objects, keyed by column label, streamed row by row
     * through the same structured writer the in-band results use.
     */
    private static long exportJson(ResultSet rows, Writer file) throws SQLException, IOException {
        ResultSetMetaData meta = rows.getMetaData();
        int columnCount = meta.getColumnCount();
        String[] names = new String[columnCount];
        for (int i = 1; i <= columnCount; i++) {
            names[i - 1] = meta.getColumnLabel(i);
        }
        long written = 0;
        JsonStream out = new JsonStream(file);
        try {
            out.beginArray();
            while (rows.next()) {
                out.beginObject();
                for (int i = 1; i <= columnCount; i++) {
                    out.name(names[i - 1]);
                    JsonCodec.write(out, Values.read(rows, meta, i));
                }
                out.endObject();
                written++;
            }
            out.endArray();
        } catch (UncheckedIOException e) {
            throw e.getCause();
        }
        file.write('\n');
        return written;
    }
}
