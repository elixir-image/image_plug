# `Image.FaceDetection` lives in the optional sibling library
# `:image_vision`. The calls in `Image.Plug.FaceAware` are guarded
# by `Code.ensure_loaded?/1` and `@compile {:no_warn_undefined,
# Image.FaceDetection}` so the compiler stays quiet, but dialyzer
# still sees them as unknown when `:image_vision` is not built.
[
  ~r/lib\/image\/plug\/face_aware\.ex:.*unknown_function.*Image\.FaceDetection/
]
