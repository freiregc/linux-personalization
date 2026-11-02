#!/usr/bin/env bash
# Funções compartilhadas entre backup.sh e install.sh.
# Uso: source "$(dirname "$0")/lib/common.sh"

# Evita carregar duas vezes.
if [[ -n "${_GNOME_PERSONALIZATION_COMMON:-}" ]]; then
  return 0
fi
_GNOME_PERSONALIZATION_COMMON=1

set -Eeuo pipefail

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_LIB_DIR/.." && pwd)"
DATA_DIR="$ROOT_DIR/data"

if [[ -t 1 ]]; then
  _C_RESET=$'\033[0m'; _C_BLUE=$'\033[1;34m'; _C_GREEN=$'\033[1;32m'
  _C_YELLOW=$'\033[1;33m'; _C_RED=$'\033[1;31m'; _C_DIM=$'\033[2m'
else
  _C_RESET=""; _C_BLUE=""; _C_GREEN=""; _C_YELLOW=""; _C_RED=""; _C_DIM=""
fi

log()  { printf '%s==>%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
err()  { printf '%s  ✗%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
dim()  { printf '%s    %s%s\n' "$_C_DIM" "$*" "$_C_RESET"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "comando obrigatório não encontrado: $c"
  done
}

in_gui_session() {
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || return 1
}

gnome_version() {
  command -v gnome-shell >/dev/null 2>&1 || return 1
  gnome-shell --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1
}

gnome_major() {
  local v
  v="$(gnome_version)" || return 1
  printf '%s' "${v%%.*}"
}

session_type() {
  printf '%s' "${XDG_SESSION_TYPE:-unknown}"
}

gset_value() {
  # Remove as aspas simples que o gsettings usa para strings.
  gsettings get "$1" "$2" 2>/dev/null | sed "s/^'//; s/'$//"
}

# ---------------------------------------------------------------------------
# Dconf: coleta e filtragem por compatibilidade
# ---------------------------------------------------------------------------

# Caminhos que fazem parte da aparência do GNOME.
# Fora: /org/gnome/desktop/peripherals, network, bluetooth, media-keys, etc.
DCONF_PATHS=(
  /org/gnome/desktop/interface/
  /org/gnome/desktop/background/
  /org/gnome/desktop/screensaver/
  /org/gnome/desktop/wm/preferences/
  /org/gnome/mutter/
  /org/gnome/shell/
  /org/gnome/nautilus/preferences/
)

# Chaves que nunca devem ser restauradas (específicas da máquina/sessão).
DCONF_DENY_KEYS=(
  welcome-dialog-last-shown-version
  last-version-installed
  preferred-monitor-by-connector
)

# Converte um dump relativo ([/]) em seções absolutas ([/org/gnome/.../]).
# Lê stdin, escreve stdout.
dconf_to_absolute() {
  local prefix="$1"
  awk -v p="$prefix" '
    /^\[/ && /\]$/ {
      s=$0
      sub(/^\[/, "", s)
      sub(/\]$/, "", s)
      sub(/\/$/, "", s)
      base=p
      sub(/\/$/, "", base)
      sub(/^\//, "", base)
      if (s == "") print "[" base "]"
      else print "[" base "/" s "]"
      next
    }
    { print }
  '
}

_dconf_key_denied() {
  local key="$1" k
  for k in "${DCONF_DENY_KEYS[@]}"; do
    [[ $key == "$k" ]] && return 0
  done
  return 1
}

# Remove seções/chaves que não existem na versão atual do GNOME.
# As seções de extensões (/org/gnome/shell/extensions/*) são preservadas
# porque os schemas delas só são conhecidos depois de instalar as extensões.
filter_dconf() {
  local infile="$1" outfile="$2" skipped="${3:-/dev/null}"
  local line section="" schema="" key="" pending="" active=0 printed=0 section_abs=""
  local -A state=() keys_cache=()

  : > "$outfile"
  : > "$skipped"

  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^\[(.*)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      section_abs="/${section#/}"
      schema="${section#/}"
      schema="${schema%/}"
      schema="${schema//\//.}"

      if [[ $section_abs == /org/gnome/shell/extensions/* ]]; then
        state[$section]="extension"
      elif [[ -z $schema ]]; then
        state[$section]="none"
      elif [[ -z ${state[$section]+x} ]]; then
        if gsettings list-schemas 2>/dev/null | grep -qx -- "$schema"; then
          state[$section]="ok"
          keys_cache[$section]="$(gsettings list-keys "$schema" 2>/dev/null || true)"
        else
          state[$section]="missing"
          printf 'schema ausente: %s (%s)\n' "$schema" "$section" >> "$skipped"
        fi
      fi

      printed=0
      if [[ ${state[$section]} == "missing" ]]; then
        active=0
        pending=""
      else
        active=1
        pending="$line"
      fi
      continue
    fi

    if [[ $line =~ ^([A-Za-z0-9_-]+)= ]]; then
      (( active )) || continue
      key="${BASH_REMATCH[1]}"

      if _dconf_key_denied "$key"; then
        printf 'chave ignorada: %s (%s)\n' "$key" "$section" >> "$skipped"
        continue
      fi

      if [[ ${state[$section]:-} == "ok" ]]; then
        if printf '%s\n' "${keys_cache[$section]:-}" | grep -qx -- "$key"; then
          if (( ! printed )); then
            printf '%s\n' "$pending" >> "$outfile"
            printed=1
          fi
          printf '%s\n' "$line" >> "$outfile"
        else
          printf 'chave ausente: %s %s\n' "$schema" "$key" >> "$skipped"
        fi
      else
        if (( ! printed )); then
          printf '%s\n' "$pending" >> "$outfile"
          printed=1
        fi
        printf '%s\n' "$line" >> "$outfile"
      fi
      continue
    fi
    # Linhas em branco e comentários são descartados.
  done < "$infile"
}

# Junta os dumps de todos os caminhos em um único arquivo absoluto.
collect_dconf() {
  local outfile="$1" skipped="$2" raw p
  raw="$(mktemp)"
  : > "$raw"

  for p in "${DCONF_PATHS[@]}"; do
    if dconf dump "$p" 2>/dev/null | dconf_to_absolute "$p" >> "$raw"; then
      :
    else
      warn "não foi possível ler $p"
    fi
    printf '\n' >> "$raw"
  done

  filter_dconf "$raw" "$outfile" "$skipped"
  rm -f "$raw"
}

# Remove ajustes específicos de hardware/monitor antes de aplicar.
sanitize_dconf() {
  local infile="$1" outfile="$2"
  sed -E \
    -e '/^preferred-monitor-by-connector=/d' \
    -e '/^welcome-dialog-last-shown-version=/d' \
    -e '/^last-version-installed=/d' \
    "$infile" > "$outfile"
}

# ---------------------------------------------------------------------------
# Wrappers de execução
# ---------------------------------------------------------------------------

DRY_RUN=0
run() {
  if (( DRY_RUN )); then
    printf '    %s[dry-run]%s %s\n' "$_C_DIM" "$_C_RESET" "$*"
  else
    "$@"
  fi
}

json_array() {
  if (( $# == 0 )); then
    printf '[]'
  else
    printf '%s\n' "$@" | jq -R . | jq -s -c .
  fi
}

distro_field() {
  # distro_field ID / VERSION_ID / PRETTY_NAME
  ( . /etc/os-release 2>/dev/null; eval "printf '%s' \"\${$1:-unknown}\"" )
}
