"""Convert htdemucs_6s to a Core ML package for on-device separation."""

from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import torch


def convert(model, out_path: Path, precision: str = "fp16"):
    import coremltools as ct
    from coremltools.converters.mil.frontend.torch import ops as torch_ops

    # nn.MultiheadAttention takes a fused kernel in eval mode, which traces to
    # a single `_native_multi_head_attention` the converter does not implement.
    # Turning the fast path off makes it trace as ordinary matmul and softmax.
    torch.backends.mha.set_fastpath_enabled(False)

    samples = int(model.segment * model.samplerate)
    example = torch.randn(1, 2, samples)

    print(f"tracing at {samples} samples ({float(model.segment):.2f}s)", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, check_trace=False)

    # Shape arithmetic arrives as a one-element array where the converter's int
    # cast wants a scalar. Unwrapping it is safe -- a length is a length.
    original_cast = torch_ops._cast

    def cast(context, node, dtype, dtype_name):
        var = context[node.inputs[0]]
        value = getattr(var, "val", None)
        if value is not None and np.shape(value) == (1,):
            from coremltools.converters.mil import Builder as mb
            context.add(mb.const(val=dtype(np.ravel(value)[0]), name=node.name))
            return
        return original_cast(context, node, dtype, dtype_name)

    torch_ops._cast = cast
    try:
        print("converting...", flush=True)
        started = time.time()
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="mix", shape=example.shape)],
            outputs=[ct.TensorType(name="stems")],
            minimum_deployment_target=ct.target.iOS17,
            compute_precision=(
                ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32
            ),
        )
    finally:
        torch_ops._cast = original_cast

    print(f"converted in {time.time() - started:.0f}s", flush=True)
    mlmodel.short_description = "htdemucs_6s: 6-stem music source separation"
    mlmodel.save(str(out_path))
    return mlmodel


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    sys.path.insert(0, "/private/tmp/claude-501/-Users-arne-Code-stems/b3cb4796-ddcd-4362-af4b-d967d7bed305/scratchpad")
    from loader import load

    from export.htdemucs_real import make_exportable

    target = Path(sys.argv[1] if len(sys.argv) > 1 else "build/htdemucs_6s.mlpackage")
    target.parent.mkdir(parents=True, exist_ok=True)
    convert(make_exportable(load()), target)
    print("saved:", target)
