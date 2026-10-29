package neogrip.db;

import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Types;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * MongoDB through JDBC answers with one column holding a document, not with
 * columns. The grid wants columns, so the document's top-level fields are
 * spread out, in order of first appearance, and anything nested is summarised
 * rather than flattened further - a document is not a row and pretending
 * otherwise invents structure that is not there.
 */
public final class Documents {
    private final int column;

    private Documents(int column) {
        this.column = column;
    }

    /** @return null when this is an ordinary tabular result */
    public static Documents detect(ResultSetMetaData meta, int columnCount) throws SQLException {
        if (columnCount != 1) {
            return null;
        }
        int type = meta.getColumnType(1);
        String typeName = String.valueOf(meta.getColumnTypeName(1)).toLowerCase();
        if (type == Types.JAVA_OBJECT || type == Types.STRUCT || type == Types.OTHER
                || typeName.contains("map") || typeName.contains("document") || typeName.contains("object")) {
            return new Documents(1);
        }
        return null;
    }

    public List<Object> row(ResultSet rows, List<String> names, List<String> types) throws SQLException {
        Object value = rows.getObject(column);
        List<Object> row = new ArrayList<>(names.size());
        for (int i = 0; i < names.size(); i++) {
            row.add(null);
        }

        if (!(value instanceof Map<?, ?> document)) {
            if (names.isEmpty()) {
                names.add("value");
                types.add("value");
                row.add(null);
            }
            row.set(0, value == null ? null : String.valueOf(value));
            return row;
        }

        for (Map.Entry<?, ?> entry : document.entrySet()) {
            String name = String.valueOf(entry.getKey());
            int index = names.indexOf(name);
            if (index < 0) {
                names.add(name);
                types.add(typeOf(entry.getValue()));
                row.add(null);
                index = names.size() - 1;
            }
            row.set(index, scalar(entry.getValue()));
        }
        return row;
    }

    /** Rows read before a field was seen are shorter than the final width. */
    public void pad(List<List<Object>> rows, int width) {
        for (List<Object> row : rows) {
            while (row.size() < width) {
                row.add(null);
            }
        }
    }

    private static String typeOf(Object value) {
        if (value == null) return "null";
        if (value instanceof Map) return "object";
        if (value instanceof List) return "array";
        if (value instanceof java.util.Date) return "date";
        if (value instanceof Boolean) return "bool";
        if (value instanceof Number) return value.getClass().getSimpleName().toLowerCase();
        return value.getClass().getSimpleName().toLowerCase();
    }

    private static Object scalar(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Map<?, ?> nested) {
            return nested.isEmpty() ? "{}" : "{…}";
        }
        if (value instanceof List<?> list) {
            return "[" + list.size() + "]";
        }
        if (value instanceof java.util.Date date) {
            return date.toInstant().toString();
        }
        if (value instanceof Boolean || value instanceof Integer || value instanceof Long) {
            return value;
        }
        if (value instanceof Double || value instanceof Float) {
            return ((Number) value).doubleValue();
        }
        if (value instanceof java.math.BigDecimal decimal) {
            return decimal.toPlainString();
        }
        if (value instanceof byte[] bytes) {
            return java.util.HexFormat.of().formatHex(bytes);
        }
        return String.valueOf(value);
    }
}
