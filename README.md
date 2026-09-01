# zparseng.c3l

SIMD-accelerated, zero-allocation HTTP/1.1 request **and response** parser for [C3](https://c3-lang.org).

`zparseng` is the current generation of `zparse`.

- **No allocation.** No `Allocator` anywhere in the API. The parser, the request and the response are fixed-size values.
- **No copying.** `uri`, `reason`, header names and values are slices into the buffer you passed in.
- **Linear on partial input.** A head arriving byte by byte costs the same total work as one arriving whole.
- **No dependencies.** Standard library only.

The repository also contains `zparse1.c3`, old gen parser, but only so the benchmark can measure against it.

## Requirements

c3c 0.8.3 or later.

## Installation

Add zparse to your project by cloning it into your libs directory:

```bash
git clone https://github.com/velikoss/zparse.c3l
```

Then add to your `project.json` dependencies:

```json
"dependencies": ["zparse"],
```

## Basic Usage

### Whole request in one buffer

```c3
import zparseng;

fn void handle(char[] buf)
{
    ZHttpRequest req;

    usz? head_len = zparseng::parse(&req, (ZString)buf.ptr, buf.len);
    if (catch err = head_len)
    {
        // err == zparseng::INCOMPLETE -> read more bytes, call again
        // anything else               -> reject the request
        return;
    }

    // req.method         GET / POST / ...
    // req.uri            "/index.html"
    // req.version        HTTP_1_0 / HTTP_1_1
    // req.headers        ZHttpHeader[MAX_HEADERS]
    // req.header_count
    // req.content_length -1 when absent
    // req.chunked        Transfer-Encoding: chunked
    // req.keep_alive
    // req.body           set when the whole Content-Length body is in the buffer

    String host = req.header("Host") ?? "";
    // the body, however it arrived, starts at buf[head_len..]
}
```

`parse` returns **the number of bytes the head occupied**, so `buf[head_len..]`
is the body and next request after on a pipelined connection.

### Bytes arriving over a socket

Keep one `ZHttpParser` per connection and call it with everything received so
far. It remembers how much it has already examined, so a head split across many
reads costs one pass in total, not one pass per read.

```c3
ZHttpRequest req;
ZHttpParser parser = { .request = &req };

char[4096] buf;
usz have = 0;

while (true)
{
    have += socket.read(buf[have..])!;

    usz? head_len = parser.parse((ZString)&buf, have);
    if (try head_len)
    {
        serve(&req, buf[head_len:have - head_len]);
        break;
    }
    if (catch err = head_len)
    {
        if (err == zparseng::INCOMPLETE) continue;  // need more bytes
        respond_with_error(err);                    // permanent failure
        break;
    }
}
```

On a keep-alive connection, call `parser.reset()` before the next request.

### Responses

```c3
ZHttpResponse resp;

usz? head_len = zparseng::parse_response(&resp, (ZString)buf.ptr, buf.len);
if (try head_len)
{
    // resp.status           200
    // resp.reason           "OK"
    // resp.version
    // resp.headers, resp.header_count
    // resp.content_length   -1 when absent
    // resp.chunked
    // resp.keep_alive
    // resp.body_until_close read to EOF: no Content-Length and no chunked
}
```

For streaming, `ZHttpResponseParser` mirrors `ZHttpParser`:

```c3
ZHttpResponseParser parser = { .response = &resp, .head_request = false };
```

## Error handling

`parse` and `parse_response` return `usz?`. Every failure is a distinct fault, so
you can map it to a status code instead of guessing:

| Fault | Meaning | Suggested status |
|---|---|---|
| `INCOMPLETE` | The head is not finished yet. Read more and call again. | - |
| `INVALID_REQUEST` | Malformed request or status line, unknown method, non-numeric status code, bare LF. | 400 |
| `INVALID_VERSION` | Not HTTP/1.0 or HTTP/1.1. | 505 |
| `INVALID_HEADER` | No colon, empty name, whitespace before the colon, bare LF. | 400 |
| `INVALID_CONTENT_LENGTH` | Not a number, overflows, duplicated with a different value, or combined with `chunked`. | 400 |
| `UNSUPPORTED_TRANSFER_ENCODING` | `Transfer-Encoding` present but its final coding is not `chunked`, so the body length is undeterminable. | 501 |
| `LINE_TOO_LONG` | A single line exceeded `MAX_LINE_SIZE`. | 431 |
| `TOO_MANY_HEADERS` | More than `MAX_HEADERS` header lines. | 431 |
| `HEAD_TOO_LARGE` | The accumulated head exceeded `MAX_HEAD_SIZE` without terminating. | 431 |

`ZHttpRequest.header` and `ZHttpResponse.header` return `NOT_FOUND` when the
header is absent, so you can potentially use `req.header("Cookie") ?? ""`.

## Limits

Sized from `env::MEMORY_ENV`, so the parser shrinks on constrained targets:

| | NORMAL | SMALL | TINY / NONE |
|---|---|---|---|
| `MAX_HEADERS` | 64 | 32 | 16 |
| `MAX_LINE_SIZE` | 8 KB | 2 KB | 512 B |
| `MAX_HEAD_SIZE` | 32 KB | 8 KB | 2 KB |

## API

```c3
struct ZHttpHeader {
    String name;
    String value;
}

struct ZHttpRequest {
    HttpMethod method;                 // GET, POST, ...
    String uri;                        // "/index.html"
    HttpVersion version;
    ZHttpHeader[MAX_HEADERS] headers;
    sz header_count;
    String body;                       // when fully present in the buffer
    long content_length;               // -1 when absent
    bool chunked;
    bool keep_alive;
}

struct ZHttpResponse {
    HttpVersion version;
    uint status;                       // 200
    String reason;                     // "OK", may be empty
    ZHttpHeader[MAX_HEADERS] headers;
    sz header_count;
    String body;
    long content_length;               // -1 when absent
    bool chunked;
    bool keep_alive;
    bool body_until_close;             // read to EOF
}

struct ZHttpParser {
    ZHttpRequest* request;
    HttpParseState state;
    sz header_index;
    sz scanned;
}

struct ZHttpResponseParser {
    ZHttpResponse* response;
    HttpParseState state;
    sz scanned;
    bool head_request;                 // set when this answers a HEAD
}

fn usz?    parse(ZHttpRequest* request, ZString input, usz length);
fn usz?    ZHttpParser.parse(&self, ZString input, usz length);
fn void    ZHttpParser.reset(&self);
fn String? ZHttpRequest.header(&self, String name);

fn usz?    parse_response(ZHttpResponse* response, ZString input, usz length, bool head_request = false);
fn usz?    ZHttpResponseParser.parse(&self, ZString input, usz length);
fn void    ZHttpResponseParser.reset(&self);
fn String? ZHttpResponse.header(&self, String name);
```

All strings borrow from `input`. They are valid only while that buffer is alive
and unmodified.

## Performance
 
The [picohttpparser](https://github.com/h2o/picohttpparser) benchmark request: 534 bytes, 9 headers.
 
Ryzen 7 2700, 32 GB DDR4, Windows 11 Pro, c3c 0.8.3, `-O3`
([bench.c3](https://github.com/velikoss/zparse.c3l/blob/master/bench.c3)):
 
| | whole head | 64-byte chunks | byte at a time |
|---|---|---|---|
| **zparseng** | **147.9 ns** (6.76 M req/s) | **265.9 ns** | **3.97 µs** |
| [http.c3l](https://github.com/lsfratel/http.c3l) | 217.7 ns (4.59 M req/s) | 297.8 ns | 8.43 µs |
| zparse (old) | 909.1 ns (1.10 M req/s) | 4.48 µs | 227 µs |
 
`zparse` is in the table to show what changed, not as an option. Use
`zparseng`.

### Running the benchmark

```bash
c3c compile-run -O3 --single-module=no bench.c3 zparse1.c3 zparseng.c3
```

To include http.c3l into benchmark results use ([this](https://github.com/velikoss/zparse.c3l/blob/master/bench_httpc3l))

## What it does not do

- **Chunked bodies are detected, not decoded.** `chunked` tells you the framing;
  decoding the chunk stream is the caller's job.
- **No timeout.** Linear parsing bounds CPU work, not wall time. A client
  holding a connection open sending one byte a minute is a problem for your
  accept loop, not the parser.

## License

MIT License

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

Report bugs via GitHub issues.