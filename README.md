# vphone GPU driver extraction

The workflow builds pinned Linux preparation tools, restores a temporary cloudOS
machine under QEMU TCG, and extracts `AppleParavirtGPUMetalIOGPUFamily.bundle`.

Artifacts contain the driver archive, SHA-256 checksums, the input manifest and
preparation logs. The workflow uses a GitHub-hosted Ubuntu runner with a 4 GiB
guest and a 2 GiB host memory reserve.
