#include <float.h>
#include <ATen/ATen.h>
#include <THC/THCAtomics.cuh>

#include "limits.cuh"

using namespace at;  // fix for pytorch<=0.4.1

#define CUDA_1D_KERNEL_LOOP(i, n)                            \
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; \
       i += blockDim.x * gridDim.x)

#define THREADS_PER_BLOCK 1024

inline int GET_BLOCKS(const int N) {
  int optimal_block_num = (N + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
  int max_block_num = 65000;
  return min(optimal_block_num, max_block_num);
}

//type-safe sign
template <typename scalar_t>
__device__ scalar_t sgn(scalar_t val) {
    return (scalar_t(0) < val) - (val < scalar_t(0));
}

// Overflow and Underflow clamp
template <typename scalar_t>
__device__  scalar_t clamp(const scalar_t n, const scalar_t lower, const scalar_t upper) {
  const scalar_t tmp = abs(n);
  const scalar_t result = max(lower, min(tmp, upper));
  return result * sgn(n);
}


template <typename scalar_t>
__global__ void SoftPool1dForward(const int nthreads,
                                  const scalar_t *bottom_input, const int batches,
                                  const int channels, const int dim,
                                  const int kernel_d, const int stride_d,
                                  scalar_t *output_data){
    int pooled_dim = dim/stride_d;
    CUDA_1D_KERNEL_LOOP(index, nthreads) {
      int pd = index % pooled_dim;
      int c = (index / pooled_dim) % channels;
      int n = index / pooled_dim / channels;

      const int offset = (n * channels + c) * dim;
      const scalar_t *offset_bottom_input = bottom_input + offset;

      scalar_t mask_sum = 0.;
      output_data[index] = 0.;
      const scalar_t upper = n_limits<scalar_t>::max();
      const scalar_t lower = n_limits<scalar_t>::min();
      const scalar_t zero = 0.;

      for(int id=0; id<kernel_d; id++){
        const int d_offset = pd*stride_d + id - kernel_d/2;
        if(d_offset >= dim || d_offset < 0)continue;
        const int offset = d_offset;

        // (Over/Under)flow check (A.) 0 <= e^{inp[offset]} <= FLT_MAX
        scalar_t mask = exp(offset_bottom_input[offset]);
        mask = clamp(mask, zero, upper);
        mask_sum += mask;
      }
      // Overflow check (B.) FLT_MIN <= sum{e^{inp[offset]}} <= FLT_MAX
      mask_sum = clamp(mask_sum, lower, upper);

      for(int id=0; id<kernel_d; id++){
        const int d_offset = pd*stride_d + id - kernel_d/2;
        if(d_offset >= dim || d_offset < 0)continue;
        const int offset = d_offset;

        // (Over/Under)flow check (C.) 0 <= e^{inp[offset]} <= FLT_MAX
        scalar_t mask = exp(offset_bottom_input[offset]);
        mask = clamp(mask, zero, upper);

        // Underflow check (D.) +FLT_MIN <= e^{inp[offset]}/sum{e^{inp[offset]}} <= 1
        mask /=  mask_sum;
        mask = clamp(mask, zero, upper);

        // Underflow check (E.) 0 <= (e^{inp[offset]}/sum{e^{inp[offset]}}) * inp[offset] <= FLT_MAX
        scalar_t weighted_inp = offset_bottom_input[offset] * mask;
        weighted_inp = clamp(weighted_inp, zero, upper);

        // Overflow check (F.) 0 <= sum[(e^{inp[offset]}/sum{e^{inp[offset]}}) * inp[offset]] <= FLT_MAX
        output_data[index] += weighted_inp;
        output_data[index] = clamp(output_data[index], zero, upper);
      }
    }
}


template <typename scalar_t>
__global__ void SoftPool2dForward(const int nthreads,
                                  const scalar_t *bottom_input, const int batches,
                                  const int channels, const int height,
                                  const int width, const int kernel_h,
                                  const int kernel_w, const int stride_h,
                                  const int stride_w, scalar_t *output_data){
    int pooled_height = height/stride_h;
    int pooled_width = width/stride_w;
    CUDA_1D_KERNEL_LOOP(index, nthreads) {
      int pw = index % pooled_width;
      int ph = (index / pooled_width) % pooled_height;
      int c = (index / pooled_width / pooled_height) % channels;
      int n = index / pooled_width / pooled_height / channels;

      const int offset = (n * channels + c) * height * width;
      const scalar_t *offset_bottom_input = bottom_input + offset;

      scalar_t mask_sum = 0.;
      output_data[index] = 0.;
      const scalar_t upper = n_limits<scalar_t>::max();
      const scalar_t lower = n_limits<scalar_t>::min();
      const scalar_t zero = 0.;

      for(int iy=0; iy<kernel_h; iy++){
        const int y_offset = ph*stride_h + iy - kernel_h/2;
        if(y_offset >= height || y_offset < 0)continue;
        for(int ix=0; ix<kernel_w; ix++){
          const int x_offset = pw*stride_w + ix - kernel_w/2;
          if(x_offset >= width || x_offset < 0)continue;
          const int offset = y_offset*width + x_offset;

          // (Over/Under)flow check (A.) 0 <= e^{inp[offset]} <= FLT_MAX
          scalar_t mask = exp(offset_bottom_input[offset]);
          mask = clamp(mask, zero, upper);
          mask_sum += mask;
        }
      }
      // Overflow check (B.) FLT_MIN <= sum{e^{inp[offset]}} <= FLT_MAX
      mask_sum = clamp(mask_sum, lower, upper);

      for(int iy=0; iy<kernel_h; iy++){
        const int y_offset = ph*stride_h + iy - kernel_h/2;
        if(y_offset >= height || y_offset < 0)continue;
        for(int ix=0; ix<kernel_w; ix++){
          const int x_offset = pw*stride_w + ix - kernel_w/2;
          if(x_offset >= width || x_offset < 0)continue;
          const int offset = y_offset*width + x_offset;

          // (Over/Under)flow check (C.) 0 <= e^{inp[offset]} <= FLT_MAX
          scalar_t mask = exp(offset_bottom_input[offset]);
          mask = clamp(mask, zero, upper);

          // Underflow check (D.) 0 <= e^{inp[offset]}/sum{e^{inp[offset]}} <= 1
          mask /=  mask_sum;
          mask = clamp(mask, zero, upper);

          // Underflow check (E.) 0 <= (e^{inp[offset]}/sum{e^{inp[offset]}}) * inp[offset] <= FLT_MAX
          scalar_t weighted_inp = offset_bottom_input[offset] * mask;
          weighted_inp = clamp(weighted_inp, zero, upper);

          // Overflow check (F.) 0 <= sum[(e^{inp[offset]}/sum{e^{inp[offset]}}) * inp[offset]] <= FLT_MAX
          output_data[index] += weighted_inp;
          output_data[index] = clamp(output_data[index], zero, upper);
        }
      }
    }
}


template <typename scalar_t>
__global__ void SoftPool3dForward(const int nthreads,
                                  const scalar_t *bottom_input, const int batches,
                                  const int channels, const int depth,
                                  const int height, const int width,
                                  const int kernel_d, const int kernel_h,
                                  const int kernel_w, const int stride_d,
                                  const int stride_h, const int stride_w,
                                  scalar_t *output_data){
    int pooled_depth = depth/stride_d;
    int pooled_height = height/stride_h;
    int pooled_width = width/stride_w;
    CUDA_1D_KERNEL_LOOP(index, nthreads) {
      int pw = index % pooled_width;
      int ph = (index / pooled_width) % pooled_height;
      int pd = (index / pooled_width / pooled_height) % pooled_depth;
      int c = (index / pooled_width / pooled_height / pooled_depth) % channels;
      int n = index / pooled_width / pooled_height / pooled_depth / channels;

      const int offset = (n * channels + c) * depth * height * width;
      const scalar_t *offset_bottom_input = bottom_input + offset;

      scalar_t mask_sum = 0.;
      output_data[index] = 0.;
      const scalar_t upper = n_limits<scalar_t>::max();
      const scalar_t lower = n_limits<scalar_t>::min();
      const scalar_t zero = 0.;

      for(int id=0; id<kernel_d; id++){
        const int d_offset = pd*stride_d + id - kernel_d/2;
        if(d_offset >= depth || d_offset < 0)continue;
        for(int iy=0; iy<kernel_h; iy++){
          const int y_offset = ph*stride_h + iy - kernel_h/2;
          if(y_offset >= height || y_offset < 0)continue;
          for(int ix=0; ix<kernel_w; ix++){
            const int x_offset = pw*stride_w + ix - kernel_w/2;
            if(x_offset >= width || x_offset < 0)continue;
            const int offset = d_offset*height + y_offset*width + x_offset;

            // (Over/Under)flow check (A.) 0 <= e^{inp[offset]} <= FLT_MAX
            scalar_t mask = exp(offset_bottom_input[offset]);
            mask = clamp(mask, zero, upper);
            mask_sum += mask;
          }
        }
      }
      // Overflow check (B.) FLT_MIN <= sum{e^{inp[offset]}} <= FLT_MAX
      mask_sum = clamp(mask_sum, lower, upper);

      for(int id=0; id<kernel_d; id++){
        const int d_offset = pd*stride_d + id - kernel_d/2;
        if(d_offset >= depth || d_offset < 0)continue;
        for(int iy=0; iy<kernel_h; iy++){
          const int y_offset = ph*stride_h + iy - kernel_h/2;
          if(y_offset >= height || y_offset < 0)continue;
          for(int ix=0; ix<kernel_w; ix++){
            const int x_offset = pw*stride_w + ix - kernel_w/2;
            if(x_offset >= width || x_offset < 0)continue;
            const int offset = d_offset*height + y_offset*width + x_offset;

            // (Over/Under)flow check (C.) 0 <= e^{inp[offset]} <= FLT_MAX
            scalar_t mask = exp(offset_bottom_input[offset]);
            mask = clamp(mask, zero, upper);

            // Underflow check (D.) +FLT_MIN <= e^{inp[offset]}/sum{e^{inp[offset]}} <= 1
            mask /=  mask_sum;
            mask = clamp(mask, zero, upper);

            // Underflow check (E.) 0 <= (e^{inp[offset]}/sum{e^{inp[offset]}}) * inp[offset] <= FLT_MAX
            scalar_t weighted_inp = offset_bottom_input[offset] * mask;
            weighted_inp = clamp(weighted_inp, zero, upper);

            // Overflow check (F.) 0 <= sum[(e^{inp[offset]}/sum{e^{inp[offset]}}) * inp[offset]] <= FLT_MAX
            output_data[index] += weighted_inp;
            output_data[index] = clamp(output_data[index], zero, upper);
          }
        }
      }
    }
}


int SoftPool1dForwardLauncher(const at::Tensor input, const int batches,
                             const int channels, const int dim,
                             const int kernel_d, const int stride_d,
                             at::Tensor output){
    const int output_size = batches * dim/stride_d * channels;
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        input.scalar_type(), "SoftPool1dLauncherForward", ([&] {
        const scalar_t *bottom_input = input.data_ptr<scalar_t>();
        scalar_t *output_data = output.data_ptr<scalar_t>();

        SoftPool1dForward<scalar_t>
        <<<GET_BLOCKS(output_size), THREADS_PER_BLOCK>>>(
          output_size, bottom_input,
          batches, channels,
          dim, kernel_d,
          stride_d, output_data);
        })
      );

    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
      fprintf(stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString(err));
      exit(-1);
    }
  return 1;
}

int SoftPool2dForwardLauncher(const at::Tensor input, const int batches,
                             const int channels, const int height,
                             const int width, const int kernel_h,
                             const int kernel_w, const int stride_h,
                             const int stride_w, at::Tensor output){
    const int output_size = batches * height/stride_h * width/stride_w * channels;
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        input.scalar_type(), "SoftPool2dLauncherForward", ([&] {
        const scalar_t *bottom_input = input.data_ptr<scalar_t>();
        scalar_t *output_data = output.data_ptr<scalar_t>();

        SoftPool2dForward<scalar_t>
        <<<GET_BLOCKS(output_size), THREADS_PER_BLOCK>>>(
          output_size, bottom_input,
          batches, channels,
          height, width,
          kernel_h, kernel_w,
          stride_h, stride_w,
          output_data);
        })
      );

    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
      fprintf(stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString(err));
      exit(-1);
    }
  return 1;
}

int SoftPool3dForwardLauncher(const at::Tensor input, const int batches,
                             const int channels, const int depth,
                             const int height, const int width,
                             const int kernel_d, const int kernel_h,
                             const int kernel_w, const int stride_d,
                             const int stride_h, const int stride_w,
                            at::Tensor output){
    const int output_size = batches * depth/stride_d * height/stride_h * width/stride_w * channels;
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        input.scalar_type(), "SoftPool3dLauncherForward", ([&] {
        const scalar_t *bottom_input = input.data_ptr<scalar_t>();
        scalar_t *output_data = output.data_ptr<scalar_t>();

        SoftPool3dForward<scalar_t>
        <<<GET_BLOCKS(output_size), THREADS_PER_BLOCK>>>(
          output_size, bottom_input,
          batches, channels,
          depth, height,
          width, kernel_d,
          kernel_h, kernel_w,
          stride_d, stride_h,
          stride_w, output_data);
        })
      );

    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
      fprintf(stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString(err));
      exit(-1);
    }
  return 1;
}


template <typename scalar_t>
__global__ void SoftPool1dBackward(const int nthreads,
                              const scalar_t *diff_output, const scalar_t *data_input,
                              const int batches, const int channels,
                              const int dim, const int kernel_d,
                              const int stride_d, scalar_t *diff_input){
    int pooled_dim = dim/stride_d;
    CUDA_1D_KERNEL_LOOP(index, nthreads) {
      int pd = index % pooled_dim;
      int c = (index / pooled_dim) % channels;
      int n = index / pooled_dim / channels;

      const int offset0 = (n * channels + c) * dim;
      const scalar_t *offset_data_input = data_input + offset0;

      const scalar_t diff_output_index = diff_output[index];

      scalar_t *offset_diff_input = diff_input + offset0;

      const int base_d = pd*stride_d - kernel_d/2;

      scalar_t mask_sum = 0.;
      const scalar_t zero = 0.;
      const scalar_t upper = n_limits<scalar_t>::max();
      const scalar_t lower = n_limits<scalar_t>::min();

      for(int id=0; id<kernel_d; id++){
        const int d_offset = base_d + id;
        if(d_offset >= dim || d_offset < 0)continue;
        const int offset = d_offset;

        // (Over/Under)flow check (A.) 0 <= e^{inp[offset]} <= FLT_MAX
        scalar_t mask = exp(offset_data_input[offset]);
        mask = clamp(mask, zero, upper);
        mask_sum += mask;
      }
      // Overflow check (B.) FLT_MIN <= sum{e^{inp[offset]}} <= FLT_MAX
      mask_sum = clamp(mask_sum, lower, upper);

      for(int id=0; id<kernel_d; id++){
        const int d_offset = base_d + id;
        if(d_offset >= dim || d_offset < 0)continue;
          const int offset = d_offset;

          // (Over/Under)flow check (C.) 0 <= e^{inp[offset]} <= FLT_MAX
          scalar_t mask = exp(offset_data_input[offset]);
          mask = clamp(mask, zero, upper);

          // Underflow check (D.) 0 <= e^{inp[offset]}/sum{e^{inp[offset]}} <= 1
          mask /=  mask_sum;
          mask = clamp(mask, zero, upper);

          // Underflow check (E.) 0 <= (e^{inp[offset]}/sum{e^{inp[offset]}}) * grad <= FLT_MAX
          scalar_t weighted_grad = diff_output_index * mask;
          weighted_grad = clamp(weighted_grad, zero, upper);

          atomicAdd(offset_diff_input+offset, weighted_grad);
      }
    }
}

template <typename scalar_t>
__global__ void SoftPool2dBackward(const int nthreads,
                              const scalar_t *diff_output, const scalar_t *data_input,
                              const int batches, const int channels,
                              const int height, const int width,
                              const int kernel_h, const int kernel_w,
                              const int stride_h, const int stride_w,
                              scalar_t *diff_input){
    int pooled_height = height/stride_h;
    int pooled_width = width/stride_w;
    CUDA_1D_KERNEL_LOOP(index, nthreads) {
      int pw = index % pooled_width;
      int ph = (index / pooled_width) % pooled_height;
      int c = (index / pooled_width / pooled_height) % channels;
      int n = index / pooled_width / pooled_height / channels;

      const int offset0 = (n * channels + c) * height * width;
      const scalar_t *offset_data_input = data_input + offset0;

      const scalar_t diff_output_index = diff_output[index];

      scalar_t *offset_diff_input = diff_input + offset0;

      const int base_y = ph*stride_h - kernel_h/2;
      const int base_x = pw*stride_w - kernel_w/2;

      scalar_t mask_sum = 0.;
      scalar_t zero = 0.;
      const scalar_t upper = n_limits<scalar_t>::max();
      const scalar_t lower = n_limits<scalar_t>::min();

      for(int iy=0; iy<kernel_h; iy++){
        const int y_offset = base_y + iy;
        if(y_offset >= height || y_offset < 0)continue;
        for(int ix=0; ix<kernel_w; ix++){
          const int x_offset = base_x + ix;
          if(x_offset >= width || x_offset < 0)continue;
          const int offset = y_offset*width + x_offset;

          // (Over/Under)flow check (A.) 0 <= e^{inp[offset]} <= FLT_MAX
          scalar_t mask = exp(offset_data_input[offset]);
          mask = clamp(mask, zero, upper);
          mask_sum += mask;
        }
      }
      // Overflow check (B.) FLT_MIN <= sum{e^{inp[offset]}} <= FLT_MAX
      mask_sum = clamp(mask_sum, lower, upper);

      for(int iy=0; iy<kernel_h; iy++){
        const int y_offset = base_y + iy;
        if(y_offset >= height || y_offset < 0)continue;
        for(int ix=0; ix<kernel_w; ix++){
          const int x_offset = base_x + ix;
          if(x_offset >= width || x_offset < 0)continue;
            const int offset = y_offset*width + x_offset;

            // (Over/Under)flow check (C.) 0 <= e^{inp[offset]} <= FLT_MAX
            scalar_t mask = exp(offset_data_input[offset]);
            mask = clamp(mask, zero, upper);

            // Underflow check (D.) 0 <= e^{inp[offset]}/sum{e^{inp[offset]}} <= 1
            mask /=  mask_sum;
            mask = clamp(mask, zero, upper);

            // Underflow check (E.) 0 <= (e^{inp[offset]}/sum{e^{inp[offset]}}) * grad <= FLT_MAX
            scalar_t weighted_grad = diff_output_index * mask;
            weighted_grad = clamp(weighted_grad, zero, upper);

            atomicAdd(offset_diff_input+offset, weighted_grad);
        }
      }
    }
}

template <typename scalar_t>
__global__ void SoftPool3dBackward(const int nthreads,
                              const scalar_t *diff_output, const scalar_t *data_input,
                              const int batches, const int channels,
                              const int depth, const int height,
                              const int width, const int kernel_d,
                              const int kernel_h, const int kernel_w ,
                              const int stride_d, const int stride_h,
                              const int stride_w, scalar_t *diff_input){
    int pooled_depth = depth/stride_d;
    int pooled_height = width/stride_h;
    int pooled_width = width/stride_w;
    CUDA_1D_KERNEL_LOOP(index, nthreads) {
      int pw = index % pooled_width;
      int ph = (index / pooled_width) % pooled_height;
      int pd = (index / pooled_width / pooled_height) % pooled_depth;
      int c = (index / pooled_width / pooled_height / pooled_depth) % channels;
      int n = index / pooled_width / pooled_height / pooled_depth / channels;

      const int offset0 = (n * channels + c) * depth * height * width;
      const scalar_t *offset_data_input = data_input + offset0;

      const scalar_t diff_output_index = diff_output[index];

      scalar_t *offset_diff_input = diff_input + offset0;

      const int base_d = pd*stride_d - kernel_d/2;
      const int base_y = ph*stride_h - kernel_h/2;
      const int base_x = pw*stride_w - kernel_w/2;

      scalar_t mask_sum = 0.;
      scalar_t zero = 0.;
      const scalar_t upper = n_limits<scalar_t>::max();
      const scalar_t lower = n_limits<scalar_t>::min();

      for(int id=0; id<kernel_d; id++){
        const int d_offset = base_d + id;
        if(d_offset >= depth || d_offset < 0)continue;
        for(int iy=0; iy<kernel_h; iy++){
          const int y_offset = base_y + iy;
          if(y_offset >= height || y_offset < 0)continue;
          for(int ix=0; ix<kernel_w; ix++){
            const int x_offset = base_x + ix;
            if(x_offset >= width || x_offset < 0)continue;
            const int offset = d_offset*height + y_offset*width + x_offset;

            // (Over/Under)flow check (A.) 0 <= e^{inp[offset]} <= FLT_MAX
            scalar_t mask = exp(offset_data_input[offset]);
            mask = clamp(mask, zero, upper);
            mask_sum += mask;
          }
        }
      }
      // Overflow check (B.) FLT_MIN <= sum{e^{inp[offset]}} <= FLT_MAX
      mask_sum = clamp(mask_sum, lower, upper);

      for(int id=0; id<kernel_d; id++){
        const int d_offset = base_d + id;
        if(d_offset >= depth || d_offset < 0)continue;
        for(int iy=0; iy<kernel_h; iy++){
          const int y_offset = base_y + iy;
          if(y_offset >= height || y_offset < 0)continue;
          for(int ix=0; ix<kernel_w; ix++){
            const int x_offset = base_x + ix;
            if(x_offset >= width || x_offset < 0)continue;
              const int offset = d_offset*height + y_offset*width + x_offset;

              // (Over/Under)flow check (C.) 0 <= e^{inp[offset]} <= FLT_MAX
              scalar_t mask = exp(offset_data_input[offset]);
              mask = clamp(mask, zero, upper);

              // Underflow check (D.) 0 <= e^{inp[offset]}/sum{e^{inp[offset]}} <= 1
              mask /=  mask_sum;
              mask = clamp(mask, zero, upper);

              // Underflow check (E.) 0 <= (e^{inp[offset]}/sum{e^{inp[offset]}}) * grad <= FLT_MAX
              scalar_t weighted_grad = diff_output_index * mask;
              weighted_grad = clamp(weighted_grad, zero, upper);

              atomicAdd(offset_diff_input+offset, weighted_grad);
          }
        }
      }
    }
}

int SoftPool1dBackwardLauncher(const at::Tensor output_grad, const at::Tensor input,
                               const int batches, const int channels,
                               const int dim, const int kernel_d,
                               const int stride_d, at::Tensor input_grad){

    const int output_size = batches * dim/stride_d * channels;

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        input.scalar_type(), "SoftPool1dLauncherBackward", ([&] {
        scalar_t *diff_input = input_grad.data_ptr<scalar_t>();
        const scalar_t *diff_output = output_grad.data_ptr<scalar_t>();
        const scalar_t *data_input = input.data_ptr<scalar_t>();

        SoftPool1dBackward<scalar_t>
        <<<GET_BLOCKS(output_size), THREADS_PER_BLOCK>>>(
          output_size, diff_output,
          data_input, batches,
          channels, dim,
          kernel_d, stride_d,
          diff_input);
        }
        )
        );

    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
      fprintf(stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString(err));
      exit(-1);
    }
  return 1;
}

int SoftPool2dBackwardLauncher(const at::Tensor output_grad, const at::Tensor input,
                               const int batches, const int channels,
                               const int height, const int width,
                               const int kernel_h, const int kernel_w,
                               const int stride_h, const int stride_w,
                               at::Tensor input_grad){

    const int output_size = batches * height/stride_h * width/stride_w * channels;

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        input.scalar_type(), "SoftPool2dLauncherBackward", ([&] {
        scalar_t *diff_input = input_grad.data_ptr<scalar_t>();
        const scalar_t *diff_output = output_grad.data_ptr<scalar_t>();
        const scalar_t *data_input = input.data_ptr<scalar_t>();

        SoftPool2dBackward<scalar_t>
        <<<GET_BLOCKS(output_size), THREADS_PER_BLOCK>>>(
          output_size, diff_output,
          data_input, batches,
          channels, height,
          width, kernel_h,
          kernel_w, stride_h,
          stride_w, diff_input);
        }
        )
        );

    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
      fprintf(stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString(err));
      exit(-1);
    }
  return 1;
}

int SoftPool3dBackwardLauncher(const at::Tensor output_grad, const at::Tensor input,
                               const int batches, const int channels,
                               const int depth, const int height,
                               const int width, const int kernel_d,
                               const int kernel_h, const int kernel_w,
                               const int stride_d, const int stride_h,
                               const int stride_w, at::Tensor input_grad){

    const int output_size = batches * depth/stride_d * height/stride_h * width/stride_w * channels;

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        input.scalar_type(), "SoftPool3dLauncherBackward", ([&] {
        scalar_t *diff_input = input_grad.data_ptr<scalar_t>();
        const scalar_t *diff_output = output_grad.data_ptr<scalar_t>();
        const scalar_t *data_input = input.data_ptr<scalar_t>();

        SoftPool3dBackward<scalar_t>
        <<<GET_BLOCKS(output_size), THREADS_PER_BLOCK>>>(
          output_size, diff_output,
          data_input, batches,
          channels, depth, height,
          width, kernel_d,
          kernel_h, kernel_w,
          stride_d, stride_h,
          stride_w, diff_input);
        }
        )
        );

    cudaError_t err = cudaGetLastError();
    if (cudaSuccess != err) {
      fprintf(stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString(err));
      exit(-1);
    }
  return 1;
}
