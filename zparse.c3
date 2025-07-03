module zparse;

enum HttpMethod {
    UNKNOWN,
    GET,
    HEAD,
    OPTIONS,
    TRACE,
    PUT,
    DELETE,
    POST,
    PATCH,
    CONNECT
}

enum HttpVersion {
    UNKNOWN,
    HTTP_1_0,
    HTTP_1_1,
    HTTP_2_0,
}

enum HttpParseState {
    METHOD,
    URI,
    VERSION,
    HEADER_KEY,
    HEADER_VALUE,
    BODY,
    COMPLETE,
    ERROR
}

struct ZHttpHeader {
    String name;
    String value;
}

struct ZHttpRequest {
    HttpMethod method;
    String uri;
    HttpVersion version;
    ZHttpHeader[64] headers;
    int header_count;
    String body;
}

struct ZHttpParser {
    ZHttpRequest* request;
    HttpParseState state;
    int header_index;
}

fn int find_char_simd(ZString str, usz length, char c, usz start) {
    char[<16>] v = c;
    usz i = start;
    while (i + 16 <= length) {
        char[<16>] chunk = str[i:16];
        bool[<16>] matches = chunk.comp_eq(v);
        if (matches.max()) {
            for (usz j = 0; j < 16; j++) {
                if (matches[j]) return (int) (i + j);
            }
        }
        i += 16;
    }
    while (i < length) {
        if (str[i] == c) return (int) i;
        i++;
    }
    return -1;
}

fn HttpMethod method_from_string(String method) {
    switch (method) {
        case "GET":     return HttpMethod.GET;
        case "PUT":     return HttpMethod.PUT;
        case "POST":    return HttpMethod.POST;
        case "HEAD":    return HttpMethod.HEAD;
        case "PATCH":   return HttpMethod.PATCH;
        case "TRACE":   return HttpMethod.TRACE;
        case "DELETE":  return HttpMethod.DELETE;
        case "OPTIONS": return HttpMethod.OPTIONS;
        case "CONNECT": return HttpMethod.CONNECT;
        default:    return HttpMethod.UNKNOWN;
    }
}

fn HttpVersion version_from_string(String version) {
    switch (version) {
        case "HTTP/1.0": return HttpVersion.HTTP_1_0;
        case "HTTP/1.1": return HttpVersion.HTTP_1_1;
        case "HTTP/2.0": return HttpVersion.HTTP_2_0;
        default:    return HttpVersion.UNKNOWN;
    }
}

fn bool ZHttpParser.parse(ZHttpParser* self, ZString input, usz length) {
    usz start = 0;
    usz current = 0;
    String current_header_key;
    isz space_pos;
    isz newline_pos;

    for (current = 0; current < length; current++) {
        char c = input[current];

        switch (self.state) {
            case METHOD:
                space_pos = find_char_simd(input, length, ' ', start);
                if (space_pos != -1) {
                    self.request.method = method_from_string((String) input[start..space_pos-1]);
                    start = (usz) space_pos + 1;
                    current = start;
                    self.state = HttpParseState.URI;
                } else {
                    return false;
                }
                break;
                
            case URI:
                space_pos = find_char_simd(input, length, ' ', start);
                if (space_pos != -1) {
                    self.request.uri = (String) input[start..space_pos-1];
                    start = (usz) space_pos + 1;
                    current = start;
                    self.state = HttpParseState.VERSION;
                } else {
                    return false;
                }
                break;
                
            case VERSION:
                newline_pos = find_char_simd(input, length, '\n', start);
                if (newline_pos != -1) {
                    usz version_end = newline_pos;
                    if (version_end > start && input[version_end-1] == '\r') {
                        version_end--;
                    }
                    
                    self.request.version = version_from_string((String) input[start..version_end-1]);
                    start = (usz) newline_pos + 1;
                    current = start;
                    self.state = HttpParseState.HEADER_KEY;
                } else {
                    return false;
                }
                break;
            case HEADER_KEY:
                if (c == ':') {
                    current_header_key = (String) input[start:current-start];
                    start = current + 1;
                    while (start < length && input[start] == ' ') start++;
                    self.state = HttpParseState.HEADER_VALUE;
                }
                else if (c == '\r') {
                    continue;
                }
                else if (c == '\n') {
                    self.state = HttpParseState.BODY;
                    start = current + 1;
                }
                break;
            case HEADER_VALUE:
                if (c == '\r') {
                    continue;
                }
                if (c == '\n') {
                    String header_value = (String) input[start:current-start];
                    if (self.request.header_count < 64) {
                        self.request.headers[self.request.header_count].name = current_header_key;
                        self.request.headers[self.request.header_count].value = header_value;
                        self.request.header_count++;
                    }
                    start = current + 1;
                    self.state = HttpParseState.HEADER_KEY;
                }
                break;
            case BODY:
                bool has_body = false;
                for (int i = 0; i < self.request.header_count; i++) {
                    if (self.request.headers[i].name == "Content-Length") {
                        has_body = true;
                        break;
                    }
                }

                if (has_body) {
                    self.request.body = (String) input[start..length];
                } else {
                    self.request.body = "";
                }
                
                return true;
            default:
                return false;
        }
    }

    if (self.state == HttpParseState.BODY) {
        return true;
    }
    return false;
}

fn bool parse(ZHttpRequest* request, ZString input, usz length) {
    ZHttpParser parser = (ZHttpParser) {.request = request};
    return parser.parse(input, length);
}