package neogrip.db.types;

import java.util.List;
import java.util.Map;
import neogrip.rpc.Json;

/**
 * The domain records the wire already implies, one file because they are
 * fifteen lines of shape and no behavior. Adding a future method means
 * declaring its record here and returning it from a handler; JsonCodec
 * serializes components in declaration order, leaves null ones out (that is
 * how the wire's optional fields behave), and honours @Json for the names
 * that are not Java spellings.
 */
public final class Types {
    private Types() {}

    /** One result column; table/schema only when the driver will say (nulls omitted). */
    public record Column(String name, String type, String table, String schema) {}

    public record QueryPage(List<Column> columns, List<List<Object>> rows, boolean hasMore, long elapsedMs) {}

    public record UpdateResult(int updateCount, long elapsedMs) {}

    /** The answer to an intercepted BEGIN/COMMIT/ROLLBACK: is one open now? */
    public record TxState(boolean transaction) {}

    public record ExportResult(long rows, String path, long elapsedMs) {}

    public record ConnectResult(String product, String driver, Map<String, Object> capabilities) {}

    /** A bare name, as the catalogs and schemas listings answer. */
    public record Named(String name) {}

    /** The {"rows":[...]} shape every catalog listing answers with. */
    public record Rows<T>(List<T> rows) {}

    public record TableRow(String name, String kind, String schema, String remarks) {}

    public record ColumnRow(
            String name,
            String type,
            boolean nullable,
            @Json("is_pk") boolean isPk,
            @Json("default_expr") String defaultExpr,
            String remarks,
            @Json("auto_increment") Boolean autoIncrement,
            Boolean generated,
            int position) {}

    /** A sampled MongoDB field: collections have no columns to ask for. */
    public record MongoField(String name, String type, boolean nullable, @Json("is_pk") boolean isPk, int count) {}

    /** One table of a schema snapshot: name, kind and every column at once. */
    public record TableWithColumns(String name, String kind, String remarks, List<ColumnRow> columns) {}

    public record IndexInfo(
            String name, boolean unique, List<String> columns, List<String> order, String kind, String filter) {}

    public record KeyInfo(
            String name,
            String schema,
            String table,
            List<String> columns,
            @Json("ref_columns") List<String> refColumns,
            @Json("on_delete") String onDelete,
            @Json("on_update") String onUpdate) {}

    /** Everything the table view draws. The arrays are always present, never null. */
    public record TableDetails(
            List<ColumnRow> rows,
            @Json("primary_key") List<String> primaryKey,
            @Json("primary_key_name") String primaryKeyName,
            String remarks,
            List<IndexInfo> indexes,
            @Json("foreign_keys") List<KeyInfo> foreignKeys,
            @Json("referenced_by") List<KeyInfo> referencedBy) {}

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
