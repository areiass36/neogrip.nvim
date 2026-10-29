package neogrip;

import java.math.BigDecimal;
import java.sql.Array;
import java.sql.Blob;
import java.sql.Clob;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Types;
import java.time.temporal.Temporal;
import java.util.HexFormat;

/**
 * Turning a JDBC value into something the editor can show without lying about
 * it.
 *
 * The rules come from what actually goes wrong:
 *
 *   NULL        must stay distinct from the empty string, so it is JSON null
 *               and nothing else is.
 *   DECIMAL     keeps every digit, as text: a double would round 8.90 and
 *               money is exactly where that matters.
 *   BIGINT      above 2^53 also goes out as text, because the decoder on the
 *               other side is Lua, whose numbers are doubles.
 *   binary      becomes hex. The bytes are not text and pretending otherwise
 *               is how a bytea column turns into replacement characters.
 *   dates       ISO 8601, from the driver's own object rather than its
 *               toString, which is locale-dependent.
 */
public final class Values {
    private Values() {}

    /** Maximum bytes of a binary column rendered as hex before it is cut. */
    private static final int MAX_BINARY_BYTES = 4096;

    /** Above this, an integer no longer survives a double. */
    private static final long SAFE_INTEGER = 1L << 53;

    public static Object read(ResultSet rows, ResultSetMetaData meta, int column) throws SQLException {
        int type = meta.getColumnType(column);

        // getObject first, then wasNull: for a primitive getter the value would
        // already have been coerced to 0 or false.
        Object value = rows.getObject(column);
        if (rows.wasNull() || value == null) {
            return null;
        }

        return switch (type) {
            case Types.NUMERIC, Types.DECIMAL -> value instanceof BigDecimal decimal
                    ? decimal.toPlainString()
                    : String.valueOf(value);
            case Types.BIGINT -> {
                long number = ((Number) value).longValue();
                yield Math.abs(number) >= SAFE_INTEGER ? String.valueOf(number) : number;
            }
            case Types.BIT, Types.BOOLEAN -> value instanceof Boolean flag ? flag : rows.getBoolean(column);
            case Types.TINYINT, Types.SMALLINT, Types.INTEGER -> ((Number) value).longValue();
            case Types.REAL, Types.FLOAT, Types.DOUBLE -> ((Number) value).doubleValue();
            case Types.BINARY, Types.VARBINARY, Types.LONGVARBINARY, Types.BLOB -> hex(value);
            case Types.ARRAY -> value instanceof Array array ? String.valueOf(array.toString()) : String.valueOf(value);
            case Types.CLOB, Types.NCLOB -> clob(value);
            default -> text(value);
        };
    }

    private static Object hex(Object value) throws SQLException {
        byte[] bytes;
        if (value instanceof byte[] raw) {
            bytes = raw;
        } else if (value instanceof Blob blob) {
            long length = Math.min(blob.length(), MAX_BINARY_BYTES);
            bytes = blob.getBytes(1, (int) length);
        } else {
            return String.valueOf(value);
        }
        if (bytes.length > MAX_BINARY_BYTES) {
            byte[] head = new byte[MAX_BINARY_BYTES];
            System.arraycopy(bytes, 0, head, 0, MAX_BINARY_BYTES);
            return HexFormat.of().formatHex(head) + "… (" + bytes.length + " bytes)";
        }
        return HexFormat.of().formatHex(bytes);
    }

    private static Object clob(Object value) throws SQLException {
        if (value instanceof Clob clob) {
            long length = Math.min(clob.length(), 1 << 20);
            return clob.getSubString(1, (int) length);
        }
        return String.valueOf(value);
    }

    private static Object text(Object value) {
        if (value instanceof Temporal || value instanceof java.util.Date) {
            return isoDate(value);
        }
        if (value instanceof byte[] bytes) {
            return HexFormat.of().formatHex(bytes);
        }
        return String.valueOf(value);
    }

    private static String isoDate(Object value) {
        if (value instanceof java.sql.Timestamp timestamp) {
            return timestamp.toInstant().toString();
        }
        if (value instanceof java.sql.Date date) {
            return date.toLocalDate().toString();
        }
        if (value instanceof java.sql.Time time) {
            return time.toLocalTime().toString();
        }
        if (value instanceof java.util.Date date) {
            return date.toInstant().toString();
        }
        return String.valueOf(value);
    }

    /** The type name shown in the grid header and used to pick a highlight. */
    public static String typeName(ResultSetMetaData meta, int column) throws SQLException {
        String name = meta.getColumnTypeName(column);
        return name == null ? "?" : name.toLowerCase();
    }
}
