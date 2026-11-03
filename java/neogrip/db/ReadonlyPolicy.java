package neogrip.db;

import java.util.Locale;
import java.util.Set;
import neogrip.db.errors.WriteRefused;

/**
 * The second readonly layer: the Lua classifier refuses first, this catches
 * what it missed, and setReadOnly - only a hint in some drivers - is the
 * third. A heuristic on the first keyword is enough for a layer that only ever
 * errs on the side of refusing (ADR-0016).
 */
public final class ReadonlyPolicy {
    private static final Set<String> WRITE_KEYWORDS = Set.of(
            "insert", "update", "delete", "merge", "replace", "upsert",
            "create", "alter", "drop", "truncate", "grant", "revoke",
            "call", "exec", "execute");

    private final boolean readonly;

    public ReadonlyPolicy(boolean readonly) {
        this.readonly = readonly;
    }

    public void refuseWrites(String sql) {
        if (!readonly) {
            return;
        }
        String text = SqlText.withoutLeadingComments(sql);
        int end = 0;
        while (end < text.length() && Character.isLetter(text.charAt(end))) {
            end++;
        }
        String keyword = text.substring(0, end).toLowerCase(Locale.ROOT);
        if (WRITE_KEYWORDS.contains(keyword)) {
            throw new WriteRefused("the connection is read-only; refusing this " + keyword);
        }
    }
}
