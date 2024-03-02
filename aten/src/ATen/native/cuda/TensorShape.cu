#define TORCH_ASSERT_ONLY_METHOD_OPERATORS
#include <ATen/Dispatch.h>
#include <ATen/core/Tensor.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/native/Resize.h>

#ifndef AT_PER_OPERATOR_HEADERS
#include <ATen/Functions.h>
#include <ATen/NativeFunctions.h>
#else
#include <ATen/ops/empty.h>
#include <ATen/ops/split_with_sizes_copy_native.h>
#include <ATen/ops/_chunk_cat_native.h>
#endif

#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 800
#include <cuda_bf16.h>
#endif

namespace at::native {

namespace detail {

// NOTE [CUDA fast path for split_with_sizes_copy.out]
// split_with_sizes_copy.out for contiguous operands has the following
// properties:
// - Each src split consists of multiple chunks that are separated by a fixed
// stride. The number of chunks and the strides are the same across all src
// splits.
// - Each dst split is the concatenation of the chunks in its corresponding src
// splits.
// - The sizes of chunks vary across splits.
// - A (src, dst) chunk pair is not guaranteed to have the
// same alignment.
//
// The following strategies are employed to optimize for this workload:
// - The entire workload is fused into a single kernel to maximize I/O
// throughput and minimize wave quantization.
// - To account for both small and large chunk sizes, a "jagged grid" is used.
// Each chunk is processed by one or more blocks depending on its size.
// - Within each chunk, the region in which writes can be vectorized is
// identified. Within this region, writes are always vectorized and reads are
// oppurtunistically vectorized.
static constexpr int64_t BLOCK_SIZE = 128;
static constexpr int64_t BYTES_PER_THREAD = 16;
static constexpr int64_t TILE_SIZE = BYTES_PER_THREAD * BLOCK_SIZE;

static __host__ __device__ inline int64_t div_up(int64_t a, int64_t b) {
  return (a + b - 1) / b;
}

static __host__ __device__ inline int64_t maxInt64(int64_t a, int64_t b) {
  return a < b ? b : a;
}

static __host__ __device__ inline int64_t minInt64(int64_t a, int64_t b) {
  return a < b ? a : b;
}

template <typename T>
__device__ inline void stream_load128(uint4& val, const T* addr) {
  uint64_t low, high;
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  low = reinterpret_cast<const uint64_t*>(addr)[0];
  high = reinterpret_cast<const uint64_t*>(addr)[1];
#else
  asm("ld.global.nc.v2.u64 {%0, %1}, [%2];"
      : "=l"(low), "=l"(high)
      : "l"(addr));
#endif
  reinterpret_cast<uint64_t*>(&val)[0] = low;
  reinterpret_cast<uint64_t*>(&val)[1] = high;
}

template <typename T>
__device__ inline void stream_store128(T* addr, const uint4& val) {
  uint64_t low, high;
  low = reinterpret_cast<const uint64_t*>(&val)[0];
  high = reinterpret_cast<const uint64_t*>(&val)[1];
#if defined(USE_ROCM) || (defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 800))
  reinterpret_cast<uint64_t*>(addr)[0] = low;
  reinterpret_cast<uint64_t*>(addr)[1] = high;
#else
  asm("st.global.cs.v2.u64 [%0], {%1, %2};" : : "l"(addr), "l"(low), "l"(high));
#endif
}

template <typename T>
static __device__ inline bool is_aligned(const void* addr) {
  return reinterpret_cast<uintptr_t>(addr) % sizeof(T) == 0;
}

template <typename T>
static __device__ inline void load128(uint4& val, const char* addr) {
  for (size_t i = 0; i < detail::BYTES_PER_THREAD / sizeof(T); ++i) {
    reinterpret_cast<T*>(&val)[i] = reinterpret_cast<const T*>(addr)[i];
  }
}

template <>
__device__ inline void load128<uint4>(uint4& val, const char* addr) {
  stream_load128(val, addr);
}

static __device__ inline void load128(uint4& val, const char* addr) {
  if (is_aligned<uint4>(addr)) {
    load128<uint4>(val, addr);
  } else if (is_aligned<int64_t>(addr)) {
    load128<uint64_t>(val, addr);
  } else if (is_aligned<uint32_t>(addr)) {
    load128<uint32_t>(val, addr);
  } else {
    load128<uint8_t>(val, addr);
  }
}

static __device__ __inline__ void get_aligned_region(
    char* ptr,
    const int64_t chunk_size,
    const int64_t alignment,
    int64_t& align_off,
    int64_t& aligned_size) {
  const int64_t ptr_val = reinterpret_cast<uintptr_t>(ptr);
  align_off = detail::div_up(ptr_val, alignment) * alignment - ptr_val;
  aligned_size = (chunk_size - align_off) / alignment * alignment;
}

__device__ inline uint4 get_zero_uint4() {
  uint4 zero;
  reinterpret_cast<uint64_t*>(&zero)[0] = 0;
  reinterpret_cast<uint64_t*>(&zero)[1] = 0;
  return zero;
}

static __device__ __inline__ void copy_chunk(
    char* dst,
    const char* src,
    int64_t chunk_size,
    int64_t thread_idx,
    int64_t num_threads) {
  if (chunk_size < num_threads) {
    if (thread_idx < chunk_size) {
      dst[thread_idx] = src[thread_idx];
    }
    return;
  }

  // Identify the region in which writes are guaranteed to be 128-bit aligned
  int64_t align_off, aligned_size;
  get_aligned_region(
      dst, chunk_size, detail::BYTES_PER_THREAD, align_off, aligned_size);

  for (int64_t off = align_off + thread_idx * detail::BYTES_PER_THREAD;
       off < align_off + aligned_size;
       off += num_threads * detail::BYTES_PER_THREAD) {
    uint4 val;
    // Oppurtunistically vectorize reads
    load128(val, &src[off]);
    stream_store128(&dst[off], val);
  }

  // Handle unaligned regions
  if (thread_idx < align_off && thread_idx < chunk_size) {
    dst[thread_idx] = src[thread_idx];
  }
  if (align_off + aligned_size + thread_idx < chunk_size) {
    dst[align_off + aligned_size + thread_idx] =
        src[align_off + aligned_size + thread_idx];
  }
}

static __global__ void split_with_sizes_copy_out_contiguous_no_cast_kernel(
    char** dst_base_addrs,
    char** src_base_addrs,
    int64_t* split_chunk_sizes,
    int64_t* block_idx_to_split_idx,
    int64_t* blocks_cumsums,
    int64_t src_stride,
    int64_t num_chunks) {
  const int64_t split_idx = block_idx_to_split_idx[blockIdx.x];
  const int64_t split_blocks =
      blocks_cumsums[split_idx + 1] - blocks_cumsums[split_idx];
  const int64_t split_threads = split_blocks * blockDim.x;
  const int64_t split_thread_idx =
      (blockIdx.x - blocks_cumsums[split_idx]) * blockDim.x + threadIdx.x;
  const int64_t split_chunk_size = split_chunk_sizes[split_idx];

  char* dst_base_addr = dst_base_addrs[split_idx];
  char* src_base_addr = src_base_addrs[split_idx];

  for (int64_t i = blockIdx.y; i < num_chunks; i += gridDim.y) {
    copy_chunk(
        dst_base_addr + i * split_chunk_size,
        src_base_addr + i * src_stride,
        split_chunk_size,
        split_thread_idx,
        split_threads);
  }
}

// Calculate the base addr for each split.
static inline std::vector<int64_t> get_split_base_addrs(
    const at::Tensor& tensor,
    at::IntArrayRef split_sizes,
    int64_t dim) {
  const auto* data_ptr = static_cast<char*>(tensor.data_ptr());
  const auto strides = tensor.strides();
  const auto element_sz = tensor.element_size();
  int64_t off = 0;
  std::vector<int64_t> split_base_addrs;
  split_base_addrs.reserve(split_sizes.size());
  for (const auto& split_size : split_sizes) {
    split_base_addrs.push_back(reinterpret_cast<int64_t>(data_ptr + off));
    off += split_size * strides[dim] * element_sz;
  }
  return split_base_addrs;
}

static inline std::vector<int64_t> get_dst_addrs(at::TensorList out) {
  std::vector<int64_t> addrs;
  addrs.reserve(out.size());
  for (const auto& tensor : out) {
    addrs.push_back(reinterpret_cast<int64_t>(tensor.data_ptr()));
  }
  return addrs;
}

// Calculate the chunk size for each split in bytes.
static inline std::vector<int64_t> get_split_chunk_sizes(
    const at::Tensor& tensor,
    at::IntArrayRef split_sizes,
    int64_t dim) {
  const auto stride = tensor.stride(dim);
  const auto element_sz = tensor.element_size();
  std::vector<int64_t> split_chunk_sizes;
  split_chunk_sizes.reserve(split_sizes.size());
  for (const auto& split_size : split_sizes) {
    split_chunk_sizes.push_back(split_size * stride * element_sz);
  }
  return split_chunk_sizes;
}

// Calculate the chunk stride in bytes. This is the same for all splits.
static inline int64_t get_chunk_stride(const at::Tensor& tensor, int64_t dim) {
  int64_t stride = 1;
  for (int64_t d = dim; d < tensor.dim(); ++d) {
    stride *= tensor.sizes()[d];
  }
  return stride * tensor.element_size();
}

// Calculate the number of chunks. This is the same for all splits.
static inline int64_t get_num_chunks(const at::Tensor& tensor, int64_t dim) {
  int64_t num_chunks = tensor.numel();
  for (int64_t d = dim; d < tensor.dim(); ++d) {
    num_chunks /= tensor.sizes()[d];
  }
  return num_chunks;
}

// Pack multiple std::vector<int64_t> into a single cuda tensor.
std::pair<at::Tensor, std::vector<int64_t*>> pack_vecs(
    std::vector<const std::vector<int64_t>*> vecs,
    const at::Device& device) {
  int64_t numel = 0;
  for (const auto* vec : vecs) {
    numel += vec->size();
  }

  auto packed = at::empty(
      {numel}, at::TensorOptions().dtype(at::kLong).pinned_memory(true));
  size_t offset = 0;
  for (const auto* vec : vecs) {
    memcpy(
        packed.data_ptr<int64_t>() + offset,
        vec->data(),
        sizeof(int64_t) * vec->size());
    offset += vec->size();
  }
  packed = packed.to(device, /*non_blocking=*/true);

  std::vector<int64_t*> ptrs;
  ptrs.reserve(vecs.size());
  offset = 0;
  for (const auto* vec : vecs) {
    ptrs.push_back(packed.data_ptr<int64_t>() + offset);
    offset += vec->size();
  }
  return std::make_pair(std::move(packed), std::move(ptrs));
}

// Copy `max_chunk_size` bytes from `src` to `dst` by `num_threads`, and pad zero when
// `src` size (i.e., actual_chunk_size) is less than `max_chunk_size`.
static __device__ __inline__ void copy_chunk_with_pad(
  char* dst,
  const char* src,
  int64_t max_chunk_size,
  int64_t actual_chunk_size,
  int64_t thread_idx,
  int64_t num_threads
) {
  if (max_chunk_size < num_threads) {
    int64_t val = 0;
    if (thread_idx < actual_chunk_size) {
      val = src[thread_idx];
    }
    if(thread_idx < max_chunk_size) {
      dst[thread_idx] = val;
    }
    return;
  }
  uint4 zero = get_zero_uint4();
  int64_t align_off, aligned_size;
  get_aligned_region(dst, actual_chunk_size, BYTES_PER_THREAD, align_off, aligned_size);
  int64_t align_end = align_off + aligned_size;
  for (
    int64_t i = align_off + thread_idx * BYTES_PER_THREAD;
    i < align_end;
    i += num_threads * BYTES_PER_THREAD
  ) {
    uint4 val = zero;
    if(is_aligned<uint4>(src + i)) {
      stream_load128(val, src + i);
    } else {
      for (size_t j = 0; j < BYTES_PER_THREAD; ++j) {
        reinterpret_cast<char*>(&val)[j] = src[i + j];
      }
    }
    stream_store128(&dst[i], val);
  }
  if(thread_idx < align_off && thread_idx < max_chunk_size) {
    char val = (char) 0;
    if (thread_idx < actual_chunk_size) {
      val = src[thread_idx];
    }
    dst[thread_idx] = val;
  }
  while(align_end + thread_idx < max_chunk_size) {
    char val = (char) 0;
    if (align_end + thread_idx < actual_chunk_size) {
      val = src[align_end + thread_idx];
    }
    dst[align_end + thread_idx] = val;
    align_end += num_threads;
  }
}

// Read `actual_chunk_size` bytes from bfloat16 array `src`  (i.e., actual_chunk_size/2 bfloat16 elements),
// cast bfloat16 to float, and write to float array `dst`. Pad 0.0f if 2*actual_chunk_size < max_chunk_size.
// src: pointer to a bfloat16 array
// dst: pointer to a float32 array
// max_chunk_size: number of bytes in dst array
// actual_chunk_size: number of bytes in src array, which is less than or equal to max_chunk_size / 2
static __device__ __inline__ void copy_chunk_with_pad_cast_bfloat16_to_float(
  char* dst,
  const char* src,
  int64_t max_chunk_size,
  int64_t actual_chunk_size,
  int64_t thread_idx,
  int64_t num_threads
) {
  const int64_t dst_elem_size = 4;
  const int64_t src_elem_size = 2;
  const int64_t max_num_elems = max_chunk_size / dst_elem_size;
  const int64_t actual_num_elems = actual_chunk_size / src_elem_size;
  int64_t elem_index = thread_idx;
  while (elem_index < actual_num_elems) {
    reinterpret_cast<float*>(dst)[elem_index] = __bfloat162float(
      reinterpret_cast<const __nv_bfloat16*>(src)[elem_index]
    );
    elem_index += num_threads;
  }
  while (elem_index < max_num_elems) {
    reinterpret_cast<float*>(dst)[elem_index] = 0.0f;
    elem_index += num_threads;
  }
}

// NOTE [CUDA kernel for chunk_cat]
// chunk_cat_cuda adopts a "jagged grid" strategy, inspired by NOTE [CUDA fast path for split_with_sizes_copy.out].
// In addition, chunk_cat_cuda supports padding via copy_chunk_with_pad when src chunk size is less than
// dst chunk size.
static __global__ void chunk_cat_cuda_kernel(
  char** src,
  char* dst,
  int64_t* block_idx_to_tensor_idx,
  int64_t* tensor_idx_to_start_tensor_bytes,
  int64_t* start_block_idx_per_tensor_chunk,
  int64_t* actual_tensor_sizes,
  int64_t* pad_tensor_chunk_sizes,
  int64_t* num_blocks_per_tensor_chunk,
  int64_t slice_size,
  int64_t chunk_size,
  bool bf162float // copying from bf16 to float if True else assuming same elem type for src and dst
) {
  const int64_t slice_idx = blockIdx.z;
  const int64_t chunk_idx = blockIdx.y;
  const int64_t tensor_idx = block_idx_to_tensor_idx[blockIdx.x];
  const int64_t tile_idx = blockIdx.x - start_block_idx_per_tensor_chunk[tensor_idx];
  // Number of threads for the `tensor_idx`-th tensor chunk.
  const int64_t num_threads = num_blocks_per_tensor_chunk[tensor_idx] * BLOCK_SIZE;
  const int64_t thread_idx = tile_idx * BLOCK_SIZE + threadIdx.x;
  int64_t ratio = 1;
  if (bf162float) {
    ratio = 2;
  }
  const char* src_addr = src[tensor_idx]
      + slice_idx * actual_tensor_sizes[tensor_idx]
      + chunk_idx * pad_tensor_chunk_sizes[tensor_idx] / ratio;
  char* dst_addr = dst
      + slice_idx * slice_size
      + chunk_idx  * chunk_size
      + tensor_idx_to_start_tensor_bytes[tensor_idx];
  // Compute the actual number of bytes to copy from src.
  const int64_t actual_copy_size = minInt64(pad_tensor_chunk_sizes[tensor_idx] / ratio,
     maxInt64(0, actual_tensor_sizes[tensor_idx] - chunk_idx * pad_tensor_chunk_sizes[tensor_idx] / ratio));
  if (bf162float) {
    copy_chunk_with_pad_cast_bfloat16_to_float(
      dst_addr,
      src_addr,
      pad_tensor_chunk_sizes[tensor_idx],
      actual_copy_size,
      thread_idx,
      num_threads
    );
  } else {
    copy_chunk_with_pad(
      dst_addr,
      src_addr,
      pad_tensor_chunk_sizes[tensor_idx],
      actual_copy_size,
      thread_idx,
      num_threads
    );
  }
}

// Checks if chunk_cat inputs are valid on CUDA devices:
// 1. tensors are non-empty
// 2. all tensors have the same shape for `(0,1,...,dim-1)`-th dimensions
// 3. all tensors are on cuda
void is_valid_chunk_cat_inputs(TensorList tensors, uint64_t dim) {
  TORCH_CHECK(!tensors.empty(),
           "chunk_cat expects a non-empty TensorList");
  const auto num_tensors = tensors.size();
  TORCH_CHECK(
    num_tensors > 0,
    "assert_leading_dimension_matches() has invalid args: should have at least 1 input tensors"
  );
  std::vector<c10::SymInt> leading_dim_sizes;
  for (const auto i : c10::irange(dim)) {
    TORCH_CHECK(tensors[0].size(i) > 0, "assert_leading_dimension_matches() error: tensor size should be positive.");
    leading_dim_sizes.push_back(tensors[0].size(i));
  }
  auto expected_dtype = tensors[0].dtype();
  c10::Device expected_device = tensors[0].device();
  for (const auto i : c10::irange(num_tensors)) {
    at::Tensor tensor = tensors[i];
    TORCH_CHECK(tensor.numel() > 0, "assert_leading_dimension_matches() error: tensor should have at least 1 element");
    auto sizes = tensor.sizes();
    TORCH_CHECK(sizes.size() >= dim, "assert_leading_dimension_matches() error: invalid dim");
    for(const auto j : c10::irange(dim)) {
      TORCH_CHECK(
        tensor.size(j) == leading_dim_sizes[j],
        "chunk_cat_cuda() has invalid args: tensors should have same sizes in the first dim dimensions"
      );
    }
    TORCH_CHECK(
      tensor.dtype() == expected_dtype,
      "chunk_cat_cuda() has invalid args: tensors should have same sizes in the first dim dimensions"
    );
    TORCH_CHECK(tensor.device() == expected_device, "chunk_cat_cuda() error: non-cuda input tensors");
  }
}

bool all_contiguous(TensorList tensors) {
  bool contiguous = true;
  for (const auto& t : tensors) {
    contiguous &= t.is_non_overlapping_and_dense();
  }
  return contiguous;
}

// Gets metadata for chunk_cat.
std::tuple<int64_t, int64_t, int64_t, int64_t, std::vector<int64_t*>> get_chunk_cat_metadata(
  TensorList tensors,
  int64_t dim,
  int64_t num_chunks,
  int64_t src_elem_size,
  int64_t dst_elem_size
) {
  TORCH_CHECK(dst_elem_size % src_elem_size == 0,
    "get_chunk_cat_metadata error: only support dst_elem_size % src_elem_size == 0");
  auto num_tensors = tensors.size();
  const auto device = tensors[0].device();
  int64_t leading_dim = 1;
  auto first_tensor_sizes = tensors[0].sizes();
  if (dim > 0) {
    leading_dim = c10::multiply_integers(first_tensor_sizes.slice(0, dim));
  }
  std::vector<int64_t> pad_tensor_chunk_sizes;
  std::vector<int64_t> num_blocks_per_tensor_chunk;
  std::vector<int64_t> start_block_idx_per_tensor_chunk{0};
  std::vector<int64_t> actual_tensor_sizes;
  std::vector<int64_t> tensor_idx_to_start_tensor_bytes{0};
  std::vector<int64_t> srcs;
  pad_tensor_chunk_sizes.reserve(num_tensors);
  num_blocks_per_tensor_chunk.reserve(num_tensors);
  start_block_idx_per_tensor_chunk.reserve(num_tensors + 1);
  actual_tensor_sizes.reserve(num_tensors);
  tensor_idx_to_start_tensor_bytes.reserve(num_tensors);
  srcs.reserve(num_tensors);
  //  block_idx_to_tensor_idx cannot be reserved since the number of blocks is data dependent.
  std::vector<int64_t> block_idx_to_tensor_idx;
  int64_t chunk_size = 0;
  for (const auto i : c10::irange(num_tensors)) {
    at::Tensor tensor = tensors[i];
    srcs.push_back(reinterpret_cast<int64_t>(tensor.data_ptr()));
    auto sizes = tensor.sizes();
    const int64_t size_along_dim = sizes[dim];
    int64_t trailing_numel = 1;
    if(sizes.size() > (uint64_t)dim + 1) {
      trailing_numel = c10::multiply_integers(sizes.slice(dim+1, sizes.size()-dim-1));
    }
    const int64_t pad_size_along_dim = detail::div_up(size_along_dim, num_chunks) * num_chunks;
    const int64_t pad_tensor_chunk_size = pad_size_along_dim * trailing_numel * dst_elem_size / num_chunks;
    pad_tensor_chunk_sizes.push_back(pad_tensor_chunk_size);
    chunk_size += pad_tensor_chunk_size;
    // Number of blocks required to process this tensor chunk.
    const int64_t num_blocks = detail::div_up(pad_tensor_chunk_size, detail::TILE_SIZE);
    num_blocks_per_tensor_chunk.push_back(num_blocks);
    start_block_idx_per_tensor_chunk.push_back(start_block_idx_per_tensor_chunk.back() + num_blocks);
    block_idx_to_tensor_idx.insert(block_idx_to_tensor_idx.end(), num_blocks, i);
    tensor_idx_to_start_tensor_bytes.push_back(tensor_idx_to_start_tensor_bytes.back() + pad_tensor_chunk_size);
    actual_tensor_sizes.push_back(size_along_dim * trailing_numel * src_elem_size);
  }
  // Tensor out = tensors[0].new_empty(chunk_size * num_chunks * leading_dim / tensors[0].element_size());
  const int64_t num_blocks_per_chunk = start_block_idx_per_tensor_chunk.back();
  const int64_t slice_size = num_chunks * chunk_size;
  auto packed = detail::pack_vecs(
    {&srcs,
     &block_idx_to_tensor_idx,
     &tensor_idx_to_start_tensor_bytes,
     &start_block_idx_per_tensor_chunk,
     &actual_tensor_sizes,
     &pad_tensor_chunk_sizes,
     &num_blocks_per_tensor_chunk},
     device);
  return std::make_tuple(chunk_size, leading_dim, num_blocks_per_chunk, slice_size, packed.second);
}

// See [CUDA kernel for chunk_cat_cuda]
Tensor _chunk_cat_cuda_contiguous_no_cast(
  TensorList tensors,
  int64_t dim,
  int64_t num_chunks
) {
  int64_t elem_size = tensors[0].element_size();
  auto [chunk_size, leading_dim, num_blocks_per_chunk, slice_size, device_ptrs] = get_chunk_cat_metadata(tensors, dim, num_chunks, elem_size, elem_size);
  Tensor out = tensors[0].new_empty(chunk_size * num_chunks * leading_dim / elem_size);
  dim3 blocks(num_blocks_per_chunk, num_chunks, leading_dim);
  dim3 threads(detail::BLOCK_SIZE, 1, 1);
  detail::chunk_cat_cuda_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
    /*srcs=*/reinterpret_cast<char**>(device_ptrs[0]),
    reinterpret_cast<char*>(out.data_ptr()),
    /*block_idx_to_tensor_idx=*/device_ptrs[1],
    /*tensor_idx_to_start_tensor_bytes=*/device_ptrs[2],
    /*start_block_idx_per_tensor_chunk=*/device_ptrs[3],
    /*actual_tensor_sizes=*/device_ptrs[4],
    /*pad_tensor_chunk_sizes=*/device_ptrs[5],
    /*num_blocks_per_tensor_chunk=*/device_ptrs[6],
    slice_size,
    chunk_size,
    /*bf162float=*/false
  );
  C10_CUDA_KERNEL_LAUNCH_CHECK();
  auto first_tensor_sizes = tensors[0].sizes();
  std::vector<int64_t> view_sizes = std::vector<int64_t>(first_tensor_sizes.begin(), first_tensor_sizes.begin()+dim);
  view_sizes.insert(view_sizes.end(), {num_chunks, -1});
  return out.view(view_sizes);
}

void _chunk_cat_out_cuda_contiguous(
  TensorList tensors,
  int64_t dim,
  int64_t num_chunks,
  Tensor &out
) {
  int64_t src_elem_size = tensors[0].element_size();
  int64_t dst_elem_size = out.element_size();
  auto [chunk_size, leading_dim, num_blocks_per_chunk, slice_size, device_ptrs] = get_chunk_cat_metadata(tensors, dim, num_chunks, src_elem_size, dst_elem_size);
  auto first_tensor_sizes = tensors[0].sizes();
  std::vector<int64_t> view_sizes = std::vector<int64_t>(first_tensor_sizes.begin(), first_tensor_sizes.begin()+dim);
  view_sizes.insert(view_sizes.end(), {num_chunks, chunk_size / dst_elem_size});
  if(out.sizes() != view_sizes) {
    if(out.numel() > 0) {
      TORCH_WARN("An output with one or more elements has been resized");
    }
    out.resize_(view_sizes);
  }
  dim3 blocks(num_blocks_per_chunk, num_chunks, leading_dim);
  dim3 threads(detail::BLOCK_SIZE, 1, 1);
  detail::chunk_cat_cuda_kernel<<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(
    /*srcs=*/reinterpret_cast<char**>(device_ptrs[0]),
    reinterpret_cast<char*>(out.data_ptr()),
    /*block_idx_to_tensor_idx=*/device_ptrs[1],
    /*tensor_idx_to_start_tensor_bytes=*/device_ptrs[2],
    /*start_block_idx_per_tensor_chunk=*/device_ptrs[3],
    /*actual_tensor_sizes=*/device_ptrs[4],
    /*pad_tensor_chunk_sizes=*/device_ptrs[5],
    /*num_blocks_per_tensor_chunk=*/device_ptrs[6],
    slice_size,
    chunk_size,
    /*bf162float=*/src_elem_size != dst_elem_size
  );
  C10_CUDA_KERNEL_LAUNCH_CHECK();
}

} // namespace detail

// See [CUDA fast path for split_with_sizes_copy.out]
void split_with_sizes_copy_out_cuda_contiguous_no_cast(
    const at::Tensor& self,
    at::IntArrayRef split_sizes,
    int64_t dim,
    at::TensorList out) {
  const auto device = self.device();
  const auto src_base_addrs =
      detail::get_split_base_addrs(self, split_sizes, dim);
  const auto dst_base_addrs = detail::get_dst_addrs(out);
  const auto src_stride = detail::get_chunk_stride(self, dim);
  const auto split_chunk_sizes =
      detail::get_split_chunk_sizes(self, split_sizes, dim);
  const auto num_chunks = detail::get_num_chunks(self, dim);

  // Calculate the number of blocks required for the first chunk across all
  // splits, assuming each thread only processes BYTES_PER_THREAD bytes.
  int64_t num_blocks = 0;
  for (const auto& split_chunk_size : split_chunk_sizes) {
    num_blocks += detail::div_up(
        split_chunk_size, detail::BLOCK_SIZE * detail::BYTES_PER_THREAD);
  }

  // Calculate the maximum number of blocks to launch. Only consider
  // maxThreadsPerMultiProcessor as a limiting factor as the kernel uses no
  // shared memory and little registers. Over-subscribe the SMs to hide I/O
  // latency.
  const auto num_sms =
      at::cuda::getCurrentDeviceProperties()->multiProcessorCount;
  const auto max_threads_per_sm =
      at::cuda::getCurrentDeviceProperties()->maxThreadsPerMultiProcessor;
  const int64_t max_blocks =
      num_sms * max_threads_per_sm / detail::BLOCK_SIZE * 2.0;

  // Make each thread process BYTES_PER_THREAD * iter_factor bytes to regulate
  // block size. Spread iter_factor evenly between chunks_per_block and
  // iters_per_chunk.
  int64_t iter_factor = detail::div_up(num_blocks * num_chunks, max_blocks);
  int64_t chunks_per_block = std::ceil(std::sqrt(iter_factor));
  chunks_per_block = std::min(chunks_per_block, num_chunks);
  const int64_t iters_per_chunk = detail::div_up(iter_factor, chunks_per_block);

  // Launch a logically jagged grid of shape
  // (chunk_size*, num_splits, num_chunks / chunks_per_block)
  // backed by a physical grid of shape
  // (sum(chunk_size), num_chunks / chunks_per_block).
  // A block can find its split_idx via block_idx_to_split_idx.
  std::vector<int64_t> block_idx_to_split_idx;
  std::vector<int64_t> blocks_cumsums{0};
  block_idx_to_split_idx.reserve(num_blocks);
  for (size_t split_idx = 0; split_idx < split_sizes.size(); ++split_idx) {
    const auto blocks = detail::div_up(
        split_chunk_sizes[split_idx],
        detail::BLOCK_SIZE * detail::BYTES_PER_THREAD * iters_per_chunk);
    block_idx_to_split_idx.insert(
        block_idx_to_split_idx.end(), blocks, split_idx);
    blocks_cumsums.push_back(blocks_cumsums.back() + blocks);
  }

  dim3 blocks(blocks_cumsums.back(), num_chunks / chunks_per_block, 1);
  dim3 threads(detail::BLOCK_SIZE, 1, 1);

  auto [_, ptrs] = detail::pack_vecs(
      {&dst_base_addrs,
       &src_base_addrs,
       &split_chunk_sizes,
       &block_idx_to_split_idx,
       &blocks_cumsums},
      device);

  detail::split_with_sizes_copy_out_contiguous_no_cast_kernel<<<
      blocks,
      threads,
      0,
      at::cuda::getCurrentCUDAStream()>>>(
      /*dst_base_addrs=*/reinterpret_cast<char**>(ptrs[0]),
      /*src_base_addrs=*/reinterpret_cast<char**>(ptrs[1]),
      /*split_chunk_sizes=*/ptrs[2],
      /*block_idx_to_split_idx=*/ptrs[3],
      /*blocks_cumsums=*/ptrs[4],
      src_stride,
      num_chunks);
  C10_CUDA_KERNEL_LAUNCH_CHECK();
}

void split_with_sizes_copy_out_cuda(
    const Tensor& self,
    IntArrayRef split_sizes,
    int64_t dim,
    TensorList out) {
  bool contiguous_no_cast = self.is_non_overlapping_and_dense();
  for (const auto& t : out) {
    contiguous_no_cast &= t.is_non_overlapping_and_dense();
    contiguous_no_cast &= (t.dtype() == self.dtype());
  }
  if (contiguous_no_cast) {
    // Perform equivalent checks performed by the composite impl
    if (dim < 0) {
      dim = at::maybe_wrap_dim(dim, self.dim());
    }
    TORCH_CHECK(
        self.dim() != 0, "split expects at least a 1-dimensional tensor")

    const int64_t dim_size = self.size(dim);
    int64_t split_sizes_sum = 0;
    for (const auto i : c10::irange(split_sizes.size())) {
      TORCH_CHECK(
          split_sizes[i] >= 0,
          "split_with_sizes expects split_sizes have only non-negative ",
          "entries, but got split_sizes=",
          split_sizes[i]);
      split_sizes_sum += split_sizes[i];
    }
    TORCH_CHECK(
        split_sizes_sum == dim_size,
        "split_with_sizes expects split_sizes to sum exactly to ",
        dim_size,
        " (input tensor's size at dimension ",
        dim,
        "), ",
        "but got split_sizes=",
        split_sizes);

    TORCH_CHECK(
        out.size() == split_sizes.size(),
        "split_with_sizes_copy_out() expected an out= argument of size ",
        split_sizes.size(),
        ", got size ",
        out.size());

    auto out_shape = self.sizes().vec();
    for (const auto i : c10::irange(split_sizes.size())) {
      out_shape[dim] = split_sizes[i];
      if (resize_output_check(out[i], out_shape)) {
        out[i].resize_(out_shape);
      }
      TORCH_CHECK(
          out[i].dtype() == self.dtype(),
          "Expected out tensor to have dtype ",
          self.dtype(),
          ", but got ",
          out[i].dtype(),
          " instead");
      TORCH_CHECK(
          out[i].device() == self.device(),
          "Expected out tensor to have device ",
          self.device(),
          ", but got ",
          out[i].device(),
          " instead");
    }
    split_with_sizes_copy_out_cuda_contiguous_no_cast(
        self, split_sizes, dim, out);
  } else {
    at::native::split_with_sizes_copy_out(self, split_sizes, dim, out);
  }
}

Tensor _chunk_cat_cuda(
  TensorList tensors,
  int64_t dim,
  int64_t num_chunks
) {
  dim = at::maybe_wrap_dim(dim, tensors[0].dim());
  detail::is_valid_chunk_cat_inputs(tensors, (uint64_t)dim);
  if(detail::all_contiguous(tensors)) {
    return detail::_chunk_cat_cuda_contiguous_no_cast(tensors, dim, num_chunks);
  } else {
    return at::native::_chunk_cat(tensors, dim, num_chunks);
  }
}

Tensor& _chunk_cat_out_cuda(
  TensorList tensors,
  int64_t dim,
  int64_t num_chunks,
  Tensor &out
) {
  dim = at::maybe_wrap_dim(dim, tensors[0].dim());
  detail::is_valid_chunk_cat_inputs(tensors, (uint64_t)dim);
  TORCH_CHECK(tensors[0].device() == out.device(),
    "_chunk_cat_out_cuda: mismatch between input and out tensor devices");
  bool is_same_type = tensors[0].dtype() == out.dtype();
  bool is_bfloat16_to_float32 =
    (tensors[0].dtype() == at::ScalarType::BFloat16) &&
    (out.dtype() == at::ScalarType::Float);
  bool both_input_output_contiguous = detail::all_contiguous(tensors) && out.is_non_overlapping_and_dense();
  if(both_input_output_contiguous && (is_same_type || is_bfloat16_to_float32)) {
    detail::_chunk_cat_out_cuda_contiguous(tensors, dim, num_chunks, out);
  } else {
    at::native::_chunk_cat_out(tensors, dim, num_chunks, out);
  }
  return out;
}

} // namespace at::native
