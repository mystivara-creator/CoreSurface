# Vulkan capabilities: evidence-first audit

Target: Redmi Note 15 5G kunzite, Adreno 710. Previous third-party utilities reported Vulkan 1.3 and VRS. Those observations do not establish each Vulkan extension, feature bit, or limit.

## Collect without reboot or driver modifications

From Termux, after updating the repo:

```sh
sh scripts/collect-vulkan.sh /sdcard/Download/kunzite-vulkan-audit
cd /sdcard/Download
tar -czf kunzite-vulkan-audit.tar.gz kunzite-vulkan-audit
```

This script captures a limited Android summary, Vulkan driver file metadata, and `vulkaninfo` results **if installed**. If `vulkaninfo` is absent, device extensions and fine-grained capabilities remain **unverified**. The script does not install tools.

## Evidence required

- Actual API version, deviceName, vendorID, deviceID and driverVersion from `vkGetPhysicalDeviceProperties`.
- Device extensions from `vkEnumerateDeviceExtensionProperties`.
- Vulkan 1.1/1.2/1.3 and extension feature bits from `vkGetPhysicalDeviceFeatures2` with correct `pNext` structures.
- Limits from `vkGetPhysicalDeviceProperties2`.
- Fragment shading rate / VRS: extension plus feature bit plus usable properties. Do not infer support from a GPU model.
- Ray tracing / mesh shader: unsupported until real driver extension + feature proof; no spoofing.
- Driver support is not the same as an application enabling that feature through `vkCreateDevice`.

References: https://docs.vulkan.org/refpages/latest/refpages/source/vkGetPhysicalDeviceFeatures2.html and https://docs.vulkan.org/refpages/latest/refpages/source/vkEnumerateDeviceExtensionProperties.html

No system changes until we can compare native driver results to Android-advertised capabilities and establish a real restriction.
