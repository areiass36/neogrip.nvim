package neogrip.jsonrpc.transport;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;

/**
 * One JSON object per line over a pair of streams, UTF-8 both ways (ADR-0002).
 *
 * This sink carries protocol frames and nothing else; anything a program wants
 * to say to a human goes to stderr, which this class deliberately has no
 * access to.
 */
public final class StdioTransport implements Transport {
    private final BufferedReader in;
    private final PrintWriter out;

    public StdioTransport(InputStream stdin, OutputStream stdout) {
        this.in = new BufferedReader(new InputStreamReader(stdin, StandardCharsets.UTF_8));
        this.out = new PrintWriter(new BufferedWriter(new OutputStreamWriter(stdout, StandardCharsets.UTF_8)));
    }

    @Override
    public String read() throws IOException {
        return in.readLine();
    }

    /**
     * Synchronized because notifications are sent from whatever thread holds
     * the notifier: two frames interleaved half a line each would not be a
     * protocol any more.
     */
    @Override
    public synchronized void write(String frame) {
        out.println(frame);
        out.flush();
    }
}
