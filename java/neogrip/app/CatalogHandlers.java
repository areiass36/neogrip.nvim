package neogrip.app;

import neogrip.db.Database;
import neogrip.db.types.Types.Ddl;
import neogrip.db.types.Types.IntrospectSummary;
import neogrip.db.types.Types.Named;
import neogrip.db.types.Types.Rows;
import neogrip.db.types.Types.TableRow;
import neogrip.db.types.Types.TableWithColumns;
import neogrip.jsonrpc.RpcMethod;
import neogrip.jsonrpc.RpcNamespace;

/**
 * The catalog, through DatabaseMetaData. The introspect sweep runs one at a
 * time and outside the session lock, on sibling connections of its own: a
 * sweep of a warehouse takes minutes, and either it waits behind a query or
 * the next query waits behind it.
 */
@RpcNamespace("catalog")
final class CatalogHandlers {
    private final Database db;

    CatalogHandlers(Database db) {
        this.db = db;
    }

    @RpcMethod
    Rows<Named> catalogs() {
        return db.catalogs();
    }

    @RpcMethod
    Rows<Named> schemas(String catalog) {
        return db.schemas(catalog);
    }

    @RpcMethod
    Rows<TableRow> tables(String catalog, String schema, String pattern) {
        return db.tables(catalog, schema, pattern);
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
