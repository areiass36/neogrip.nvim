package neogrip.app;

import java.io.IOException;
import java.sql.SQLException;
import neogrip.db.Database;
import neogrip.db.types.Types.Ddl;
import neogrip.db.types.Types.IntrospectSummary;
import neogrip.db.types.Types.Named;
import neogrip.db.types.Types.Rows;
import neogrip.db.types.Types.TableRow;
import neogrip.db.types.Types.TableWithColumns;
import neogrip.rpc.RpcMethod;
import neogrip.rpc.RpcNamespace;

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
    Rows<Named> catalogs() throws SQLException {
        return db.catalogs();
    }

    @RpcMethod
    Rows<Named> schemas(String catalog) throws SQLException {
        return db.schemas(catalog);
    }

    @RpcMethod
    Rows<TableRow> tables(String catalog, String schema, String pattern) throws SQLException {
        return db.tables(catalog, schema, pattern);
    }

    @RpcMethod
    Rows<?> columns(String catalog, String schema, String table) throws SQLException {
        return db.columns(catalog, schema, table);
    }

    @RpcMethod
    Rows<TableWithColumns> snapshot(String catalog, String schema) throws SQLException {
        return db.snapshot(catalog, schema);
    }

    @RpcMethod
    Object details(String catalog, String schema, String table) throws SQLException {
        return db.details(catalog, schema, table);
    }

    @RpcMethod
    Object ddl(String catalog, String schema, String table) throws SQLException {
        return db.ddl(catalog, schema, table);
    }

    @RpcMethod
    Ddl nativeDdl(String catalog, String schema, String table) {
        return db.nativeDdl(catalog, schema, table);
    }

    @RpcMethod
    IntrospectSummary introspect(String catalog, String path, int parallelism, long budgetMs, boolean details)
            throws SQLException, IOException {
        return db.introspect(catalog, path, parallelism, budgetMs, details);
    }
}
