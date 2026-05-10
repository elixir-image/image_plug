# Face-aware crops, zoom, and pixelation

This guide describes how `image_plug` integrates with the optional [`image_vision`](https://hex.pm/packages/image_vision) library to add face-aware behaviour to the IR. It covers the seam (`Image.Plug.FaceAware`), the per-provider URL grammar that drives it (`gravity=face`, `face-zoom=…`, `z_…`, `z-…`, `crop=faces`), the runtime model loading, and the graceful fallback when `image_vision` is not in the consumer's dependency tree.

## Why a seam, not a hard dep

`image_plug` does not declare `:image_vision` as a dependency. The face-detection model — YuNet ONNX, ~340 KB on disk plus the Ortex / Nx / EXLA runtime — adds tens of megabytes to the dependency closure and ML build complexity that not every consumer wants. Apps that don't need face-aware behaviour pay nothing.

The integration point is `Image.Plug.FaceAware`. It calls into `Image.FaceDetection` only after a runtime `Code.ensure_loaded?/1` check, with `@compile {:no_warn_undefined, Image.FaceDetection}` so the build stays clean when the optional dep is absent. When `image_vision` is not loaded, every function in the seam returns `{:error, :unavailable}` and the interpreter routes around it transparently — face-aware requests fall back to libvips' attention-based saliency crop, which is a reasonable approximation in most cases.

## What gets face-aware behaviour

Two operations in the IR consume face detections:

* `Ops.Resize{gravity: :face, face_zoom: float}` — pre-crops the image to the most prominent detected face plus padding (derived from `face_zoom`) before the regular thumbnail resize pass. The thumbnail then sees a face-centred region and produces a face-centred result. With `:image_vision` absent or with no detected face, the existing `:attention` saliency crop takes over.

* `Ops.PixelateFaces{scale: float}` — detects every face above the confidence threshold and pixelates each region in place, leaving the rest of the image untouched. With `:image_vision` absent, the op is a no-op (the original image is returned unchanged).

## URL grammar across the four providers

The same IR field — `Resize.face_zoom`, a float in `[0.0, 1.0]` — is expressed differently in each provider's URL:

| Provider | Token | Range | Notes |
| --- | --- | --- | --- |
| Cloudflare | `face-zoom=<float>` | `[0.0, 1.0]` | Pairs with `gravity=face`. Default `0.0` is dropped from the URL. |
| Cloudinary | `z_<float>` | `[0.0, 1.0]` | Pairs with `g_face`. Added in this version of `image_plug`'s parser. |
| imgix | — | — | imgix's URL grammar has no face-zoom equivalent. The IR field is silently dropped on URL projection. |
| ImageKit | `z-<float>` | `[0.0, 1.0]` | Pairs with `fo-face`. |

Gravity itself rides alongside:

| Provider | Face gravity token |
| --- | --- |
| Cloudflare | `gravity=face` |
| Cloudinary | `g_face` |
| imgix | `crop=faces` |
| ImageKit | `fo-face` |

`Image.Components.URL.<provider>/2` emits the right token for each. The four URLs round-trip back to the same IR through the matching parser in `image_plug`.

## Semantics of `face_zoom`

`face_zoom` is the *tightness* of the face-aware crop, not a literal zoom factor:

* `face_zoom = 0.0` (the default) gives a loose crop — the bounding box is expanded by a full `padding = 1.0` on each side, which often means the entire image. The downstream resize pass then sees the same input as a normal `gravity=center` request, and the output is indistinguishable from a centred crop. **This is the most common reason a user reports "I picked `gravity=face` and nothing happened"** — the answer is to also give `face_zoom` a non-zero value.

* `face_zoom = 0.6` (Cloudflare's documented default) gives a moderately tight crop with some context around the face. This is a good general-purpose setting for portrait thumbnails.

* `face_zoom = 1.0` hugs the face bounding box — the resulting crop is essentially the face with no surrounding context.

The mapping inside `Image.Plug.FaceAware.face_crop/2` is `padding = max(1.0 - face_zoom, 0.0)`, so the relationship between `face_zoom` and bounding-box padding is linear and inverse.

## Behaviour when no face is detected

`Image.FaceDetection.crop_largest/2` returns `{:error, :no_face_detected}` when nothing scores above the YuNet confidence threshold (default `0.6`). The interpreter catches this and falls through to the normal thumbnail flow with the original image and the original `gravity` setting. The request still succeeds — you don't see a placeholder; you get a saliency-based crop.

## Model loading

The first request that invokes face detection downloads the YuNet ONNX weights (`face_detection_yunet_2023mar.onnx`, ~340 KB) from HuggingFace into `image_vision`'s model cache directory:

* On macOS: `~/Library/Caches/image_vision/opencv/face_detection_yunet/`
* In a container: configure via `:image_vision, :cache_dir` (typically a mounted volume — see the `image_playground` Dockerfile).

The download happens once per cache directory. Subsequent requests load the model from `:persistent_term` and run inference on every face-aware request.

## Wiring it into your app

Add `:image_vision` to your dependencies:

```elixir
def deps do
  [
    {:image_plug, "~> 0.1"},
    {:image_vision, "~> 0.3"},
    # image_vision's ML stack:
    {:ortex, "~> 0.1"},
    {:nx, "~> 0.10"},
    {:exla, "~> 0.10"}
  ]
end
```

That's it — no further configuration is required. `Image.Plug.FaceAware.available?/0` flips to `true` on next boot and the interpreter starts honouring `gravity: :face` and `Ops.PixelateFaces`. To verify end-to-end, point a Cloudflare URL at a known face image:

```
GET /cdn-cgi/image/width=300,height=300,fit=cover,gravity=face,face-zoom=0.6/portrait.jpg
```

Compare the bytes against the same URL with `gravity=center,face-zoom=0` (the default) on an image that has a face well off-centre — different MD5s prove face detection ran.

## Related

* `Image.Plug.FaceAware` — the seam itself; `available?/0`, `face_crop/2`, `pixelate_faces/2`.
* `Image.FaceDetection` — the underlying detector in `image_vision`.
* `image_components/guides/usage.md` — how to drive `face_zoom` through the `<.image>` Phoenix.Component.
* `image_playground` — exercises this end-to-end with a slider per parameter.
