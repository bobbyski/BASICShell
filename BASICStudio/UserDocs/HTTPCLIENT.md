# HttpClient Class

`HttpClient` performs asynchronous HTTP GET requests without blocking the BASIC runtime lane.

```basic
let client = HttpClient("https://api.example.com")
client.header("Accept", "application/json")

response = await client.get("/status")
print response("STATUS")
print response("BODY")
```

## URL Templates

Pass a dictionary as the second argument to replace named `{placeholders}`. Values are converted with locale-independent BASIC formatting and percent-encoded as URL path components.

```basic
dim values as dictionary
values("latitude") = 35.7796
values("longitude") = -78.6382

response = await client.get(
    "/points/{latitude},{longitude}", \
    values)
```

Every placeholder must have a dictionary value. Unresolved placeholders raise an error before a request is sent.

## Methods

| Method | Result |
|---|---|
| `header(name, value)` | Adds or replaces a default request header. |
| `get(pathOrUrl)` | Starts a GET and returns an awaitable `TASK`. |
| `get(template, substitutions)` | Substitutes dictionary values, starts a GET, and returns a `TASK`. |

The path may be relative to the constructor base URL or an absolute HTTP/HTTPS URL.

## Response

Awaiting `get` returns a dictionary:

| Key | Value |
|---|---|
| `STATUS` | Numeric HTTP status. |
| `OK` | `TRUE` for status 200 through 299. |
| `BODY` | UTF-8 response text. |
| `URL` | Final URL after redirects. |
| `HEADERS` | Response-header dictionary. |

Use `FromJsonString(response("BODY"), true)` to parse JSON.

The earlier `HTTPGETASYNC(url)` intrinsic remains available for small compatibility programs. `HttpClient` is preferred when requests need a base URL, headers, or URL templates.
