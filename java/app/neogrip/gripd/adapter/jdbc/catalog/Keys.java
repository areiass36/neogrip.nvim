package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.DatabaseMetaData;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import neogrip.gripd.contract.Contracts;

/**
 * Primary keys, indexes and foreign keys, in the order the server declares
 * them - KEY_SEQ and ORDINAL_POSITION, not row order, decide a composite key.
 */
public final class Keys {
    private Keys() {}

    /**
     * One column of a key: the row order is the driver's business, and
     * KEY_SEQ is the only thing that says which column comes first.
     */
    record KeyColumn(int position, String name) {}

    /** One column of an index, which ORDINAL_POSITION orders the same way. */
    record IndexColumn(int position, String name, String direction) {}

    /** Both ends of one column of a foreign key, which has to stay a pair. */
    record KeyPair(int position, String here, String there) {}

    /**
     * The names of a key's columns in the order the key declares; the sort is
     * stable, so a driver reporting no sequence numbers keeps its row order.
     */
    static Set<String> inOrder(List<KeyColumn> columns) {
        columns.sort(Comparator.comparingInt(KeyColumn::position));
        Set<String> names = new LinkedHashSet<>();
        for (KeyColumn column : columns) {
            names.add(column.name());
        }
        return names;
    }

    /**
     * A table's primary key: its columns in order, and the constraint name -
     * dropping or recreating the constraint needs the name the server knows it by.
     */
    static final class PrimaryKey {
        static final PrimaryKey NONE = new PrimaryKey(Set.of(), null);

        final Set<String> columns;
        /** PK_NAME, or null on an engine that does not name its constraints. */
        final String name;

        PrimaryKey(Set<String> columns, String name) {
            this.columns = columns;
            this.name = name;
        }

        boolean isEmpty() {
            return columns.isEmpty();
        }
    }

    static PrimaryKey primaryKeyOf(DatabaseMetaData meta, String catalog, String schema, String table) {
        List<KeyColumn> columns = new ArrayList<>();
        String name = null;
        try (ResultSet keys = meta.getPrimaryKeys(Metadata.orNull(catalog), Metadata.orNull(schema), table)) {
            while (keys.next()) {
                columns.add(new KeyColumn(Metadata.optionalInt(keys, "KEY_SEQ", 0), keys.getString("COLUMN_NAME")));
                if (name == null) {
                    name = Metadata.orNull(Metadata.optionalString(keys, "PK_NAME"));
                }
            }
        } catch (SQLException ignored) {
            // Not every driver reports keys; the column list is still useful.
        }
        return new PrimaryKey(inOrder(columns), name);
    }

    /** A schema small enough that asking table by table for its keys is cheap. */
    static final int KEY_FALLBACK_TABLES = 50;

    /**
     * Every primary key in the schema at once, by passing a null table name -
     * more than getPrimaryKeys promises, so null means the driver refused,
     * while an empty map is an answer and must not trigger the per-table
     * sweep; see doc/internals.md#schema-and-tree.
     */
    static java.util.Map<String, PrimaryKey> schemaPrimaryKeys(
            DatabaseMetaData meta, String catalog, String schema) {
        java.util.Map<String, List<KeyColumn>> columns = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> names = new java.util.LinkedHashMap<>();
        try (ResultSet rows = meta.getPrimaryKeys(Metadata.orNull(catalog), Metadata.orNull(schema), null)) {
            while (rows.next()) {
                String table = rows.getString("TABLE_NAME");
                columns.computeIfAbsent(table, key -> new ArrayList<>())
                        .add(new KeyColumn(Metadata.optionalInt(rows, "KEY_SEQ", 0), rows.getString("COLUMN_NAME")));
                String name = Metadata.orNull(Metadata.optionalString(rows, "PK_NAME"));
                if (name != null) {
                    names.putIfAbsent(table, name);
                }
            }
        } catch (SQLException refused) {
            return null;
        }
        // Sorted only after the whole schema has arrived: two tables' key rows can be interleaved.
        java.util.Map<String, PrimaryKey> keys = new java.util.LinkedHashMap<>();
        for (java.util.Map.Entry<String, List<KeyColumn>> table : columns.entrySet()) {
            keys.put(table.getKey(), new PrimaryKey(inOrder(table.getValue()), names.get(table.getKey())));
        }
        return keys;
    }

    static List<Contracts.IndexInfo> indexInfos(
            DatabaseMetaData meta, String catalog, String schema, String table) {
        java.util.LinkedHashMap<String, List<IndexColumn>> indexes = new java.util.LinkedHashMap<>();
        java.util.Map<String, Boolean> unique = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> kinds = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> filters = new java.util.LinkedHashMap<>();
        // approximate=true: listing index names is not worth a statistics refresh.
        try (ResultSet rows = meta.getIndexInfo(Metadata.orNull(catalog), Metadata.orNull(schema), table, false, true)) {
            while (rows.next()) {
                int type = Metadata.optionalInt(rows, "TYPE", DatabaseMetaData.tableIndexOther);
                // A tableIndexStatistic row is the table's cardinality, not an index, and is
                // dropped on type: a driver that fills in its name would have the editor
                // render a statistic as something to create.
                if (type == DatabaseMetaData.tableIndexStatistic) {
                    continue;
                }
                String name = rows.getString("INDEX_NAME");
                String column = rows.getString("COLUMN_NAME");
                if (name == null || column == null) {
                    continue;
                }
                indexes.computeIfAbsent(name, key -> new ArrayList<>())
                        .add(new IndexColumn(
                                Metadata.optionalInt(rows, "ORDINAL_POSITION", 0),
                                column,
                                direction(Metadata.optionalString(rows, "ASC_OR_DESC"))));
                unique.putIfAbsent(name, !rows.getBoolean("NON_UNIQUE"));
                kinds.putIfAbsent(name, indexKind(type));
                String filter = Metadata.orNull(Metadata.optionalString(rows, "FILTER_CONDITION"));
                if (filter != null) {
                    // A partial index is a different index from the one its columns describe.
                    filters.putIfAbsent(name, filter);
                }
            }
        } catch (SQLException ignored) {
            // Query engines have no indexes to report; see doc/internals.md#schema-and-tree.
        }
        List<Contracts.IndexInfo> list = new ArrayList<>(indexes.size());
        for (java.util.Map.Entry<String, List<IndexColumn>> index : indexes.entrySet()) {
            List<IndexColumn> columns = index.getValue();
            columns.sort(Comparator.comparingInt(IndexColumn::position));
            List<String> names = new ArrayList<>(columns.size());
            // A parallel array a reader can ignore beats a shape change to the columns.
            List<String> order = new ArrayList<>(columns.size());
            for (IndexColumn column : columns) {
                names.add(String.valueOf(column.name()));
                order.add(column.direction());
            }
            list.add(new Contracts.IndexInfo(
                    index.getKey(),
                    unique.getOrDefault(index.getKey(), false),
                    names,
                    order,
                    kinds.getOrDefault(index.getKey(), "other"),
                    filters.get(index.getKey())));
        }
        return list;
    }

    /**
     * "unknown" rather than defaulting to ascending: a driver that leaves
     * ASC_OR_DESC null has not said the index is ascending.
     */
    static String direction(String ascOrDesc) {
        if ("A".equals(ascOrDesc)) {
            return "asc";
        }
        if ("D".equals(ascOrDesc)) {
            return "desc";
        }
        return "unknown";
    }

    /** The index's structure, which decides what a renderer calls it. */
    static String indexKind(int type) {
        return switch (type) {
            case DatabaseMetaData.tableIndexClustered -> "clustered";
            case DatabaseMetaData.tableIndexHashed -> "hashed";
            default -> "other";
        };
    }

    /**
     * Foreign keys in either direction. Which side of the metadata row is this
     * table swaps with the direction: imported keys have it as the FK side,
     * exported keys as the PK side.
     */
    static List<Contracts.KeyInfo> keyInfos(
            DatabaseMetaData meta, String catalog, String schema, String table, boolean imported) {
        // Both ends of a column stay one pair: built as two lists they were ordered separately,
        // and a two-column key could point its second column at the first of the key it references.
        java.util.LinkedHashMap<String, List<KeyPair>> pairs = new java.util.LinkedHashMap<>();
        java.util.LinkedHashMap<String, String[]> target = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> onDelete = new java.util.LinkedHashMap<>();
        java.util.Map<String, String> onUpdate = new java.util.LinkedHashMap<>();

        try (ResultSet rows = imported
                ? meta.getImportedKeys(Metadata.orNull(catalog), Metadata.orNull(schema), table)
                : meta.getExportedKeys(Metadata.orNull(catalog), Metadata.orNull(schema), table)) {
            while (rows.next()) {
                String name = String.valueOf(rows.getString("FK_NAME"));
                pairs.computeIfAbsent(name, key -> new ArrayList<>())
                        .add(new KeyPair(
                                Metadata.optionalInt(rows, "KEY_SEQ", 0),
                                rows.getString(imported ? "FKCOLUMN_NAME" : "PKCOLUMN_NAME"),
                                rows.getString(imported ? "PKCOLUMN_NAME" : "FKCOLUMN_NAME")));
                target.putIfAbsent(name, new String[] {
                    rows.getString(imported ? "PKTABLE_SCHEM" : "FKTABLE_SCHEM"),
                    rows.getString(imported ? "PKTABLE_NAME" : "FKTABLE_NAME")
                });
                String deleteRule = rule(rows, "DELETE_RULE");
                if (deleteRule != null) {
                    onDelete.putIfAbsent(name, deleteRule);
                }
                String updateRule = rule(rows, "UPDATE_RULE");
                if (updateRule != null) {
                    onUpdate.putIfAbsent(name, updateRule);
                }
            }
        } catch (SQLException ignored) {
            // No referential metadata on this engine.
        }

        List<Contracts.KeyInfo> list = new ArrayList<>(pairs.size());
        for (java.util.Map.Entry<String, List<KeyPair>> key : pairs.entrySet()) {
            List<KeyPair> columns = key.getValue();
            columns.sort(Comparator.comparingInt(KeyPair::position));
            String[] other = target.getOrDefault(key.getKey(), new String[] {null, null});
            List<String> here = new ArrayList<>(columns.size());
            List<String> there = new ArrayList<>(columns.size());
            for (KeyPair pair : columns) {
                here.add(String.valueOf(pair.here()));
                there.add(String.valueOf(pair.there()));
            }
            list.add(new Contracts.KeyInfo(
                    key.getKey(),
                    other[0],
                    String.valueOf(other[1]),
                    here,
                    there,
                    onDelete.get(key.getKey()),
                    onUpdate.get(key.getKey())));
        }
        return list;
    }

    /**
     * A referential action under its standard name; RESTRICT and NO ACTION
     * stay apart even though JDBC documents them as aliases, because the
     * servers that accept both do not treat them as the same thing.
     *
     * @return null where the driver would not say, since a rendered ON DELETE
     *         that guessed reads as deliberate.
     */
    static String rule(ResultSet rows, String column) {
        int value;
        try {
            value = rows.getInt(column);
            if (rows.wasNull()) {
                return null;
            }
        } catch (SQLException missing) {
            return null;
        }
        return switch (value) {
            case DatabaseMetaData.importedKeyCascade -> "cascade";
            case DatabaseMetaData.importedKeyRestrict -> "restrict";
            case DatabaseMetaData.importedKeySetNull -> "set null";
            case DatabaseMetaData.importedKeySetDefault -> "set default";
            case DatabaseMetaData.importedKeyNoAction -> "no action";
            default -> null;
        };
    }
}
