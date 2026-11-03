package neogrip.gripd.adapter.jdbc.catalog;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import neogrip.gripd.adapter.jdbc.Drivers;
import neogrip.gripd.contract.Contracts;

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

    /** Documents read from each end of a collection (ADR-0038). */
    static final int WINDOW = 50;

    /**
     * A collection has no columns, so the fields of a sample stand in for
     * them. A field that holds different types in different documents is
     * reported once per type, which is the honest answer and the thing worth
     * knowing before writing a query against it.
     *
     * Both ends are read, fifty documents each (ADR-0038). The first hundred
     * alone biased the answer toward whatever was inserted first, so a field
     * added to the collection last year was invisible while a field dropped
     * last year was still reported. A true random sample is available - the
     * wrapper accepts {@code aggregate([{$sample:{size:n}}])}, which was
     * measured working - and was deliberately not used: a field list that
     * differs between two calls is worse in a tree than one biased toward the
     * two ends, because the user sees nodes appear and vanish without touching
     * anything.
     */
    static Contracts.Rows<Contracts.MongoField> sampleFields(Connection connection, String collection) throws SQLException {
        java.util.LinkedHashMap<String, String> fields = new java.util.LinkedHashMap<>();
        java.util.LinkedHashMap<String, Integer> counts = new java.util.LinkedHashMap<>();

        // The oldest documents, then the newest. A collection smaller than one
        // window is answered twice by the two scripts, so documents are counted
        // by _id and the second pass skips what the first already saw: without
        // that, a two-document collection reported every field as appearing in
        // four documents.
        String head = "db." + collection + ".find({}).limit(" + WINDOW + ")";
        String tail = "db." + collection + ".find({}).sort({_id: -1}).limit(" + WINDOW + ")";
        java.util.Set<Object> seen = new java.util.LinkedHashSet<>();
        for (String script : List.of(head, tail)) {
            readInto(connection, script, fields, counts, seen);
        }
        // How many documents the answer was actually worked out from, which is
        // what makes "in 1 of 100" a ratio a reader can trust.
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
     * One window of documents, folded into the field map.
     *
     * A refusal is swallowed: the tail is an improvement on the head and not a
     * replacement for it, so a wrapper that will not sort still answers with
     * the fields of the documents it would list (ADR-0029).
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
                    // Every Mongo document has an _id; one without is counted
                    // rather than dropped, because a field list is still a
                    // better answer than nothing.
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
            // Said above: one window short is still an answer.
        }
    }

    /**
     * Collection names through the wrapper's own script, because its JDBC
     * getTables is unreliable here: it trips TimSort's contract check, and
     * past that throws NumberFormatException parsing a null. db.getCollectionNames()
     * is the statement the doctor already leans on, and it answers plainly.
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
