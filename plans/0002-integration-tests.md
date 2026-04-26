# Plan 0002 — Integration test environment for `image_plug` and `image_components`

Status: draft, awaiting review.

## 1. Goals

* Stand up an HTTP-level integration harness for `image_plug` so requests are exercised end-to-end through a real socket, not via the synthetic `Plug.Test.conn/3` already used in unit tests. Catch issues unit tests cannot — chunked-transfer behaviour, real `Accept` parsing, real `If-None-Match` round-trips, real source streaming.

* Use property-based testing (StreamData) to systematically exercise every Cloudflare option in valid and invalid configurations. Catch corner-case regressions a fixed-example suite would miss.

* Build a parallel integration harness for `image_components` that uses the component to render `<.image>` / `<.picture>` markup, parses the rendered URLs, and fetches each via a running `image_plug`. Closes the loop: every URL the component emits is one the plug accepts, and every byte the plug returns matches the markup's promise.

* Vendor a curated subset of test images from the `Image` library (`../image/test/support/images/`) so this work doesn't depend on Image's internal test fixtures staying put.

## 2. Non-goals

* Performance / load testing — outside scope; tests are correctness-only.

* Fuzzing the underlying `Image`/libvips primitives — those have their own coverage in the `Image` library.

* Browser-level rendering tests of the `<picture>` markup — we verify the markup shape and the URL byte responses; rendering correctness is the browser's contract.

* Visual regression on the produced images. The decoder verifies dimensions and basic shape; pixel-perfect comparison is out of scope.

## 3. Test infrastructure

### 3.1 Vendored fixtures

Copy a small curated subset from `../image/test/support/images/` into `image_server/test/fixtures/images/` (most files already exist; the new ones augment coverage). The subset is small (each file < 200 KB except `aircraft.HEIC` which we may skip) and exists so the test suite is self-contained.

Curated set:

| Source filename | Local name | Size | Why |
| --- | --- | --- | --- |
| `Kip_small.jpg` | `portrait.jpg` | 21 KB | Small JPEG with EXIF — exercises `metadata=` policy and rotation. |
| `Kip_small.png` | `portrait.png` | 67 KB | Same content as PNG — exercises format negotiation. |
| `Kip_small_rotated.jpg` | `portrait_rotated.jpg` | ~ | EXIF rotation tag — verifies auto-rotate behaviour. |
| `penguin_with_alpha.png` | `alpha.png` | 41 KB | Transparency — exercises `background=` flatten. |
| `2x2-maze.png` | `tiny.png` | 0.5 KB | Smallest possible PNG — bounds tests. |
| `Sydney-Opera-House-BW.jpg` | `landscape.jpg` | 156 KB | Wide aspect ratio — exercises fit modes. |
| `puppy.webp` | `sample.webp` | 87 KB | Source format coverage. |
| `animated.webp` | `animated.webp` | 37 KB | Multi-frame — exercises `anim=`. |
| `jose.png` | `large.png` | 95 KB | A larger PNG for resize-down assertions. |

The existing `sample.jpg` (640×480 solid colour) and `sample.png` (generated programmatically in M2) stay — they're cheap to regenerate and useful for "did the encoder emit valid bytes" sanity. The existing `watermark.png` stays for overlay tests.

A small shell script `test/fixtures/vendor_images.sh` documents the source paths and license. The Image library's images are MIT-licensed via that repo; we attribute in `test/fixtures/images/README.md`. Git-add the vendored files; do not run the script in CI.

### 3.2 HTTP harness for `image_plug`

A new test-support module `Image.Plug.IntegrationCase` does the following in `setup_all`:

* Starts a Bandit server on a random free port (`Bandit.start_link(plug: build_plug(opts), port: 0)`).

* Captures the assigned port from `Bandit.runtime_info/1`.

* Returns `%{base_url: "http://127.0.0.1:#{port}", port: port}` to tests.

* `setup` (per-test) is a no-op — the server stays up across the test module.

The test module configures the plug:

```elixir
defmodule MyIntegrationTest do
  use Image.Plug.IntegrationCase,
    provider: {Image.Plug.Provider.Cloudflare, []},
    source_resolver: {Image.Plug.SourceResolver.File, root: "test/fixtures/images"},
    on_error: :status_text
end
```

`use` macro generates the `setup_all` and the `request/2` helper (returns a `{status, headers, body}` tuple via `Req.get/2`). HTTP client: `Req`. Already a transitive dep via `image`.

`async: false` for any module using this case — Bandit binds a real socket.

### 3.3 HTTP harness for `image_components`

Two-process setup. The integration test in `image_components` needs a running `image_plug` to fetch from:

* Add `{:image_plug, path: "../image_server", only: :test}` to `image_components/mix.exs`. Path-dep is fine because both packages live in the same workspace; it does not affect Hex publishing.

* Mirror `Image.Plug.IntegrationCase` in `image_components` as `Image.Component.IntegrationCase` — same Bandit-on-random-port pattern, but mounts an `image_plug` configured with the vendored fixtures (also vendored into `image_components/test/fixtures/images/`).

* The case exposes both the `base_url` of the running plug and a render helper that wires `host:` into the component so generated URLs target it.

Test flow per case:

1. Render component with assigns → HTML string.
2. Parse with Floki, extract every `srcset` URL and the `src`.
3. For each URL: `Req.get(url)` → assert 200, decode the body via `Image.from_binary/1`, assert width matches the URL's `width=` parameter.
4. Optionally assert `<picture>` shape (number of `<source>`, `type` ordering).

### 3.4 Property-test framework

* Add `{:stream_data, "~> 1.1"}` to both packages as `only: [:test]`.

* Use ExUnit's `property` macro from `ExUnitProperties`. Default `max_runs: 100`.

* Property tests live alongside example-based tests: `test/image/plug/integration/properties_test.exs`, `test/image/component/integration/properties_test.exs`. Naming convention `_properties_test.exs` makes them easy to run in isolation (`mix test --include property`).

* All properties accept a configurable seed via `STREAM_DATA_SEED` env var so failures reproduce. Document in the case module's moduledoc.

## 4. `image_plug` integration test design

### 4.1 Generator catalog

A new module `Image.Plug.TestGenerators` (under `test/support/`) defines one generator per Cloudflare option key — both a `valid_*` and an `invalid_*` variant.

```elixir
def valid_width, do: integer(1..4096)
def invalid_width, do: one_of([integer(-100..0), constant("not_an_integer"), constant("")])

def valid_fit, do: member_of([:contain, :cover, :crop, :pad, :scale_down, :squeeze])
def invalid_fit, do: filter(string(:ascii, max_length: 12), &(&1 not in known_fits()))

def valid_quality, do: one_of([integer(1..100), member_of(["high", "medium-high", "medium-low", "low"])])
def invalid_quality, do: one_of([integer(101..1000), integer(-100..0), constant("very_high")])

# ... one pair per option key (gravity, dpr, format, metadata, anim, compression, ...)

def valid_options_string, do:
  list_of(valid_option_pair(), max_length: 6)
  |> map(&Enum.map(&1, fn {k, v} -> "#{k}=#{v}" end))
  |> map(&Enum.join(&1, ","))
```

Helpers:

* `valid_option_pair` — picks a random key from the supported set and emits `{key, valid_value_for_key}`.

* `invalid_option_pair` — same but with one component invalid.

* `mixed_options_string` — a random mix where exactly N of M components are invalid; tests should confirm the request errors with the *first* invalid component's tag.

### 4.2 Compliant-request property suite

For each option key that produces an observable effect on the output bytes, a property of the form:

```elixir
property "width=N produces an image whose decoded width is N (or close to it after fit)" do
  check all width <- valid_width(),
            source <- member_of(["portrait.jpg", "landscape.jpg"]) do
    {:ok, response} = request("/cdn-cgi/image/width=#{width}/#{source}")
    assert response.status == 200
    {:ok, decoded} = Image.from_binary(response.body)
    assert Image.width(decoded) == width
  end
end
```

Property catalogue (one per option, where applicable):

| Property | Assertion |
| --- | --- |
| `width` produces correct decoded width | `Image.width(decoded) == width` |
| `height` produces correct decoded height | `Image.height(decoded) == height` |
| `fit=cover` with both width+height fills the box exactly | both dims match |
| `fit=scale_down` never upscales | output dims ≤ source dims |
| `format=jpeg/png/webp` produces correct magic bytes | `binary_part(body, 0, 3)` matches table |
| `format=auto` with `Accept: image/webp` returns WebP | content-type matches |
| `quality=N` produces a smaller body for lower N (statistical) | quality 50 < quality 90 (one-shot, not property) |
| `rotate=N` swaps dimensions when N is 90 or 270 | dim-swap match |
| `flip=h` produces the same dimensions | dims unchanged |
| `dpr=N` multiplies output dimensions by N | width × N |
| `metadata=none` strips EXIF | `Image.exif/1` returns `{:error, :no_metadata}` |
| `background=#hex` flattens transparency | source pixel at (0,0) matches hex when source had alpha |
| `gravity=north_west` cover-crops to the top-left | sample pixel matches source's top-left |

Each property runs N=100 examples by default, with `max_shrinking_steps: 50`. A failed property reports the seed for reproduction.

### 4.3 Invalid-request property suite

Inverse properties, one per option key:

```elixir
property "out-of-range width returns 400 :invalid_option" do
  check all bad_width <- invalid_width() do
    {:ok, response} = request("/cdn-cgi/image/width=#{bad_width}/portrait.jpg")
    assert response.status == 400
    assert ["invalid_option"] == get_header(response, "x-image-plug-error")
  end
end
```

Inverse property catalogue:

| Property | Expected status | Expected error tag |
| --- | --- | --- |
| Invalid width / height / dpr | 400 | `invalid_option` |
| Invalid fit / format / metadata / gravity | 400 | `invalid_option` |
| Invalid quality (out of 1..100) | 400 | `invalid_option` |
| Invalid rotate (not 90/180/270) | 400 | `invalid_option` |
| Invalid flip (not h/v/hv) | 400 | `invalid_option` |
| Unknown option key (strict mode) | 400 | `unknown_option` |
| Malformed `XxY` gravity | 400 | `invalid_option` |
| Malformed `trim=` segment count | 400 | `invalid_option` |
| Malformed URL (no /cdn-cgi/image/) | 400 | `malformed_url` |
| Source not found | 404 | `source_not_found` |
| Unknown variant (hosted form) | 404 | `variant_not_found` |
| Source path with `..` | 400 | `invalid_option` |

### 4.4 Composition properties

Combine N options in one URL and validate behaviour stays consistent:

* **All-valid composition**: `valid_options_string` of length 1..6 → response 200, body decodes, no error header. Property runs over the cross-product implicitly via random combinations.

* **One-bad composition**: take a valid options list, replace exactly one entry with its invalid counterpart. Expect 4xx with the invalid entry's expected tag. (The parser short-circuits on first invalid entry; the test confirms this.)

* **Order independence**: for any valid options list, shuffling the order produces the same ETag and the same body bytes. Confirms the normaliser canonicalises correctly.

* **Cardinality enforcement**: emit two `width=` entries → 400 (later one wins per Cloudflare; we don't yet enforce uniqueness in the parser — this property surfaces the gap and the resolution may be a parser tweak).

### 4.5 Named end-to-end cases

Beyond properties, a hand-written cases file `test/image/plug/integration/end_to_end_test.exs` covers:

* **ETag round-trip**: GET, capture ETag, GET with `If-None-Match` → 304 with empty body, no Bandit chunked frames.

* **AVIF fallback**: `format=avif` request when `Image.Plug.Capabilities.avif_write?/0` returns false → 200 with `content-type: image/webp` and `x-image-plug-format-fallback: avif->webp`.

* **Chunked streaming**: assert the response is `transfer-encoding: chunked` (no `content-length`) for image bodies, and that `Req.get(url, into: stream_fn)` receives multiple chunks for a > 100 KB input. Confirms the streaming pipeline isn't accidentally collected into one buffer.

* **Variant resolution**: seed `"thumbnail"` via `Image.Plug.put_variant/2` in `setup_all`, fetch hosted form `/<acct>/portrait.jpg/thumbnail` → 200, decoded width matches the seeded variant's width.

* **HTTP source resolver**: spin up a Bypass instance inside the test serving a fixture file, mount the plug with `SourceResolver.HTTP` allow-listed at `localhost`, fetch `/cdn-cgi/image/width=200/http://localhost:<bypass-port>/x.jpg`. Asserts the streaming HTTP source works under real I/O.

* **`on_error` policies**: separate cases for `:status_text`, `:render_error_image` (response is PNG with magic bytes + tag header), `:fallback_to_source` (response is the source bytes when the pipeline fails after load).

* **Telemetry**: attach a handler in `setup_all`, assert `[:image_plug, :request, :stop]` fires with the expected metadata for both success and failure cases.

## 5. `image_components` integration test design

### 5.1 Render-then-fetch loop

The core integration assertion: every URL the component emits is one a real `image_plug` accepts.

```elixir
defmodule Image.Component.IntegrationTest do
  use Image.Component.IntegrationCase

  test "constrained <.image> srcset URLs all return 200 with correct widths", ctx do
    html =
      render_component(&Image.Component.image/1, %{
        src: "/portrait.jpg",
        alt: "p",
        width: 800,
        height: 600,
        sizes: "100vw",
        host: ctx.image_plug_host
      })

    [img] = Floki.find(Floki.parse_fragment!(html), "img")
    [srcset] = Floki.attribute(img, "srcset")

    for {url, expected_width} <- parse_srcset(srcset) do
      {:ok, response} = Req.get(url)
      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      assert Image.width(decoded) == expected_width
    end
  end
end
```

`Image.Component.IntegrationCase`:

* `setup_all` starts an `image_plug` Bandit on a random port, configured with `SourceResolver.File` rooted at the test fixtures.

* Returns `%{image_plug_host: "127.0.0.1:<port>"}` so the component knows what to target.

* Provides `parse_srcset/1` and `parse_sources/1` Floki-based helpers.

### 5.2 Layout-mode coverage

One end-to-end test per layout mode:

* `:constrained` — width-descriptor srcset → every URL returns 200 with the descriptor's width.

* `:fixed` — density-descriptor srcset (`1x`, `2x`, `3x`) → URL i returns an image of width = base_width × i.

* `:full_width` — same as constrained but ladder differs.

### 5.3 `<picture>` markup verification

* `<.image formats={[:avif, :webp]}>` end-to-end: `<source type="image/avif">` URLs return AVIF (or WebP via fallback if libvips lacks AVIF) with correct widths. Same for WebP. Fallback `<img>` returns the default format.

* `<.picture>` art-direction end-to-end: each `<source media>`'s URLs return images of the per-source intrinsic width. Fallback `<img>` returns the fallback's width.

### 5.4 Error-path coverage

* Component generates a URL pointing at a missing source → fetch returns 404 with `x-image-plug-error: source_not_found`. Confirms the error path is exposed end-to-end and the component does not silently mask backend errors.

* Component with a custom `:url_options` carrying an unknown key → fetch returns 400 with `x-image-plug-error: unknown_option`. Confirms options pass through verbatim.

### 5.5 Property test (image_components)

A single small property:

```elixir
property "every component-generated srcset URL returns 200 with the descriptor's width" do
  check all width <- integer(64..1024),
            layout <- member_of([:fixed, :constrained, :full_width]) do
    html = render_with(width: width, layout: layout, host: ctx.image_plug_host)
    for {url, expected_w} <- parse_srcset_from(html) do
      {:ok, response} = Req.get(url)
      assert response.status == 200
      {:ok, decoded} = Image.from_binary(response.body)
      assert Image.width(decoded) == expected_w
    end
  end
end
```

Catches drift between `Image.Component.URL`'s grammar and `Image.Plug.Provider.Cloudflare.Options`' parser. If anyone changes one without the other, this property fails.

## 6. Phasing

Each phase is independently shippable with its own four-check DoD gate.

**Phase A — fixtures + harness skeleton.** Vendor the fixture set into both packages with the README + license note. Create `Image.Plug.IntegrationCase` and `Image.Component.IntegrationCase`. Add `:stream_data` and `:req` (test-only) to both. Verify the harnesses boot and one trivial test passes per package.

**Phase B — `image_plug` named end-to-end cases (§4.5).** Hand-written, no properties yet. Covers the cases unit tests can't (chunked transfer, ETag round-trip, AVIF fallback at the wire level, `:render_error_image` byte verification, telemetry under real I/O). Highest signal per line of code.

**Phase C — `image_plug` generator catalog + compliant property suite (§4.1, §4.2).** Build `Image.Plug.TestGenerators`, then the per-option compliant properties. Stop after each option to confirm the property green-lights before moving on.

**Phase D — `image_plug` invalid + composition properties (§4.3, §4.4).** The inverse properties + composition. Cardinality property is expected to fail initially (parser doesn't enforce uniqueness yet); plan resolves either by tightening the parser or relaxing the property — flag for review.

**Phase E — `image_components` harness + render-then-fetch loop (§5.1).** Path-dep on `image_plug`, mirror the case module, write the first end-to-end test (one constrained image).

**Phase F — `image_components` layout-mode + `<picture>` coverage (§5.2, §5.3).** One named test per shape.

**Phase G — `image_components` error-path + property test (§5.4, §5.5).** Closes the loop on URL-grammar drift.

## 7. Definition of done (per phase)

The standard four-check gate, plus:

* `mix test --only property` runs cleanly with at least 100 examples per property.

* Property failures emit a reproducible seed (default StreamData behaviour; we just confirm it works).

* `STREAM_DATA_SEED=<n> mix test path/to/property_test.exs` reproduces a specific failure.

* CI runtime budget: integration suite under 30 seconds per package on a developer laptop. Properties dominate; if they exceed the budget, tighten generators (smaller `max_runs` for the most expensive properties) before declaring done.

## 8. Open questions

1. **HTTP client.** `Req` is the obvious choice — already a transitive dep, friendly API. Confirm before adding to `image_plug`'s test deps. Alternative: bare `:httpc` (zero deps, ugly API). Recommendation: `Req`.

2. **Path-dep direction.** §3.3 proposes `image_components/test` depending on `image_plug` via `path:`. The reverse (`image_plug/test` depending on `image_components`) makes no sense — `image_plug` doesn't generate component markup. Confirm the path-dep direction.

3. **Property runs in CI vs local.** Default 100 runs locally is fine; CI can stay at 100 unless suite runtime suffers, in which case `--max-runs 25` for CI via env var. Decide before Phase C.

4. **Cardinality of duplicate option keys.** §4.4 surfaces that the parser currently accepts `width=200,width=400` (last wins). Cloudflare's behaviour is also "last wins" per their docs. Should we keep it, or treat duplicates as `:invalid_option`? The property is the forcing function; pick a side now to avoid churn.

5. **Vendoring license note.** The Image library's test fixtures don't have an explicit per-file license file. Need to confirm with @kipcole9 (project owner) that vendoring is fine, or use only files we can produce ourselves (the M2 `sample.jpg`/`sample.png` were Image-generated solid colours — we can produce more of those).

6. **Telemetry assertions in property tests.** Property tests + `assert_received` is finicky (handlers can race when 100 examples run in parallel). Recommendation: keep telemetry assertions in named-case tests (Phase B), out of the property suite.

7. **Bandit vs Cowboy.** §3.2 picks Bandit for the harness. `image_plug` already has it as a dev/test dep. No reason to use Cowboy. Confirm.

Once these are answered we close out the open questions and proceed with Phase A.

