#!/bin/sh
set -eu

REPO="${REPO:-shtorm-7/sing-box-extended}"
BIN_PATH="${BIN_PATH:-/usr/bin/sing-box}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
MIN_FREE_KB="${MIN_FREE_KB:-24576}"

API_URL="https://api.github.com/repos/${REPO}/releases/latest"
WORKDIR=""
SERVICE_WAS_RUNNING=0
BACKUP_PATH=""
TMP_BIN=""
BIN_REPLACED=0

log() {
	printf '%s\n' "$*"
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_root() {
	[ "$(id -u)" = "0" ] || die "run this script as root"
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

detect_arch() {
	machine="$(uname -m)"

	case "$machine" in
		i386 | i486 | i586 | i686)
			printf '%s\n' "386"
			;;
		x86_64 | amd64)
			printf '%s\n' "amd64"
			;;
		aarch64 | arm64)
			printf '%s\n' "arm64"
			;;
		armv7 | armv7l)
			printf '%s\n' "armv7"
			;;
		loongarch64 | loong64)
			printf '%s\n' "loong64"
			;;
		riscv64)
			printf '%s\n' "riscv64"
			;;
		*)
			die "unsupported system architecture: ${machine}"
			;;
	esac
}

fetch_stdout() {
	url="$1"

	if have_cmd curl; then
		curl -fsSL -H "User-Agent: Mozilla/5.0" "$url"
	elif have_cmd wget; then
		wget -qO- --user-agent="Mozilla/5.0" "$url"
	else
		die "curl or wget is required"
	fi
}

download_file() {
	url="$1"
	out="$2"

	if have_cmd curl; then
		curl -fL --retry 3 -H "User-Agent: Mozilla/5.0" -o "$out" "$url"
	elif have_cmd wget; then
		wget --user-agent="Mozilla/5.0" -O "$out" "$url"
	else
		die "curl or wget is required"
	fi
}

make_workdir() {
	base="${TMPDIR:-/tmp}"

	if have_cmd mktemp; then
		WORKDIR="$(mktemp -d "${base}/sing-box-extended.XXXXXX")"
	else
		WORKDIR="${base}/sing-box-extended.$$"
		mkdir -p "$WORKDIR"
	fi
}

available_kb() {
	df -Pk "$1" | awk 'END { print $4 }'
}

file_size_kb() {
	du -k "$1" | awk 'NR == 1 { print $1 }'
}

check_free_space() {
	path="$1"
	required_kb="$2"
	description="$3"
	free_kb="$(available_kb "$path")"

	case "$free_kb" in
		'' | *[!0-9]*) die "could not determine free disk space at ${path}" ;;
	esac

	[ "$free_kb" -ge "$required_kb" ] ||
		die "not enough free disk space for ${description} at ${path}: ${free_kb} KB available, ${required_kb} KB required"
}

cleanup() {
	if [ -n "$TMP_BIN" ] && [ -e "$TMP_BIN" ]; then
		rm -f "$TMP_BIN"
	fi
	if [ "$BIN_REPLACED" = "0" ] && [ -n "$BACKUP_PATH" ] && [ -e "$BACKUP_PATH" ]; then
		rm -f "$BACKUP_PATH"
	fi
	if [ "$KEEP_WORKDIR" != "1" ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
		rm -rf "$WORKDIR"
	fi
	if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
		log "Starting ${SERVICE_NAME} service after interrupted installation..."
		"/etc/init.d/${SERVICE_NAME}" start || true
		SERVICE_WAS_RUNNING=0
	fi
}

service_exists() {
	[ -x "/etc/init.d/${SERVICE_NAME}" ]
}

is_service_running() {
	service_exists || return 1
	"/etc/init.d/${SERVICE_NAME}" running >/dev/null 2>&1
}

stop_service() {
	if is_service_running; then
		SERVICE_WAS_RUNNING=1
		log "Stopping ${SERVICE_NAME} service..."
		"/etc/init.d/${SERVICE_NAME}" stop
	fi
}

start_service_if_needed() {
	if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
		log "Starting ${SERVICE_NAME} service..."
		"/etc/init.d/${SERVICE_NAME}" start
		SERVICE_WAS_RUNNING=0
	fi
}

find_extracted_binary() {
	find "$WORKDIR/extract" -type f -name sing-box -perm -111 | head -n 1
}

main() {
	need_root
	have_cmd tar || die "tar is required"
	have_cmd gzip || die "gzip is required"
	have_cmd df || die "df is required"
	have_cmd du || die "du is required"
	have_cmd awk || die "awk is required"
	case "$MIN_FREE_KB" in
		'' | *[!0-9]*) die "MIN_FREE_KB must be a non-negative integer" ;;
	esac
	arch="$(detect_arch)"
	
	# Приоритет: musl-сборка под текущую архитектуру (arm64, amd64 и т.д.)
	asset_pattern="${ASSET_PATTERN:-linux-${arch}-musl.*\.tar\.gz}"
	make_workdir
	trap cleanup EXIT HUP INT TERM

	log "Detected architecture: ${arch}"
	log "Target pattern: ${asset_pattern}"
	log "Resolving latest release from ${REPO}..."
	release_json="$WORKDIR/release.json"
	fetch_stdout "$API_URL" > "$release_json"

	tag="$(
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$release_json" |
			head -n 1
	)"
	
	# Разбиваем JSON по строкам для изоляции url каждого ассета
	asset_url="$(
		tr ',' '\n' < "$release_json" |
			grep "browser_download_url" |
			grep -E "$asset_pattern" |
			head -n 1 |
			sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
	)"

	[ -n "$asset_url" ] || die "release asset matching ${asset_pattern} was not found in release ${tag}"
	[ -n "$tag" ] || tag="latest"

	required_work_kb="$MIN_FREE_KB"
	check_free_space "$WORKDIR" "$required_work_kb" "download and extraction"

	archive="$WORKDIR/sing-box-extended.tar.gz"
	log "Downloading ${tag}: ${asset_url}"
	download_file "$asset_url" "$archive"

	mkdir -p "$WORKDIR/extract"
	log "Extracting archive..."
	tar -xzf "$archive" -C "$WORKDIR/extract"

	new_bin="$(find_extracted_binary)"
	[ -n "$new_bin" ] || die "sing-box binary was not found in downloaded archive"
	[ -s "$new_bin" ] || die "downloaded sing-box binary is empty"

	log "Downloaded binary version:"
	"$new_bin" version || die "downloaded sing-box binary cannot run on this device"

	new_bin_kb="$(file_size_kb "$new_bin")"
	old_bin_kb=0
	if [ -e "$BIN_PATH" ]; then
		old_bin_kb="$(file_size_kb "$BIN_PATH")"
	fi
	check_free_space "$(dirname "$BIN_PATH")" "$((new_bin_kb + old_bin_kb + 1024))" "backup and installation"

	stop_service

	if [ -e "$BIN_PATH" ]; then
		BACKUP_PATH="${BIN_PATH}.backup.$(date +%Y%m%d%H%M%S)"
		log "Backing up ${BIN_PATH} to ${BACKUP_PATH}"
		cp -p "$BIN_PATH" "$BACKUP_PATH"
	fi

	TMP_BIN="${BIN_PATH}.new.$$"
	log "Installing extended sing-box (musl) to ${BIN_PATH}"
	cp "$new_bin" "$TMP_BIN"
	chmod 0755 "$TMP_BIN"
	mv "$TMP_BIN" "$BIN_PATH"
	TMP_BIN=""
	BIN_REPLACED=1

	log "Installed binary version:"
	"$BIN_PATH" version

	start_service_if_needed
	log "Done."
}

main "$@"
