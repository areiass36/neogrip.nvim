package neogrip.db;

/**
 * How this side tells the client that something happened on its own - a
 * rollback nobody asked for - without knowing that a wire exists.
 *
 * The database layer used to build the notification's parameter map itself,
 * which meant the code that rolls back a transaction knew the spelling of a
 * protocol frame. It says what happened; the edge decides how that travels.
 */
public interface Notifications {
    /** Worth a line in the editor's status, and not an answer to any request. */
    void status(String phase, String message);
}
