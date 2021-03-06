/**
 * @file      rasterize.cu
 * @brief     CUDA-accelerated rasterization pipeline.
 * @authors   Skeleton code: Yining Karl Li, Kai Ninomiya, Shuai Shao (Shrek)
 * @date      2012-2016
 * @copyright University of Pennsylvania & STUDENT
 */

#include <cmath>
#include <cstdio>
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/random.h>
#include "common.h"
#include <util/checkCUDAError.h>
#include <util/tiny_gltf_loader.h>
#include "rasterizeTools.h"
#include "rasterize.h"
#include <glm/gtc/quaternion.hpp>
#include <glm/gtc/matrix_transform.hpp>

#define blockSize 256

// Toggle features

// Lambert shading
#define LIGHTING 1

// Bilinear texture filtering and perspective correction work with TEXTURE enabled
#define TEXTURE 0
#define BILINEAR 0
#define PERSPECTIVE 0

#define POINTCLOUD 10
#define POINTS 1
#define LINE 0

using StreamCompaction::Common::PerformanceTimer;
PerformanceTimer& timer()
{
	static PerformanceTimer timer;
	return timer;
}

// timer().startGpuTimer();
// timer().endGpuTimer();
// cout << timer().getGpuElapsedTimeForPreviousOperation() << endl;

namespace {

	typedef unsigned short VertexIndex;
	typedef glm::vec3 VertexAttributePosition;
	typedef glm::vec3 VertexAttributeNormal;
	typedef glm::vec2 VertexAttributeTexcoord;
	typedef unsigned char TextureData;

	typedef unsigned char BufferByte;

	enum PrimitiveType{
		Point = 1,
		Line = 2,
		Triangle = 3
	};

	struct VertexOut {
		glm::vec4 pos;

		// TODO: add new attributes to your VertexOut
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;	// eye space normal used for shading, cuz normal will go wrong after perspective transformation
		 glm::vec3 col;
		 glm::vec2 texcoord0;
		 TextureData* dev_diffuseTex = NULL;
		 int texWidth, texHeight;
         int tex;
		// ...
	};

	struct Primitive {
		PrimitiveType primitiveType = Triangle;	// C++ 11 init
		VertexOut v[3];

        TextureData* dev_diffuseTex = NULL;
        int texWidth, texHeight;
        int tex;
	};

	struct Fragment {
		glm::vec3 color;
       
		// TODO: add new attributes to your Fragment
		// The attributes listed below might be useful, 
		// but always feel free to modify on your own

		 glm::vec3 eyePos;	// eye space position used for shading
		 glm::vec3 eyeNor;
		 VertexAttributeTexcoord texcoord0;
		 TextureData* dev_diffuseTex;
		// ...

         int texWidth, texHeight;
         int tex;
	};

	struct PrimitiveDevBufPointers {
		int primitiveMode;	//from tinygltfloader macro
		PrimitiveType primitiveType;
		int numPrimitives;
		int numIndices;
		int numVertices;

		// Vertex In, const after loaded
		VertexIndex* dev_indices;
		VertexAttributePosition* dev_position;
		VertexAttributeNormal* dev_normal;
		VertexAttributeTexcoord* dev_texcoord0;

		// Materials, add more attributes when needed
		TextureData* dev_diffuseTex;
		int diffuseTexWidth;
		int diffuseTexHeight;
		/*TextureData* dev_specularTex;
		TextureData* dev_normalTex;*/
		// ...

		// Vertex Out, vertex used for rasterization, this is changing every frame
		VertexOut* dev_verticesOut;

		// TODO: add more attributes when needed
        int tex;
	};

}

static std::map<std::string, std::vector<PrimitiveDevBufPointers>> mesh2PrimitivesMap;


static int width = 0;
static int height = 0;

static int totalNumPrimitives = 0;
static Primitive *dev_primitives = NULL;
static Fragment *dev_fragmentBuffer = NULL;
static glm::vec3 *dev_framebuffer = NULL;

static int * dev_depth = NULL;	// you might need this buffer when doing depth test

/**
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ 
void sendImageToPBO(uchar4 *pbo, int w, int h, glm::vec3 *image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        glm::vec3 color;
        color.x = glm::clamp(image[index].x, 0.0f, 1.0f) * 255.0;
        color.y = glm::clamp(image[index].y, 0.0f, 1.0f) * 255.0;
        color.z = glm::clamp(image[index].z, 0.0f, 1.0f) * 255.0;
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

/** 
* Writes fragment colors to the framebuffer
*/
__global__
void render(int w, int h, Fragment *fragmentBuffer, glm::vec3 *framebuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * w);

    if (x < w && y < h) {
        framebuffer[index] = fragmentBuffer[index].color;

		// TODO: add your fragment shader code here
        framebuffer[index] = fragmentBuffer[index].color;
#if LIGHTING
        glm::vec3 light = glm::normalize(glm::vec3(3, 5, 2));
        framebuffer[index] *= glm::dot(light, fragmentBuffer[index].eyeNor);
#endif
    }
}

/**
 * Called once at the beginning of the program to allocate memory.
 */
void rasterizeInit(int w, int h) {
    width = w;
    height = h;
	cudaFree(dev_fragmentBuffer);
	cudaMalloc(&dev_fragmentBuffer, width * height * sizeof(Fragment));
	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
    cudaFree(dev_framebuffer);
    cudaMalloc(&dev_framebuffer,   width * height * sizeof(glm::vec3));
    cudaMemset(dev_framebuffer, 0, width * height * sizeof(glm::vec3));
    
	cudaFree(dev_depth);
	cudaMalloc(&dev_depth, width * height * sizeof(int));

	checkCUDAError("rasterizeInit");
}

__global__
void initDepth(int w, int h, int * depth)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < w && y < h)
	{
		int index = x + (y * w);
		depth[index] = INT_MAX;
	}
}


/**
* kern function with support for stride to sometimes replace cudaMemcpy
* One thread is responsible for copying one component
*/
__global__ 
void _deviceBufferCopy(int N, BufferByte* dev_dst, const BufferByte* dev_src, int n, int byteStride, int byteOffset, int componentTypeByteSize) {
	
	// Attribute (vec3 position)
	// component (3 * float)
	// byte (4 * byte)

	// id of component
	int i = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (i < N) {
		int count = i / n;
		int offset = i - count * n;	// which component of the attribute

		for (int j = 0; j < componentTypeByteSize; j++) {
			
			dev_dst[count * componentTypeByteSize * n 
				+ offset * componentTypeByteSize 
				+ j]

				= 

			dev_src[byteOffset 
				+ count * (byteStride == 0 ? componentTypeByteSize * n : byteStride) 
				+ offset * componentTypeByteSize 
				+ j];
		}
	}
	

}

__global__
void _nodeMatrixTransform(
	int numVertices,
	VertexAttributePosition* position,
	VertexAttributeNormal* normal,
	glm::mat4 MV, glm::mat3 MV_normal) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {
		position[vid] = glm::vec3(MV * glm::vec4(position[vid], 1.0f));
		normal[vid] = glm::normalize(MV_normal * normal[vid]);
	}
}

glm::mat4 getMatrixFromNodeMatrixVector(const tinygltf::Node & n) {
	
	glm::mat4 curMatrix(1.0);

	const std::vector<double> &m = n.matrix;
	if (m.size() > 0) {
		// matrix, copy it

		for (int i = 0; i < 4; i++) {
			for (int j = 0; j < 4; j++) {
				curMatrix[i][j] = (float)m.at(4 * i + j);
			}
		}
	} else {
		// no matrix, use rotation, scale, translation

		if (n.translation.size() > 0) {
			curMatrix[3][0] = n.translation[0];
			curMatrix[3][1] = n.translation[1];
			curMatrix[3][2] = n.translation[2];
		}

		if (n.rotation.size() > 0) {
			glm::mat4 R;
			glm::quat q;
			q[0] = n.rotation[0];
			q[1] = n.rotation[1];
			q[2] = n.rotation[2];

			R = glm::mat4_cast(q);
			curMatrix = curMatrix * R;
		}

		if (n.scale.size() > 0) {
			curMatrix = curMatrix * glm::scale(glm::vec3(n.scale[0], n.scale[1], n.scale[2]));
		}
	}

	return curMatrix;
}

void traverseNode (
	std::map<std::string, glm::mat4> & n2m,
	const tinygltf::Scene & scene,
	const std::string & nodeString,
	const glm::mat4 & parentMatrix
	) 
{
	const tinygltf::Node & n = scene.nodes.at(nodeString);
	glm::mat4 M = parentMatrix * getMatrixFromNodeMatrixVector(n);
	n2m.insert(std::pair<std::string, glm::mat4>(nodeString, M));

	auto it = n.children.begin();
	auto itEnd = n.children.end();

	for (; it != itEnd; ++it) {
		traverseNode(n2m, scene, *it, M);
	}
}

void rasterizeSetBuffers(const tinygltf::Scene & scene) {

	totalNumPrimitives = 0;

	std::map<std::string, BufferByte*> bufferViewDevPointers;

	// 1. copy all `bufferViews` to device memory
	{
		std::map<std::string, tinygltf::BufferView>::const_iterator it(
			scene.bufferViews.begin());
		std::map<std::string, tinygltf::BufferView>::const_iterator itEnd(
			scene.bufferViews.end());

		for (; it != itEnd; it++) {
			const std::string key = it->first;
			const tinygltf::BufferView &bufferView = it->second;
			if (bufferView.target == 0) {
				continue; // Unsupported bufferView.
			}

			const tinygltf::Buffer &buffer = scene.buffers.at(bufferView.buffer);

			BufferByte* dev_bufferView;
			cudaMalloc(&dev_bufferView, bufferView.byteLength);
			cudaMemcpy(dev_bufferView, &buffer.data.front() + bufferView.byteOffset, bufferView.byteLength, cudaMemcpyHostToDevice);

			checkCUDAError("Set BufferView Device Mem");

			bufferViewDevPointers.insert(std::make_pair(key, dev_bufferView));

		}
	}



	// 2. for each mesh: 
	//		for each primitive: 
	//			build device buffer of indices, material, and each attributes
	//			and store these pointers in a map
	{

		std::map<std::string, glm::mat4> nodeString2Matrix;
		auto rootNodeNamesList = scene.scenes.at(scene.defaultScene);

		{
			auto it = rootNodeNamesList.begin();
			auto itEnd = rootNodeNamesList.end();
			for (; it != itEnd; ++it) {
				traverseNode(nodeString2Matrix, scene, *it, glm::mat4(1.0f));
			}
		}


		// parse through node to access mesh

		auto itNode = nodeString2Matrix.begin();
		auto itEndNode = nodeString2Matrix.end();
		for (; itNode != itEndNode; ++itNode) {

			const tinygltf::Node & N = scene.nodes.at(itNode->first);
			const glm::mat4 & matrix = itNode->second;
			const glm::mat3 & matrixNormal = glm::transpose(glm::inverse(glm::mat3(matrix)));

			auto itMeshName = N.meshes.begin();
			auto itEndMeshName = N.meshes.end();

			for (; itMeshName != itEndMeshName; ++itMeshName) {

				const tinygltf::Mesh & mesh = scene.meshes.at(*itMeshName);

				auto res = mesh2PrimitivesMap.insert(std::pair<std::string, std::vector<PrimitiveDevBufPointers>>(mesh.name, std::vector<PrimitiveDevBufPointers>()));
				std::vector<PrimitiveDevBufPointers> & primitiveVector = (res.first)->second;

				// for each primitive
				for (size_t i = 0; i < mesh.primitives.size(); i++) {
					const tinygltf::Primitive &primitive = mesh.primitives[i];

					if (primitive.indices.empty())
						return;

					// TODO: add new attributes for your PrimitiveDevBufPointers when you add new attributes
					VertexIndex* dev_indices = NULL;
					VertexAttributePosition* dev_position = NULL;
					VertexAttributeNormal* dev_normal = NULL;
					VertexAttributeTexcoord* dev_texcoord0 = NULL;

					// ----------Indices-------------

					const tinygltf::Accessor &indexAccessor = scene.accessors.at(primitive.indices);
					const tinygltf::BufferView &bufferView = scene.bufferViews.at(indexAccessor.bufferView);
					BufferByte* dev_bufferView = bufferViewDevPointers.at(indexAccessor.bufferView);

					// assume type is SCALAR for indices
					int n = 1;
					int numIndices = indexAccessor.count;
					int componentTypeByteSize = sizeof(VertexIndex);
					int byteLength = numIndices * n * componentTypeByteSize;

					dim3 numThreadsPerBlock(128);
					dim3 numBlocks((numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					cudaMalloc(&dev_indices, byteLength);
					_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
						numIndices,
						(BufferByte*)dev_indices,
						dev_bufferView,
						n,
						indexAccessor.byteStride,
						indexAccessor.byteOffset,
						componentTypeByteSize);


					checkCUDAError("Set Index Buffer");


					// ---------Primitive Info-------

					// Warning: LINE_STRIP is not supported in tinygltfloader
					int numPrimitives;
					PrimitiveType primitiveType;
					switch (primitive.mode) {
					case TINYGLTF_MODE_TRIANGLES:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices / 3;
						break;
					case TINYGLTF_MODE_TRIANGLE_STRIP:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_TRIANGLE_FAN:
						primitiveType = PrimitiveType::Triangle;
						numPrimitives = numIndices - 2;
						break;
					case TINYGLTF_MODE_LINE:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices / 2;
						break;
					case TINYGLTF_MODE_LINE_LOOP:
						primitiveType = PrimitiveType::Line;
						numPrimitives = numIndices + 1;
						break;
					case TINYGLTF_MODE_POINTS:
						primitiveType = PrimitiveType::Point;
						numPrimitives = numIndices;
						break;
					default:
						// output error
						break;
					};


					// ----------Attributes-------------

					auto it(primitive.attributes.begin());
					auto itEnd(primitive.attributes.end());

					int numVertices = 0;
					// for each attribute
					for (; it != itEnd; it++) {
						const tinygltf::Accessor &accessor = scene.accessors.at(it->second);
						const tinygltf::BufferView &bufferView = scene.bufferViews.at(accessor.bufferView);

						int n = 1;
						if (accessor.type == TINYGLTF_TYPE_SCALAR) {
							n = 1;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC2) {
							n = 2;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC3) {
							n = 3;
						}
						else if (accessor.type == TINYGLTF_TYPE_VEC4) {
							n = 4;
						}

						BufferByte * dev_bufferView = bufferViewDevPointers.at(accessor.bufferView);
						BufferByte ** dev_attribute = NULL;

						numVertices = accessor.count;
						int componentTypeByteSize;

						// Note: since the type of our attribute array (dev_position) is static (float32)
						// We assume the glTF model attribute type are 5126(FLOAT) here

						if (it->first.compare("POSITION") == 0) {
							componentTypeByteSize = sizeof(VertexAttributePosition) / n;
							dev_attribute = (BufferByte**)&dev_position;
						}
						else if (it->first.compare("NORMAL") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeNormal) / n;
							dev_attribute = (BufferByte**)&dev_normal;
						}
						else if (it->first.compare("TEXCOORD_0") == 0) {
							componentTypeByteSize = sizeof(VertexAttributeTexcoord) / n;
							dev_attribute = (BufferByte**)&dev_texcoord0;
						}

						std::cout << accessor.bufferView << "  -  " << it->second << "  -  " << it->first << '\n';

						dim3 numThreadsPerBlock(128);
						dim3 numBlocks((n * numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
						int byteLength = numVertices * n * componentTypeByteSize;
						cudaMalloc(dev_attribute, byteLength);

						_deviceBufferCopy << <numBlocks, numThreadsPerBlock >> > (
							n * numVertices,
							*dev_attribute,
							dev_bufferView,
							n,
							accessor.byteStride,
							accessor.byteOffset,
							componentTypeByteSize);

						std::string msg = "Set Attribute Buffer: " + it->first;
						checkCUDAError(msg.c_str());
					}

					// malloc for VertexOut
					VertexOut* dev_vertexOut;
					cudaMalloc(&dev_vertexOut, numVertices * sizeof(VertexOut));
					checkCUDAError("Malloc VertexOut Buffer");

					// ----------Materials-------------

					// You can only worry about this part once you started to 
					// implement textures for your rasterizer
					TextureData* dev_diffuseTex = NULL;
					int diffuseTexWidth = 0;
					int diffuseTexHeight = 0;

                    int texture = 0;
					if (!primitive.material.empty()) {
						const tinygltf::Material &mat = scene.materials.at(primitive.material);
						printf("material.name = %s\n", mat.name.c_str());

						if (mat.values.find("diffuse") != mat.values.end()) {
							std::string diffuseTexName = mat.values.at("diffuse").string_value;
							if (scene.textures.find(diffuseTexName) != scene.textures.end()) {
								const tinygltf::Texture &tex = scene.textures.at(diffuseTexName);
								if (scene.images.find(tex.source) != scene.images.end()) {
									const tinygltf::Image &image = scene.images.at(tex.source);

									size_t s = image.image.size() * sizeof(TextureData);
									cudaMalloc(&dev_diffuseTex, s);
									cudaMemcpy(dev_diffuseTex, &image.image.at(0), s, cudaMemcpyHostToDevice);
									
									diffuseTexWidth = image.width;
									diffuseTexHeight = image.height;
                                    texture = image.component;

									checkCUDAError("Set Texture Image data");
								}
							}
						}

						// TODO: write your code for other materials
						// You may have to take a look at tinygltfloader
						// You can also use the above code loading diffuse material as a start point 
					}


					// ---------Node hierarchy transform--------
					cudaDeviceSynchronize();
					
					dim3 numBlocksNodeTransform((numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
					_nodeMatrixTransform << <numBlocksNodeTransform, numThreadsPerBlock >> > (
						numVertices,
						dev_position,
						dev_normal,
						matrix,
						matrixNormal);

					checkCUDAError("Node hierarchy transformation");

					// at the end of the for loop of primitive
					// push dev pointers to map
					primitiveVector.push_back(PrimitiveDevBufPointers{
						primitive.mode,
						primitiveType,
						numPrimitives,
						numIndices,
						numVertices,

						dev_indices,
						dev_position,
						dev_normal,
						dev_texcoord0,

						dev_diffuseTex,
						diffuseTexWidth,
						diffuseTexHeight,

						dev_vertexOut,	//VertexOut

                        texture

					});

					totalNumPrimitives += numPrimitives;

				} // for each primitive

			} // for each mesh

		} // for each node

	}
	

	// 3. Malloc for dev_primitives
	{
		cudaMalloc(&dev_primitives, totalNumPrimitives * sizeof(Primitive));
	}
	

	// Finally, cudaFree raw dev_bufferViews
	{

		std::map<std::string, BufferByte*>::const_iterator it(bufferViewDevPointers.begin());
		std::map<std::string, BufferByte*>::const_iterator itEnd(bufferViewDevPointers.end());
			
			//bufferViewDevPointers

		for (; it != itEnd; it++) {
			cudaFree(it->second);
		}

		checkCUDAError("Free BufferView Device Mem");
	}


}



__global__ 
void _vertexTransformAndAssembly(
	int numVertices, 
	PrimitiveDevBufPointers primitive, 
	glm::mat4 MVP, glm::mat4 MV, glm::mat3 MV_normal, 
	int width, int height) {

	// vertex id
	int vid = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (vid < numVertices) {

		// TODO: Apply vertex transformation here
		// Multiply the MVP matrix for each vertex position, this will transform everything into clipping space
		// Then divide the pos by its w element to transform into NDC space
		// Finally transform x and y to viewport space

		// TODO: Apply vertex assembly here
		// Assemble all attribute arrays into the primitive array

        VertexAttributePosition& currPos = primitive.dev_position[vid];
        VertexOut& outVertex = primitive.dev_verticesOut[vid];

        glm::vec4 pos = MVP * glm::vec4(currPos, 1.0f);
        glm::vec4 ndc = pos / pos.w;
        ndc.x = (1.0f - ndc.x) * width / 2.0f;
        ndc.y = (1.0f - ndc.y) * width / 2.0f;

		outVertex.pos = ndc;
		outVertex.eyeNor = glm::normalize(MV_normal * primitive.dev_normal[vid]);
		outVertex.eyePos = glm::vec3(MV * glm::vec4(currPos, 1.0f));

#if TEXTURE
        if (primitive.dev_diffuseTex != NULL) {
            outVertex.texcoord0 = primitive.dev_texcoord0[vid];
        }
        outVertex.dev_diffuseTex = primitive.dev_diffuseTex;
        outVertex.texWidth = primitive.diffuseTexWidth;
        outVertex.texHeight = primitive.diffuseTexHeight;
        outVertex.tex = primitive.tex;
#endif

	}
}



static int curPrimitiveBeginId = 0;

__global__ 
void _primitiveAssembly(int numIndices, int curPrimitiveBeginId, Primitive* dev_primitives, PrimitiveDevBufPointers primitive) {

	// index id
	int iid = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (iid < numIndices) {

		// TODO: uncomment the following code for a start
		// This is primitive assembly for triangles

		int pid;	// id for cur primitives vector
		if (primitive.primitiveMode == TINYGLTF_MODE_TRIANGLES) {
			pid = iid / (int)primitive.primitiveType;
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType]
				= primitive.dev_verticesOut[primitive.dev_indices[iid]];
#if TEXTURE
            dev_primitives[pid + curPrimitiveBeginId].dev_diffuseTex
                = primitive.dev_diffuseTex;
            dev_primitives[pid + curPrimitiveBeginId].texWidth
                = primitive.diffuseTexWidth;
            dev_primitives[pid + curPrimitiveBeginId].texHeight
                = primitive.diffuseTexHeight;
#elif !POINTS && !LINE
			dev_primitives[pid + curPrimitiveBeginId].v[iid % (int)primitive.primitiveType].col
				= glm::vec3(1.0f, 1.0f, 1.0f); // default is white
#endif
		}

		// TODO: other primitive types (point, line)
	}
	
}

__device__
void kernRasterizeExtraPrims(int width, int height, glm::vec3& color, glm::vec3& pos1, glm::vec3 pos2, Fragment* fragmentbuffer) {
	glm::vec3 dist = glm::abs(pos1 - pos2);
	if (dist.x > 0 && dist.y > 0) {
		float length = glm::max(dist.x, dist.y);
#if POINTS
		for (float i = 0; i <= length; i += POINTCLOUD) {
#else
		for (float i = 0; i <= length; i++) {
#endif
			glm::vec3 point = ((1.0f - (i / length)) * pos1 + (i / length) * pos2);
			int index = (int)(point.x) + (int)(point.y) * width;
			fragmentbuffer[index].color = color;
		}
	}
}

__global__           
void kernRasterize(int n, Primitive* primitives, Fragment* fragmentbuffer, int* depthsbuffer, int width, int height) {
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= n) {
		return;
	}

	Primitive& prim = primitives[index];

	glm::vec3 tri[3] = {
		glm::vec3(prim.v[0].pos),
		glm::vec3(prim.v[1].pos),
		glm::vec3(prim.v[2].pos)
	};

	AABB aabb = getAABBForTriangle(tri);
	if (aabb.min.x < 0 || aabb.max.x > width - 1 || aabb.min.y < 0 || aabb.max.y > height - 1) {
		return;
	}

	for (int x = aabb.min.x; x <= aabb.max.x; x++) {
		for (int y = aabb.min.y; y <= aabb.max.y; y++) {
			int idx = x + y * width;

			glm::vec3 bcc = calculateBarycentricCoordinate(tri, glm::vec2(x, y));
			if (isBarycentricCoordInBounds(bcc)) {
				float z = getZAtCoordinate(bcc, tri);
				int depth = -INT_MAX * z;
				atomicMin(&depthsbuffer[idx], depth);

				if (depthsbuffer[idx] == depth) {
					Fragment& frag = fragmentbuffer[idx];

					frag.color = bcc.x * prim.v[0].col + bcc.y * prim.v[1].col + bcc.z * prim.v[2].col;
					frag.eyePos = bcc.x * prim.v[0].eyePos + bcc.y * prim.v[1].eyePos + bcc.z * prim.v[2].eyePos;
					frag.eyeNor = bcc.x * prim.v[0].eyeNor + bcc.y * prim.v[1].eyeNor + bcc.z * prim.v[2].eyeNor;
#if TEXTURE
					frag.dev_diffuseTex = prim.v[0].dev_diffuseTex;
					frag.texWidth = prim.v[0].texWidth;
					frag.texHeight = prim.v[0].texHeight;
					frag.tex = prim.v[0].tex;
#if PERSPECTIVE
					glm::vec3 u_a = glm::vec3(bcc.x / prim.v[0].eyePos.z, bcc.y / prim.v[1].eyePos.z, bcc.z / prim.v[2].eyePos.z);
					frag.texcoord0 = ((u_a.x * prim.v[0].texcoord0) + (u_a.y * prim.v[1].texcoord0) + (u_a.z * prim.v[2].texcoord0))
						/ (u_a.x + u_a.y + u_a.z);
#else
					frag.texcoord0 = bcc.x * prim.v[0].texcoord0 + bcc.y * prim.v[1].texcoord0 + bcc.z * prim.v[2].texcoord0;
#endif
#endif
				}
			}
		}
	}

#if POINTS || LINE
	if (prim.primitiveType == TINYGLTF_MODE_POINTS) {
		glm::vec3 color = prim.v[0].col;
		color += prim.v[0].eyeNor;
		color = glm::normalize(color);

		kernRasterizeExtraPrims(width, height, color, glm::vec3(prim.v[0].pos), glm::vec3(prim.v[1].pos), fragmentbuffer);
		kernRasterizeExtraPrims(width, height, color, glm::vec3(prim.v[2].pos), glm::vec3(prim.v[0].pos), fragmentbuffer);
	}
#endif
}

__device__ __host__
glm::vec3 getTexture(int x, int y, int width, int height, TextureData* texture, int tex) {
    int index = x + y * width;
    int id = tex * index;

    if (x >= 0 && x < width && y >= 0 && y < height) {
        return (glm::vec3(texture[id], texture[id + 1], texture[id + 2]) / 255.0f);
    }

    return glm::vec3(0.0f);
}

__global__
void kernTextureMap(int width, int height, Fragment* fragmentbuffer) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;
    int index = x + (y * width);

    if (x >= 0 && x < width && y >= 0 && y < height) {
        Fragment& frag = fragmentbuffer[index];
        if (frag.dev_diffuseTex != NULL) {
            float texX = frag.texcoord0.x * (frag.texWidth - 1.0f) + 0.5f;
            float texY = frag.texcoord0.y * (frag.texHeight - 1.0f) + 0.5f;
#if BILINEAR
			// Reference: https://en.wikipedia.org/wiki/Bilinear_interpolation
			float u = texX * 1.0f - 0.5f;
			float v = texY * 1.0f - 0.5f;
			float x = glm::floor(u);
			float y = glm::floor(v);
			float u_ratio = u - x;
			float v_ratio = v - y;
			float u_opposite = 1.0f - u_ratio;
			float v_opposite = 1.0f - v_ratio;

			glm::vec3 tex00 = getTexture(x, y, frag.texWidth, frag.texHeight, frag.dev_diffuseTex, frag.tex);
			glm::vec3 tex10 = getTexture(x + 1, y, frag.texWidth, frag.texHeight, frag.dev_diffuseTex, frag.tex);
			glm::vec3 tex01 = getTexture(x, y + 1, frag.texWidth, frag.texHeight, frag.dev_diffuseTex, frag.tex);
			glm::vec3 tex11 = getTexture(x + 1, y + 1, frag.texWidth, frag.texHeight, frag.dev_diffuseTex, frag.tex);

			glm::vec3 result = (tex00 * u_opposite + tex10 * u_ratio) * v_opposite + (tex01 * u_opposite + tex11 * u_ratio) * v_ratio;
			frag.color = result;
#else
			frag.color = getTexture(texX, texY, frag.texWidth, frag.texHeight, frag.dev_diffuseTex, frag.tex);
#endif
        }
    }
}

/**
 * Perform rasterization.
 */
void rasterize(uchar4 *pbo, const glm::mat4 & MVP, const glm::mat4 & MV, const glm::mat3 MV_normal) {
    int sideLength2d = 8;
    dim3 blockSize2d(sideLength2d, sideLength2d);
    dim3 blockCount2d((width  - 1) / blockSize2d.x + 1,
		(height - 1) / blockSize2d.y + 1);
    dim3 numBlocksPrimitives((totalNumPrimitives + blockSize - 1) / blockSize);
	//std::cout << totalNumPrimitives << std::endl;

	// Execute your rasterization pipeline here
	// (See README for rasterization pipeline outline.)

	// Vertex Process & primitive assembly
	{
		curPrimitiveBeginId = 0;
		dim3 numThreadsPerBlock(128);

		auto it = mesh2PrimitivesMap.begin();
		auto itEnd = mesh2PrimitivesMap.end();

		//timer().startGpuTimer();
		for (; it != itEnd; ++it) {
			auto p = (it->second).begin();	// each primitive
			auto pEnd = (it->second).end();
			for (; p != pEnd; ++p) {
				dim3 numBlocksForVertices((p->numVertices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);
				dim3 numBlocksForIndices((p->numIndices + numThreadsPerBlock.x - 1) / numThreadsPerBlock.x);

				_vertexTransformAndAssembly << < numBlocksForVertices, numThreadsPerBlock >> >(p->numVertices, *p, MVP, MV, MV_normal, width, height);
				checkCUDAError("Vertex Processing");
				cudaDeviceSynchronize();
				_primitiveAssembly << < numBlocksForIndices, numThreadsPerBlock >> >
					(p->numIndices, 
					curPrimitiveBeginId, 
					dev_primitives, 
					*p);
				checkCUDAError("Primitive Assembly");

				curPrimitiveBeginId += p->numPrimitives;
			}
		}

		checkCUDAError("Vertex Processing and Primitive Assembly");
	}
	//timer().endGpuTimer();
	//std::cout << timer().getGpuElapsedTimeForPreviousOperation() << std::endl;

	cudaMemset(dev_fragmentBuffer, 0, width * height * sizeof(Fragment));
	//timer().startGpuTimer();
	initDepth << <blockCount2d, blockSize2d >> >(width, height, dev_depth);
	//timer().endGpuTimer();
	//std::cout << timer().getGpuElapsedTimeForPreviousOperation() << std::endl;

	// TODO: rasterize
	//timer().startGpuTimer();
    kernRasterize << <numBlocksPrimitives, blockSize >> >(totalNumPrimitives, dev_primitives, dev_fragmentBuffer, dev_depth, width, height);
	//timer().endGpuTimer();
	//std::cout << timer().getGpuElapsedTimeForPreviousOperation() << std::endl;
    checkCUDAError("kernRasterize failed");

#if TEXTURE
	// UV Texture Map
	//timer().startGpuTimer();
    kernTextureMap << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer);
	//timer().endGpuTimer();
	//std::cout << timer().getGpuElapsedTimeForPreviousOperation() << std::endl;
    checkCUDAError("kernTextureMap failed");
#endif

    // Copy depthbuffer colors into framebuffer
	//timer().startGpuTimer();
	render << <blockCount2d, blockSize2d >> >(width, height, dev_fragmentBuffer, dev_framebuffer);
	//timer().endGpuTimer();
	//std::cout << timer().getGpuElapsedTimeForPreviousOperation() << std::endl;
	checkCUDAError("fragment shader");
    // Copy framebuffer into OpenGL buffer for OpenGL previewing
    sendImageToPBO<<<blockCount2d, blockSize2d>>>(pbo, width, height, dev_framebuffer);
    checkCUDAError("copy render result to pbo");
}

/**
 * Called once at the end of the program to free CUDA memory.
 */
void rasterizeFree() {

    // deconstruct primitives attribute/indices device buffer

	auto it(mesh2PrimitivesMap.begin());
	auto itEnd(mesh2PrimitivesMap.end());
	for (; it != itEnd; ++it) {
		for (auto p = it->second.begin(); p != it->second.end(); ++p) {
			cudaFree(p->dev_indices);
			cudaFree(p->dev_position);
			cudaFree(p->dev_normal);
			cudaFree(p->dev_texcoord0);
			cudaFree(p->dev_diffuseTex);

			cudaFree(p->dev_verticesOut);

			
			//TODO: release other attributes and materials
		}
	}

	////////////

    cudaFree(dev_primitives);
    dev_primitives = NULL;

	cudaFree(dev_fragmentBuffer);
	dev_fragmentBuffer = NULL;

    cudaFree(dev_framebuffer);
    dev_framebuffer = NULL;

	cudaFree(dev_depth);
	dev_depth = NULL;

    checkCUDAError("rasterize Free");
}
