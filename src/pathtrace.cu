#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"


/*
#define CHECK_NAN
#define CHECK_INF
#define CHECK_NEGATIVE
*/


constexpr bool
	sortByMaterial = false,
	stratifiedSplat = false,
	cacheFirstBounce = false;


#define ERRORCHECK 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__ thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

static Scene *hst_scene = nullptr;
static glm::vec3 *dev_directIllum = nullptr, *dev_indirectIllum = nullptr;
static float *dev_directIllumSqr = nullptr, *dev_indirectIllumSqr = nullptr;
static Geom *dev_geoms = nullptr;
static Material *dev_materials = nullptr;
static PathSegment *dev_paths = nullptr;
static ShadeableIntersection *dev_intersections = nullptr;
static AABBTreeNode *dev_aabbTree = nullptr;
static int aabbTreeRoot;

// static variables for device memory, any extra info you need, etc
static int *dev_materialSortBuffer = nullptr;
static int *dev_materialSortBuffer2 = nullptr;

static bool firstBounceCached = false;
static ShadeableIntersection *dev_firstBounceIntersections = nullptr;

static int numStratifiedSamples;
static float stratifiedSamplingRange;
static IntersectionSample *dev_samplePool = nullptr;
static CameraSample *dev_camSamplePool = nullptr;

static glm::vec3 *dev_normalBuffer = nullptr;
static glm::vec3 *dev_positionBuffer = nullptr;
static glm::vec3 *dev_filteredDirectSpecular = nullptr, *dev_filteredIndirectDiffuse = nullptr, *dev_filteredTemp = nullptr;
static float *dev_stddevBuffer = nullptr;

void pathtraceInit(Scene *scene, int sqrtNumStratifiedSamples) {
	hst_scene = scene;
	const Camera &cam = hst_scene->state.camera;
	const int pixelCount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_directIllum, pixelCount * sizeof(glm::vec3));
	cudaMemset(dev_directIllum, 0, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_directIllumSqr, pixelCount * sizeof(float));
	cudaMemset(dev_directIllumSqr, 0, pixelCount * sizeof(float));

	cudaMalloc(&dev_indirectIllum, pixelCount * sizeof(glm::vec3));
	cudaMemset(dev_indirectIllum, 0, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_indirectIllumSqr, pixelCount * sizeof(float));
	cudaMemset(dev_indirectIllumSqr, 0, pixelCount * sizeof(float));

	cudaMalloc(&dev_paths, pixelCount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelCount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelCount * sizeof(ShadeableIntersection));

	// initialize any extra device memeory you need
	if (cacheFirstBounce) {
		cudaMalloc(&dev_firstBounceIntersections, pixelCount * sizeof(ShadeableIntersection));
	}
	firstBounceCached = false;

	cudaMalloc(&dev_materialSortBuffer, pixelCount * sizeof(int));
	cudaMalloc(&dev_materialSortBuffer2, pixelCount * sizeof(int));

	cudaMalloc(&dev_aabbTree, scene->aabbTree.size() * sizeof(AABBTreeNode));
	cudaMemcpy(dev_aabbTree, scene->aabbTree.data(), scene->aabbTree.size() * sizeof(AABBTreeNode), cudaMemcpyHostToDevice);
	aabbTreeRoot = scene->aabbTreeRoot;

	stratifiedSamplingRange = 1.0f / sqrtNumStratifiedSamples;
	numStratifiedSamples = sqrtNumStratifiedSamples * sqrtNumStratifiedSamples;
	cudaMalloc(&dev_samplePool, scene->state.traceDepth * numStratifiedSamples * sizeof(IntersectionSample));
	cudaMalloc(&dev_camSamplePool, numStratifiedSamples * sizeof(CameraSample));

	cudaMalloc(&dev_normalBuffer, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_positionBuffer, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_filteredDirectSpecular, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_filteredIndirectDiffuse, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_filteredTemp, pixelCount * sizeof(glm::vec3));
	cudaMalloc(&dev_stddevBuffer, pixelCount * sizeof(float));

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_directIllum);
	cudaFree(dev_directIllumSqr);
	cudaFree(dev_indirectIllum);
	cudaFree(dev_indirectIllumSqr);

	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);

	// clean up any extra device memory you created
	cudaFree(dev_materialSortBuffer);
	cudaFree(dev_materialSortBuffer2);

	if (cacheFirstBounce) {
		cudaFree(dev_firstBounceIntersections);
	}

	cudaFree(dev_aabbTree);
	cudaFree(dev_samplePool);
	cudaFree(dev_camSamplePool);

	cudaFree(dev_normalBuffer);
	cudaFree(dev_positionBuffer);
	cudaFree(dev_filteredDirectSpecular);
	cudaFree(dev_filteredIndirectDiffuse);
	cudaFree(dev_filteredTemp);
	cudaFree(dev_stddevBuffer);

	checkCUDAError("pathtraceFree");
}

__host__ __device__ int stratifiedSampleIndex(int iter, int pixelIndex, int total) {
	if (stratifiedSplat) {
		return iter % total; // "splatting"
	} else {
		return (iter + utilhash(pixelIndex)) % total; // full stratified
	}
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(
	Camera cam, int iter, int traceDepth, PathSegment *pathSegments,
	const CameraSample *samples, int numStratifiedSamples, float stratifiedSamplingRange
) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x >= cam.resolution.x && y >= cam.resolution.y) {
		return;
	}

	int index = x + (y * cam.resolution.x);
	PathSegment &segment = pathSegments[index];

	thrust::default_random_engine rand = makeSeededRandomEngine(iter, index, -1);
	thrust::uniform_real_distribution<float> dist(0.0f, stratifiedSamplingRange);

	CameraSample sample = samples[stratifiedSampleIndex(iter, index, numStratifiedSamples)];

	// implement antialiasing by jittering the ray
	glm::vec2 pixelOffset = sample.pixel + glm::vec2(dist(rand), dist(rand));
	glm::vec3 dir =
		cam.view -
		cam.right * (cam.pixelLength.x * ((static_cast<float>(x) + pixelOffset.x - 0.5f) / cam.resolution.x - 0.5f)) -
		cam.up * (cam.pixelLength.y * ((static_cast<float>(y) + pixelOffset.y - 0.5f) / cam.resolution.x - 0.5f));

	// depth of field
	dir *= cam.focalDistance;
	glm::vec2 aperture = sampleUnitDiskUniform(sample.dof + glm::vec2(dist(rand), dist(rand))) * cam.aperture;
	glm::vec3 dofOffset = aperture.x * cam.right + aperture.y * cam.up;

	segment.ray.origin = cam.position + dofOffset;
	segment.ray.direction = glm::normalize(dir - dofOffset);

	segment.colorThroughput = glm::vec3(1.0f);
	segment.directAccum = glm::vec3(0.0f);
	segment.indirectAccum = glm::vec3(0.0f);

	segment.pixelIndex = index;
	segment.lastGeom = -1;
	segment.remainingBounces = traceDepth;
	segment.prevBounceNoMis = true; // so that light sources are rendered correctly
	segment.prevBounceSpecular = true;
	segment.indirectIllum = false;
}


// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth, int numPaths, PathSegment *pathSegments,
	const Geom *geoms, int geoms_size, const AABBTreeNode *aabbTree, int aabbTreeRoot,
	ShadeableIntersection *intersections, int *materialKeys
) {
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index >= numPaths) {
		return;
	}

	PathSegment &pathSegment = pathSegments[path_index];

	float t_min = FLT_MAX;
	int hitGeomIndex = -1;

	glm::vec3 normToken;
	hitGeomIndex = traverseAABBTree<false>(
		pathSegment.ray, aabbTree, aabbTreeRoot, geoms, pathSegment.lastGeom, -1,
		&t_min, &normToken
	);
	pathSegment.lastGeom = hitGeomIndex;

	int materialId;
	if (hitGeomIndex == -1) {
		t_min = -1.0f;
		materialId = -1;
	} else {
		// The ray hits something
		glm::vec3 geomNorm, shadeNorm;
		computeNormals(geoms[hitGeomIndex], normToken, &geomNorm, &shadeNorm);
		intersections[path_index].geometricNormal = geomNorm;
		intersections[path_index].shadingNormal = shadeNorm;

		materialId = geoms[hitGeomIndex].materialid;
	}
	intersections[path_index].t = t_min;
	intersections[path_index].materialId = materialId;
	materialKeys[path_index] = materialId;
}

__global__ void shade(
	int iter, int depth, int numPaths, ShadeableIntersection *intersections, PathSegment *paths,
	IntersectionSample *samplePool, float stratRange, int stratCount, int lightMis, int numLights,
	const Geom *geoms, const Material *materials, const AABBTreeNode *tree, int treeRoot
) {
	int iSelf = blockIdx.x * blockDim.x + threadIdx.x;
	if (iSelf >= numPaths) {
		return;
	}

	ShadeableIntersection intersection = intersections[iSelf];
	PathSegment path = paths[iSelf];

	if (intersection.materialId != -1) {
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, iSelf, depth);
		thrust::uniform_real_distribution<float> dist(0.0f, stratRange);

		IntersectionSample sample = samplePool[stratifiedSampleIndex(iter, path.pixelIndex, stratCount)];
		sample.out += glm::vec2(dist(rng), dist(rng));
		sample.mis1 += glm::vec2(dist(rng), dist(rng));
		sample.mis2 += glm::vec2(dist(rng), dist(rng));

		glm::vec3 intersectPoint = path.ray.origin + path.ray.direction * intersection.t;
		const Material &mat = materials[intersection.materialId];

		bool isSpecular =
			mat.type == MaterialType::specularReflection || mat.type == MaterialType::specularTransmission;
		bool isSpecularRay = isSpecular;
		bool misIsIndirect = path.indirectIllum || !path.prevBounceSpecular;
		if (lightMis != -1 && !isSpecular) {
			multipleImportanceSampling(
				path, intersectPoint, intersection.geometricNormal, intersection.shadingNormal,
				mat, sample.mis1, sample.mis2, lightMis, numLights, misIsIndirect,
				geoms, materials, tree, treeRoot
			);
		}
		scatterRay(
			path, intersectPoint,
			intersection.geometricNormal, intersection.shadingNormal, mat,
			sample.out, &isSpecularRay,
			depth == 0 || lightMis == -1 || geoms[path.lastGeom].type != GeomType::TRIANGLE,
			path.indirectIllum
		);
		path.indirectIllum = misIsIndirect;
		path.prevBounceNoMis = isSpecular;
		path.prevBounceSpecular = isSpecularRay;
	} else {
		path.colorThroughput = glm::vec3(0.0f);
		path.remainingBounces = 0;
	}
	paths[iSelf] = path;
}

// Add the current iteration's output to the overall image
__global__ void finalGather(
	int nPaths,
	glm::vec3 *direct, float *directSqr,
	glm::vec3 *indirect, float *indirectSqr,
	PathSegment *iterationPaths
) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths) {
		PathSegment iterationPath = iterationPaths[index];
		direct[iterationPath.pixelIndex] += iterationPath.directAccum;
		directSqr[iterationPath.pixelIndex] += glm::length2(iterationPath.directAccum);
		indirect[iterationPath.pixelIndex] += iterationPath.indirectAccum;
		indirectSqr[iterationPath.pixelIndex] += glm::length2(iterationPath.indirectAccum);
	}
}

struct IsRayTravelling {
	__host__ __device__ bool operator()(const PathSegment &path) {
		return path.remainingBounces > 0;
	}
};

struct MaterialCompare {
	__host__ __device__ bool operator()(const ShadeableIntersection &lhs, const ShadeableIntersection &rhs) {
		return lhs.materialId > rhs.materialId;
	}
};

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter, int lightMis, int numLights) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
			(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
			(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	generateRayFromCamera<<<blocksPerGrid2d, blockSize2d>>>(
		cam, iter, traceDepth, dev_paths, dev_camSamplePool, numStratifiedSamples, stratifiedSamplingRange
	);
	checkCUDAError("generate camera ray");

	PathSegment* dev_path_end = dev_paths + pixelcount;
	int numPaths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks
	for (int depth = 0; numPaths > 0; ++depth) {
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		int numblocksPathSegmentTracing = (numPaths + blockSize1d - 1) / blockSize1d;
		if (depth == 0 && firstBounceCached) {
			cudaMemcpy(
				dev_intersections, dev_firstBounceIntersections,
				pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice
			);
		} else {
			computeIntersections<<<numblocksPathSegmentTracing, blockSize1d>>>(
				depth, numPaths, dev_paths,
				dev_geoms, hst_scene->geoms.size(), dev_aabbTree, aabbTreeRoot,
				dev_intersections, dev_materialSortBuffer
			);

			if (cacheFirstBounce && depth == 0) {
				cudaMemcpy(
					dev_firstBounceIntersections, dev_intersections,
					pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice
				);
				firstBounceCached = true;
			}
		}

		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
		// evaluating the BSDF.
		// Start off with just a big kernel that handles all the different
		// materials you have in the scenefile.
		// compare between directly shading the path segments and shading
		// path segments that have been reshuffled to be contiguous in memory.

		if (sortByMaterial) {
			cudaMemcpy(
				dev_materialSortBuffer2, dev_materialSortBuffer, sizeof(int) * numPaths, cudaMemcpyDeviceToDevice
			);
			thrust::sort_by_key(thrust::device, dev_materialSortBuffer, dev_materialSortBuffer + numPaths, dev_intersections);
			thrust::sort_by_key(thrust::device, dev_materialSortBuffer2, dev_materialSortBuffer2 + numPaths, dev_paths);
		}

		shade<<<numblocksPathSegmentTracing, blockSize1d>>>(
			iter, depth, numPaths, dev_intersections, dev_paths,
			dev_samplePool + depth * numStratifiedSamples, stratifiedSamplingRange, numStratifiedSamples,
			lightMis, numLights,
			dev_geoms, dev_materials, dev_aabbTree, aabbTreeRoot
		);

		numPaths = thrust::partition(thrust::device, dev_paths, dev_paths + numPaths, IsRayTravelling()) - dev_paths;
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather<<<numBlocksPixels, blockSize1d>>>(
		pixelcount,
		dev_directIllum, dev_directIllumSqr,
		dev_indirectIllum, dev_indirectIllumSqr,
		dev_paths
	);

	checkCUDAError("pathtrace");
}

void updateStratifiedSamples(
	const std::vector<std::vector<IntersectionSample>> &pools, const std::vector<CameraSample> &camSamples
) {
	IntersectionSample *dev_ptr = dev_samplePool;
	for (std::size_t i = 0; i < pools.size(); ++i) {
		cudaMemcpy(
			dev_ptr, pools[i].data(), pools[i].size() * sizeof(IntersectionSample), cudaMemcpyHostToDevice
		);
		dev_ptr += pools[i].size();
	}
	cudaMemcpy(
		dev_camSamplePool, camSamples.data(), camSamples.size() * sizeof(CameraSample), cudaMemcpyHostToDevice
	);
}


template <typename T> __host__ __device__ T &texelFetch(T *tex, int width, int height, int x, int y) {
	// clamp
	x = glm::clamp(x, 0, width - 1);
	y = glm::clamp(y, 0, height - 1);
	return tex[y * width + x];
}

__host__ __device__ glm::vec3 textureSampleBilinear(
	const glm::vec3 *tex, int width, int height, float pixelX, float pixelY
) {
	pixelX -= 0.5f;
	pixelY -= 0.5f;
	int x = static_cast<int>(glm::floor(pixelX)), y = static_cast<int>(glm::floor(pixelY));
	float fx = pixelX - static_cast<float>(x), fy = pixelY - static_cast<float>(y);

	glm::vec3
		p11 = texelFetch(tex, width, height, x, y), p12 = texelFetch(tex, width, height, x + 1, y),
		p21 = texelFetch(tex, width, height, x, y + 1), p22 = texelFetch(tex, width, height, x + 1, y + 1);

	return glm::mix(glm::mix(p11, p12, fx), glm::mix(p21, p22, fx), fy);
}

__global__ void aTrousIter(
	const glm::vec3 *color, const glm::vec3 *normal, const glm::vec3 *position,
	const float *stddev, int width, int height, float stepSize,
	float colorWeightSqr, float normalWeightSqr, float positionWeightSqr,
	glm::vec3 *colorOut
) {
	int ix = threadIdx.x + blockIdx.x * blockDim.x;
	int iy = threadIdx.y + blockIdx.y * blockDim.y;
	if (ix >= width || iy >= height) {
		return;
	}
	int pixelIndex = iy * width + ix;

	float totalWeight = 0.0f;
	glm::vec3 totalColor(0.0f);

	glm::vec3
		centerColor = color[pixelIndex],
		centerNormal = normal[pixelIndex],
		centerPosition = position[pixelIndex];
	float centerStddev = stddev[pixelIndex];

	float centerX = ix + 0.5f, centerY = iy + 0.5f;
	const float
		offsets[5]{ -2.0f * stepSize, -1.0f * stepSize, 0.0f, 1.0f * stepSize, 2.0f * stepSize },
		weights[5]{ 0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f };
#pragma unroll
	for (int x = 0; x < 5; ++x) {
#pragma unroll
		for (int y = 0; y < 5; ++y) {
			float curWeight = weights[x] * weights[y];
			glm::vec3 curColor;
			if (x == 2 && y == 2) {
				curColor = centerColor;
			} else {
				float pixelX = centerX + offsets[x], pixelY = centerY + offsets[y];

				curColor = textureSampleBilinear(color, width, height, pixelX, pixelY);
				float colorExp = glm::length2(curColor - centerColor) / (colorWeightSqr * centerStddev + 0.01f);

				glm::vec3 curNormal = textureSampleBilinear(normal, width, height, pixelX, pixelY);
				float normalExp = glm::length2(curNormal - centerNormal) / (normalWeightSqr * stepSize * stepSize);

				glm::vec3 curPosition = textureSampleBilinear(position, width, height, pixelX, pixelY);
				float positionExp = glm::length2(curPosition - centerPosition) / positionWeightSqr;

				curWeight *= glm::exp(-(colorExp + normalExp + positionExp));
			}
			totalColor += curWeight * curColor;
			totalWeight += curWeight;
		}
	}

	colorOut[iy * width + ix] = totalColor / totalWeight;
}

__global__ void aTrousCopyBuffer(const glm::vec3 *accumBuf, glm::vec3 *target, int numPixels, int iter) {
	int iSelf = threadIdx.x + blockIdx.x * blockDim.x;
	if (iSelf >= numPixels) {
		return;
	}
	target[iSelf] = accumBuf[iSelf] / static_cast<float>(iter);
}

__global__ void aTrousGenBuffers(
	Camera cam, glm::vec3 *normal, glm::vec3 *position,
	int width, int height, int iter,
	const Geom* geoms, const AABBTreeNode* aabbTree, int aabbTreeRoot
) {
	int ix = threadIdx.x + blockIdx.x * blockDim.x;
	int iy = threadIdx.y + blockIdx.y * blockDim.y;
	if (ix >= width || iy >= height) {
		return;
	}
	int pixelIndex = iy * width + ix;

	glm::vec3 dir =
		cam.view -
		cam.right * (cam.pixelLength.x * ((static_cast<float>(ix) - 0.5f) / cam.resolution.x - 0.5f)) -
		cam.up * (cam.pixelLength.y * ((static_cast<float>(iy) - 0.5f) / cam.resolution.x - 0.5f));

	glm::vec3 &norm = normal[pixelIndex], &pos = position[pixelIndex];

	Ray ray;
	ray.origin = cam.position;
	ray.direction = dir;

	float dist = FLT_MAX;
	glm::vec3 normalToken;
	int geomId = traverseAABBTree<false>(ray, aabbTree, aabbTreeRoot, geoms, -1, -1, &dist, &normalToken);
	if (geomId != -1) {
		glm::vec3 geomNorm, shadeNorm;
		computeNormals(geoms[geomId], normalToken, &geomNorm, &shadeNorm);

		pos = ray.origin + dist * ray.direction;
		norm = shadeNorm;
	} else {
		pos = glm::vec3(0.0f);
		norm = glm::vec3(0.0f);
	}
}

__global__ void aTrousComputeVariance(
	float *stddev, const glm::vec3 *colorTotal, const float *colorSqr,
	int width, int height, int iter
) {
	int ix = threadIdx.x + blockIdx.x * blockDim.x;
	int iy = threadIdx.y + blockIdx.y * blockDim.y;
	if (ix >= width || iy >= height) {
		return;
	}
	int pixelIndex = iy * width + ix;

	glm::vec3 pixColorTotal = colorTotal[pixelIndex];
	float pixColorSqrTotal = colorSqr[pixelIndex];
	if (iter > 1) {
		stddev[pixelIndex] = glm::sqrt(glm::max(
			0.0f,
			(pixColorSqrTotal - glm::length2(pixColorTotal) / static_cast<float>(iter)) / (iter - 1)
		));
	} else {
		stddev[pixelIndex] = 1.0f; // do not use variance
	}
}

void aTrousPrepare(int iter) {
	const Camera &cam = hst_scene->state.camera;

	dim3 blockSize2D(16, 16);
	dim3 numBlocks2D(
		(cam.resolution.x + blockSize2D.x - 1) / blockSize2D.x,
		(cam.resolution.y + blockSize2D.y - 1) / blockSize2D.y
	);

	aTrousGenBuffers<<<numBlocks2D, blockSize2D>>> (
		hst_scene->state.camera, dev_normalBuffer, dev_positionBuffer,
		cam.resolution.x, cam.resolution.y, iter,
		dev_geoms, dev_aabbTree, aabbTreeRoot
	);
}

void aTrous(
	BufferType buf, int levels, float radius, int iter, float colorWeight, float normalWeight, float positionWeight
) {
	const Camera &cam = hst_scene->state.camera;

	int numPixels = cam.resolution.x * cam.resolution.y;
	int blockSize = 128;
	int numBlocks = (numPixels + blockSize - 1) / blockSize;

	dim3 blockSize2D(16, 16);
	dim3 numBlocks2D(
		(cam.resolution.x + blockSize2D.x - 1) / blockSize2D.x,
		(cam.resolution.y + blockSize2D.y - 1) / blockSize2D.y
	);

	const glm::vec3 *colorBuf;
	glm::vec3 **resultBuf;
	const float *colorSqrBuf;
	if (buf == BufferType::DirectSpecularIllumination) {
		colorBuf = dev_indirectIllum;
		colorSqrBuf = dev_indirectIllumSqr;
		resultBuf = &dev_filteredIndirectDiffuse;
	} else if (buf == BufferType::IndirectDiffuseIllumination) {
		colorBuf = dev_directIllum;
		colorSqrBuf = dev_directIllumSqr;
		resultBuf = &dev_filteredDirectSpecular;
	} else {
		std::abort();
	}

	aTrousCopyBuffer<<<numBlocks, blockSize>>>(colorBuf, *resultBuf, numPixels, iter);
	aTrousComputeVariance<<<numBlocks2D, blockSize2D>>>(
		dev_stddevBuffer, colorBuf, colorSqrBuf, cam.resolution.x, cam.resolution.y, iter
	);

	float stepSize = 0.5f * radius / glm::pow(2.0f, levels);
	for (int i = 0; i < levels; ++i) {
		aTrousIter<<<numBlocks2D, blockSize2D>>>(
			*resultBuf, dev_normalBuffer, dev_positionBuffer,
			dev_stddevBuffer, cam.resolution.x, cam.resolution.y, stepSize,
			colorWeight * colorWeight, normalWeight * normalWeight, positionWeight * positionWeight,
			dev_filteredTemp
		);

		stepSize *= 2.0f;
		std::swap(*resultBuf, dev_filteredTemp);
	}
}


__host__ __device__ glm::vec3 processTexel(
	const glm::vec3 *buf1, const void *buf2, int index, BufferType bufType, int iter
) {
	glm::vec3 pix1 = buf1[index];
	switch (bufType) {
	case BufferType::DirectSpecularIlluminationVariance:
		[[fallthrough]];
	case BufferType::IndirectDiffuseIlluminationVariance:
		{
			float sumSqr = static_cast<const float*>(buf2)[index];
			float variance = (sumSqr - glm::length2(pix1) / static_cast<float>(iter)) / (iter - 1);
			return glm::pow(glm::vec3(variance, 0.0f, 0.0f), glm::vec3(0.3f));
		}

	case BufferType::DirectSpecularIllumination:
		[[fallthrough]];
	case BufferType::IndirectDiffuseIllumination:
		[[fallthrough]];
	case BufferType::FullIllumination:
		{
			if (buf2) {
				pix1 += static_cast<const glm::vec3*>(buf2)[index];
			}
			glm::vec3 raw = pix1 / static_cast<float>(iter);
			pix1 = glm::pow(raw, glm::vec3(1.0f / 2.2f));
#if defined(CHECK_NAN) || defined(CHECK_NEGATIVE)
			{
				glm::vec3 newPix = glm::clamp(pix1 * 0.2f, 0.0f, 0.2f);
#	ifdef CHECK_NAN
				if (glm::any(glm::isnan(raw))) {
					newPix.x = 1.0f;
				}
#	endif
#	ifdef CHECK_INF
				if (glm::any(glm::isinf(raw))) {
					newPix.y = 1.0f;
				}
#	endif
#	ifdef CHECK_NEGATIVE
				if (glm::any(glm::lessThan(raw, glm::vec3(0.0f)))) {
					newPix.z = 1.0f;
				}
#	endif
				pix1 = newPix;
			}
#endif
			return pix1;
		}

	case BufferType::Normal:
		return (pix1 + 1.0f) * 0.5f;

	case BufferType::Position:
		{
			float scale = 30.0f;
			return (pix1 + 0.5f * scale) / scale;
		}

	case BufferType::FilteredDirectSpecular:
		[[fallthrough]];
	case BufferType::FilteredIndirectDiffuse:
		return glm::pow(pix1, glm::vec3(1.0f / 2.2f));

	case BufferType::FilteredColor:
		return glm::pow(
			pix1 + static_cast<const glm::vec3*>(buf2)[index],
			glm::vec3(1.0f / 2.2f)
		);
	}
}

__global__ void sendImageToPBO(
	uchar4 *pbo, const glm::vec3 *buf1, const void *buf2, glm::ivec2 resolution, int iter, BufferType bufType
) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = processTexel(buf1, buf2, index, bufType, iter);
		glm::ivec3 color = glm::clamp(glm::ivec3(pix * 255.0f), 0, 255);
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

__global__ void processImage(
	glm::vec3 *out, const glm::vec3 *in1, const void *in2, glm::ivec2 resolution, int iter, BufferType bufType
) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		out[index] = processTexel(in1, in2, index, bufType, iter);
	}
}

void getBuffers(BufferType buf, const glm::vec3 **buf1, const void **buf2) {
	*buf2 = nullptr;
	switch (buf) {
	case BufferType::DirectSpecularIlluminationVariance:
		*buf2 = dev_directIllumSqr;
		[[fallthrough]];
	case BufferType::DirectSpecularIllumination:
		*buf1 = dev_directIllum;
		break;
	case BufferType::IndirectDiffuseIlluminationVariance:
		*buf2 = dev_indirectIllumSqr;
		[[fallthrough]];
	case BufferType::IndirectDiffuseIllumination:
		*buf1 = dev_indirectIllum;
		break;
	case BufferType::FullIllumination:
		*buf1 = dev_directIllum;
		*buf2 = dev_indirectIllum;
		break;
	case BufferType::Normal:
		*buf1 = dev_normalBuffer;
		break;
	case BufferType::Position:
		*buf1 = dev_positionBuffer;
		break;
	case BufferType::FilteredDirectSpecular:
		*buf1 = dev_filteredDirectSpecular;
		break;
	case BufferType::FilteredIndirectDiffuse:
		*buf1 = dev_filteredIndirectDiffuse;
		break;
	case BufferType::FilteredColor:
		*buf1 = dev_filteredDirectSpecular;
		*buf2 = dev_filteredIndirectDiffuse;
		break;
	}
}

void sendBufferToPbo(uchar4 *pbo, BufferType buf, int iter) {
	const Camera &cam = hst_scene->state.camera;

	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	const glm::vec3 *buf1;
	const void *buf2;
	getBuffers(buf, &buf1, &buf2);
	sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, buf1, buf2, cam.resolution, iter, buf);
}

void saveBufferState(BufferType buf, int iter) {
	const Camera &cam = hst_scene->state.camera;

	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	glm::vec3 *tmpBuffer;
	cudaMalloc(&tmpBuffer, cam.resolution.x * cam.resolution.y * sizeof(glm::vec3));

	const glm::vec3 *buf1;
	const void *buf2;
	getBuffers(buf, &buf1, &buf2);
	processImage<<<blocksPerGrid2d, blockSize2d>>>(tmpBuffer, buf1, buf2, cam.resolution, iter, buf);
	cudaMemcpy(
		hst_scene->state.image.data(), tmpBuffer,
		cam.resolution.x * cam.resolution.y * sizeof(glm::vec3),
		cudaMemcpyDeviceToHost
	);
	cudaFree(tmpBuffer);
}
