# 0033. JSON and CSV are a record-writer library, not part of the protocol

- Date: 2026-11-03T15:13:20Z
- Status: Accepted

## Context

The JSON writer, the JSON parser, the reflective record serializer and the `@Json` annotation were born
inside `neogrip.rpc` because the protocol was the first thing that needed them (ADR-0027). They are not
protocol: they are structure handling, and two other call sites already prove it.

`db/Exports.java` imports `JsonCodec` and `JsonStream` from the transport library only to stream a result
into a file, and `db/catalog/Introspect.java` does the same for a catalog snapshot (ADR-0010). `db/Csv.java`
is RFC 4180 field quoting with nothing of a database in it, filed under `neogrip.db`. And `Exports` picks
between two near-identical loops - header, row loop, value by value - with
`boolean json = "json".equalsIgnoreCase(format)`, so an unknown format name silently writes CSV and a
third format would mean a third loop.

Alternatives considered: a codec SPI so `neogrip.jsonrpc` declares what it needs and the application plugs
a serializer in (rejected - an indirection nobody asked for; a framework depending on a serializer is what
Spring does with Jackson, and it is the shorter honest arrow); a `RecordReader` symmetric to the writer
(rejected for now - nothing in the program reads CSV, and the editor side already has its own
`neogrip.codec.csv` for the DuckDB requery path (ADR-0021); a reader here would be built on speculation).

## Decision

`neogrip.dataformat`, a library that knows nothing about this program or its protocol.

- One common interface for a stream of records, which is what every file-shaped output here is:

  ```java
  public interface RecordWriter extends AutoCloseable {
      void header(List<String> fields) throws IOException;
      void record(List<Object> values) throws IOException;
      @Override void close() throws IOException;
  }
  ```

- `close()` finishes the structure - the closing bracket of a JSON array, the trailing newline - and never
  closes the sink, which belongs to whoever opened it.
- `DataFormat` is the factory (`JSON`, `CSV`) and `FormatOptions` carries the null marker and the
  delimiter. `DataFormat.of(name)` fails naming the formats it knows instead of falling back to CSV.
- `json/` holds the streaming writer, the parser and the reflective mapper (`JsonWriter`, `JsonParser`,
  `JsonMapper`, `JsonName`), moved out of `neogrip.rpc`; `csv/` holds the RFC 4180 field quoting and the
  record writer over it.
- `neogrip.jsonrpc` depends on `neogrip.dataformat`; the reverse never happens.
- A new format is one class in the library and no change in the application.

## Consequences

- The two export loops collapse into one, and the export path stops knowing what a format is.
- An unknown format name becomes an error instead of a CSV file, which is a behavior change in the only
  direction that can be right.
- `Exports` and `Introspect` lose their imports from the transport library: writing a file no longer
  depends on the protocol.
- The format set is closed by an enum. A format supplied from outside the library would need a registry,
  and none is built until something needs one.
- The library ships the write side only; reading stays JSON-only, exactly as today.
- The Java CSV writer's rules (quoting, the null marker) have no test of their own today - only a row
  count is asserted - so the rewrite lands with a check on the exported file's contents.
