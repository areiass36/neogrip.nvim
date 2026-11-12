package neogrip.gripd.domain;

/**
 * How this side tells the client something happened on its own without knowing
 * that a wire exists: it says what happened, the edge decides how that travels.
 */
public interface Notifications {
    /** Worth a line in the editor's status, and not an answer to any request. */
    void status(String phase, String message);

    /**
     * A named result's statement has begun executing (ADR-0042); said again on
     * every window refill, because a refill is another execution of the same statement.
     */
    void executing(String hash);
}
