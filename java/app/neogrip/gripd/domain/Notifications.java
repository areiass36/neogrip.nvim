package neogrip.gripd.domain;

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

    /**
     * A named result's statement has begun executing (ADR-0042). Said again on
     * every window refill, because a refill is another execution of the same
     * statement and is the slowest thing a reader waits on.
     *
     * Named here as what happened rather than as a phase of a generic
     * progress event, so that the vocabulary of the frame stays at the edge.
     */
    void executing(String hash);
}
