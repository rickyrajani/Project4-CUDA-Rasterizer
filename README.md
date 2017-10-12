CUDA Rasterizer
===============

[CLICK ME FOR INSTRUCTION OF THIS PROJECT](./INSTRUCTION.md)

**University of Pennsylvania, CIS 565: GPU Programming and Architecture, Project 4**

* Ricky Rajani
* Tested on: Windows 7, i7-6700 @ 3.40GHz 16GB, NVIDIA Quadro K620 (Moore 100C Lab)

This project implements a simplified rasterized graphics pipeline, similar to the OpenGL pipeline, using CUDA.

### Core Features:
- Vertex assembly
- Vertex shading
- Primitive assembly
- Depth test
- Rasterization
- Race avoidance using atomic function
- Fragment shading with lambert lighting
- Framebuffer

### Extra Features:
- UV texture mapping with bilinear texture filtering and perspective correct texture coordinates
- Support for rasterizing additional primitives: lines and points

# Samples

- Cow
- Duck normal
- 2 cylinder enginek

Points
- duck - 20
- duck - 50
- Performance Analysis (timing for kernRasterize)

Lines
- truck
- cow
- Performance Analysis (timing for kernRasterize)

UV Texture Mapping
- Cesium Milk Truck
- Duck
- Performance Analysis (timing for kernTextureMap)

Bilinear Texture filtering
- Checkerboard with
- Checkerboard without
- Performance Analysis (timing)

Perspective Correction
- Checkerboard with
- Checkerboard without
- Performance Analysis (timing)

# Performance Analysis
Pipeline Timing: Box
Pipeline Timing: Duck
Pipeline Timing: Cow

- Number of primitives
- Vertex Transform and Assembly
- Primitive Assembly
- initDepth
- kernRasterize
- Render

### Credits

* [tinygltfloader](https://github.com/syoyo/tinygltfloader) by [@soyoyo](https://github.com/syoyo)
* [glTF Sample Models](https://github.com/KhronosGroup/glTF/blob/master/sampleModels/README.md)
