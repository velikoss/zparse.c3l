module zparse_test;
import zparse;
import std::io;

const ZString REQ1 =  // Different path and host
"GET /about.html HTTP/1.1\r\n"
"Host: www.example.com\r\n"
"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n"
"Accept: text/html\r\n"
"\r\n";

const ZString REQ2 =  // POST request with content
"POST /api/login HTTP/1.1\r\n"
"Host: auth.example.com\r\n"
"User-Agent: MyApp/1.0\r\n"
"Content-Type: application/json\r\n"
"Content-Length: 28\r\n"
"\r\n"
"{\"user\":\"admin\",\"pass\":\"123\"}";

const ZString REQ3 =  // Different HTTP version and minimal headers
"GET /index.html HTTP/2.0\r\n"
"Host: www.minimal.com\r\n"
"\r\n";

const ZString REQ4 =  // Request with different encoding and language
"GET /products/123 HTTP/1.1\r\n"
"Host: shop.example.com\r\n"
"User-Agent: Mozilla/5.0\r\n"
"Accept-Encoding: br\r\n"
"Accept-Language: fr\r\n"
"\r\n";

const ZString REQ5 =  // HEAD request with custom headers
"HEAD /status HTTP/1.1\r\n"
"Host: api.example.com\r\n"
"X-API-Key: 12345-ABCDE\r\n"
"Cache-Control: no-cache\r\n"
"\r\n";

const ZString REQ6 =
"GET /wp-content/uploads/2010/03/hello-kitty-darth-vader-pink.jpg HTTP/1.1\r\n"
"Host: www.kittyhell.com\r\n"
"User-Agent: Mozilla/5.0 (Macintosh; U; Intel Mac OS X 10.6; ja-JP-mac; rv:1.9.2.3) Gecko/20100401 Firefox/3.6.3 "
"Pathtraq/0.9\r\n"
"Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\n"
"Accept-Language: ja,en-us;q=0.7,en;q=0.3\r\n"
"Accept-Encoding: gzip,deflate\r\n"
"Accept-Charset: Shift_JIS,utf-8;q=0.7,*;q=0.7\r\n"
"Keep-Alive: 115\r\n"
"Connection: keep-alive\r\n"
"Cookie: wp_ozh_wsa_visits=2; wp_ozh_wsa_visit_lasttime=xxxxxxxxxx; "
"__utma=xxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.xxxxxxxxxx.x; "
"__utmz=xxxxxxxxx.xxxxxxxxxx.x.x.utmccn=(referral)|utmcsr=reader.livedoor.com|utmcct=/reader/|utmcmd=referral\r\n"
"\r\n";

const ZString[6] REQS = {REQ1, REQ2, REQ3, REQ4, REQ5, REQ6};
usz[6] reqs_len = {0,0,0,0,0,0};

fn void test_all() @test {
    ZHttpRequest request;
    ZHttpParser parser = (ZHttpParser) { .request = &request };
    test::@check(parser.parse(REQ1, REQ1.len()), "%s", request);
    test::@check(zparse::parse(&request, REQ2, REQ2.len()), "%s", request);
    test::@check(zparse::parse(&request, REQ3, REQ2.len()), "%s", request);
    test::@check(zparse::parse(&request, REQ4, REQ2.len()), "%s", request);
    test::@check(zparse::parse(&request, REQ5, REQ2.len()), "%s", request);
    test::@check(zparse::parse(&request, REQ6, REQ2.len()), "%s", request);
    return;
}

fn void bench_simple() @benchmark {
    ZHttpRequest request;
    ZHttpParser parser = (ZHttpParser) { .request = &request };
    if (!parser.parse(REQ1, REQ1.len())) {
        io::eprintn("Error!");
    }
    return;
}

fn void bench_complex() @benchmark {
    ZHttpRequest request;
    ZHttpParser parser = (ZHttpParser) { .request = &request };
    if (!parser.parse(REQ6, REQ6.len())) {
        io::eprintn("Error!");
    }
    return;
}

fn void bench_thousand() @benchmark {
    reqs_len = {REQ1.len(), REQ2.len(), REQ3.len(), REQ4.len(), REQ5.len(), REQ6.len()};
    for (int i = 0; i < 1000; i++) {
        ZHttpRequest request;
        if (!zparse::parse(&request, REQS[i%6], reqs_len[i%6])) {
            io::eprintn("Error!");
        }
    }
    return;
}