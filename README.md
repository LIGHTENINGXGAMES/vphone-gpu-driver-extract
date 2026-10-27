# vphone GPU driver extraction

The workflow builds pinned Linux preparation tools, restores a temporary cloudOS
machine under QEMU TCG, and extracts `AppleParavirtGPUMetalIOGPUFamily.bundle`.

Artifacts contain the driver archive, SHA-256 checksums, the input manifest and
preparation logs. The workflow uses a GitHub-hosted Ubuntu runner with a 4 GiB
guest and a 2 GiB host memory reserve.

Verified with cloudOS 26.4 beta (23E5207q) on 2026-10-27:
[successful extraction](https://github.com/LIGHTENINGXGAMES/vphone-gpu-driver-extract/actions/runs/40448538947).
The driver is version 64.4.4, SDK 26.4: three files totaling 512,236 bytes.
The bundle TAR's SHA-256 is
`8cecb53742d31900165a437c299accf63fff3ec091608ef59a37b134cd2b6c72`.

Artifacts expire after three days; keep the extracted bundle locally.
