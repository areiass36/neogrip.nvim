package neogrip.gripd.adapter.rpc;

/**
 * The contract's version, mirroring doc/protocol.md and the Lua side's
 * rpc/protocol.lua. Bumped only by an ADR; a mismatch is refused at the
 * handshake rather than discovered later by a field nobody recognises.
 */
public final class Protocol {
    private Protocol() {}

    public static final int VERSION = 2;
}
