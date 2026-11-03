package neogrip.jsonrpc.transport;

import java.io.IOException;

/**
 * Where frames come from and where they go.
 *
 * The server reads and writes whole frames and knows nothing about charsets,
 * buffering or when to flush - which is what lets the same server speak over a
 * pipe, a socket or a pair of in-memory queues.
 */
public interface Transport {
    /** The next frame, or null when the input has ended. */
    String read() throws IOException;

    /**
     * One frame, on its way out before this returns, because a client is
     * blocked waiting for it.
     *
     * Does not throw: a sink that cannot be written to is a client that has
     * gone away, and the read that follows reports that by ending. Callers
     * include notification senders on arbitrary threads, and a checked
     * exception there would travel all the way into code that has no idea a
     * wire exists.
     */
    void write(String frame);
}
