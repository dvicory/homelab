{ pkgs, compiler }:
pkgs.runCommandCC "spirv-inline-assembly-library-contract"
  {
    nativeBuildInputs = [ pkgs.llvm_21 ];
    buildInputs = [
      compiler
      pkgs.llvm_21.dev
    ];
  }
  ''
    $CXX $(llvm-config --cxxflags) ${./library-error-check.cpp} \
      -I${compiler}/include -L${compiler}/lib -lLLVMSPIRVLib \
      $(llvm-config --ldflags --libs asmparser core support --system-libs) \
      -o library-error-check
    ./library-error-check
    touch "$out"
  ''
