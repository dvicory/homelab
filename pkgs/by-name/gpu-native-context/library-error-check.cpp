#include <LLVMSPIRVLib/LLVMSPIRVLib.h>
#include <llvm/AsmParser/Parser.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/Support/SourceMgr.h>
#include <llvm/Support/raw_ostream.h>
#include <iostream>
#include <sstream>
#include <string>

static bool check(const char *ir, bool assembly, bool expected) {
  llvm::LLVMContext context;
  llvm::SMDiagnostic diagnostic;
  auto module = llvm::parseAssemblyString(ir, diagnostic, context);
  if (!module) {
    diagnostic.print("library-error-check", llvm::errs());
    return false;
  }
  SPIRV::TranslatorOpts options;
  options.setAllowedToUseExtension(
      SPIRV::ExtensionID::SPV_INTEL_inline_assembly, assembly);
  std::ostringstream output;
  std::string error;
  bool translated = llvm::writeSpirv(module.get(), options, output, error);
  if (translated != expected ||
      (translated && !SPIRV::isSpirvBinary(output.str()))) {
    std::cerr << "Unexpected library translation result: " << error << '\n';
    return false;
  }
  return true;
}

int main() {
  const char *assembly = R"(target triple = "spir64-unknown-unknown"
define spir_kernel void @assembly_kernel(ptr addrspace(1) %out, i32 %repeat) {
entry:
  br label %loop
loop:
  %value = phi i32 [ 0, %entry ], [ %next, %body ]
  %again = icmp ne i32 %repeat, 0
  br i1 %again, label %body, label %exit
body:
  %next = call i32 asm sideeffect "", "=r"()
  br label %loop
exit:
  store i32 %value, ptr addrspace(1) %out
  ret void
}
)";
  const char *ordinary = R"(target triple = "spir64-unknown-unknown"
declare void @llvm.lifetime.start.p0(i64 immarg, ptr)
declare void @llvm.lifetime.end.p0(i64 immarg, ptr)
define spir_kernel void @ordinary_kernel(ptr addrspace(1) %out) {
entry:
  %slot = alloca i32
  call void @llvm.lifetime.start.p0(i64 4, ptr %slot)
  store i32 42, ptr %slot
  %value = load i32, ptr %slot
  store i32 %value, ptr addrspace(1) %out
  call void @llvm.lifetime.end.p0(i64 4, ptr %slot)
  ret void
}
)";
  if (!check(assembly, true, true) || !check(assembly, false, false) ||
      !check(ordinary, false, true))
    return 1;
  std::cout << "PASS: supported assembly; recoverable unsupported assembly with a forward value; subsequent ordinary translation with lifetime intrinsics\n";
}
