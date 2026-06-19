#!/usr/bin/env bash
#
# mnmv2.sh — Monsters & Memories on macOS (Customized)
#
#   Mac native launcher patches the game  ->  CrossOver runs mnm.exe
#
# Default layout:
#   Game files     : $HOME/games/mnm/
#   Launcher .app  : $HOME/games/mnm_patcher_app.app
#   Download cache : $HOME/games/dl/
#
# This version prefers launching the Mac launcher from the parent of the
# game directory to avoid creating a nested "mnm/mnm/" structure.
#
# The Windows launcher crashes under Wine, so we only use the Mac launcher
# for patching/auth and CrossOver for the game client only.
#
# See LEARNINGS.md for technical background.

set -euo pipefail

# ---- configuration ----------------------------------------------------------
# Default focused layout (customized in mnmv2.sh):
#   GAMES_BASE     = $HOME/games/mnm          → where game files live
#   APP_INSTALL_DIR = $HOME/games             → where launcher .app is installed
#   DL_DIR         = $HOME/games/dl           → launcher tarball cache
#
# We launch the Mac launcher from the *parent* of GAMES_BASE when possible
# to reduce the chance of the launcher creating an extra nested folder.
GAMES_BASE="${MNM_GAMES_BASE:-${HOME}/games/mnm}"

# Launcher update sources
UPDATE_API_BASE="https://account.monstersandmemories.com/api/launcher/update"
FALLBACK_BASE="https://pub-f06cad9ebbcd412bb0f4ff64f0f6a3d7.r2.dev/launcher_v2/installer"
FALLBACK_MAC_TAR_URL="${FALLBACK_BASE}/Monsters%20%26%20Memories.app.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Download cache for launcher tarballs (under your games folder by default)
DL_DIR="${MNM_DL_DIR:-${GAMES_BASE}/../dl}"

APP_BUNDLE_NAME="mnm_patcher_app.app"

# Where to install the Mac launcher .app bundle
# Default: $HOME/games/  → results in $HOME/games/mnm_patcher_app.app
APP_INSTALL_DIR="${MNM_APP_DIR:-${HOME}/games}"
APP_INSTALL_PATH="${APP_INSTALL_DIR}/${APP_BUNDLE_NAME}"
APP_BIN="${APP_INSTALL_PATH}/Contents/MacOS/mnm_launcher"

LAUNCHER_DB="${HOME}/Library/Application Support/com.monstersandmemories.mnm-patcher-app/launcher.db"

BOTTLE_NAME="${MNM_BOTTLE:-mnm}"
BOTTLE_TEMPLATE="win10_64"
BOTTLE_ROOT="${HOME}/Library/Application Support/CrossOver/Bottles/${BOTTLE_NAME}"

# Strong default for game files
DEFAULT_GAME_DIR="${MNM_GAMEDIR:-${GAMES_BASE}}"
GAME_EXE_NAME="mnm.exe"

# ---- terminal output --------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi
info()  { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN}✓${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}!${C_RESET} $*" >&2; }
fail()  { echo "${C_RED}✗${C_RESET} $*" >&2; exit 1; }
step()  { echo; echo "${C_BOLD}${C_BLUE}▸ $*${C_RESET}"; }

# ---- helpers ----------------------------------------------------------------
detect_crossover() {
    local c
    for c in "/Applications/CrossOver.app" "${HOME}/Applications/CrossOver.app"; do
        [[ -d "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}
cx_bin() {
    local cx; cx="$(detect_crossover)" || return 1
    echo "${cx}/Contents/SharedSupport/CrossOver/bin"
}

db_get() {
    # db_get KEY -> prints value or nothing
    local key="$1"
    [[ -f "$LAUNCHER_DB" ]] || return 0
    sqlite3 "$LAUNCHER_DB" \
        "SELECT value FROM settings WHERE variable='${key//\'/\'\'}';" 2>/dev/null
}

game_dir() {
    # Resolution order (customized for mnmv2.sh):
    #   1. MNM_GAMEDIR env override (highest priority)
    #   2. gamePath stored in launcher.db
    #   3. Auto-discover starting with GAMES_BASE (~/games/mnm)
    #   4. Fall back to GAMES_BASE
    if [[ -n "${MNM_GAMEDIR:-}" ]]; then
        echo "$MNM_GAMEDIR"
        return
    fi

    # 2. Value stored by the launcher
    local gp
    gp="$(db_get gamePath)"
    if [[ -n "$gp" ]]; then
        echo "$gp"
        return
    fi

    # 3. Auto-discover (now includes your GAMES_BASE first)
    local candidate
    for candidate in \
        "${GAMES_BASE}" \
        "${SCRIPT_DIR}/mnm" \
        "${HOME}/Downloads/mnm" \
        "${HOME}/Applications/mnm" \
        "${HOME}/Games/mnm"
    do
        if [[ -f "${candidate}/${GAME_EXE_NAME}" ]]; then
            echo "$candidate"
            return
        fi
    done

    # 4. Final fallback
    echo "$DEFAULT_GAME_DIR"
}

# token_exp — echoes the `exp` unix timestamp of the stored JWT, or nothing.
# JWT is 3 base64url segments joined by "."; we decode segment 2 (payload)
# and grep for "exp":NUMBER — no jq dependency.
token_exp() {
    local tok payload pad decoded
    tok="$(db_get token)"
    [[ -n "$tok" ]] || return 0
    payload="$(awk -F. '{print $2}' <<<"$tok")"
    pad=$(( (4 - ${#payload} % 4) % 4 ))
    decoded="$(printf '%s%s' "$payload" "$(printf '=%.0s' $(seq 1 $pad 2>/dev/null))" \
              | tr '_-' '/+' | base64 -d 2>/dev/null)" || return 0
    # e.g. "...,\"exp\":1775962601,..."
    grep -oE '"exp":[0-9]+' <<<"$decoded" | head -n1 | cut -d: -f2
}

# token_status — prints "valid", "expiring N h", or "expired N d"
token_status() {
    local exp now delta days hours
    exp="$(token_exp)"
    [[ -n "$exp" ]] || { echo "no-token"; return; }
    now="$(date +%s)"
    delta=$(( exp - now ))
    if (( delta < 0 )); then
        days=$(( (-delta) / 86400 ))
        echo "expired ${days}d ago"
    elif (( delta < 3600 )); then
        echo "expiring <1h"
    elif (( delta < 86400 )); then
        hours=$(( delta / 3600 ))
        echo "expiring in ${hours}h"
    else
        days=$(( delta / 86400 ))
        echo "valid ~${days}d"
    fi
}

ensure_dl_dir() { mkdir -p "$DL_DIR"; }

# Target triple the update API expects for this machine.
update_target() {
    case "$(uname -m)" in
        arm64|aarch64) echo "darwin-aarch64" ;;
        x86_64)        echo "darwin-x86_64" ;;
        *)             echo "darwin-aarch64" ;;   # best guess
    esac
}

# latest_mac_launcher -> echoes "version<tab>url" if the API answered, else
# nothing. No jq: the JSON is flat and grep+sed is plenty.
latest_mac_launcher() {
    local target resp url ver
    target="$(update_target)"
    resp="$(curl -fsSL --max-time 8 \
        "${UPDATE_API_BASE}?target=${target}&current_version=0.0.0" 2>/dev/null)" || return 1
    url="$(grep -oE '"url":"[^"]+"' <<<"$resp" | head -n1 | sed 's/^"url":"//; s/"$//')"
    ver="$(grep -oE '"version":"[^"]+"' <<<"$resp" | head -n1 | sed 's/^"version":"//; s/"$//')"
    [[ -n "$url" ]] || return 1
    printf '%s\t%s\n' "${ver:-unknown}" "$url"
}

# installed_launcher_version -> reads CFBundleShortVersionString from the
# installed app's Info.plist, or empty if not installed.
installed_launcher_version() {
    [[ -d "$APP_INSTALL_PATH" ]] || return 0
    defaults read "${APP_INSTALL_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null
}

download_if_missing() {
    local url="$1" out="$2" label="$3"
    if [[ -s "$out" ]]; then
        ok "${label} already downloaded ($(du -h "$out" | cut -f1))"
        return 0
    fi
    info "Downloading ${label}…"
    curl -L --fail -# -o "$out" -C - "$url"
    ok "Downloaded ${label}"
}

# ---- subcommands ------------------------------------------------------------
cmd_doctor() {
    step "Environment check"
    local arch osver cx ver
    arch="$(uname -m)"
    osver="$(sw_vers -productVersion)"
    echo "  macOS        : ${osver}"
    echo "  Architecture : ${arch}"
    [[ "$arch" == "arm64" ]] && ok "Apple Silicon detected" \
        || warn "Not Apple Silicon — DXVK will work but D3DMetal won't"

    if cx="$(detect_crossover)"; then
        ver="$(defaults read "${cx}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
        ok "CrossOver ${ver} at ${cx}"
    else
        warn "CrossOver not found — 'bottle'/'play' will fail"
    fi

    step "Install state"
    if [[ -x "$APP_BIN" ]]; then
        local iver lver latest
        iver="$(installed_launcher_version)"
        latest="$(latest_mac_launcher)" || true
        lver="${latest%%$'\t'*}"
        # The update API sometimes advertises a higher version string while
        # serving a byte-identical tar.gz. We compare the tar hash from the
        # last install (recorded in .installed_tar.sha256) against the tar
        # the API currently points at. If the hashes match, the "newer"
        # version is a relabel — nothing to do.
        if [[ -n "$iver" && -n "$lver" && "$iver" != "$lver" && "$lver" != "unknown" ]]; then
            local marker="${DL_DIR}/.installed_tar.sha256" cached_tar="${DL_DIR}/mnm_launcher_${lver}.app.tar.gz"
            local inst_sha="" latest_sha=""
            [[ -f "$marker" ]] && inst_sha="$(cat "$marker")"
            [[ -s "$cached_tar" ]] && latest_sha="$(shasum -a 256 "$cached_tar" | cut -d' ' -f1)"
            if [[ -n "$inst_sha" && -n "$latest_sha" && "$inst_sha" == "$latest_sha" ]]; then
                ok "Mac launcher ${iver} (API advertises ${lver}, same binary)"
            elif [[ -z "$latest_sha" ]]; then
                echo "  Mac launcher : ${iver}. API advertises ${lver} — run ./mnmv2.sh mac to verify"
            else
                warn "Mac launcher ${iver} installed — different binary at ${lver} (run: ./mnmv2.sh mac)"
            fi
        else
            ok "Mac launcher ${iver:-unknown} at ${APP_INSTALL_PATH}"
        fi
    else
        echo "  Mac launcher : not installed — run: ./mnmv2.sh mac"
    fi
    [[ -d "$BOTTLE_ROOT" ]] && ok "Bottle '${BOTTLE_NAME}' exists" \
        || echo "  Bottle       : not created — run: ./mnmv2.sh bottle"

    step "Game state (from launcher.db)"
    if [[ -f "$LAUNCHER_DB" ]]; then
        local user tok gp exe
        user="$(db_get username)"
        tok="$(db_get token)"
        gp="$(game_dir)"

        if [[ -n "$tok" ]]; then
            [[ -n "$user" ]] && ok "Logged in as ${user}" || ok "Logged in"
            local status; status="$(token_status)"
            case "$status" in
                valid*)    ok "Token — ${status}" ;;
                expiring*) warn "Token ${status} — re-login soon (./mnmv2.sh patch)" ;;
                expired*)  warn "Token ${status} — re-login (./mnmv2.sh patch) before play" ;;
                *)         ok "Token present (${#tok} chars)" ;;
            esac
        elif [[ -n "$user" ]]; then
            warn "Username ${user} remembered but no token — finish login in ./mnmv2.sh patch"
        else
            warn "Not logged in — run ./mnmv2.sh patch"
        fi

        echo "  Expected game dir : ${GAMES_BASE}"
        echo "  Current gamePath  : ${gp}"
        exe="${gp}/${GAME_EXE_NAME}"
        if [[ -f "$exe" ]]; then
            ok "Game exe found: ${exe}"
        else
            warn "No ${GAME_EXE_NAME} found yet — run ./mnmv2.sh patch then Install in launcher"
        fi
    else
        warn "launcher.db missing — open the launcher once (./mnmv2.sh patch)"
    fi

    step "Downloads cached in ${DL_DIR}"
}

cmd_mac() {
    step "Installing native Mac launcher"
    ensure_dl_dir

    # Resolve the latest version via the update API. Falls back to the frozen
    # public URL if the API is down — but warns loudly because that one is
    # often several versions stale (was 0.20.3 vs 0.22.13 at time of writing).
    local url version tar
    local latest; latest="$(latest_mac_launcher)" || true
    if [[ -n "$latest" ]]; then
        version="${latest%%$'\t'*}"
        url="${latest#*$'\t'}"
        ok "Update API says latest is ${version}"
    else
        warn "Update API unreachable — using fallback URL (may be stale)"
        version="fallback"
        url="$FALLBACK_MAC_TAR_URL"
    fi
    tar="${DL_DIR}/mnm_launcher_${version}.app.tar.gz"

    download_if_missing "$url" "$tar" "launcher ${version}"

    info "Verifying archive…"
    gzip -t "$tar" && ok "Archive OK"

    local tmp; tmp="$(mktemp -d -t mnm-extract)"
    # Double-quoted: expands $tmp NOW so the trap has a literal path at
    # fire time. Avoids set -u breaking when cmd_all chains functions.
    trap "rm -rf '$tmp'" RETURN

    info "Extracting…"
    tar -xzf "$tar" -C "$tmp"
    local extracted="${tmp}/${APP_BUNDLE_NAME}"
    [[ -d "$extracted" ]] || fail "Expected ${APP_BUNDLE_NAME} in archive"

    # Two-step fix: xattr -dr alone leaves _CodeSignature/CodeResources
    # missing, which codesign --verify will reject on modern macOS.
    info "Stripping com.apple.quarantine…"
    xattr -dr com.apple.quarantine "$extracted" 2>/dev/null || true
    info "Re-signing ad-hoc (regenerates _CodeSignature/CodeResources)…"
    codesign --force --deep --sign - "$extracted"
    codesign --verify --verbose=0 "$extracted" && ok "Signature valid"

    [[ -d "$APP_INSTALL_PATH" ]] && { warn "Replacing existing ${APP_INSTALL_PATH}"; rm -rf "$APP_INSTALL_PATH"; }
    info "Installing to ${APP_INSTALL_PATH}…"
    if ! mv "$extracted" "$APP_INSTALL_PATH" 2>/dev/null; then
        warn "Falling back to sudo for ${APP_INSTALL_DIR}"
        sudo mv "$extracted" "$APP_INSTALL_PATH"
    fi
    # Marker so doctor can tell whether a newly advertised version is a
    # meaningful update or just a version-label bump over the same bytes.
    shasum -a 256 "$tar" | cut -d' ' -f1 > "${DL_DIR}/.installed_tar.sha256"
    ok "Installed"
    echo
    info "Next: ${C_BOLD}./mnmv2.sh patch${C_RESET}  (opens the launcher with --stinky-cheese)"
}

cmd_bottle() {
    step "Creating CrossOver bottle"
    local bin; bin="$(cx_bin)" || fail "CrossOver not installed"

    if [[ -d "$BOTTLE_ROOT" ]]; then
        ok "Bottle '${BOTTLE_NAME}' already exists — leaving it alone"
        return 0
    fi

    info "Creating '${BOTTLE_NAME}' (template ${BOTTLE_TEMPLATE}, DXVK)…"
    "${bin}/cxbottle" \
        --bottle "$BOTTLE_NAME" \
        --create \
        --template "$BOTTLE_TEMPLATE" \
        --description "Monsters & Memories (game client via DXVK)" \
        --param "EnvironmentVariables:CX_GRAPHICS_BACKEND=dxvk"
    ok "Bottle created at ${BOTTLE_ROOT}"
    echo
    info "The bottle only runs the game client (${GAME_EXE_NAME}) — no Windows launcher."
}

cmd_patch() {
    [[ -x "$APP_BIN" ]] || fail "Mac launcher not installed — run: ./mnmv2.sh mac"

    local target_dir
    target_dir="$(game_dir)"

    info "Launching Mac launcher from parent of game directory..."
    info "Target game path: ${target_dir}"

    mkdir -p "$target_dir"

    # We cd into the *parent* of the target game dir before launching.
    # This helps prevent the launcher from creating a nested "mnm/mnm/" folder.
    local launch_dir
    launch_dir="$(dirname "$target_dir")"

    (cd "$launch_dir" && nohup "$APP_BIN" --stinky-cheese >/dev/null 2>&1 & disown)

    ok "Launcher started"
    warn "${C_BOLD}Do NOT click Play${C_RESET} inside the Mac launcher."
    warn "When finished, close the launcher and run: ${C_BOLD}./mnmv2.sh play${C_RESET}"
}

cmd_refresh() {
    # Open the launcher WITHOUT --stinky-cheese, so `check_for_updates`
    # runs. This is useful because the update check likely also refreshes
    # server-side things the daily path never touches — including the
    # channel dropdown entitlements fetched via `fetch_channel_data`.
    #
    # Trade-off: on older launcher builds, skipping stinky-cheese can
    # drop you into an infinite "downloading update" loop when the server
    # advertises a version label newer than the binary it actually serves.
    # If that happens, close it, use `patch` (stinky-cheese on) for daily
    # use, and only call `refresh` occasionally.
    [[ -x "$APP_BIN" ]] || fail "Mac launcher not installed — run: ./mnmv2.sh mac"
    if pgrep -fq "mnm_launcher"; then
        warn "Launcher is still running — close it first."
        exit 1
    fi
    info "Opening launcher with update check ENABLED (no --stinky-cheese)…"
    warn "If it loops downloading, force-quit it and use ${C_BOLD}./mnmv2.sh patch${C_RESET} instead."
    nohup "$APP_BIN" >/dev/null 2>&1 &
    disown
    ok "Launcher started. Log in, then check the channel dropdown for a new entry."
}

cmd_repatch() {
    # Forces the launcher to recheck the manifest. Symptom this fixes:
    # launcher.db.game_versions says you're on a new version, but the
    # on-disk game.exe reports an older build (split-brain). "Repair"
    # in the launcher UI doesn't help because it short-circuits on the
    # version record. Deleting that row makes the next launch fetch the
    # manifest fresh and download only the changed chunks.
    [[ -f "$LAUNCHER_DB" ]] || fail "No launcher.db — run: ./mnmv2.sh patch first"

    if pgrep -fq "mnm_launcher"; then
        warn "Launcher is still running — close it first, then re-run this."
        exit 1
    fi

    local cur; cur="$(sqlite3 "$LAUNCHER_DB" "SELECT version FROM game_versions WHERE slug='mnm';" 2>/dev/null)"
    if [[ -n "$cur" ]]; then
        info "Clearing recorded version: ${cur}"
        sqlite3 "$LAUNCHER_DB" "DELETE FROM game_versions WHERE slug='mnm';"
        ok "Cleared. Launcher will re-diff against the live manifest on next open."
    else
        ok "No stale version record to clear."
    fi

    cmd_patch
    echo
    info "In the launcher: click Download/Patch to pull the delta. Files it already has are reused."
}

cmd_play() {
    local bin; bin="$(cx_bin)" || fail "CrossOver not installed"
    [[ -d "$BOTTLE_ROOT" ]] || fail "No bottle — run: ./mnmv2.sh bottle"
    [[ -f "$LAUNCHER_DB" ]] || fail "No launcher.db — run patch + log in first"

    local token gp exe
    token="$(db_get token)"
    [[ -n "$token" ]] || fail "No token in launcher.db — open the launcher and log in (./mnmv2.sh patch)"

    local status; status="$(token_status)"
    case "$status" in
        expired*)
            warn "Token ${status} — the game will reject it."
            warn "Run: ${C_BOLD}./mnmv2.sh patch${C_RESET} first (launcher will refresh the token)."
            fail "Aborting before guaranteed login failure."
            ;;
        expiring\ \<1h)
            warn "Token ${status} — it may expire during your session."
            ;;
    esac

    gp="$(game_dir)"
    exe="${gp}/${GAME_EXE_NAME}"
    [[ -f "$exe" ]] || fail "Game not downloaded — ${exe} missing. Run: ./mnmv2.sh patch  (then Install in the UI)"

    info "Launching ${GAME_EXE_NAME} in bottle '${BOTTLE_NAME}' (workdir: ${gp})…"
    # --workdir is important for Unity asset loading.
    # --no-wait lets this shell return while the game runs.
    #
    # DXVK tunables (CrossOver 26's DXVK fork honours these):
    #   DXVK_ASYNC=1  — compile shaders on a background thread instead of
    #                   blocking the render thread. Massive stutter cut on
    #                   first visit to each zone. If your CrossOver's DXVK
    #                   doesn't support it, the var is silently ignored.
    #   DXVK_HUD       — tiny overlay so you can SEE fps/gpu load/frametime
    #                    rather than guessing. Set to empty string to hide.
    #   DXVK_STATE_CACHE_PATH — stable per-user path so the compiled shader
    #                    cache survives bottle rebuilds / nukes. Next run
    #                    of any zone you've already visited is much faster.
    # Build DXVK environment variables
    local dxvk_cache="${HOME}/Library/Caches/mnm-dxvk"
    mkdir -p "$dxvk_cache"

    local envlist="DXVK_ASYNC=1 DXVK_STATE_CACHE_PATH=${dxvk_cache}"

    # Toggle DXVK_HUD with MNM_HUD=1
    if [[ "${MNM_HUD:-0}" == "1" ]]; then
        envlist="${envlist} DXVK_HUD=fps,gpuload,frametime"
        info "DXVK HUD enabled (MNM_HUD=1)"
    fi
    "${bin}/cxstart" \
        --bottle "$BOTTLE_NAME" \
        --workdir "$gp" \
        --env "$envlist" \
        --no-wait \
        -- "$exe" --token "$token"
    ok "Game started."
}

cmd_all() {
    cmd_doctor
    cmd_mac
    cmd_bottle
    echo
    info "Next steps (expected layout: ~/games/mnm/):"
    echo "  1. ${C_BOLD}./mnmv2.sh patch${C_RESET}   (opens launcher from ~/games/)"
    echo "  2. Log in and click Install — game should install into ~/games/mnm/"
    echo "  3. Close the launcher when finished"
    echo "  4. ${C_BOLD}./mnmv2.sh play${C_RESET}"
}

cmd_clean() {
    step "Removing cached downloads"
    rm -rf "$DL_DIR" "${SCRIPT_DIR}/extracted"
    ok "Done. Bottle and installed .app not touched."
}

# reset-db — Resets the Mac launcher state (launcher.db + installed .app)
# Use this when you want to start fresh with the launcher (e.g. wrong install path,
# corrupted state, or after manually deleting folders). It does NOT touch your
# CrossOver bottle or game files.
cmd_reset_db() {
    step "Resetting Mac launcher database and app"

    local supportdir="${HOME}/Library/Application Support/com.monstersandmemories.mnm-patcher-app"

    echo "This will remove:"
    echo "  • Launcher database and settings (${supportdir})"
    echo "  • Installed Mac launcher app     (${APP_INSTALL_PATH})"
    echo
    echo "It will NOT remove:"
    echo "  • Your CrossOver bottle"
    echo "  • Game files"
    echo

    read -r -p "Type ${C_BOLD}reset${C_RESET} to confirm: " ans
    [[ "$ans" == "reset" ]] || fail "Cancelled."

    if [[ -d "$supportdir" ]]; then
        info "Removing launcher data: ${supportdir}"
        rm -rf "$supportdir"
    fi

    if [[ -d "$APP_INSTALL_PATH" ]]; then
        info "Removing Mac launcher: ${APP_INSTALL_PATH}"
        rm -rf "$APP_INSTALL_PATH"
    fi

    ok "Launcher reset complete."
    info "Run ${C_BOLD}./mnmv2.sh patch${C_RESET} to set up the launcher again."
}

cmd_nuke() {
    step "Full teardown"

    # Read gamePath BEFORE wiping the db — can't read it after.
    local gp bin supportdir
    gp="$(game_dir)"
    supportdir="${HOME}/Library/Application Support/com.monstersandmemories.mnm-patcher-app"

    echo "This will remove:"
    echo "  app bundle    ${APP_INSTALL_PATH}"
    echo "  launcher data ${supportdir}"
    echo "  game files    ${gp}"
    echo "  bottle        ${BOTTLE_ROOT}"
    echo "  downloads     ${DL_DIR}"
    echo
    echo "It will NOT touch: CrossOver itself, other bottles, anything else."
    read -r -p "Type ${C_BOLD}nuke${C_RESET} to confirm: " ans
    [[ "$ans" == "nuke" ]] || fail "Cancelled."

    # Safety: we only rm -rf paths that look like what we expect. Prevents
    # an accidental wipe of $HOME if gamePath was set oddly.
    local safe_game_dir=0
    case "$gp" in
        */mnm|*/mnm/|*/Monsters*Memories*|*/mnm-*) safe_game_dir=1 ;;
    esac

    # Kill any running launcher so replacement / removal doesn't race.
    pkill -9 -f mnm_launcher 2>/dev/null || true
    sleep 1

    if [[ -d "$APP_INSTALL_PATH" ]]; then
        info "Removing ${APP_INSTALL_PATH}"
        rm -rf "$APP_INSTALL_PATH" 2>/dev/null || sudo rm -rf "$APP_INSTALL_PATH"
    fi

    if [[ -d "$supportdir" ]]; then
        info "Removing ${supportdir}"
        rm -rf "$supportdir"
    fi

    if (( safe_game_dir )) && [[ -d "$gp" ]]; then
        info "Removing ${gp}"
        rm -rf "$gp"
    elif [[ -d "$gp" ]]; then
        warn "Skipping game dir ${gp} — path doesn't look like a game install. Remove by hand if you really want."
    fi

    if [[ -d "$BOTTLE_ROOT" ]]; then
        info "Removing bottle ${BOTTLE_NAME}"
        if bin="$(cx_bin)"; then
            "${bin}/cxbottle" --bottle "$BOTTLE_NAME" --delete --force >/dev/null 2>&1 || rm -rf "$BOTTLE_ROOT"
        else
            rm -rf "$BOTTLE_ROOT"
        fi
    fi

    rm -rf "$DL_DIR" "${SCRIPT_DIR}/extracted"
    ok "Clean slate. Next: ${C_BOLD}./mnmv2.sh all${C_RESET} and then ${C_BOLD}./mnmv2.sh patch${C_RESET}."
}

cmd_nuke_bottle() {
    local bin; bin="$(cx_bin)" || fail "CrossOver not installed"
    [[ -d "$BOTTLE_ROOT" ]] || { ok "No bottle '${BOTTLE_NAME}' to remove"; return 0; }
    warn "This will delete the CrossOver bottle at: ${BOTTLE_ROOT}"
    read -r -p "Type the bottle name (${BOTTLE_NAME}) to confirm: " ans
    [[ "$ans" == "$BOTTLE_NAME" ]] || fail "Cancelled."
    "${bin}/cxbottle" --bottle "$BOTTLE_NAME" --delete --force
    ok "Bottle deleted."
}

# ---- dispatch ---------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}mnmv2.sh${C_RESET} — Monsters & Memories on macOS (Mac launcher + CrossOver game)

Usage: $0 <command>

${C_BOLD}Commands${C_RESET}
  doctor        Check env, installs, token, game files
  mac           Download + fix + install the Mac launcher
  bottle        Create the CrossOver bottle for the game client
  patch         Open the Mac launcher with --stinky-cheese (skips update loop)
  refresh       Open the launcher WITHOUT --stinky-cheese so it runs its
                update check (may refresh beta channel entitlements). Use
                patch if it loops.
  repatch       Clear the stuck version record and re-open for a forced diff
  play          Read token from launcher.db, run mnm.exe in the bottle
  all           doctor + mac + bottle  (then run patch, then play)
  clean         Remove cached downloads
  reset-db      Reset launcher.db + installed Mac launcher (keeps bottle + game files)
  nuke          Full teardown: app + launcher data + game files + bottle + dl/
  nuke-bottle   Destroy the CrossOver bottle only (confirms first)

${C_BOLD}Workflow${C_RESET}
  ${C_DIM}first time:${C_RESET}    ./mnmv2.sh all && ./mnmv2.sh patch  ${C_DIM}# log in + download${C_RESET}
                                    ./mnmv2.sh play   ${C_DIM}# once patching is done${C_RESET}
  ${C_DIM}every launch:${C_RESET}  ./mnmv2.sh play
  ${C_DIM}on patch day:${C_RESET}  ./mnmv2.sh patch  ${C_DIM}# update, then play again${C_RESET}

${C_BOLD}Env overrides${C_RESET}
  MNM_GAMES_BASE   Base directory for game (default: $HOME/games/mnm)
                   Game will be installed directly inside this folder.
  MNM_HUD          Show DXVK HUD (1 = enabled)     (default: off)
  MNM_DL_DIR     download cache                 (default: ./dl)
  MNM_APP_DIR    where to install the .app      (default: /Applications)
  MNM_BOTTLE     CrossOver bottle name          (default: mnm)
  MNM_GAMEDIR    override game install path     (default: auto-discover)
EOF
}

case "${1:-}" in
    doctor)         cmd_doctor ;;
    mac)            cmd_mac ;;
    bottle)         cmd_bottle ;;
    patch)          cmd_patch ;;
    refresh)        cmd_refresh ;;
    repatch)        cmd_repatch ;;
    play)           cmd_play ;;
    all)            cmd_all ;;
    clean)          cmd_clean ;;
    reset-db)       cmd_reset_db ;;
    nuke)           cmd_nuke ;;
    nuke-bottle)    cmd_nuke_bottle ;;
    -h|--help|help|"") usage ;;
    *)              usage; exit 2 ;;
esac
