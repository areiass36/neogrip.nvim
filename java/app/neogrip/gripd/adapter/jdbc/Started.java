package neogrip.gripd.adapter.jdbc;

/**
 * What an execution says about itself when it begins (ADR-0042).
 *
 * A cursor holds one of these rather than a notifier and its own name: it has
 * no business knowing either, and the caller decides whether anybody is
 * listening by handing over a no-op when nobody is.
 */
@FunctionalInterface
interface Started {
    void now();
}
