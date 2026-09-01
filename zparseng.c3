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
    HEAD_TOO_LARGE,
    NOT_FOUND;

const sz MAX_HEADERS   = env::MEMORY_ENV == NORMAL ? 64 : (env::MEMORY_ENV == SMALL ? 32 : 16);
const sz MAX_HEAD_SIZE = env::MEMORY_ENV == NORMAL ? 32 * 1024 : (env::MEMORY_ENV == SMALL ? 8 * 1024 : 2 * 1024);
const sz MAX_LINE_SIZE = env::MEMORY_ENV == NORMAL ? 8 * 1024 : (env::MEMORY_ENV == SMALL ? 2 * 1024 : 512);

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
    STATUS_LINE,
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
    sz header_count;
    String body;
    long content_length; // -1 when absent
    bool chunked;
    bool keep_alive;
}

struct ZHttpParser {
    ZHttpRequest* request;
    HttpParseState state;
    sz header_index;
    sz scanned;
}

struct ZHttpResponse {
    HttpVersion version;
    uint status;
    String reason;
    ZHttpHeader[MAX_HEADERS] headers;
    sz header_count;
    String body;
    long content_length; // -1 when absent
    bool chunked;
    bool keep_alive;
    // No Content-Length and no chunked: the body runs until the peer closes.
    // Requests have no such mode.
    bool body_until_close;
}

struct ZHttpResponseParser {
    ZHttpResponse* response;
    HttpParseState state;
    sz scanned;
    // A response to HEAD carries header fields describing a body that is not
    // sent. Only the caller knows which request this answers.
    bool head_request;
}

fn sz? find_char_simd(ZString str, sz length, char c, sz start) {
    char[<16>] v = c;
    sz i = start;
    while (i + 16 <= length) {
        char[<16>] chunk = *(char[<16>]*)&str[i];
        int bits = chunk.comp_eq(v).mask_to_int();
        if (bits) return i + bits.ctz();
        i += 16;
    }
    while (i < length) {
        if (str[i] == c) return i;
        i++;
    }
    return NOT_FOUND~;
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


macro String slice(ZString input, sz from, sz count) @local
    => (String)((char*)input)[(usz)from : (usz)count];

<*
 @return "true when the head is complete"
 @return? HEAD_TOO_LARGE
*>
fn bool? head_ready(sz* scanned, ZString input, sz len) @local {
    if (*scanned == 0) return true;   // first call: parse optimistically
    sz i = *scanned > 3 ? *scanned - 3 : 0;
    bool complete = false;
    while (i < len) {
        sz? found = find_char_simd(input, len, '\n', i);
        if (catch found) break;
        if (found >= 3 && input[found - 1] == '\r' && input[found - 2] == '\n' && input[found - 3] == '\r') {
            complete = true;
            break;
        }
        i = found + 1;
    }
    *scanned = len;
    if (!complete && len > MAX_HEAD_SIZE) return HEAD_TOO_LARGE~;
    return complete;
}

<*
 @return "Offset just past the terminating CRLF"
 @return? INCOMPLETE, INVALID_HEADER, INVALID_CONTENT_LENGTH, UNSUPPORTED_TRANSFER_ENCODING, LINE_TOO_LONG, TOO_MANY_HEADERS
*>
fn sz? parse_header_block(Msg* out, ZString input, sz len, sz start, HttpVersion version) <Msg> @private {
    sz nh = 0;
    sz line_start = start;
    long clen = -1;
    bool chunked = false;
    bool has_te = false;
    bool close_seen = false;
    bool keep_seen = false;
    String key;

    while (true) {
        if (start < len && input[start] == '\r' && start + 1 >= len) return INCOMPLETE~;
        if (start + 1 < len && input[start] == '\r' && input[start + 1] == '\n') {
            start += 2;
            break;
        }

        line_start = start;
        sz? colon = find_char_simd(input, len, ':', start);
        if (catch colon) {
            if (len - line_start > MAX_LINE_SIZE) return LINE_TOO_LONG~;
            return INCOMPLETE~;
        }
        if (colon == start) return INVALID_HEADER~;
        if (input[colon - 1] == ' ' || input[colon - 1] == '\t') return INVALID_HEADER~;
        key = slice(input, start, colon - start);
        start = colon + 1;

        sz? nl = find_char_simd(input, len, '\n', start);
        if (catch nl) {
            if (len - line_start > MAX_LINE_SIZE) return LINE_TOO_LONG~;
            return INCOMPLETE~;
        }
        if (nl - line_start > MAX_LINE_SIZE) return LINE_TOO_LONG~;
        if (nl == start || input[nl - 1] != '\r') return INVALID_HEADER~;
        String value = trim_ows(slice(input, start, nl - 1 - start));

        if (nh == MAX_HEADERS) return TOO_MANY_HEADERS~;
        out.headers[nh] = { .name = key, .value = value };
        nh++;

        if (ascii_ieq(key, "content-length")) {
            long v = parse_decimal(value)!;
            if (clen >= 0 && clen != v) return INVALID_CONTENT_LENGTH~;
            clen = v;
        } else if (ascii_ieq(key, "transfer-encoding")) {
            has_te = true;
            usz last = 0;
            for (usz i = 0; i < value.len; i++) {
                if (value[i] == ',') last = i + 1;
            }
            if (ascii_ieq(trim_ows(value[last..]), "chunked")) chunked = true;
        } else if (ascii_ieq(key, "connection")) {
            if (ascii_ieq(value, "close")) close_seen = true;
            if (ascii_ieq(value, "keep-alive")) keep_seen = true;
        }

        start = nl + 1;
    }

    // Check for request smuggling
    if (chunked && clen >= 0) return INVALID_CONTENT_LENGTH~;
    if (has_te && !chunked) return UNSUPPORTED_TRANSFER_ENCODING~;

    out.header_count   = nh;
    out.content_length = clen;
    out.chunked        = chunked;
    out.keep_alive     = version == HttpVersion.HTTP_1_1 ? !close_seen : keep_seen;
    return start;
}

<*
 @return "Bytes consumed by the head; the body starts at input[return]"
 @return? INCOMPLETE, INVALID_REQUEST, INVALID_VERSION, INVALID_HEADER, INVALID_CONTENT_LENGTH, UNSUPPORTED_TRANSFER_ENCODING, LINE_TOO_LONG, TOO_MANY_HEADERS, HEAD_TOO_LARGE
*>
fn usz? ZHttpParser.parse(&self, ZString input, usz length) {
    sz len = (sz)length;
    if (!head_ready(&self.scanned, input, len)!) return INCOMPLETE~;

    sz? sp1 = find_char_simd(input, len, ' ', 0);
    if (catch sp1) { self.scanned = len; return INCOMPLETE~; }
    self.request.method = method_from_string(slice(input, 0, sp1));
    if (self.request.method == HttpMethod.UNKNOWN) return INVALID_REQUEST~;

    sz? sp2 = find_char_simd(input, len, ' ', sp1 + 1);
    if (catch sp2) { self.scanned = len; return INCOMPLETE~; }
    if (sp2 == sp1 + 1) return INVALID_REQUEST~;
    self.request.uri = slice(input, sp1 + 1, sp2 - sp1 - 1);

    sz? nl = find_char_simd(input, len, '\n', sp2 + 1);
    if (catch nl) { self.scanned = len; return INCOMPLETE~; }
    if (nl == sp2 + 1 || input[nl - 1] != '\r') return INVALID_REQUEST~;
    HttpVersion version = version_from_string(slice(input, sp2 + 1, nl - 1 - sp2 - 1));
    if (version != HttpVersion.HTTP_1_0 && version != HttpVersion.HTTP_1_1) return INVALID_VERSION~;
    self.request.version = version;

    sz? start = parse_header_block{ZHttpRequest}(self.request, input, len, nl + 1, version);
    if (catch e = start) {
        if (e == INCOMPLETE) self.scanned = len;
        return e~;
    }

    self.request.body = "";
    if (self.request.content_length > 0 && start + (sz)self.request.content_length <= len) {
        self.request.body = slice(input, start, (sz)self.request.content_length);
    }
    self.state = HttpParseState.COMPLETE;
    return (usz)start;
}

<*
 @return "Bytes consumed by the head; the body starts at input[return]"
 @return? INCOMPLETE, INVALID_REQUEST, INVALID_VERSION, INVALID_HEADER, INVALID_CONTENT_LENGTH, UNSUPPORTED_TRANSFER_ENCODING, LINE_TOO_LONG, TOO_MANY_HEADERS, HEAD_TOO_LARGE
*>
fn usz? ZHttpResponseParser.parse(&self, ZString input, usz length) {
    sz len = (sz)length;
    if (!head_ready(&self.scanned, input, len)!) return INCOMPLETE~;

    sz? nl = find_char_simd(input, len, '\n', 0);
    if (catch nl) { self.scanned = len; return INCOMPLETE~; }
    if (nl == 0 || input[nl - 1] != '\r') return INVALID_REQUEST~;
    sz eol = nl - 1;

    if (eol < 12) return INVALID_REQUEST~;
    HttpVersion version = version_from_string(slice(input, 0, 8));
    if (version != HttpVersion.HTTP_1_0 && version != HttpVersion.HTTP_1_1) return INVALID_VERSION~;
    if (input[8] != ' ') return INVALID_REQUEST~;

    uint code = 0;
    for (sz i = 9; i < 12; i++) {
        if (input[i] < '0' || input[i] > '9') return INVALID_REQUEST~;
        code = code * 10 + (uint)(input[i] - '0');
    }
    if (eol > 12 && input[12] != ' ') return INVALID_REQUEST~;

    self.response.version = version;
    self.response.status  = code;
    self.response.reason  = eol > 13 ? trim_ows(slice(input, 13, eol - 13)) : "";

    sz? start = parse_header_block{ZHttpResponse}(self.response, input, len, nl + 1, version);
    if (catch e = start) {
        if (e == INCOMPLETE) self.scanned = len;
        return e~;
    }

    bool bodyless = self.head_request
                 || (code >= 100 && code < 200)
                 || code == 204
                 || code == 304;

    self.response.body_until_close = !bodyless
                                  && !self.response.chunked
                                  && self.response.content_length < 0;
    self.response.body = "";
    if (bodyless) {
        self.response.content_length = 0;
        self.response.chunked = false;
    } else if (self.response.content_length > 0 && start + (sz)self.response.content_length <= len) {
        self.response.body = slice(input, start, (sz)self.response.content_length);
    }
    self.state = HttpParseState.COMPLETE;
    return (usz)start;
}

fn usz? parse(ZHttpRequest* request, ZString input, usz length) {
    ZHttpParser parser = (ZHttpParser) {.request = request};
    return parser.parse(input, length);
}

fn usz? parse_response(ZHttpResponse* response, ZString input, usz length, bool head_request = false) {
    ZHttpResponseParser parser = { .response = response, .head_request = head_request };
    return parser.parse(input, length);
}

fn void ZHttpParser.reset(&self) {
    self.scanned = 0;
    self.header_index = 0;
    self.state = HttpParseState.METHOD;
}

fn void ZHttpResponseParser.reset(&self) {
    self.scanned = 0;
    self.state = HttpParseState.STATUS_LINE;
}

fn String? ZHttpRequest.header(&self, String name) {
    for (sz i = 0; i < self.header_count; i++) {
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

fn String? ZHttpResponse.header(&self, String name) {
    for (sz i = 0; i < self.header_count; i++) {
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
