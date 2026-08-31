"""Make an HTDemucs instance convertible by removing complex tensors from it.

With `cac=True` -- which htdemucs_6s uses -- the network itself already works
on real tensors: the complex spectrogram exists only to be unpacked by
`view_as_real`, and `_mask` ignores it outright. So nothing is lost by carrying
(real, imag) as a trailing axis from the moment the STFT produces it.

Every slice and pad then happens on a real tensor, which is what Core ML needs.
"""

from __future__ import annotations

import math
import types

import torch
import torch.nn.functional as F

from .spectral import real_ispectro, real_spectro


def _spec(self, x: torch.Tensor) -> torch.Tensor:
    """(B, C, L) -> (B, C, freqs, frames, 2)."""
    hop, n_fft = self.hop_length, self.nfft
    frames = int(math.ceil(x.shape[-1] / hop))
    pad = hop // 2 * 3
    x = F.pad(x, (pad, pad + frames * hop - x.shape[-1]), mode="reflect")

    z = real_spectro(x, n_fft, hop)
    z = z[..., :-1, :, :]                 # drop the Nyquist bin
    z = z[..., 2 : 2 + frames, :]         # trim the padding frames
    return z


def _magnitude(self, z: torch.Tensor) -> torch.Tensor:
    """(B, C, Fr, T, 2) -> (B, 2C, Fr, T), real and imaginary as channels."""
    batch, channels, freqs, frames, _ = z.shape
    return z.permute(0, 1, 4, 2, 3).reshape(batch, channels * 2, freqs, frames)


def _mask(self, z: torch.Tensor, m: torch.Tensor) -> torch.Tensor:
    """(B, S*C*2, Fr, T) -> (B, S*C, Fr, T, 2), never exceeding rank 5.

    Sources and channels stay merged on purpose: splitting them here would make
    the tensor rank 6, and Core ML supports no more than rank 5. `_ispec`
    separates them again once the trailing axis is gone.
    """
    batch = m.shape[0]
    freqs, frames = m.shape[-2], m.shape[-1]
    out = m.reshape(-1, 2, freqs, frames)          # (B*S*C, 2, Fr, T)
    out = out.permute(0, 2, 3, 1)                  # (B*S*C, Fr, T, 2)
    return out.reshape(batch, -1, freqs, frames, 2).contiguous()


def _ispec(self, z: torch.Tensor, length: int, scale: int = 0) -> torch.Tensor:
    """(B, S*C, Fr, T, 2) -> (B, S, C, length)."""
    hop = self.hop_length // (4 ** scale)
    z = F.pad(z, (0, 0, 0, 0, 0, 1))      # one extra frequency bin
    z = F.pad(z, (0, 0, 2, 2))            # two frames either side
    pad = hop // 2 * 3
    padded_length = hop * int(math.ceil(length / hop)) + 2 * pad
    x = real_ispectro(z, hop, length=padded_length)
    x = x[..., pad : pad + length]
    # Split sources from channels only now, once rank has room again.
    return x.reshape(x.shape[0], len(self.sources), self.audio_channels, length)


def make_exportable(model):
    """Swap the four spectral methods on one HTDemucs instance."""
    if not getattr(model, "cac", False):
        raise ValueError("only the complex-as-channels variant is supported")
    for name, function in (
        ("_spec", _spec), ("_magnitude", _magnitude),
        ("_mask", _mask), ("_ispec", _ispec),
    ):
        setattr(model, name, types.MethodType(function, model))
    # The segment is fixed at export time, so the run-time re-derivation of it
    # only adds shape arithmetic the converter cannot fold.
    model.use_train_segment = False
    return model
