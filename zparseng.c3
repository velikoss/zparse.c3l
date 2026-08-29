module zparseng;

import std::core::env;
import std::core::mem;
import std::math::vector;
import std::bits;

faultdef
    INCOMPLETE,
    INVALID_REQUEST,
    INVALID_VERSION,
    INVALID_HEADER,
    INVALID_CONTENT_LENGTH,
    UNSUPPORTED_TRANSFER_ENCODING,
    LINE_TOO_LONG,
    TOO_MANY_HEADERS,
    NOT_FOUND;

const usz MAX_HEADERS   = env::MEMORY_ENV == NORMAL ? 64 : (env::MEMORY_ENV == SMALL ? 32 : 16);
const usz MAX_HEAD_SIZE = env::MEMORY_ENV == NORMAL ? 32 * 1024 : (env::MEMORY_ENV == SMALL ? 8 * 1024 : 2 * 1024);
const usz MAX_LINE_SIZE = env::MEMORY_ENV == NORMAL ? 8 * 1024 : (env::MEMORY_ENV == SMALL ? 2 * 1024 : 512);

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
    ZHttpHeader[MAX_HEADERS] headers;
    int header_count;
    String body;
    long content_length; // -1 when absent
    bool chunked;
    bool keep_alive;
}

struct ZHttpParser {
    ZHttpRequest* request;
    HttpParseState state;
    int header_index;
    usz scanned;
}

fn int find_char_simd(ZString str, usz length, char c, usz start) {
    char[<16>] v = c;
    usz i = start;
    while (i + 16 <= length) {
        char[<16>] chunk = mem::load((char[<16>]*)&str[i], 1);
        int bits = chunk.comp_eq(v).mask_to_int();
        if (bits) return (int)(i + (usz)bits.ctz());
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

fn char ascii_lower(char c) @inline @local => c >= 'A' && c <= 'Z' ? (char)(c + 32) : c;

fn bool ascii_ieq(String a, String lower) @inline {
    if (a.len != lower.len) return false;
    for (usz i = 0; i < a.len; i++) {
        if (ascii_lower(a[i]) != lower[i]) return false;
    }
    return true;
}

fn String trim_ows(String s) @inline @local {
    usz b = 0;
    usz e = s.len;
    while (b < e && (s[b] == ' ' || s[b] == '\t')) b++;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t')) e--;
    return s[b:e - b];
}

fn long? parse_decimal(String s) @local {
    if (!s.len) return INVALID_CONTENT_LENGTH~;
    ulong v = 0;
    foreach (c : s) {
        if (c < '0' || c > '9') return INVALID_CONTENT_LENGTH~;
        if (v > (ulong::max - (ulong)(c - '0')) / 10) return INVALID_CONTENT_LENGTH~;
        v = v * 10 + (ulong)(c - '0');
    }
    if (v > (ulong)long::max) return INVALID_CONTENT_LENGTH~;
    return (long)v;
}

fn usz? ZHttpParser.parse(&self, ZString input, usz length) {
    if (self.scanned > 0) {
        usz from = self.scanned > 3 ? self.scanned - 3 : 0;
        usz i = from;
        bool complete = false;
        while (i < length) {
            int nl = find_char_simd(input, length, '\n', i);
            if (nl < 0) break;
            usz at = (usz)nl;
            if (at >= 3 && input[at - 1] == '\r' && input[at - 2] == '\n' && input[at - 3] == '\r') { complete = true; break; }
            i = at + 1;
        }
        self.scanned = length;
        if (!complete) {
            if (length > MAX_HEAD_SIZE) return LINE_TOO_LONG~;
            return INCOMPLETE~;
        }
    }

    usz start = 0;
    int nh = 0;
    long clen = -1;
    bool chunked = false;
    bool has_te = false;
    bool close_seen = false;
    bool keep_seen = false;
    HttpVersion version = HttpVersion.UNKNOWN;
    String current_header_key;

    self.state = HttpParseState.METHOD;

    while (true) {
        switch (self.state) {
            case METHOD:
                int sp = find_char_simd(input, length, ' ', start);
                if (sp < 0) { self.scanned = length; return INCOMPLETE~; }
                self.request.method = method_from_string((String)input[start:(usz)sp - start]);
                if (self.request.method == HttpMethod.UNKNOWN) return INVALID_REQUEST~;
                start = (usz)sp + 1;
                self.state = HttpParseState.URI;

            case URI:
                int sp = find_char_simd(input, length, ' ', start);
                if (sp < 0) { self.scanned = length; return INCOMPLETE~; }
                if ((usz)sp == start) return INVALID_REQUEST~;
                self.request.uri = (String)input[start:(usz)sp - start];
                start = (usz)sp + 1;
                self.state = HttpParseState.VERSION;

            case VERSION:
                int nl = find_char_simd(input, length, '\n', start);
                if (nl < 0) { self.scanned = length; return INCOMPLETE~; }
                usz end = (usz)nl;
                
				if (end == start || input[end - 1] != '\r') return INVALID_REQUEST~;
                end--;
                version = version_from_string((String)input[start:end - start]);
                
				if (version != HttpVersion.HTTP_1_0 && version != HttpVersion.HTTP_1_1) return INVALID_VERSION~;
                self.request.version = version;
                start = (usz)nl + 1;
                self.state = HttpParseState.HEADER_KEY;

            case HEADER_KEY:
                if (start < length && input[start] == '\r' && start + 1 >= length) { self.scanned = length; return INCOMPLETE~; }
                if (start + 1 < length && input[start] == '\r' && input[start + 1] == '\n') {
                    start += 2;
                    self.state = HttpParseState.BODY;
                    continue;
                }
                int colon = find_char_simd(input, length, ':', start);
                if (colon < 0) { self.scanned = length; return INCOMPLETE~; }
                if ((usz)colon == start) return INVALID_HEADER~;
                
				if (input[(usz)colon - 1] == ' ' || input[(usz)colon - 1] == '\t') return INVALID_HEADER~;
                current_header_key = (String)input[start:(usz)colon - start];
                start = (usz)colon + 1;
                self.state = HttpParseState.HEADER_VALUE;

            case HEADER_VALUE:
                int nl = find_char_simd(input, length, '\n', start);
                if (nl < 0) { self.scanned = length; return INCOMPLETE~; }
                usz end = (usz)nl;
                if (end == start || input[end - 1] != '\r') return INVALID_HEADER~;
                end--;
                String value = trim_ows((String)input[start:end - start]);

                // if headers exceed our limit, return error
				if (nh == (int)MAX_HEADERS) return TOO_MANY_HEADERS~;
                self.request.headers[nh] = { .name = current_header_key, .value = value };
                nh++;

                if (ascii_ieq(current_header_key, "content-length")) {
                    long v = parse_decimal(value)!;
                    if (clen >= 0 && clen != v) return INVALID_CONTENT_LENGTH~;
                    clen = v;
                } else if (ascii_ieq(current_header_key, "transfer-encoding")) {
                    has_te = true;
                    usz last = 0;
                    for (usz i = 0; i < value.len; i++) {
                        if (value[i] == ',') last = i + 1;
                    }
                    if (ascii_ieq(trim_ows(value[last..]), "chunked")) chunked = true;
                } else if (ascii_ieq(current_header_key, "connection")) {
                    if (ascii_ieq(value, "close")) close_seen = true;
                    if (ascii_ieq(value, "keep-alive")) keep_seen = true;
                }

                start = (usz)nl + 1;
                self.state = HttpParseState.HEADER_KEY;

            case BODY:
                // Check for request smuggling
			    if (chunked && clen >= 0) return INVALID_CONTENT_LENGTH~;
                if (has_te && !chunked) return UNSUPPORTED_TRANSFER_ENCODING~;

                self.request.header_count   = nh;
                self.request.content_length = clen;
                self.request.chunked        = chunked;
                self.request.keep_alive     = version == HttpVersion.HTTP_1_1 ? !close_seen : keep_seen;
                self.request.body           = "";
                if (clen > 0 && start + (usz)clen <= length) {
                    self.request.body = (String)input[start:(usz)clen];
                }
                self.state = HttpParseState.COMPLETE;
                return start;

            default:
                return INVALID_REQUEST~;
        }
    }
}

fn usz? parse(ZHttpRequest* request, ZString input, usz length) {
    ZHttpParser parser = (ZHttpParser) {.request = request};
    return parser.parse(input, length);
}

fn void ZHttpParser.reset(&self) {
    self.scanned = 0;
    self.header_index = 0;
    self.state = HttpParseState.METHOD;
}

fn String? ZHttpRequest.header(&self, String name) {
    for (int i = 0; i < self.header_count; i++) {
        String h = self.headers[i].name;
        if (h.len != name.len) continue;
        bool eq = true;
        for (usz j = 0; j < h.len; j++) {
            if (ascii_lower(h[j]) != ascii_lower(name[j])) { eq = false; break; }
        }
        if (eq) return self.headers[i].value;
    }
    return NOT_FOUND~;
}

struct HeadScanner {
    usz scanned;
}

fn bool? HeadScanner.head_complete(&self, ZString input, usz length, usz* head_len) {
    usz from = self.scanned > 3 ? self.scanned - 3 : 0;
    usz i = from;
    while (i < length) {
        int nl = find_char_simd(input, length, '\n', i);
        if (nl < 0) break;
        usz at = (usz)nl;
        if (at >= 3 && input[at - 1] == '\r' && input[at - 2] == '\n' && input[at - 3] == '\r') {
            *head_len = at + 1;
            self.scanned = length;
            return true;
        }
        i = at + 1;
    }
    self.scanned = length;
    if (length > MAX_LINE_SIZE * 4) return LINE_TOO_LONG~;
    return false;
}