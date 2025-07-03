# zparse - High-performance HTTP Parser in C3

Lightweight, SIMD-accelerated HTTP request parser for the C3 language.

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

```c
import zparse;

fn void handle_request(ZString request, usz length) {
    ZHttpRequest parsed_req;
    ZHttpParser parser = { .request = &parsed_req };
    
    if (parser.parse(request, length)) {
        // Request successfully parsed
        // Access:
        // parsed_req.method   (GET/POST/etc)
        // parsed_req.uri      ("/path.html")
        // parsed_req.headers  (array of name-value pairs)
        // parsed_req.body     (for POST/PUT requests)
    }
}
```

## Performance

Benchmark results on Ryzen 7 2700 (32GB DDR4, Windows 11 Pro, C3C Built-in Benchmark, -O3 flag, [bench.c3](https://github.com/velikoss/zparse.c3l/blob/master/bench.c3)):

```
--------------- BENCHMARKS ----------------
Benchmarking zparse::bench_simple .... [COMPLETE] 321.18 ns, 1027.74 CPU clocks
Benchmarking zparse::bench_complex ... [COMPLETE] 1277.69 ns, 4088.52 CPU clocks
Benchmarking zparse::bench_thousand .. [COMPLETE] 387429.31 ns, 1239770.25 CPU clocks
```

### Throughput Analysis:

| Benchmark Type       | Time/Req | CPU Cycles | Requests/sec  | Description |
|----------------------|----------|------------|---------------|-------------|
| **Simple Request**   | 321 ns   | 1,028      | **3.11M req/s** | Minimal GET request |
| **Complex Request**  | 1.28 μs  | 4,089      | **783K req/s**  | Real-world with cookies |
| **Bulk Processing**  | 0.39 μs  | 1,240      | **2.58M req/s** | Mixed request average |

## API Overview

### Core Structures

```c
struct ZHttpRequest {
    HttpMethod method;        // HTTP method (GET, POST, etc)
    String uri;               // Request URI
    HttpVersion version;      // HTTP version
    ZHttpHeader[64] headers;  // Header array
    int header_count;         // Number of headers
    String body;              // Request body (if present)
};

struct ZHttpParser {
    ZHttpRequest* request; 
    HttpParseState state;
    int header_index;
};
```

### Key Functions

- `ZHttpParser.parse(ZString request, usz length)`: Parse HTTP request

## Examples

### Parsing a GET request

```c
const ZString req = 
"GET /index.html HTTP/1.1\r\n"
"Host: example.com\r\n"
"\r\n";

ZHttpRequest request;
ZHttpParser parser = { .request = &request };
if (!parser.parse(&parser, req, req.len())) {
    // Error
}
// Access parsed data in request
```

## Benchmarks

zparse includes built-in benchmarks:

To test them use: `c3c -O3 benchmark`

## Test Cases

The module includes 6 real-world test cases covering:

1. Simple GET request
2. POST request with JSON body
3. HTTP/2.0 request
4. Request with encoding headers
5. HEAD request with custom headers
6. Complex request with cookies

Run tests with:
`c3c test`

## Requirements

- C3 compiler
- No external dependencies

## License

MIT License

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

Report bugs via GitHub issues.
