package neogrip.db;

/**
 * Reading the shape of a statement without parsing it.
 *
 * Two different rules need the same first step - the readonly check and the
 * transaction interception both look at the first keyword - and a statement
 * that opens with a comment would hide that keyword from both of them.
 */
public final class SqlText {
    private SqlText() {}

    /** The statement with any leading line or block comments taken off. */
    public static String withoutLeadingComments(String sql) {
        String text = sql;
        while (true) {
            text = text.stripLeading();
            if (text.startsWith("--")) {
                int end = text.indexOf('\n');
                if (end < 0) {
                    return "";
                }
                text = text.substring(end + 1);
            } else if (text.startsWith("/*")) {
                int end = text.indexOf("*/");
                if (end < 0) {
                    return "";
                }
                text = text.substring(end + 2);
            } else {
                return text;
            }
        }
    }
}
