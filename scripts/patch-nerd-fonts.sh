#!/usr/bin/env bash
#
# patch-nerd-fonts.sh — Patch all Wumpus Mono TTF variants with Nerd Fonts glyphs
#
# Usage:  ./scripts/patch-nerd-fonts.sh [--force] [FILE ...]
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
NERD_FONTS_VERSION="v3.3.0"
PATCHER="${NERD_FONTS_DIR}/font-patcher"
OUTPUT_DIR="${REPO_ROOT}/fonts/NerdFont"
FORCE=false
INPUT_FILES=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [FILE ...]

Patch Wumpus Mono TTF variants with Nerd Fonts glyphs.
If no files are given, all .ttf files in the repo root are patched.

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
        -*)      error "Unknown option: $1" ;;
        *)       INPUT_FILES+=("$1"); shift ;;
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

    git clone --filter=blob:none --sparse --branch "${NERD_FONTS_VERSION}" --depth 1 \
        https://github.com/ryanoasis/nerd-fonts.git \
        "${NERD_FONTS_DIR}"

    pushd "${NERD_FONTS_DIR}" >/dev/null
    git sparse-checkout set --no-cone \
        /font-patcher \
        /src/glyphs/ \
        /src/svgs/ \
        /bin/scripts/name_parser/
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
    if [[ ${#INPUT_FILES[@]} -gt 0 ]]; then
        for f in "${INPUT_FILES[@]}"; do
            [[ -f "$f" ]] || error "File not found: $f"
            ttf_files+=("$f")
        done
    else
        while IFS= read -r -d '' f; do
            ttf_files+=("$f")
        done < <(find "${REPO_ROOT}" -maxdepth 1 -name '*.ttf' -print0)
    fi

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
# 4. Post-process: strip empty braille cmap entries
#
# The --complete patch adds cmap entries for U+2800–U+28FF that point to
# empty glyphs. Those stubs block OS font fallback, so braille characters
# render as blank boxes in terminals. Remove them.
# ---------------------------------------------------------------------------

strip_empty_braille() {
    local cleanup="${REPO_ROOT}/scripts/strip-empty-braille.py"
    if [[ ! -f "${cleanup}" ]]; then
        warn "strip-empty-braille.py not found — skipping braille cleanup"
        return
    fi

    if ! command -v python3 &>/dev/null; then
        warn "python3 not found — skipping braille cleanup"
        return
    fi

    if ! python3 -c "import fontTools" &>/dev/null; then
        info "Installing fontTools for braille cleanup …"
        python3 -m pip install --quiet --user fontTools \
            || python3 -m pip install --quiet --break-system-packages fontTools \
            || { warn "could not install fontTools — skipping braille cleanup"; return; }
    fi

    info "Stripping empty braille cmap entries from patched fonts …"
    local f
    for f in "${OUTPUT_DIR}"/*.ttf; do
        [[ -f "$f" ]] || continue
        python3 "${cleanup}" "$f"
    done
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
    strip_empty_braille
    info "Done!"
}

main
