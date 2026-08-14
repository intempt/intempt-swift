# Verified REST contract

Every line below was confirmed against production (`api.intempt.com/v1`) on
2026-08-14 using the deprecated `linea` project. Nothing here is inferred from
a spec or from the JS SDK alone — where the two disagreed, the live response won.

## Authentication

`Authorization: Basic base64(prefix:secret)`, where the API key is
`prefix.secret` split on the first `.`.

| Probe | Result |
|---|---|
| Valid Basic on the source-scoped `/track` route | **201** |
| Wrong secret | **401** |
| No `Authorization` header | **401** |

401 is classified terminal — retrying a bad credential cannot succeed, but the
queued events are **kept**, because the data is valid and the integration is
what's broken.

## `POST /{org}/projects/{project}/sources/{sourceId}/track`

Body: `{"track":[ {name, type, payload:[{…}]}, … ]}`. One request carries a
mixed batch.

| `type` | Result | Required identity |
|---|---|---|
| `track` | 201 | `profileId` |
| `identify` | 201 | `userId` |
| `group` | 201 | `accountId` |
| `alias` | 201 | `profileId` + `userId` + `anotherUserId` |
| `record` | 201 | `userId` and/or `accountId` |
| `product` | 201 | `data.productId` |
| mixed batch (`track` + `identify`) | 201 | — |

Success is **201**, not 200. `/consents/data` returns **200**. Both fall inside
the 200–299 success range, but a classifier hardcoded to `== 200` would treat
every accepted event batch as a failure.

Response body is **empty** on success. There is no server-assigned id to read
back, so the client's `ev_`-prefixed `eventId` is the only dedup handle.

### Negative cases

| Probe | Result | Notes |
|---|---|---|
| Payload with no `userId`/`profileId`/`accountId`/`productId` | **400** | `PayloadValidator` rejects this client-side, so the request is never made |
| Malformed JSON | **400** | terminal |
| `{"track":[]}` | **201** | accepted, but `Flush` never sends an empty batch — it would be a wasted round trip |

### Compression: NOT SUPPORTED

`Content-Encoding: gzip` with a gzipped body returns **HTTP 400**. The endpoint
does not decompress.

**Consequence:** `Data+Compression.swift` was cut from the build. Porting
upstream mixpanel-swift's gzip path would have made every single request fail.

## `POST /{org}/projects/{project}/consents/data`

Flat body, not batched, not wrapped in a `track` envelope:

```json
{"action":"accept","profileId":"…","sourceId":"…","source":"ios","validUntil":31536000}
```

Returns **200**.

## `POST /{org}/projects/{project}/optimization/choose-api`

Body — note the nested `identification` object. The JS SDK's
`ChoicesRequestModel` is the authority here; there is no `optimizationType`
discriminator and no `names` array, which an earlier draft of our plan assumed.

```json
{
  "identification": {"sourceId":"…","profileId":"…"},
  "url": "…",          // optional
  "device": "…",       // optional
  "sessionId": "…",    // optional
  "productId": null    // optional
}
```

Returns **200** with:

```json
{"choices":[{"target":"…","changes":[…],"variant":"8458","updatedAt":1780479018724,"experience":"8038"}]}
```

`identification` alone is sufficient — a request with no `url`, `device` or
`sessionId` still returns 200. Omitting `identification` returns **400**
`{"errors":[{"message":"Identification is required"}]}`.

`choose-api` is the native endpoint; `choose-web` is the browser one. They are
separate registrations on the same service and are **not** interchangeable.

## `POST /{org}/projects/{project}/feeds/{feedId}/data`

Flat body — **not** `identification`-wrapped, unlike `choose-api`:

```json
{"profileId":"…","sourceId":"…","limit":10,"fields":["title","price","imageUrl"],"productId":"…"}
```

Returns **200** with `{"products":[…]}`.

### `fields` is effectively mandatory on mobile

Measured on feed 5258, `limit: 10`:

| Request | Response size |
|---|---|
| with `fields: [title, price, imageUrl]` | **503 bytes** |
| without `fields` | **222,919 bytes** |

**443x larger.** Omitting `fields` returns every column including
`intempt_image_vector` — raw ML embedding arrays. Over cellular that is an
unacceptable payload for a recommendation strip.

**Consequence:** the SDK's `products(feedId:count:fields:)` defaults `fields` to
`["productId", "title", "price", "imageUrl", "url"]` and never sends an
unfielded request. A caller must pass `fields` explicitly to widen it.

### Feed inputs

`GET /{org}/projects/{project}/feeds` lists the configured feeds and each one's
`feedInput`:

| `feedInput` | Requires |
|---|---|
| `NO_INPUT` | nothing |
| `USER` | `profileId` |
| `PRODUCT` | `productId` |

A `PRODUCT` feed called without `productId` returns **200 with an empty
`products` array** — not an error. Silent empty results are the failure mode to
document, since there is nothing in the response to distinguish "no
recommendations" from "you forgot the input".

### Error shape

Errors across every endpoint use:

```json
{"errors":[{"message":"Invalid feed id: nonexistent"}]}
```

Parsed by `IntemptError.serverMessages(from:)` so a failure surfaces the
server's own wording rather than a bare status code.

## Retry-After

No `Retry-After` header was observed on any success or 4xx response. The
`RetryPolicy` honours it as a floor when present and falls back to its own
exponential curve when absent, so its absence is not a problem — but it means
the header path is covered only by unit tests, not by a live observation.
