package neogrip.db;

import java.util.Locale;
import java.util.Set;

/**
 * The second readonly layer: the Lua classifier refuses first, this catches
 * what it missed, and setReadOnly - only a hint in some drivers - is the
 * third. A heuristic on the first keyword is enough for a layer that only ever
 * errs on the side of refusing (ADR-0016).
 */
public final class ReadonlyGuard {
    private final boolean readonly;

    public ReadonlyGuard(boolean readonly) {
        this.readonly = readonly;
    }

    /** Thrown instead of running a write on a readonly connection. */
    public static final class Refused extends RuntimeException {
        private static final long serialVersionUID = 1L;

        Refused(String message) {
            super(message);
        }
    }

    private static final Set<String> WRITE_KEYWORDS = Set.of(
            "insert", "update", "delete", "merge", "replace", "upsert",
            "create", "alter", "drop", "truncate", "grant", "revoke",
            "call", "exec", "execute");

    public void refuseWrites(String sql) {
        if (!readonly) {
            return;
        }
        String text = stripLeadingComments(sql);
        int end = 0;
        while (end < text.length() && Character.isLetter(text.charAt(end))) end++;
        String keyword = text.substring(0, end).toLowerCase(Locale.ROOT);
        if (WRITE_KEYWORDS.contains(keyword)) {
            throw new Refused("the connection is read-only; refusing this " + keyword);
        }
    }

    /** Shared with the transaction interceptor, which reads the same first keyword. */
    static String stripLeadingComments(String sql) {
        String text = sql;
        while (true) {
            text = text.stripLeading();
            if (text.startsWith("--")) {
                int end = text.indexOf('\n');
                if (end < 0) return "";
                text = text.substring(end + 1);
            } else if (text.startsWith("/*")) {
                int end = text.indexOf("*/");
                if (end < 0) return "";
                text = text.substring(end + 2);
            } else {
                return text;
            }
        }
    }
}
