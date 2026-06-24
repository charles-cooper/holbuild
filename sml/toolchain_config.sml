structure HolbuildToolchainConfig =
struct

datatype kernel_variant = StandardKernel | TracingKernel

fun kernel_variant_name StandardKernel = "stdknl"
  | kernel_variant_name TracingKernel = "trknl"

fun kernel_variant_build_args StandardKernel = []
  | kernel_variant_build_args TracingKernel = ["--trknl"]

fun kernel_variant_tracing TracingKernel = true
  | kernel_variant_tracing StandardKernel = false

end
