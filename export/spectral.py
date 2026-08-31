"""Real-valued STFT/ISTFT, so the graph carries no complex tensors.

Core ML has no complex dtype. Its converter can build a complex value and run
`stft` and `irfft`, but it cannot slice or pad one -- and demucs does both. It
also has no `istft` and no `view_as_complex` at all.

So: convert to real immediately after the forward transform, do every slice and
pad on real tensors, and hand-write the inverse as irfft plus an overlap-add
that a converter can actually follow.
"""

from __future__ import annotations

import torch
import torch.nn.functional as F


def real_spectro(x: torch.Tensor, n_fft: int, hop: int) -> torch.Tensor:
    """(..., L) -> (..., freqs, frames, 2), the last axis being (real, imag)."""
    *other, length = x.shape
    x = x.reshape(-1, length)
    window = torch.hann_window(n_fft, device=x.device, dtype=x.dtype)
    z = torch.stft(
        x, n_fft, hop, window=window, win_length=n_fft,
        normalized=True, center=True, return_complex=True, pad_mode="reflect",
    )
    z = torch.view_as_real(z)                       # (N, freqs, frames, 2)
    _, freqs, frames, _ = z.shape
    return z.view(*other, freqs, frames, 2)


def _overlap_add(frames: torch.Tensor, hop: int, n_fft: int) -> torch.Tensor:
    """Sum overlapping frames back into a signal, cheaply.

    A transposed convolution with an identity kernel does this in one line, but
    it costs O(n_fft^2) per frame -- 5.7 GMAC for one 7.8 s segment, which made
    the converted model run at 0.05x realtime.

    Since hop divides n_fft exactly, the frames split into `n_fft // hop`
    interleaved lanes whose members never overlap each other. Each lane is then
    just a reshape laid end to end, and the lanes are summed at their offsets.
    That is O(n_fft) per frame and uses only reshape, pad and add.
    """
    count, size, total_frames = frames.shape
    lanes = n_fft // hop

    remainder = (-total_frames) % lanes
    if remainder:
        frames = F.pad(frames, (0, remainder))
    padded_frames = total_frames + remainder
    per_lane = padded_frames // lanes
    out_length = (padded_frames - 1) * hop + n_fft

    signal = None
    for lane in range(lanes):
        # Frames lane, lane+L, lane+2L ... start n_fft apart, so they tile.
        block = frames[:, :, lane::lanes]                       # (N, n_fft, per_lane)
        block = block.permute(0, 2, 1).reshape(count, per_lane * n_fft)
        left = lane * hop
        right = out_length - left - block.shape[-1]
        block = F.pad(block, (left, right))
        signal = block if signal is None else signal + block
    return signal[:, :out_length]


def real_ispectro(z: torch.Tensor, hop: int, length: int) -> torch.Tensor:
    """(..., freqs, frames, 2) -> (..., length). Mirrors torch.istft."""
    *other, freqs, frames, _ = z.shape
    n_fft = 2 * (freqs - 1)
    z = z.reshape(-1, freqs, frames, 2)

    window = torch.hann_window(n_fft, device=z.device, dtype=z.dtype)

    # irfft is supported by the converter; istft is not, so the overlap-add
    # below is written out by hand.
    spectrum = torch.complex(z[..., 0], z[..., 1])
    frames_time = torch.fft.irfft(spectrum, n=n_fft, dim=1)      # (N, n_fft, T)

    # torch.stft(normalized=True) scaled by 1/sqrt(n_fft); undo it here.
    frames_time = frames_time * (n_fft ** 0.5)
    frames_time = frames_time * window.view(1, -1, 1)

    signal = _overlap_add(frames_time, hop, n_fft)

    # Divide out the summed window envelope so overlaps do not gain up.
    squared = (window ** 2).view(1, -1, 1).expand(1, n_fft, frames)
    envelope = _overlap_add(squared, hop, n_fft)
    signal = signal / (envelope + 1e-8)

    # center=True padded by n_fft // 2 at each end.
    start = n_fft // 2
    signal = signal[..., start : start + length]
    return signal.reshape(*other, length)
