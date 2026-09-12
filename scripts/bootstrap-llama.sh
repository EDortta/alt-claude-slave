#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${LLAMA_SRC_DIR:-$HOME/.local/src/llama.cpp}"
INSTALL_DIR="${LLAMA_INSTALL_DIR:-$HOME/.local/opt/llama.cpp}"

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y build-essential cmake git libcurl4-openssl-dev libopenblas-dev
else
  echo "Instale CMake, compilador C++, Git, libcurl e OpenBLAS antes de continuar." >&2
  exit 1
fi

if [[ -d "$SRC_DIR/.git" ]]; then
  git -C "$SRC_DIR" pull --ff-only
else
  mkdir -p "$(dirname "$SRC_DIR")"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$SRC_DIR"
fi

cmake -S "$SRC_DIR" -B "$SRC_DIR/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_NATIVE=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=OpenBLAS
cmake --build "$SRC_DIR/build" --config Release -j "$(nproc)"

mkdir -p "$INSTALL_DIR/bin"
for binary in llama-cli llama-server llama-bench; do
  install -m 0755 "$SRC_DIR/build/bin/$binary" "$INSTALL_DIR/bin/$binary"
done

echo "llama.cpp instalado em $INSTALL_DIR/bin"

