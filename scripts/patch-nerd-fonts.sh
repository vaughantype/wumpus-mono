#!/usr/bin/env bash
#
# patch-nerd-fonts.sh — Patch all Wumpus Mono TTF variants with Nerd Fonts glyphs
#
# Usage:  ./scripts/patch-nerd-fonts.sh [--force]
#
# Requires: fontforge (will attempt to install via system package manager if missing)
#
# This script:
#   1. Checks for / installs fontforge
#   2. Sparse-clones the Nerd Fonts patcher (no multi-GB font downloads)
#   3. Patches every .ttf found in the repo root with --complete --mono
#   4. Outputs patched fonts to fonts/NerdFont/
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NERD_FONTS_DIR="${REPO_ROOT}/.nerd-fonts"
PATCHER="${NERD_FONTS_DIR}/font-patcher"
OUTPUT_DIR="${REPO_ROOT}/fonts/NerdFont"
FORCE=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Patch all Wumpus Mono TTF variants with Nerd Fonts glyphs.

Options:
  --force    Re-patch even if output fonts already exist
  --help     Show this help message
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --help)  usage ;;
        *)       error "Unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Ensure fontforge is available
# ---------------------------------------------------------------------------

ensure_fontforge() {
    if command -v fontforge &>/dev/null; then
        info "fontforge found: $(command -v fontforge)"
        return
    fi

    info "fontforge not found — attempting to install …"

    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq fontforge
    elif command -v brew &>/dev/null; then
        brew install fontforge
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y fontforge
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm fontforge
    else
        error "Could not detect a supported package manager. Please install fontforge manually."
    fi

    command -v fontforge &>/dev/null || error "fontforge installation failed."
    info "fontforge installed successfully."
}

# ---------------------------------------------------------------------------
# 2. Sparse-clone the Nerd Fonts patcher
# ---------------------------------------------------------------------------

clone_nerd_fonts() {
    if [[ -x "${PATCHER}" ]]; then
        info "Nerd Fonts patcher already present at ${PATCHER}"
        return
    fi

    info "Sparse-cloning Nerd Fonts patcher …"
    rm -rf "${NERD_FONTS_DIR}"

    git clone --filter=blob:none --sparse \
        https://github.com/ryanoasis/nerd-fonts.git \
        "${NERD_FONTS_DIR}"

    pushd "${NERD_FONTS_DIR}" >/dev/null
    git sparse-checkout set \
        font-patcher \
        src/glyphs \
        src/svgs \
        bin/scripts/name_parser
    popd >/dev/null

    [[ -f "${PATCHER}" ]] || error "font-patcher not found after clone."
    chmod +x "${PATCHER}"
    info "Nerd Fonts patcher ready."
}

# ---------------------------------------------------------------------------
# 3. Patch all TTF variants
# ---------------------------------------------------------------------------

patch_fonts() {
    mkdir -p "${OUTPUT_DIR}"

    local ttf_files=()
    while IFS= read -r -d '' f; do
        ttf_files+=("$f")
    done < <(find "${REPO_ROOT}" -maxdepth 1 -name '*.ttf' -print0)

    if [[ ${#ttf_files[@]} -eq 0 ]]; then
        error "No .ttf files found in ${REPO_ROOT}"
    fi

    info "Found ${#ttf_files[@]} TTF file(s) to patch."

    local count=0
    for ttf in "${ttf_files[@]}"; do
        local base
        base="$(basename "$ttf")"

        # Skip if output already exists (unless --force)
        if [[ "${FORCE}" == false ]] && ls "${OUTPUT_DIR}"/*NerdFont* &>/dev/null; then
            local patched_name
            patched_name="$(echo "$base" | sed 's/\(.*\)\.ttf/\1/')"
            if ls "${OUTPUT_DIR}/"*"${patched_name}"* &>/dev/null 2>&1 || \
               ls "${OUTPUT_DIR}/"*NerdFont* &>/dev/null 2>&1; then
                # A more targeted check: see if this specific variant was already patched
                if [[ -f "${OUTPUT_DIR}/${base}" ]] || \
                   compgen -G "${OUTPUT_DIR}/*NerdFontMono*" >/dev/null 2>&1; then
                    warn "Skipping ${base} (output exists — use --force to re-patch)"
                    continue
                fi
            fi
        fi

        info "Patching ${base} …"
        fontforge -script "${PATCHER}" \
            --complete \
            --mono \
            --outputdir "${OUTPUT_DIR}" \
            "$ttf"

        count=$((count + 1))
    done

    info "Patched ${count} font(s) → ${OUTPUT_DIR}/"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    info "Wumpus Mono — Nerd Fonts patcher"
    info "================================="
    ensure_fontforge
    clone_nerd_fonts
    patch_fonts
    info "Done!"
}

main
