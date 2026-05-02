# TODO

Follow-ups captured during development. Items here are not blockers for the current milestone but should be addressed before the v0.1 release.

## Streaming pipeline construction — DONE

Aligned `Image.Plug.SourceResolver.File` (now uses `File.stream!(path, 2048, []) |> Image.open()`) and documented the full source→encoder→conn chain in `Image.Plug.Pipeline.Encoder`'s moduledoc, citing the [`stream_image_test.exs`](https://github.com/kipcole9/image/blob/main/test/stream_image_test.exs) reference shape. Added `Image.Plug.StreamingPipelineTest` as a regression that exercises both the verbatim Image-library chain and our plug end-to-end (asserting `conn.state == :chunked`). The encoder stays conn-agnostic (returns `{:stream, Enumerable.t()}`); the plug does the `Plug.Conn.chunk/2` reduce so we keep the conn for header manipulation, error fallbacks, and telemetry — equivalent to what `Image.write(image, conn, suffix: ext)` does internally.

## Operation sequence constraints — DONE

`Image.Plug.Pipeline.Normaliser` rewritten to enforce a Sharp-style canonical order (Trim → Background → Resize → Rotate → Flip → Border → Adjust → Blur → Sharpen → Draw → Segment) regardless of the order the provider emits the ops in. Cardinality enforced for every single-instance op kind. Extended no-op folding (Adjust all-1.0, Sharpen/Blur sigma 0, Flip nil direction, Border/explicit Trim all-zero sides). 13 new regression tests including the explicit "Resize lands before any post-resize op no matter when the user appends it" case the original TODO called out.

## LiveView image-tag component — MOVED to `:image_components`

Spun out into a sibling package at `/Users/kip/Development/image/image_components/` (mix app `:image_components`, module namespace `Image.Component.*` — singular namespace, plural package name to match the existing project slot). The earlier one-line `image_components` placeholder was deleted in the same change. Hard dep on `:phoenix_live_view`. Self-contained — its own Cloudflare URL builder; no dep on `:image_plug` (the two packages share the URL grammar, not code).

Includes the full unpic-style port: layout modes (`:fixed | :constrained | :full_width`) with CLS-prevention CSS, both width-descriptor and density-descriptor srcsets, format-fallback `<picture type>` markup, art-direction `<picture media>` markup (`Image.Component.Picture.picture/1`), and a `:host` option for cross-host CDN setups (mirrors unpic's `domain`).

See `image_components`'s own README and CHANGELOG for any further follow-ups.

## Image sibling library: operations needed by CDN adapters — MOSTLY DONE

`Image` 0.67.0 landed the Group A and Group B helpers; `image_plug` now wires every one of them through to its providers. The sections below capture what shipped and what's still outstanding.

### Shipped in `Image` 0.67.0 + wired into `image_plug`

* **`Image.gamma/2`** — `image_plug`'s interpreter now calls this directly instead of dropping into `Vix.Vips.Operation.gamma`. Used by Cloudflare/imgix/Cloudinary `gamma` / `gam` / `e_gamma`.

* **Selective EXIF preservation** — `Image.minimize_metadata/2` accepts a `:keep` list. Cloudflare `metadata=copyright` is now wired end-to-end in `Image.Plug.Pipeline.Encoder` via `keep: [:copyright, :orientation]`. Conformance ⚠️ → ✅.

* **`Image.sepia/2`** — wired into imgix `sepia=N` and Cloudinary `e_sepia[:N]`. Conformance ❌ → ✅ in both.

* **`Image.tint/2`** — wired into imgix `monochrome=<hex>` (replaces the plain-B&W workaround). Conformance ⚠️ → ✅.

* **`Image.set_orientation/2`** — wired into imgix `or=N`. The encoder snapshots and restores the `orientation` header across `Image.minimize_metadata/2` so the override survives metadata stripping. Conformance ❌ → ✅.

* **`Image.posterize/2`** — wired into Cloudinary `e_cartoonify[:level_count]`. Conformance ❌ → ✅.

* **`Image.pixelate/2`** — wired into Cloudinary `e_pixelate[:block_size]`. Conformance ❌ → ✅. (Imgix's `px=N` is still ⚠️ — `Image.pixelate/2` exists but the imgix parser hasn't been wired; trivial follow-up if anyone needs it.)

* **`Image.fade/2`** — wired into Cloudinary `e_fade[:N]` (bottom-edge fade). Conformance ❌ → ✅. Cloudinary's directional flavours (`e_fade_top` etc.) aren't modelled.

* **`Image.opacity/2`** — wired into Cloudinary `o_<n>` (0..100 percentage). Conformance ❌ → ✅.

* **`Image.rounded/2`** — wired into Cloudinary `r_<n>` / `r_max`. Already SVG-mask-based in `Image`, no draw functions involved. Conformance ❌ → ✅.

* **`Image.drop_shadow/2`** — wired into ImageKit `e-shadow[-bl-<n>_st-<n>_x-<n>_y-<n>_c-<hex>]`. Conformance ❌ → ✅.

* **Encoder `:lossy`, `:progressive`, `:chroma_subsampling` flags** — `Image.write/3` accepts all three; `image_plug`'s `Format` IR carries them through; Cloudinary `fl_lossy` / `fl_progressive` and ImageKit `lo-` / `pr-` / `cp-` are wired to set them. Conformance ❌ → ✅ in Cloudinary and ImageKit.

### Shipped in the follow-up cycle

* **`Image.enhance/2`** — luminance equalisation + saturation boost + sharpen. Wired into Cloudinary `e_improve` / `e_auto_brightness` / `e_auto_color` / `e_auto_contrast`, imgix `auto=enhance`, ImageKit `e-retouch`. ⚠️ in conformance guides because the hosted versions are ML-driven (we approximate).

* **`Image.vignette/2`** wired into Cloudinary `e_vignette[:N]`. ❌ → ✅.

* **imgix `px=N`** wired to `Image.pixelate/2`. ❌ → ✅.

* **ImageKit `ar-<W>-<H>`** wired (provider-side dimension derivation, no `Image` change). ❌ → ✅.

* **ImageKit `z-<n>`** wired to the existing `face_zoom` field on Resize (parsed and stored, interpreter is still a no-op pending face detection in `:image`). ❌ → ⚠️.

### Still outstanding

* **ICC profile colourspace** — `Image.to_colorspace/3` shipped in `:image` 0.67. The IR has `Ops.IccTransform{profile, intent}` and the interpreter is wired. Custom-ICC paths (Adobe RGB, ProPhoto) are deliberately *not* synthesised from URL strings — `cs_adobergb1998` / `cs=adobergb1998` still return `:unsupported_option`. Construct `IccTransform` ops directly when composing pipelines, or add an application-level `:icc_aliases` option to map URL tokens onto known profile paths.

* **Auto-quality model** — content-aware quality picker for Cloudinary `q_auto`. Out of scope for `Image`; would need a calibrated heuristic.

* **Animated-image frame trim** — ImageKit `tr=t-<from>-<to>`. Needs `Image.extract_frames/3` or a pages-by-time-range helper.

* ~~**Face-aware crop / zoom** — needs face detection in `:image` (probably via `:image_vision`). The IR fields exist (`face_zoom`, `gravity: :face`) but the interpreter doesn't act on `face_zoom` yet.~~ **Shipped.** `Image.Plug.FaceAware` wraps `Image.FaceDetection.crop_largest/2` (gated behind `Code.ensure_loaded?/1`) and the interpreter pre-crops to the largest face when `gravity: :face` is set. `face_zoom` controls padding (`0` = loose context, `1` = tight crop). `Ops.PixelateFaces` (Cloudinary `e_pixelate_faces`) pixelates only the detected face regions. All face-aware ops fall back gracefully when `:image_vision` is absent.

* **Auto-contrast (content-aware)** — ImageKit `e-contrast` is currently approximated as `Adjust{contrast: 1.1}`. A content-aware version (one of the `enhance/1` family) would be sharper.

* **AI-driven background removal** — `Image.Background.remove/2` and `Image.Background.mask/2` ship in `:image_vision` (BiRefNet-lite via Ortex). The wire-up pattern is the same one used for face detection (see `Image.Plug.FaceAware`): an `Ops.RemoveBackground{}` IR op whose interpreter clause delegates to `Image.Background.remove/2` only when `Code.ensure_loaded?(Image.Background)` is true. Maps to ImageKit `e-bgremove` / `e-removedotbg`. Not yet implemented.

* **Other AI-driven calls** — super-resolution, generative edits. Permanent `:image` gap (live in `:image_vision` instead).

### Notes

Each adapter ships with a documented gap matrix (`✅` / `⚠️` / `❌`) in `guides/<provider>_conformance.md`. The Group A + B work and this follow-up cycle together moved 22 entries from `❌`/`⚠️` to `✅` / `⚠️`.

## Cloudinary CDN provider + adapter — DONE

Shipped in both `image_plug` (`Image.Plug.Provider.Cloudinary` — URL recogniser, options parser, signing, wiring) and `image_components` (`Image.Component.CDN.Cloudinary` — URL builder, signing). 42 unit tests + 10 integration tests on the plug side, 18 unit tests + 2 integration tests on the component side, all passing. SHA-256 wire-format-compatible signing with the in-path `s--<sig>--` segment and 32 url-safe-base64-character truncation. Multi-stage chained transforms recognised but flattened to one comma-joined option set (the v0.1 IR doesn't model chained transforms; documented in the conformance guide as ⚠️). See `guides/cloudinary_conformance.md` for the per-option matrix and the documented gaps.

## ImageKit CDN provider + adapter — DONE

Shipped in both `image_plug` (`Image.Plug.Provider.ImageKit` — URL recogniser, options parser, signing, wiring) and `image_components` (`Image.Component.CDN.ImageKit` — URL builder, signing). 39 unit tests + 10 integration tests on the plug side, 17 unit tests + 2 integration tests on the component side, all passing. HMAC-SHA1 wire-format-compatible signing with `?ik-s=<hex>` and `?ik-t=<unix>`. Both URL forms supported on inbound (path-prefix `tr:...` and query-string `?tr=...`); the component emits the path-prefix form. See `guides/image_kit_conformance.md` for the per-option matrix and the documented gaps.

## Rename to `Image.Plug` — DONE

Mix app renamed `:image_server` → `:image_plug`; module namespace `Image.Server.*` → `Image.Plug.*` (request plug merged into the top-level `Image.Plug` module); supervisor / telemetry prefix / default ETS table / response headers / app env key / log prefix all updated; lib + test directory tree moved; README, CHANGELOG, plans, and TODO updated. The on-disk project directory is still `image_server/` — leave that for whenever the parent repo restructures, or rename in a separate filesystem-only commit.
