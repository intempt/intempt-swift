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

401 is classified terminal, and by ruling R-retry (D9, INT-7438) the batch is
**dropped** on the first 401, as intempt-android does: the backend never accepts
an event it answered 401 for.

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
{"action":"accept","profileId":"…","sourceId":"…","source":"ios","validUntil":1793000000000}
```

`validUntil` is the absolute expiry in **epoch milliseconds**, or `-1` for unlimited. The public
API takes a duration in seconds (`consent(action:validUntil:)`) and the SDK sends
`(now + duration) × 1000`, so `0` expires now.

Returns **200** when push-source accepts it. Since `ConsentService.normalizeValidUntil`
(push-source fa775720, 2026-10-16) it returns **400** for a `validUntil` that is not
`unlimited`, `-1`, empty, an epoch in seconds or milliseconds between 2010 and 2040, or an ISO-8601
date. A raw duration such as `31536000`, or `0`, is a 400. Before INT-5956 the SDK sent exactly
that. A consent rejected three times in a row (any status at 300 or above except 403, 404, 408, 429
and 5xx; 401 and 402 included) is dropped with an error log. The retryable ones are kept and
retried, and a consent still undelivered after 30 days is dropped.

## `POST /{org}/projects/{project}/optimization/choose-api`

Body — note the nested `identification` object. The authority is
`ExperienceApiChooseRequest.java` in `audience-service`, read at `origin/main`
= `97fa27d`, not the JS SDK's `ChoicesRequestModel`. There is no
`optimizationType` discriminator: that field is dead on the wire and nothing
reads it.

```json
{
  "identification": {"sourceId":"…","profileId":"…","userId":"…"},
  "names":     ["…"],  // optional — filters to these selector names
  "groups":    ["…"],  // optional — filters to these selector groups
  "device":    "…",    // optional — all | desktop | mobile, and NOTHING else
  "sessionId": "…",    // optional
  "productId": "…",    // optional
  "timestamp": 0       // optional
}
```

`names` **exists and is a first-class filter.** This document said it did not
until 2026-08-31, and that sentence cost a reviewer a false CRITICAL against
another SDK's flag surface, which the reviewer believed could never work.
`ExperienceChooserService.chooseApi` passes it straight into
`experienceService.retrieveApiExperiences(request.getGroups(),
request.getNames(), …)`. Omitting `names` returns every experience the person
qualifies for, which is what a bulk `allFlags()` read is.

`device` deserialises into the `ExperienceDevice` enum, whose only members are
`all`, `desktop` and `mobile`. It carries `@JsonValue` and no `@JsonCreator`,
and `application.yml` sets `accept-case-insensitive-enums: true` — which fixes
CASE, not vocabulary. Any other string fails to bind and takes the whole
request with it, so every flag read returns the caller's default, silently.

Returns **200** with `ExperienceApiChooseResponse{ List<ExperienceApiChoose> }`,
where each choice is `{name, group, body}` and `body` is an arbitrary JSON node:

```json
{"choices":[{"name":"new_checkout","group":"banner","body":true}]}
```

There is **no `reason` field**, and no `variant`, `target`, `changes`,
`updatedAt` or `experience`. `git grep -n reason` over
`audience-service/src/main/java/com/intempt/cdp/audience/experience/` returns
0. The shape with `target`/`changes`/`variant` documented here until
2026-08-31 was **choose-web's**, printed under a `choose-api` heading directly
above the paragraph insisting the two are not interchangeable.

`identification` alone is sufficient — a request with no `names`, `device` or
`sessionId` still returns 200. Omitting `identification` returns **400**
`{"errors":[{"message":"Identification is required"}]}`.

`choose-api` is the native endpoint; `choose-web` is the browser one. They are
separate registrations on the same service and are **not** interchangeable.
A body or a response shape copied from one into the other is the recurring
mistake, and the two corrections above are both instances of it.

## `POST /{org}/projects/{project}/feeds/{feedId}/data`

Flat body — **not** `identification`-wrapped, unlike `choose-api`. The profile
is sent as `id` + `type: "profile"` (audience-service `FeedRequest`; intemptjs and
intempt-android send the same body):

```json
{"id":"…","type":"profile","sourceId":"…","limit":10,"fields":["title","price","imageUrl"],"productId":"…"}
```

`FeedRequest` has no `profileId` field. A flat `profileId` is silently dropped:
the profile is never resolved and a `USER`-input feed returns **200 with an empty
`products` array** (INT-5952). `type` is required whenever `id` is set
(`user`, `account` or `profile`).

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
| `USER` | `id` + `type: "profile"` |
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

## Transient 400s

Production has been observed returning **400 to a payload it accepts moments
later**. A 55-event drain failed its first batch with a 400; the identical
bytes then returned 201 on six consecutive retries.

Superseded 2026-11-11: Beso ruled the SDK matches intempt-android (R-retry, D9,
INT-7438). A batch answered with a non-retryable status (anything at 300 or above
except 403, 404, 408, 429 and 5xx) is dropped on the **first** answer, 401 and
402 included. Known cost: a repeat of the transient 400 above now loses that
batch, and the live multi-batch drain test fails on it.

Live tests still retry the flush, which covers 5xx, 429 and network failures;
they no longer survive a transient 400.

## Batch size

Verified accepted at 10, 20, 25, 30, 40 and 50 entries (8,692 bytes at 50). No
size-based rejection was observed, so `maxBatchSize` stays at 50 to match
intemptjs's `RequestBatcher`.

## `type` is not validated

A batch entry with `"type":"notARealType"` returns **201**, as does an entry
with no `type` field at all. The discriminator is not enforced at ingestion.

This is why `SessionModel` omits `type` entirely rather than inventing one:
matching intemptjs's `SessionEventModel`, which has run in production for
years, is safer than a value that merely looks tidier.

## Retry-After

No `Retry-After` header was observed on any success or 4xx response. The
`RetryPolicy` honours it as a floor when present and falls back to its own
exponential curve when absent, so its absence is not a problem — but it means
the header path is covered only by unit tests, not by a live observation.
