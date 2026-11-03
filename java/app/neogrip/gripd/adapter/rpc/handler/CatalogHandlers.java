package neogrip.gripd.adapter.rpc.handler;

import neogrip.gripd.adapter.jdbc.Database;
import neogrip.gripd.contract.Contracts.Counts;
import neogrip.gripd.contract.Contracts.Ddl;
import neogrip.gripd.contract.Contracts.IntrospectSummary;
import neogrip.gripd.contract.Contracts.Named;
import neogrip.gripd.contract.Contracts.Rows;
import neogrip.gripd.contract.Contracts.TableRow;
import neogrip.gripd.contract.Contracts.TableWithColumns;
import neogrip.jsonrpc.RpcMethod;
import neogrip.jsonrpc.RpcNamespace;

/**
 * The catalog, through DatabaseMetaData. The introspect sweep runs one at a
 * time and outside the session lock, on sibling connections of its own: a
 * sweep of a warehouse takes minutes, and either it waits behind a query or
 * the next query waits behind it.
 */
@RpcNamespace("catalog")
public final class CatalogHandlers {
    private final Database db;

    public CatalogHandlers(Database db) {
        this.db = db;
    }

    @RpcMethod
    Rows<Named> catalogs(String after, int limit) {
        return db.catalogs(after, limit);
    }

    @RpcMethod
    Rows<Named> schemas(String catalog, String after, int limit) {
        return db.schemas(catalog, after, limit);
    }

    @RpcMethod
    Rows<TableRow> tables(String catalog, String schema, String pattern, String after, int limit) {
        return db.tables(catalog, schema, pattern, after, limit);
    }

    /**
     * Approximate row counts for a whole namespace in one statement, for the
     * engines that keep an estimate; an empty answer everywhere else.
     */
    @RpcMethod
    Counts counts(String catalog, String schema) {
        return db.counts(catalog, schema);
    }

    @RpcMethod
    Rows<?> columns(String catalog, String schema, String table) {
        return db.columns(catalog, schema, table);
    }

    @RpcMethod
    Rows<TableWithColumns> snapshot(String catalog, String schema) {
        return db.snapshot(catalog, schema);
    }

    @RpcMethod
    Object details(String catalog, String schema, String table) {
        return db.details(catalog, schema, table);
    }

    @RpcMethod
    Object ddl(String catalog, String schema, String table) {
        return db.ddl(catalog, schema, table);
    }

    @RpcMethod
    Ddl nativeDdl(String catalog, String schema, String table) {
        return db.nativeDdl(catalog, schema, table);
    }

    @RpcMethod
    IntrospectSummary introspect(String catalog, String path, int parallelism, long budgetMs, boolean details) {
        return db.introspect(catalog, path, parallelism, budgetMs, details);
    }
}
