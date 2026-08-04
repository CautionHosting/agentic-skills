#!/usr/bin/env bash
# Build a Platform-branch CLI, package a real app EIF with its compiled STEVE
# pin, and smoke-test the generated rootfs under QEMU.
#
# This is a Platform integration test, not a Nitro-attestation test. QEMU has
# no /dev/nsm, PCR measurement, or production VSOCK transport.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  test-enclave-component-pin.sh build --app DIR [options]
  test-enclave-component-pin.sh run --build-dir DIR [options]
  test-enclave-component-pin.sh smoke [options]
  test-enclave-component-pin.sh all --app DIR [options]

Modes:
  build   Build a branch-local CLI unless --caution-bin is supplied, run
          `caution apps build --no-cache`, and validate the generated artifacts.
  run     Boot an existing build directory under QEMU in the foreground. Use
          --kernel-mode nitro for exact-kernel logs or standard for networking.
  smoke   Test an already-running QEMU guest.
  all     Build, boot with the standard kernel, smoke-test it, then stop it.

Build options:
  --app DIR                         App repo containing caution.hcl/Procfile.
  --caution-bin FILE                Use this CLI instead of building one.
  --expected-steve-commit SHA       Expected 40-character STEVE commit.
                                     Defaults to Platform's compiled pin.
  --override-steve-commit SHA       Set STEVE_COMMIT for a pre-bump build.
                                     Omit this to prove the compiled default.
  --key-exchange SUITE              XWING-DRAFT10 (default) or X25519.
  --expect-path PATH                Require PATH in rootfs; repeatable.
  --allow-dirty                     Permit dirty Platform/app repositories.

QEMU/smoke options:
  --build-dir DIR                   Printed `Location:` from apps build.
  --app-port PORT                   Guest/host application port (default: 8083).
  --app-path PATH                   HTTP path to test (default: /).
  --host-address ADDRESS            QEMU host-forward bind address
                                     (default: 127.0.0.1). Use 0.0.0.0 inside
                                     OrbStack to publish ports to macOS.
  --kernel-mode MODE                standard (default, networking) or
                                     nitro (exact pinned kernel, logs only).
  --kernel FILE                     Explicit kernel for the selected mode.
  --refresh-kernel                  Rebuild/re-extract the cached kernel.
  --cpus COUNT                      QEMU virtual CPUs (default: 1).
  --memory-mb MB                    QEMU memory (default: 1024).

Environment:
  CAUTION_REPO=/path/to/platform    Platform checkout; see scripts/_common.sh.
  CAUTION_QEMU_KERNEL_IMAGE=IMAGE   Kernel source image (default: ubuntu:24.04).

Examples:
  CAUTION_REPO=/src/platform ./test-enclave-component-pin.sh all \
    --app /src/test-app \
    --expected-steve-commit 0123456789abcdef0123456789abcdef01234567 \
    --expect-path usr/local/bin/hello

  ./test-enclave-component-pin.sh build \
    --app /src/test-app \
    --caution-bin /src/platform/out/qemu-pin-cli/caution

  ./test-enclave-component-pin.sh run \
    --build-dir /home/user/.cache/caution/build/local/.../eif-stage \
    --kernel-mode nitro
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-all}"
case "$MODE" in
  build|run|smoke|all) shift ;;
  *)
    usage >&2
    exit 2
    ;;
esac

APP_DIR=""
CAUTION_BIN=""
EXPECTED_STEVE_COMMIT=""
OVERRIDE_STEVE_COMMIT=""
KEY_EXCHANGE="XWING-DRAFT10"
BUILD_DIR=""
APP_PORT="8083"
APP_PATH="/"
HOST_ADDRESS="127.0.0.1"
KERNEL_MODE="standard"
KERNEL_PATH=""
STANDARD_NETWORK_BUNDLE_DIR=""
QEMU_INITRD_PATH=""
CPUS="1"
MEMORY_MB="1024"
ALLOW_DIRTY=0
REFRESH_KERNEL=0
EXPECT_PATHS=()

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || {
    printf 'error: %s requires a value\n' "$option" >&2
    exit 2
  }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      require_value "$1" "${2:-}"
      APP_DIR="$2"
      shift 2
      ;;
    --caution-bin)
      require_value "$1" "${2:-}"
      CAUTION_BIN="$2"
      shift 2
      ;;
    --expected-steve-commit)
      require_value "$1" "${2:-}"
      EXPECTED_STEVE_COMMIT="$2"
      shift 2
      ;;
    --override-steve-commit)
      require_value "$1" "${2:-}"
      OVERRIDE_STEVE_COMMIT="$2"
      shift 2
      ;;
    --key-exchange)
      require_value "$1" "${2:-}"
      KEY_EXCHANGE="$2"
      shift 2
      ;;
    --expect-path)
      require_value "$1" "${2:-}"
      EXPECT_PATHS+=("$2")
      shift 2
      ;;
    --build-dir)
      require_value "$1" "${2:-}"
      BUILD_DIR="$2"
      shift 2
      ;;
    --app-port)
      require_value "$1" "${2:-}"
      APP_PORT="$2"
      shift 2
      ;;
    --app-path)
      require_value "$1" "${2:-}"
      APP_PATH="$2"
      shift 2
      ;;
    --host-address)
      require_value "$1" "${2:-}"
      HOST_ADDRESS="$2"
      shift 2
      ;;
    --kernel)
      require_value "$1" "${2:-}"
      KERNEL_PATH="$2"
      shift 2
      ;;
    --kernel-mode)
      require_value "$1" "${2:-}"
      KERNEL_MODE="$2"
      shift 2
      ;;
    --refresh-kernel)
      REFRESH_KERNEL=1
      shift
      ;;
    --cpus)
      require_value "$1" "${2:-}"
      CPUS="$2"
      shift 2
      ;;
    --memory-mb)
      require_value "$1" "${2:-}"
      MEMORY_MB="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# Resolves the Platform checkout and provides log()/die().
source "$SCRIPT_DIR/_common.sh"

TEMP_FILES=()
TEMP_DIRS=()
TEMP_CONTAINERS=()
QEMU_PID=""

cleanup() {
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  if [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
    rm -f "${TEMP_FILES[@]}"
  fi
  local dir
  for dir in "${TEMP_DIRS[@]}"; do
    rm -rf -- "$dir"
  done
  local container
  for container in "${TEMP_CONTAINERS[@]}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_linux_amd64() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  [[ "$os" == "Linux" ]] || die "run this inside Linux amd64; detected $os/$arch"
  [[ "$arch" == "x86_64" || "$arch" == "amd64" ]] \
    || die "run this inside Linux amd64; detected $os/$arch"
}

validate_number() {
  local label="$1"
  local value="$2"
  local maximum="$3"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$label must be an integer: $value"
  (( value > 0 && value <= maximum )) || die "$label is out of range: $value"
}

validate_sha() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9a-f]{40}$ ]] \
    || die "$label must be a lowercase 40-character Git SHA: $value"
}

check_clean_repo() {
  local directory="$1"
  local label="$2"
  local status

  git -C "$directory" rev-parse --show-toplevel >/dev/null 2>&1 \
    || die "$label is not inside a Git repository: $directory"
  status="$(git -C "$directory" status --porcelain)"
  if [[ -n "$status" && "$ALLOW_DIRTY" -ne 1 ]]; then
    printf '%s\n' "$status" >&2
    die "$label repository is dirty; commit/stash changes or pass --allow-dirty"
  fi
}

resolve_expected_steve_commit() {
  local pin_file="$REPO/src/enclave-builder/src/build.rs"

  if [[ -n "$OVERRIDE_STEVE_COMMIT" ]]; then
    validate_sha "override STEVE commit" "$OVERRIDE_STEVE_COMMIT"
  fi

  if [[ -z "$EXPECTED_STEVE_COMMIT" ]]; then
    if [[ -n "$OVERRIDE_STEVE_COMMIT" ]]; then
      EXPECTED_STEVE_COMMIT="$OVERRIDE_STEVE_COMMIT"
    else
      EXPECTED_STEVE_COMMIT="$(
        awk -F'"' '/^const DEFAULT_STEVE_COMMIT: &str = "/ { print $2; exit }' "$pin_file"
      )"
    fi
  fi

  validate_sha "expected STEVE commit" "$EXPECTED_STEVE_COMMIT"
  if [[ -n "$OVERRIDE_STEVE_COMMIT" \
        && "$OVERRIDE_STEVE_COMMIT" != "$EXPECTED_STEVE_COMMIT" ]]; then
    die "--override-steve-commit and --expected-steve-commit disagree"
  fi
}

prepare_cli() {
  local install_dir

  if [[ -n "$CAUTION_BIN" ]]; then
    [[ -x "$CAUTION_BIN" ]] || die "caution binary is not executable: $CAUTION_BIN"
    CAUTION_BIN="$(cd "$(dirname "$CAUTION_BIN")" && pwd)/$(basename "$CAUTION_BIN")"
    log "using supplied CLI: $CAUTION_BIN"
    return
  fi

  check_clean_repo "$REPO" "Platform"
  require_command make
  require_command docker

  install_dir="$REPO/out/qemu-pin-cli"
  log "building branch-local StageX CLI from $REPO"
  make -C "$REPO" install-cli-stagex CLI_INSTALL_DIR="$install_dir"
  CAUTION_BIN="$install_dir/caution"
  [[ -x "$CAUTION_BIN" ]] || die "CLI build did not produce $CAUTION_BIN"
}

normalize_existing_dir() {
  local directory="$1"
  [[ -d "$directory" ]] || die "directory does not exist: $directory"
  (cd "$directory" && pwd)
}

normalize_existing_file() {
  local file="$1"
  [[ -f "$file" ]] || die "file does not exist: $file"
  (cd "$(dirname "$file")" && printf '%s/%s\n' "$PWD" "$(basename "$file")")
}

rootfs_contains() {
  local listing="$1"
  local requested="$2"
  local normalized="${requested#/}"
  normalized="${normalized#./}"

  grep -Fxq "$normalized" "$listing" || grep -Fxq "./$normalized" "$listing"
}

validate_build_artifacts() {
  local manifest="$BUILD_DIR/manifest.json"
  local run_sh="$BUILD_DIR/run.sh"
  local containerfile="$BUILD_DIR/Containerfile.eif"
  local rootfs="$BUILD_DIR/output/rootfs.cpio.gz"
  local eif="$BUILD_DIR/output/enclave.eif"
  local manifest_commit rootfs_listing expected_path

  for expected_path in "$manifest" "$run_sh" "$containerfile" "$rootfs" "$eif"; do
    [[ -f "$expected_path" ]] || die "missing build artifact: $expected_path"
  done

  manifest_commit="$(jq -r '.steve_commit // empty' "$manifest")"
  [[ "$manifest_commit" == "$EXPECTED_STEVE_COMMIT" ]] \
    || die "manifest STEVE commit '$manifest_commit' != expected '$EXPECTED_STEVE_COMMIT'"

  grep -Fq "git checkout $EXPECTED_STEVE_COMMIT" "$containerfile" \
    || die "Containerfile.eif does not check out expected STEVE commit"
  grep -Fq '/steve &' "$run_sh" || die "generated run.sh does not start STEVE"

  case "$KEY_EXCHANGE" in
    XWING-DRAFT10)
      grep -Fq 'STEVE_KEY_EXCHANGE=XWING-DRAFT10' "$run_sh" \
        || die "generated run.sh does not select XWING-DRAFT10"
      ;;
    X25519)
      if grep -Fq 'STEVE_KEY_EXCHANGE=' "$run_sh"; then
        die "generated run.sh should leave STEVE's X25519 default implicit"
      fi
      ;;
    *)
      die "--key-exchange must be XWING-DRAFT10 or X25519"
      ;;
  esac

  rootfs_listing="$(mktemp "${TMPDIR:-/tmp}/caution-rootfs.XXXXXX")"
  TEMP_FILES+=("$rootfs_listing")
  gzip -dc "$rootfs" | cpio -it 2>/dev/null > "$rootfs_listing"

  for expected_path in steve bootproofd run.sh "${EXPECT_PATHS[@]}"; do
    rootfs_contains "$rootfs_listing" "$expected_path" \
      || die "rootfs is missing expected path: $expected_path"
  done

  log "validated STEVE commit: $EXPECTED_STEVE_COMMIT"
  log "validated key exchange: $KEY_EXCHANGE"
  log "validated rootfs: STEVE + Bootproof + requested app paths"
  sha256sum "$eif"
  printf 'BUILD_DIR=%s\n' "$BUILD_DIR"
}

build_eif() {
  local build_log
  local -a build_command

  [[ -n "$APP_DIR" ]] || die "--app is required for $MODE"
  APP_DIR="$(normalize_existing_dir "$APP_DIR")"
  [[ -f "$APP_DIR/caution.hcl" || -f "$APP_DIR/Procfile" ]] \
    || die "app directory has neither caution.hcl nor Procfile: $APP_DIR"
  check_clean_repo "$APP_DIR" "App"

  resolve_expected_steve_commit
  prepare_cli
  require_command jq
  require_command gzip
  require_command cpio
  require_command sha256sum

  build_log="$(mktemp "${TMPDIR:-/tmp}/caution-pin-build.XXXXXX")"
  TEMP_FILES+=("$build_log")

  build_command=(env)
  if [[ -n "$OVERRIDE_STEVE_COMMIT" ]]; then
    build_command+=("STEVE_COMMIT=$OVERRIDE_STEVE_COMMIT")
    log "building with explicit STEVE_COMMIT override"
  else
    log "building without STEVE_COMMIT override to prove the compiled Platform pin"
  fi
  build_command+=("$CAUTION_BIN" apps build --no-cache)

  (
    cd "$APP_DIR"
    "${build_command[@]}"
  ) 2>&1 | tee "$build_log"

  BUILD_DIR="$(
    awk -F'Location: ' '/^Location: / { value=$2 } END { print value }' "$build_log"
  )"
  [[ -n "$BUILD_DIR" ]] || die "could not parse the apps-build Location"
  BUILD_DIR="$(normalize_existing_dir "$BUILD_DIR")"
  validate_build_artifacts
}

prepare_standard_kernel() {
  local kernel_cache_dir
  local kernel_image="${CAUTION_QEMU_KERNEL_IMAGE:-ubuntu:24.04}"

  require_command docker
  kernel_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/caution/qemu"
  mkdir -p "$kernel_cache_dir"
  KERNEL_PATH="$kernel_cache_dir/vmlinuz-amd64"
  STANDARD_NETWORK_BUNDLE_DIR="$kernel_cache_dir/qemu-network-amd64"

  if [[ -f "$KERNEL_PATH" \
      && -f "$STANDARD_NETWORK_BUNDLE_DIR/.complete" \
      && "$REFRESH_KERNEL" -ne 1 ]]; then
    log "using cached QEMU kernel and network modules: $KERNEL_PATH"
    return
  fi

  rm -rf -- "$STANDARD_NETWORK_BUNDLE_DIR"
  log "building a standard x86_64 QEMU kernel and network support from $kernel_image"
  docker run --rm -v "$kernel_cache_dir:/out" "$kernel_image" \
    bash -euc '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -q
      kernel_package="$(
        apt-cache depends linux-image-generic \
          | awk '"'"'$1 == "Depends:" && $2 ~ /^linux-image-[0-9].*-generic$/ {
              print $2
              exit
            }'"'"'
      )"
      test -n "$kernel_package"
      apt-get install -y --no-install-recommends \
        kmod "$kernel_package" xz-utils zstd
      kernel="$(find /boot -maxdepth 1 -type f -name "vmlinuz-*-generic" | sort | tail -n 1)"
      test -n "$kernel"
      version="$(basename "$kernel")"
      version="${version#vmlinuz-}"
      bundle=/out/qemu-network-amd64
      owner="$(stat -c "%u:%g" /out)"

      rm -rf "$bundle"
      mkdir -p "$bundle/modules"
      : > "$bundle/modules.list"

      index=0
      network_driver_found=0
      while read -r directive module _; do
        if test "$directive" = builtin; then
          network_driver_found=1
          continue
        fi
        test "$directive" = insmod || continue
        test -f "$module"
        network_driver_found=1

        filename="$(basename "$module")"
        filename="${filename%.zst}"
        filename="${filename%.xz}"
        filename="${filename%.gz}"
        printf -v output_name "%03d-%s" "$index" "$filename"
        output="$bundle/modules/$output_name"

        case "$module" in
          *.zst) zstd -q -d -c "$module" > "$output" ;;
          *.xz)  xz -d -c "$module" > "$output" ;;
          *.gz)  gzip -d -c "$module" > "$output" ;;
          *)     cp "$module" "$output" ;;
        esac

        printf "/qemu-network/modules/%s\n" "$output_name" \
          >> "$bundle/modules.list"
        index=$((index + 1))
      done < <(modprobe --set-version "$version" --show-depends virtio_net)

      test "$network_driver_found" = 1
      touch "$bundle/.complete"
      chmod 0644 "$kernel"
      cp "$kernel" /out/vmlinuz-amd64
      chown -R "$owner" /out/vmlinuz-amd64 "$bundle"
    '
  [[ -f "$KERNEL_PATH" ]] || die "kernel build did not produce $KERNEL_PATH"
  [[ -f "$STANDARD_NETWORK_BUNDLE_DIR/.complete" ]] \
    || die "kernel build did not produce the QEMU network module bundle"
}

prepare_nitro_kernel() {
  local containerfile="$BUILD_DIR/Containerfile.eif"
  local kernel_cache_dir nitro_image digest container

  [[ -f "$containerfile" ]] || die "missing generated Containerfile.eif: $containerfile"
  nitro_image="$(
    awk '/^FROM / {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^stagex\/user-linux-nitro@sha256:[0-9a-f]+$/) {
          print $i
          exit
        }
      }
    }' "$containerfile"
  )"
  [[ -n "$nitro_image" ]] \
    || die "could not resolve the pinned Nitro kernel image from Containerfile.eif"
  digest="${nitro_image##*@sha256:}"

  require_command docker
  kernel_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/caution/qemu"
  mkdir -p "$kernel_cache_dir"
  KERNEL_PATH="$kernel_cache_dir/linux-nitro-${digest}.bzImage"

  if [[ -f "$KERNEL_PATH" && "$REFRESH_KERNEL" -ne 1 ]]; then
    log "using cached pinned Nitro kernel: $KERNEL_PATH"
    return
  fi

  log "extracting the exact pinned Nitro kernel: $nitro_image"
  container="$(docker create "$nitro_image")"
  TEMP_CONTAINERS+=("$container")
  docker cp "$container:/bzImage" "$KERNEL_PATH"
  docker rm "$container" >/dev/null
  TEMP_CONTAINERS=()
  [[ -f "$KERNEL_PATH" ]] || die "Nitro kernel extraction did not produce $KERNEL_PATH"
}

prepare_kernel() {
  if [[ -n "$KERNEL_PATH" ]]; then
    KERNEL_PATH="$(normalize_existing_file "$KERNEL_PATH")"
    return
  fi

  case "$KERNEL_MODE" in
    standard) prepare_standard_kernel ;;
    nitro) prepare_nitro_kernel ;;
  esac
}

prepare_standard_network_initrd() {
  local rootfs="$1"
  local stage_dir overlay combined

  require_command cpio
  require_command gzip

  stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/caution-qemu-network.XXXXXX")"
  TEMP_DIRS+=("$stage_dir")
  mkdir -p "$stage_dir/qemu-network/modules"
  : > "$stage_dir/qemu-network/modules.list"

  if [[ -n "$STANDARD_NETWORK_BUNDLE_DIR" ]]; then
    cp "$STANDARD_NETWORK_BUNDLE_DIR/modules.list" \
      "$stage_dir/qemu-network/modules.list"
    if [[ -s "$STANDARD_NETWORK_BUNDLE_DIR/modules.list" ]]; then
      cp "$STANDARD_NETWORK_BUNDLE_DIR"/modules/* \
        "$stage_dir/qemu-network/modules/"
    fi
  fi

  cp "$SCRIPT_DIR/qemu-network-init.sh" "$stage_dir/qemu-run.sh"
  chmod 0755 "$stage_dir/qemu-run.sh"

  overlay="$(mktemp "${TMPDIR:-/tmp}/caution-qemu-network.XXXXXX.cpio.gz")"
  combined="$(mktemp "${TMPDIR:-/tmp}/caution-qemu-rootfs.XXXXXX.cpio.gz")"
  TEMP_FILES+=("$overlay" "$combined")

  (
    cd "$stage_dir"
    find . -print0 \
      | LC_ALL=C sort -z \
      | cpio --null -o -H newc 2>/dev/null \
      | gzip -n > "$overlay"
  )
  cat "$rootfs" "$overlay" > "$combined"
  QEMU_INITRD_PATH="$combined"
}

qemu_args() {
  local rootfs="$BUILD_DIR/output/rootfs.cpio.gz"
  local initrd target
  local forwards

  [[ -f "$rootfs" ]] || die "missing QEMU rootfs: $rootfs"
  initrd="$rootfs"
  target="/run.sh"

  if [[ "$KERNEL_MODE" == "standard" ]]; then
    prepare_standard_network_initrd "$rootfs"
    initrd="$QEMU_INITRD_PATH"
    target="/qemu-run.sh"
  fi

  QEMU_COMMAND=(
    qemu-system-x86_64
    -smp "$CPUS"
    -m "${MEMORY_MB}M"
    -nographic
    -kernel "$KERNEL_PATH"
    -initrd "$initrd"
    -append "console=ttyS0 reboot=k panic=1 nomodules nit.target=$target"
  )

  if [[ "$KERNEL_MODE" == "standard" ]]; then
    forwards="user,id=net0"
    forwards+=",hostfwd=tcp:${HOST_ADDRESS}:${APP_PORT}-:${APP_PORT}"
    forwards+=",hostfwd=tcp:${HOST_ADDRESS}:49500-:49500"
    forwards+=",hostfwd=tcp:${HOST_ADDRESS}:49502-:49502"
    QEMU_COMMAND+=(
      -netdev "$forwards"
      -device virtio-net-pci,netdev=net0
    )
  fi
}

run_qemu_foreground() {
  [[ -n "$BUILD_DIR" ]] || die "--build-dir is required for run"
  BUILD_DIR="$(normalize_existing_dir "$BUILD_DIR")"
  prepare_kernel
  qemu_args
  if [[ "$KERNEL_MODE" == "nitro" ]]; then
    log "booting the exact pinned Nitro kernel (logs only; no networking)"
  else
    log "booting a swapped standard kernel with networking"
  fi
  log "exit QEMU with Ctrl-a x"
  "${QEMU_COMMAND[@]}"
}

start_qemu_background() {
  local qemu_log

  prepare_kernel
  qemu_args
  qemu_log="$(mktemp "${TMPDIR:-/tmp}/caution-qemu.XXXXXX")"
  TEMP_FILES+=("$qemu_log")
  log "starting QEMU in the background; serial log: $qemu_log"
  "${QEMU_COMMAND[@]}" >"$qemu_log" 2>&1 &
  QEMU_PID=$!

  local attempt
  for attempt in $(seq 1 120); do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      tail -n 100 "$qemu_log" >&2 || true
      die "QEMU exited before the application became ready"
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:${APP_PORT}${APP_PATH}" \
      >/dev/null 2>&1; then
      log "QEMU application is ready"
      return
    fi
    sleep 1
  done

  tail -n 100 "$qemu_log" >&2 || true
  die "application did not become ready within 120 seconds"
}

smoke_endpoints() {
  local direct_body steve_body attestation_body
  local app_url="http://127.0.0.1:${APP_PORT}${APP_PATH}"
  local steve_url="http://127.0.0.1:49500${APP_PATH}"
  local attestation_url="http://127.0.0.1:49502/attestation"

  require_command curl
  require_command jq

  direct_body="$(mktemp "${TMPDIR:-/tmp}/caution-direct.XXXXXX")"
  steve_body="$(mktemp "${TMPDIR:-/tmp}/caution-steve.XXXXXX")"
  attestation_body="$(mktemp "${TMPDIR:-/tmp}/caution-attestation.XXXXXX")"
  TEMP_FILES+=("$direct_body" "$steve_body" "$attestation_body")

  curl -fsS --max-time 10 "$app_url" > "$direct_body"
  log "direct application endpoint passed: $app_url"

  curl -fsS --max-time 10 "$steve_url" > "$steve_body"
  cmp -s "$direct_body" "$steve_body" \
    || die "STEVE plaintext fallback response differs from the direct app response"
  log "STEVE packaged and reached its application upstream on port 49500"

  curl -sS --max-time 10 -X POST "$attestation_url" \
    -H 'Content-Type: application/json' \
    -d '{"nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}' \
    > "$attestation_body"
  jq -e . "$attestation_body" >/dev/null \
    || die "Bootproof returned non-JSON output"
  grep -Eqi 'NSM|AttestationGeneration|attestation generation|could not initialize' \
    "$attestation_body" \
    || die "Bootproof did not reach the expected missing-NSM boundary"
  log "Bootproof reached the expected missing-NSM boundary"
  log "PASS: package/start/routing smoke only; no Nitro attestation or PCR proof"
}

require_linux_amd64
validate_number "app port" "$APP_PORT" 65535
validate_number "cpus" "$CPUS" 1024
validate_number "memory" "$MEMORY_MB" 1048576
[[ "$HOST_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
  || die "--host-address must be an IPv4 address"
[[ "$APP_PATH" == /* ]] || die "--app-path must begin with /"
case "$KERNEL_MODE" in
  standard|nitro) ;;
  *) die "--kernel-mode must be standard or nitro" ;;
esac
require_command git

case "$MODE" in
  build)
    build_eif
    ;;
  run)
    require_command qemu-system-x86_64
    run_qemu_foreground
    ;;
  smoke)
    smoke_endpoints
    ;;
  all)
    [[ "$KERNEL_MODE" == "standard" ]] \
      || die "all mode requires --kernel-mode standard; use build then run for Nitro logs"
    require_command qemu-system-x86_64
    require_command curl
    build_eif
    start_qemu_background
    smoke_endpoints
    ;;
esac
