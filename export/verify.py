"""Compare the Core ML model against PyTorch on a real slice of music."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch


def snr_db(reference: np.ndarray, actual: np.ndarray) -> float:
    noise = reference - actual
    power = float(np.mean(reference ** 2))
    error = float(np.mean(noise ** 2))
    if error <= 0:
        return float("inf")
    return 10 * np.log10(power / max(error, 1e-30))


def load_segment(path: Path, samples: int, offset: int = 44100 * 30) -> torch.Tensor:
    audio, rate = sf.read(str(path), dtype="float32", always_2d=True,
                          start=offset, frames=samples)
    if audio.shape[0] < samples:                       # pad a short tail
        audio = np.pad(audio, ((0, samples - audio.shape[0]), (0, 0)))
    if audio.shape[1] == 1:
        audio = np.repeat(audio, 2, axis=1)
    return torch.from_numpy(audio.T).unsqueeze(0).contiguous()


def main(mlpackage: Path, audio_path: Path):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    sys.path.insert(0, "/private/tmp/claude-501/-Users-arne-Code-stems/b3cb4796-ddcd-4362-af4b-d967d7bed305/scratchpad")
    from loader import load

    from export.htdemucs_real import make_exportable

    torch.backends.mha.set_fastpath_enabled(False)
    model = make_exportable(load())
    samples = int(model.segment * model.samplerate)
    mix = load_segment(audio_path, samples)
    print(f"input: {tuple(mix.shape)} from {audio_path.name}")

    with torch.no_grad():
        reference = model(mix).numpy()

    import coremltools as ct
    mlmodel = ct.models.MLModel(str(mlpackage))
    predicted = mlmodel.predict({"mix": mix.numpy()})
    actual = np.asarray(next(iter(predicted.values())))
    print(f"coreml output: {actual.shape}\n")

    def dbfs(x):
        rms = float(np.sqrt(np.mean(np.square(x))))
        return 20 * np.log10(max(rms, 1e-12))

    print(f"{'stem':<10}{'SNR':>9}{'stem level':>13}{'error level':>14}")
    print("-" * 46)
    for index, name in enumerate(model.sources):
        ref, act = reference[0, index], actual[0, index]
        print(f"{name:<10}{snr_db(ref, act):>6.1f} dB"
              f"{dbfs(ref):>10.1f} dBFS{dbfs(ref - act):>9.1f} dBFS")
    print("-" * 46)
    print(f"{'overall':<10}{snr_db(reference, actual):>6.1f} dB"
          f"{dbfs(reference):>10.1f} dBFS{dbfs(reference - actual):>9.1f} dBFS")
    print("\nError level is what matters: below about -60 dBFS nothing is audible,")
    print("however small the stem it sits in.")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
