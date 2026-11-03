package neogrip.gripd.contract;

import java.util.List;
import java.util.Map;
import neogrip.dataformat.json.JsonName;

/**
 * The domain records the wire already implies, one file because they are
 * fifteen lines of shape and no behavior. Adding a future method means
 * declaring its record here and returning it from a handler; JsonMapper
 * serializes components in declaration order, leaves null ones out (that is
 * how the wire's optional fields behave), and honours @JsonName for the names
 * that are not Java spellings.
 */
public final class Contracts {
    private Contracts() {}

    /** One result column; table/schema only when the driver will say (nulls omitted). */
    public record Column(String name, String type, String table, String schema) {}

    /**
     * One batch of an open result (ADR-0031). `hash` is echoed back so the
     * client can assert it is appending the right rows to the right result;
     * `columns` is absent on a continuation unless a document result grew its
     * own, and `done` says the result has no more rows and is already closed.
     */
    public record QueryPage(
            String hash, List<Column> columns, List<List<Object>> rows, boolean done, long elapsedMs) {}

    public record UpdateResult(int updateCount, long elapsedMs) {}

    /** The answer to an intercepted BEGIN/COMMIT/ROLLBACK: is one open now? */
    public record TxState(boolean transaction) {}

    public record ExportResult(long rows, String path, long elapsedMs) {}

    public record ConnectResult(String product, String driver, Map<String, Object> capabilities) {}

    /** A bare name, as the catalogs and schemas listings answer. */
    public record Named(String name) {}

    /**
     * The {"rows":[...]} shape every catalog listing answers with.
     *
     * `truncated` is present only when a page was cut, so the client knows the
     * difference between "that is all of them" and "ask again after the last
     * name you got" (ADR-0038). Everything that is not paged - a table's
     * columns, a schema snapshot - answers through {@link #of}.
     */
    public record Rows<T>(List<T> rows, Boolean truncated) {
        public static <T> Rows<T> of(List<T> rows) {
            return new Rows<>(rows, null);
        }
    }

    public record TableRow(String name, String kind, String schema, String remarks) {}

    /**
     * Approximate row counts for one namespace, by set name (ADR-0038).
     *
     * A set the engine keeps no estimate for is absent rather than zero: a
     * client shows no number instead of a wrong one.
     */
    public record Counts(Map<String, Long> counts) {}

    public record ColumnRow(
            String name,
            String type,
            boolean nullable,
            @JsonName("is_pk") boolean isPk,
            @JsonName("default_expr") String defaultExpr,
            String remarks,
            @JsonName("auto_increment") Boolean autoIncrement,
            Boolean generated,
            int position) {}

    /** A sampled MongoDB field: collections have no columns to ask for. */
    public record MongoField(String name, String type, boolean nullable, @JsonName("is_pk") boolean isPk, int count) {}

    /** One table of a schema snapshot: name, kind and every column at once. */
    public record TableWithColumns(String name, String kind, String remarks, List<ColumnRow> columns) {}

    public record IndexInfo(
            String name, boolean unique, List<String> columns, List<String> order, String kind, String filter) {}

    public record KeyInfo(
            String name,
            String schema,
            String table,
            List<String> columns,
            @JsonName("ref_columns") List<String> refColumns,
            @JsonName("on_delete") String onDelete,
            @JsonName("on_update") String onUpdate) {}

    /** Everything the table view draws. The arrays are always present, never null. */
    public record TableDetails(
            List<ColumnRow> rows,
            @JsonName("primary_key") List<String> primaryKey,
            @JsonName("primary_key_name") String primaryKeyName,
            String remarks,
            List<IndexInfo> indexes,
            @JsonName("foreign_keys") List<KeyInfo> foreignKeys,
            @JsonName("referenced_by") List<KeyInfo> referencedBy) {}

    /** The server's own CREATE TABLE, or null for the engines that have none. */
    public record Ddl(String ddl) {}

    public record IntrospectSummary(
            String path,
            int schemas,
            int tables,
            long columns,
            int details,
            boolean partial,
            boolean parallel,
            long elapsedMs) {}
}
