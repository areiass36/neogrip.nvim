package neogrip.db.catalog;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import neogrip.db.types.Types;

/**
 * A collection has no columns, so the fields of a sample stand in for them. A
 * field that holds different types in different documents is reported once per
 * type, which is the honest answer and the thing worth knowing before writing
 * a query against it.
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

    /** How many documents to look at when working out a collection's fields. */
    static final int SAMPLE_SIZE = 100;

    /**
     * A collection has no columns, so the fields of a sample stand in for
     * them. A field that holds different types in different documents is
     * reported once per type, which is the honest answer and the thing worth
     * knowing before writing a query against it.
     */
    static Types.Rows<Types.MongoField> sampleFields(Connection connection, String collection) throws SQLException {
        java.util.LinkedHashMap<String, String> fields = new java.util.LinkedHashMap<>();
        java.util.LinkedHashMap<String, Integer> counts = new java.util.LinkedHashMap<>();

        String script = "db." + collection + ".find({})";
        try (java.sql.Statement statement = connection.createStatement()) {
            try {
                statement.setMaxRows(SAMPLE_SIZE);
            } catch (SQLException ignored) {
                // The driver caps it itself, or not at all.
            }
            try (ResultSet rows = statement.executeQuery(script)) {
                while (rows.next()) {
                    Object value = rows.getObject(1);
                    if (!(value instanceof java.util.Map<?, ?> document)) {
                        continue;
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
        }

        List<Types.MongoField> list = new ArrayList<>(fields.size());
        for (java.util.Map.Entry<String, String> field : fields.entrySet()) {
            String name = field.getKey().substring(0, field.getKey().indexOf('\u0000'));
            list.add(new Types.MongoField(
                    name,
                    field.getValue(),
                    true,
                    name.equals("_id"),
                    counts.getOrDefault(field.getKey(), 0)));
        }
        return new Types.Rows<>(list);
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
