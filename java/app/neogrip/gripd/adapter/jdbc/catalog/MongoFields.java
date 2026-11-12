package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import neogrip.gripd.adapter.jdbc.Drivers;
import neogrip.gripd.contract.Contracts;

/**
 * A collection has no columns, so the fields of a sample stand in for them; a
 * field that holds different types in different documents is reported once per type.
 */
public final class MongoFields {
    private MongoFields() {}

    static boolean isMongo(Connection connection) {
        try {
            return String.valueOf(connection.getMetaData().getDatabaseProductName()).toLowerCase().contains("mongo");
        } catch (SQLException e) {
            return false;
        }
    }

    /** Documents read from each end of a collection (ADR-0038). */
    static final int WINDOW = 50;

    /**
     * Both ends are read (ADR-0038) and the sampling is deterministic; see
     * doc/internals.md#schema-and-tree.
     */
    static Contracts.Rows<Contracts.MongoField> sampleFields(Connection connection, String collection) throws SQLException {
        java.util.LinkedHashMap<String, String> fields = new java.util.LinkedHashMap<>();
        java.util.LinkedHashMap<String, Integer> counts = new java.util.LinkedHashMap<>();

        // The second pass skips _ids the first saw; see doc/internals.md#schema-and-tree.
        String head = "db." + collection + ".find({}).limit(" + WINDOW + ")";
        String tail = "db." + collection + ".find({}).sort({_id: -1}).limit(" + WINDOW + ")";
        java.util.Set<Object> seen = new java.util.LinkedHashSet<>();
        for (String script : List.of(head, tail)) {
            readInto(connection, script, fields, counts, seen);
        }
        // The documents actually sampled, which makes "in 1 of 100" a ratio a reader can trust.
        int sampleSize = seen.size();

        List<Contracts.MongoField> list = new ArrayList<>(fields.size());
        for (java.util.Map.Entry<String, String> field : fields.entrySet()) {
            String name = field.getKey().substring(0, field.getKey().indexOf('\u0000'));
            list.add(new Contracts.MongoField(
                    name,
                    field.getValue(),
                    true,
                    name.equals("_id"),
                    counts.getOrDefault(field.getKey(), 0),
                    sampleSize));
        }
        return Contracts.Rows.of(list);
    }

    /**
     * One window of documents folded into the field map; a refusal is
     * swallowed because the tail is an improvement on the head, not a
     * replacement for it (ADR-0029).
     */
    private static void readInto(
            Connection connection,
            String script,
            java.util.Map<String, String> fields,
            java.util.Map<String, Integer> counts,
            java.util.Set<Object> seen) {
        try (java.sql.Statement statement = connection.createStatement()) {
            Drivers.tolerate(() -> statement.setMaxRows(WINDOW));
            try (ResultSet rows = statement.executeQuery(script)) {
                while (rows.next()) {
                    Object value = rows.getObject(1);
                    if (!(value instanceof java.util.Map<?, ?> document)) {
                        continue;
                    }
                    // A document without an _id is counted rather than dropped.
                    Object id = document.get("_id");
                    if (id != null && !seen.add(id)) {
                        continue;
                    }
                    if (id == null) {
                        seen.add(new Object());
                    }
                    for (java.util.Map.Entry<?, ?> entry : document.entrySet()) {
                        String name = String.valueOf(entry.getKey());
                        String type = bsonType(entry.getValue());
                        String key = name + "\u0000" + type;
                        fields.putIfAbsent(key, type);
                        counts.merge(key, 1, Integer::sum);
                    }
                }
            }
        } catch (SQLException | RuntimeException refused) {
            // One window short is still an answer.
        }
    }

    /**
     * Collection names through the wrapper's own script, because its JDBC
     * getTables fails; see doc/internals.md#gripd-process.
     */
    static List<String> collectionNames(Connection connection) throws SQLException {
        List<String> names = new ArrayList<>();
        try (java.sql.Statement statement = connection.createStatement();
                ResultSet rows = statement.executeQuery("db.getCollectionNames()")) {
            while (rows.next()) {
                Object value = rows.getObject(1);
                if (value instanceof List<?> list) {
                    for (Object element : list) {
                        names.add(String.valueOf(element));
                    }
                } else if (value != null) {
                    names.add(String.valueOf(value));
                }
            }
        }
        return names;
    }

    static String bsonType(Object value) {
        if (value == null) return "null";
        if (value instanceof java.util.Map) return "object";
        if (value instanceof java.util.List) return "array";
        if (value instanceof java.util.Date) return "date";
        if (value instanceof Boolean) return "bool";
        if (value instanceof byte[]) return "binary";
        return value.getClass().getSimpleName().toLowerCase();
    }
}
