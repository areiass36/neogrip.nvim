package neogrip.db.catalog;

import java.io.BufferedWriter;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.sql.Connection;
import java.sql.DatabaseMetaData;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import neogrip.db.types.Types;
import neogrip.rpc.JsonCodec;
import neogrip.rpc.JsonStream;
import neogrip.rpc.RpcException;
import neogrip.rpc.Wire;

/**
 * The whole catalog, written to a file instead of answered through the
 * protocol (ADR-0010): a warehouse's catalog runs to hundreds of megabytes of
 * JSON, and a line that long is not a protocol message. Every schema is swept
 * once, on connections of the sweep's own, and the editor reads the file -
 * which also survives a restart, and a server that has since gone away.
 */
public final class Introspect {
    private final Connection connection;
    /** Tripped by the cancel operation: a sweep has no statement to cancel. */
    private final AtomicBoolean cancelled;
    /** What this process connected with, so the sweep can open siblings of it. */
    private final String url;
    private final Properties properties;

    public Introspect(Connection connection, AtomicBoolean cancelled, String url, Properties properties) {
        this.connection = connection;
        this.cancelled = cancelled;
        this.url = url == null ? "" : url;
        this.properties = properties == null ? new Properties() : properties;
    }

    /**
     * The whole catalog, written to a file instead of answered through the
     * protocol.
     *
     * The snapshot above fixed the walking for one schema; a database has
     * hundreds of them, and the explorer cannot ask for one per keystroke. So
     * every schema is swept once, written to disk, and read from there - which
     * also survives a restart, and a server that has since gone away.
     *
     * The answer is a path rather than the catalog itself because a warehouse's
     * catalog runs to hundreds of megabytes of JSON, and a line that long is
     * not a protocol message.
     */
    public Types.IntrospectSummary introspect(
            String catalog, String outFile, int parallelism, long deadlineMs, boolean wantDetails)
            throws SQLException, IOException {
        long start = System.currentTimeMillis();
        // No budget at all rather than one that has already run out: a caller
        // that asks for nothing wants the whole catalog, not an empty pass.
        long deadline = deadlineMs > 0 ? start + deadlineMs : Long.MAX_VALUE;
        // The flag is shared with the statement the worker may be running, so
        // a cancel sent before this request must not end it on sight.
        cancelled.set(false);

        if (outFile == null || outFile.isEmpty()) {
            throw new RpcException(Wire.INVALID_REQUEST, "introspect needs a file to write the catalog to");
        }
        if (MongoFields.isMongo(connection)) {
            // getColumns wants the Atlas SQL schema a plain mongod does not
            // have, and a snapshot of collections without fields would answer
            // "no fields" where the explorer has to sample documents instead.
            throw new RpcException(
                    Wire.INVALID_REQUEST,
                    "a collection catalog cannot be swept; the explorer samples documents instead");
        }

        DatabaseMetaData meta = connection.getMetaData();
        List<Snapshot.SchemaBody> schemas = Snapshot.schemaBodies(meta, catalog);
        String label = catalog == null || catalog.isEmpty() ? currentCatalog(connection) : catalog;
        String product = product(meta);

        Path target = Path.of(outFile);
        Path temp = null;
        SiblingPool.Pool pool = null;
        ExecutorService threads = null;
        boolean parallel = false;
        boolean partial = false;
        boolean written = false;
        int detailed = 0;
        try {
            // One schema has no concurrency in it to find, so this stage is
            // sized by how many there are.
            pool = SiblingPool.openSiblings(meta, url, properties, schemas.size(), parallelism, null);
            threads = SiblingPool.sweepThreads(pool);
            if (pool != null) {
                parallel = true;
            }
            SiblingPool.run(sweepTasks(schemas, pool, catalog), threads);

            if (wantDetails && !cancelled.get()) {
                int walk = 0;
                for (Snapshot.SchemaBody schema : schemas) {
                    walk += schema.kinds.size();
                }
                // This stage is per table, and that is where a database with
                // everything in one schema has its concurrency: MySQL has one
                // schema by definition, SQLite has none, and the common
                // Postgres database never left public - while any of them can
                // have hundreds of tables, each wanting four metadata calls.
                // Sizing this by schemas would leave all three sequential.
                int before = pool == null ? 0 : pool.size();
                pool = SiblingPool.openSiblings(meta, url, properties, walk, parallelism, pool);
                if (pool != null && pool.size() != before) {
                    // The sweeps are done with the old threads, and there are
                    // now more connections than there were of them.
                    if (threads != null) {
                        threads.shutdown();
                    }
                    threads = SiblingPool.sweepThreads(pool);
                }
                if (pool != null) {
                    parallel = true;
                }

                AtomicBoolean ranOut = new AtomicBoolean();
                AtomicInteger done = new AtomicInteger();
                SiblingPool.run(detailTasks(schemas, pool, catalog, deadline, ranOut, done), threads);
                partial = ranOut.get();
                detailed = done.get();
            }

            if (!cancelled.get()) {
                temp = tempBeside(target);
                boolean complete;
                try (Writer file = new BufferedWriter(
                        new OutputStreamWriter(Files.newOutputStream(temp), StandardCharsets.UTF_8))) {
                    complete = writeSnapshot(file, product, label, parallel, partial, schemas, cancelled);
                }
                if (complete) {
                    move(temp, target);
                    temp = null;
                    written = true;
                }
            }
        } finally {
            if (threads != null) {
                threads.shutdownNow();
            }
            if (pool != null) {
                pool.closeAll();
            }
            if (temp != null) {
                // The write failed or was cancelled. Nothing may be left
                // where the editor reads a finished snapshot.
                try {
                    Files.deleteIfExists(temp);
                } catch (IOException ignored) {
                    // A file in the cache directory that nobody will read.
                }
            }
        }

        // A snapshot that reached its place is an answer even if a cancel
        // arrived a moment later; nothing else can get this far unwritten.
        if (!written) {
            throw new RpcException(Wire.CANCELLED, "the catalog sweep was cancelled");
        }

        int tables = 0;
        long columns = 0;
        for (Snapshot.SchemaBody schema : schemas) {
            tables += schema.kinds.size();
            columns += schema.columnCount;
        }
        return new Types.IntrospectSummary(
                outFile,
                schemas.size(),
                tables,
                columns,
                detailed,
                partial,
                parallel,
                System.currentTimeMillis() - start);
    }

    /**
     * One task per schema, each holding a connection for all three of that
     * schema's sweeps.
     */
    private List<Callable<Void>> sweepTasks(List<Snapshot.SchemaBody> schemas, SiblingPool.Pool pool, String catalog) {
        List<Callable<Void>> tasks = new ArrayList<>();
        for (Snapshot.SchemaBody schema : schemas) {
            tasks.add(() -> {
                if (cancelled.get()) {
                    return null;
                }
                Connection held = pool == null ? connection : pool.take();
                try {
                    // Neither sweep is capped. The caps the snapshot operation
                    // uses are there because its answer has to fit on one
                    // line; this one writes to a file, so a cap would only
                    // hide tables the explorer could have had.
                    Snapshot.sweepSchema(schema, held.getMetaData(), catalog, Integer.MAX_VALUE, Integer.MAX_VALUE);
                } finally {
                    if (pool != null) {
                        pool.release(held);
                    }
                }
                return null;
            });
        }
        return tasks;
    }

    /** One task per table, for the pass that describes each one. */
    private List<Callable<Void>> detailTasks(
            List<Snapshot.SchemaBody> schemas,
            SiblingPool.Pool pool,
            String catalog,
            long deadline,
            AtomicBoolean ranOut,
            AtomicInteger done) {
        List<Callable<Void>> tasks = new ArrayList<>();
        for (Snapshot.SchemaBody schema : schemas) {
            for (String table : schema.kinds.keySet()) {
                tasks.add(() -> {
                    if (cancelled.get()) {
                        return null;
                    }
                    // The sweeps always finish, because a snapshot without
                    // columns is worth nothing. The budget is spent here
                    // instead, where running out costs one table's definition
                    // and not the file.
                    if (System.currentTimeMillis() > deadline) {
                        ranOut.set(true);
                        return null;
                    }
                    Connection held = pool == null ? connection : pool.take();
                    try {
                        schema.details.put(
                                table,
                                Details.collectDetails(
                                        held.getMetaData(),
                                        catalog,
                                        schema.pattern,
                                        table,
                                        schema.keys.getOrDefault(table, Keys.PrimaryKey.NONE)));
                        done.incrementAndGet();
                    } catch (SQLException refused) {
                        // One table the engine will not describe is no reason
                        // to lose the other ten thousand.
                    } finally {
                        if (pool != null) {
                            pool.release(held);
                        }
                    }
                    return null;
                });
            }
        }
        return tasks;
    }

    /** The same string the ready line announces, so both name one server. */
    private static String product(DatabaseMetaData meta) {
        try {
            return meta.getDatabaseProductName() + " " + meta.getDatabaseProductVersion();
        } catch (SQLException ignored) {
            // A driver that cannot describe itself still has a catalog.
            return "";
        }
    }

    private static String currentCatalog(Connection connection) {
        try {
            String current = connection.getCatalog();
            return current == null ? "" : current;
        } catch (SQLException ignored) {
            // Not every driver has catalogs to be in one of.
            return "";
        }
    }

    /**
     * The snapshot, straight into the file.
     *
     * Nothing bigger than one table is ever held as a single string: the
     * per-schema buffers are appended to the stream in the order the schemas
     * were listed, so a catalog larger than this process's heap still gets
     * written.
     *
     * @return false when a cancel arrived mid-write, which leaves the file for
     *         the caller to delete instead of moving it into place.
     */
    private static boolean writeSnapshot(
            Writer file,
            String product,
            String catalog,
            boolean parallel,
            boolean partial,
            List<Snapshot.SchemaBody> schemas,
            AtomicBoolean cancelled)
            throws IOException {
        try {
            JsonStream out = new JsonStream(file);
            out.beginObject();
            out.name("at").value(System.currentTimeMillis() / 1000);
            out.name("product").value(product);
            out.name("catalog").value(catalog);
            out.name("parallel").value(parallel);
            out.name("partial").value(partial);
            out.name("schemas").beginArray();
            for (Snapshot.SchemaBody schema : schemas) {
                if (cancelled.get()) {
                    return false;
                }
                out.beginObject().name("name").value(schema.name).name("tables").beginArray();
                for (java.util.Map.Entry<String, String> table : schema.kinds.entrySet()) {
                    writeTable(out, schema, table.getKey(), table.getValue());
                }
                out.endArray().endObject();
            }
            out.endArray().endObject();
            return true;
        } catch (java.io.UncheckedIOException wrapped) {
            throw wrapped.getCause();
        }
    }

    /**
     * One table, in the shape the table view's renderers already read.
     *
     * The index and key arrays are written empty rather than left out when the
     * detail pass did not reach this table, so a reader never has to tell a
     * missing field from a table that has no indexes: the details flag is what
     * says which of the two it is.
     *
     * Where the detail pass ran, its primary key and its columns are the ones
     * written: it asked per table, and the schema sweep's single call for all
     * of them is the one that can come back empty on an engine that does not
     * support it.
     */
    private static void writeTable(JsonStream out, Snapshot.SchemaBody schema, String table, String kind) {
        Details.DetailParts details = schema.details.get(table);
        out.beginObject();
        out.name("name").value(table);
        out.name("kind").value(kind);
        String remarks = schema.remarks.get(table);
        if (remarks != null) {
            out.name("remarks").value(remarks);
        }

        List<Types.ColumnRow> columns =
                details != null && details.columns != null ? details.columns : schema.columns.get(table);
        out.name("columns");
        JsonCodec.write(out, columns == null ? List.of() : columns);

        Keys.PrimaryKey primaryKey =
                details != null ? details.primaryKey : schema.keys.getOrDefault(table, Keys.PrimaryKey.NONE);
        out.name("primary_key");
        JsonCodec.write(out, new ArrayList<>(primaryKey.columns));
        if (primaryKey.name != null) {
            out.name("primary_key_name").value(primaryKey.name);
        }

        out.name("indexes");
        JsonCodec.write(out, details != null ? details.indexes : List.of());
        out.name("foreign_keys");
        JsonCodec.write(out, details != null ? details.foreignKeys : List.of());
        out.name("referenced_by");
        JsonCodec.write(out, details != null ? details.referencedBy : List.of());
        out.name("details").value(details != null);
        out.endObject();
    }

    /**
     * A snapshot is only ever read whole, so it is written beside its target
     * and moved onto it at the end: a crash, a cancel or a full disk then
     * leaves the previous snapshot in place instead of half of a new one.
     */
    private static Path tempBeside(Path target) throws IOException {
        Path parent = target.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        return Files.createTempFile(parent == null ? Path.of(".") : parent, ".neogrip-catalog", ".json");
    }

    private static void move(Path temp, Path target) throws IOException {
        try {
            Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException unsupported) {
            // Not every file system can swap a file in one step, and a reader
            // that catches the gap falls back to asking the server.
            Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
        }
    }
}
