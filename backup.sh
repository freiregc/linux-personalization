#!/usr/bin/env bash
# backup.sh — exporta a personalização visual do GNOME para ./data
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Uso: ./backup.sh [opções]

Exporta tema GTK, ícones, fontes, wallpaper, extensões e preferências do
GNOME para o diretório ./data (pronto para commit no git).

Opções:
  --all-assets        Copia TODOS os temas e temas de ícones de ~/.themes
                      e ~/.icons (pode chegar a ~200 MB). O padrão copia
                      apenas o que está em uso.
  --output DIR        Diretório de saída (padrão: ./data)
  --include-hostname  Inclui o hostname no manifest.json (evita por padrão,
                      para não vazar informação em repositório público).
  -h, --help          Mostra esta ajuda.

Exemplos:
  ./backup.sh
  ./backup.sh --all-assets
  ./backup.sh --output /tmp/meu-backup
EOF
}

ALL_ASSETS=0
OUTPUT_DIR="$DATA_DIR"
INCLUDE_HOSTNAME=0

while (( $# )); do
  case "$1" in
    --all-assets) ALL_ASSETS=1 ;;
    --output) shift; [[ $# -gt 0 ]] || die "--output exige um diretório"; OUTPUT_DIR="$1" ;;
    --output=*) OUTPUT_DIR="${1#*=}" ;;
    --include-hostname) INCLUDE_HOSTNAME=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1 (use --help)" ;;
  esac
  shift
done

require_cmd dconf gsettings jq rsync

in_gui_session || warn "DBUS_SESSION_BUS_ADDRESS não definido; lendo a configuração do usuário atual mesmo assim."

GNOME_FULL="$(gnome_version || true)"
GNOME_MAJOR="${GNOME_FULL%%.*}"
[[ -n $GNOME_MAJOR ]] || warn "gnome-shell não encontrado; o manifest ficará sem a versão do GNOME."

TMP="$ROOT_DIR/.data.tmp.$$"
cleanup() {
  if [[ -n ${TMP:-} && -d $TMP ]]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

rm -rf "$TMP"
mkdir -p "$TMP"/{dconf,extensions,themes,icons,fonts,wallpaper,gtk}
shopt -s nullglob

# ---------------------------------------------------------------------------
# 1. Dconf
# ---------------------------------------------------------------------------
log "Exportando preferências do GNOME (dconf)"
collect_dconf "$TMP/dconf/gnome-appearance.dconf" "$TMP/dconf/keys.skipped"
printf '%s\n' "${DCONF_PATHS[@]}" > "$TMP/dconf/paths.txt"
SKIPPED_COUNT="$(wc -l < "$TMP/dconf/keys.skipped" | tr -d ' ')"
ok "dconf exportado ($(wc -l < "$TMP/dconf/gnome-appearance.dconf" | tr -d ' ') linhas, $SKIPPED_COUNT itens ignorados)"

# ---------------------------------------------------------------------------
# 2. Extensões de usuário
# ---------------------------------------------------------------------------
log "Copiando extensões de usuário"
EXT_SRC="$HOME/.local/share/gnome-shell/extensions"
if [[ -d $EXT_SRC ]]; then
  rsync -a --exclude='.git/' "$EXT_SRC/" "$TMP/extensions/"
  EXT_COUNT="$(find "$TMP/extensions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  ok "$EXT_COUNT extensão(ões) copiada(s)"
else
  warn "nenhuma extensão de usuário encontrada em $EXT_SRC"
fi

EXTENSIONS_JSON="$(
  find "$TMP/extensions" -mindepth 2 -maxdepth 2 -name metadata.json -print0 \
    | xargs -0 -r jq -c '{uuid, name, version, shell_version: .["shell-version"]}' \
    | jq -s -c . 2>/dev/null || printf '[]'
)"
[[ -n $EXTENSIONS_JSON ]] || EXTENSIONS_JSON='[]'

# ---------------------------------------------------------------------------
# 3. Temas GTK
# ---------------------------------------------------------------------------
log "Selecionando temas GTK"

declare -a THEME_NAMES=()
declare -A _THEME_SEEN=()
add_theme() {
  local n="$1"
  [[ -n $n ]] || return 0
  [[ -n ${_THEME_SEEN[$n]:-} ]] && return 0
  [[ -d "$HOME/.themes/$n" ]] || return 0
  _THEME_SEEN[$n]=1
  THEME_NAMES+=("$n")
}

GTK_THEME="$(gset_value org.gnome.desktop.interface gtk-theme || true)"
add_theme "$GTK_THEME"

# Variantes do mesmo tema (hdpi, xhdpi, Compact etc.).
if [[ -n $GTK_THEME ]]; then
  for d in "$HOME"/.themes/*/; do
    b="$(basename "$d")"
    [[ $b == "$GTK_THEME" || $b == "$GTK_THEME"-* ]] && add_theme "$b"
  done
fi

# Temas referenciados pelos symlinks de ~/.config/gtk-4.0.
GTK4_LINKS_JSON='[]'
if [[ -d "$HOME/.config/gtk-4.0" ]]; then
  while IFS= read -r f; do
    target="$(readlink -f "$f" 2>/dev/null || true)"
    [[ -n $target ]] || continue
    case "$target" in
      "$HOME/.themes/"*)
        rel="${target#"$HOME/.themes/"}"
        theme="${rel%%/*}"
        sub="${rel#*/}"
        add_theme "$theme"
        GTK4_LINKS_JSON="$(
          jq -c --arg name "$(basename "$f")" --arg theme "$theme" --arg target "$sub" \
            '. + [{name: $name, theme: $theme, target: $target}]' <<<"$GTK4_LINKS_JSON"
        )"
        ;;
    esac
  done < <(find "$HOME/.config/gtk-4.0" -maxdepth 1 -type l -print 2>/dev/null)
fi

if (( ALL_ASSETS )); then
  for d in "$HOME"/.themes/*/; do add_theme "$(basename "$d")"; done
fi

for n in "${THEME_NAMES[@]}"; do
  rsync -a "$HOME/.themes/$n/" "$TMP/themes/$n/"
done

if (( ${#THEME_NAMES[@]} )); then
  ok "tema(s): ${THEME_NAMES[*]}"
else
  warn "nenhum tema de usuário em ~/.themes (o tema do sistema continua sendo o padrão)"
fi

# ---------------------------------------------------------------------------
# 4. Temas de ícones
# ---------------------------------------------------------------------------
log "Selecionando tema de ícones"

declare -a ICON_NAMES=()
declare -A _ICON_SEEN=()
collect_icon() {
  local n="$1" base inh i
  [[ -n $n ]] || return 0
  [[ -n ${_ICON_SEEN[$n]:-} ]] && return 0
  _ICON_SEEN[$n]=1

  base=""
  if [[ -d "$HOME/.icons/$n" ]]; then
    base="$HOME/.icons/$n"
  elif [[ -d "$HOME/.local/share/icons/$n" ]]; then
    base="$HOME/.local/share/icons/$n"
  else
    return 0
  fi

  ICON_NAMES+=("$n")
  rsync -a "$base/" "$TMP/icons/$n/"

  # Copia heranças que também sejam de usuário (hicolor/breeze ficam no sistema).
  inh="$(sed -n 's/^Inherits=//p' "$base/index.theme" 2>/dev/null | head -n1 | tr ',' ' ')"
  for i in $inh; do
    collect_icon "$i"
  done
}

ICON_THEME="$(gset_value org.gnome.desktop.interface icon-theme || true)"
collect_icon "$ICON_THEME"

if (( ALL_ASSETS )); then
  for d in "$HOME"/.icons/*/ "$HOME"/.local/share/icons/*/; do
    [[ -d $d ]] && collect_icon "$(basename "$d")" || true
  done
fi

if (( ${#ICON_NAMES[@]} )); then
  ok "ícone(s): ${ICON_NAMES[*]}"
else
  warn "tema de ícones '$ICON_THEME' não está em ~/.icons nem em ~/.local/share/icons"
fi

# ---------------------------------------------------------------------------
# 5. Fontes
# ---------------------------------------------------------------------------
log "Copiando fontes do usuário"
FONT_DIRS=("$HOME/.local/share/fonts" "$HOME/.fonts")
FONT_FOUND=0
for d in "${FONT_DIRS[@]}"; do
  if [[ -d $d ]]; then
    rsync -a "$d/" "$TMP/fonts/"
    FONT_FOUND=1
  fi
done
if (( FONT_FOUND )); then
  ok "$(find "$TMP/fonts" -type f | wc -l | tr -d ' ') arquivo(s) de fonte"
else
  warn "nenhuma fonte de usuário encontrada"
fi

# ---------------------------------------------------------------------------
# 6. Wallpaper
# ---------------------------------------------------------------------------
log "Copiando papel de parede"
WALLPAPER_FILE=""
WALLPAPER_ORIGINAL=""
WALLPAPER_SS_FILE=""

_wallpaper_path() {
  local value="$1" p
  [[ $value == file://* ]] || return 1
  p="${value#file://}"
  p="${p//%20/ }"
  [[ -f $p ]] || return 1
  printf '%s' "$p"
}

BG_URI="$(gset_value org.gnome.desktop.background picture-uri || true)"
BG_DARK_URI="$(gset_value org.gnome.desktop.background picture-uri-dark || true)"

for uri in "$BG_URI" "$BG_DARK_URI"; do
  if p="$(_wallpaper_path "$uri")"; then
    WALLPAPER_FILE="$(basename "$p")"
    WALLPAPER_ORIGINAL="$p"
    cp -f "$p" "$TMP/wallpaper/$WALLPAPER_FILE"
    break
  fi
done

SS_URI="$(gset_value org.gnome.desktop.screensaver picture-uri || true)"
if ss_path="$(_wallpaper_path "$SS_URI")"; then
  # Ignora o wallpaper padrão do sistema (ex.: /usr/share/backgrounds/...)
  if [[ $ss_path != /usr/share/* ]]; then
    WALLPAPER_SS_FILE="screensaver-$(basename "$ss_path")"
    cp -f "$ss_path" "$TMP/wallpaper/$WALLPAPER_SS_FILE"
  fi
fi

if [[ -n $WALLPAPER_FILE ]]; then
  ok "wallpaper: $WALLPAPER_FILE"
else
  warn "wallpaper atual não é um arquivo local; nada copiado"
fi

# ---------------------------------------------------------------------------
# 7. Configurações GTK e tema do shell
# ---------------------------------------------------------------------------
log "Copiando configurações GTK"
for v in 3.0 4.0; do
  if [[ -f "$HOME/.config/gtk-$v/settings.ini" ]]; then
    mkdir -p "$TMP/gtk/gtk-$v"
    cp -f "$HOME/.config/gtk-$v/settings.ini" "$TMP/gtk/gtk-$v/settings.ini"
  fi
done
ok "settings.ini do GTK 3/4 copiados (quando existiam)"

SHELL_THEME="$(dconf read /org/gnome/shell/extensions/user-theme/name 2>/dev/null | tr -d "'" || true)"

# ---------------------------------------------------------------------------
# 8. Manifest e checksums
# ---------------------------------------------------------------------------
log "Gerando manifest.json e SHA256SUMS"

THEMES_JSON="$(json_array "${THEME_NAMES[@]}")"
ICONS_JSON="$(json_array "${ICON_NAMES[@]}")"

HOSTNAME_JSON=""
if (( INCLUDE_HOSTNAME )); then
  HOSTNAME_JSON="$(hostname 2>/dev/null || printf 'unknown')"
fi

jq -n \
  --arg schema_version "1" \
  --arg created_at "$(date -Iseconds)" \
  --arg distro_id "$(distro_field ID)" \
  --arg distro_version "$(distro_field VERSION_ID)" \
  --arg distro_pretty "$(distro_field PRETTY_NAME)" \
  --arg gnome_shell "$GNOME_FULL" \
  --argjson gnome_major "${GNOME_MAJOR:-0}" \
  --arg session_type "$(session_type)" \
  --arg hostname "$HOSTNAME_JSON" \
  --argjson all_assets "$([[ $ALL_ASSETS == 1 ]] && echo true || echo false)" \
  --argjson themes "$THEMES_JSON" \
  --argjson icons "$ICONS_JSON" \
  --argjson gtk4_links "$GTK4_LINKS_JSON" \
  --arg gtk_theme "$GTK_THEME" \
  --arg icon_theme "$ICON_THEME" \
  --arg shell_theme "$SHELL_THEME" \
  --arg wallpaper_file "$WALLPAPER_FILE" \
  --arg wallpaper_original "$WALLPAPER_ORIGINAL" \
  --arg wallpaper_ss_file "$WALLPAPER_SS_FILE" \
  --argjson wallpaper_screensaver "$([[ -n $WALLPAPER_SS_FILE ]] && echo true || echo false)" \
  --argjson extensions "$EXTENSIONS_JSON" \
  --argjson dconf_paths "$(json_array "${DCONF_PATHS[@]}")" \
  --argjson dconf_ignored "$SKIPPED_COUNT" \
  '{
    schema_version: ($schema_version | tonumber),
    created_at: $created_at,
    distro: { id: $distro_id, version_id: $distro_version, pretty_name: $distro_pretty },
    gnome_shell: $gnome_shell,
    gnome_major: $gnome_major,
    session_type: $session_type,
    hostname: (if $hostname == "" then null else $hostname end),
    assets: {
      all_assets: $all_assets,
      themes: $themes,
      icons: $icons,
      fonts: true,
      gtk_theme: (if $gtk_theme == "" then null else $gtk_theme end),
      icon_theme: (if $icon_theme == "" then null else $icon_theme end),
      shell_theme: (if $shell_theme == "" then null else $shell_theme end),
      gtk4_links: $gtk4_links
    },
    wallpaper: {
      file: (if $wallpaper_file == "" then null else $wallpaper_file end),
      original_path: (if $wallpaper_original == "" then null else $wallpaper_original end),
      screensaver_file: (if $wallpaper_ss_file == "" then null else $wallpaper_ss_file end),
      restore_screensaver: $wallpaper_screensaver
    },
    extensions: $extensions,
    dconf: { paths: $dconf_paths, ignored: $dconf_ignored },
    notes: [
      "monitors.xml não é copiado: contém conectores e seriais específicos da máquina.",
      "preferred-monitor-by-connector é removido na restauração; usa o monitor primário.",
      "Chaves inexistentes na versão de destino são filtradas no install.sh."
    ]
  }' > "$TMP/manifest.json"

(
  cd "$TMP"
  find . -type f ! -name SHA256SUMS -print0 \
    | sort -z \
    | xargs -0 -r sha256sum > SHA256SUMS
)
ok "manifest.json gerado"

# ---------------------------------------------------------------------------
# 9. Publica o resultado
# ---------------------------------------------------------------------------
if [[ -d $OUTPUT_DIR ]] && [[ "$OUTPUT_DIR" != "$DATA_DIR" ]]; then
  warn "sobrescrevendo $OUTPUT_DIR"
fi
rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
mv "$TMP" "$OUTPUT_DIR"
TMP=""

TOTAL_SIZE="$(du -sh "$OUTPUT_DIR" | awk '{print $1}')"
printf '\n'
ok "Backup concluído em $OUTPUT_DIR ($TOTAL_SIZE)"
info "Temas:       ${#THEME_NAMES[@]}"
info "Ícones:      ${#ICON_NAMES[@]}"
info "Extensões:   $(find "$OUTPUT_DIR/extensions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
info "Wallpaper:   ${WALLPAPER_FILE:-nenhum}"
info "Ignorados:   $SKIPPED_COUNT (ver data/dconf/keys.skipped)"
printf '\n'
info "Próximos passos:"
info "  git add -A && git commit -m 'backup: $(date +%Y-%m-%d)'"
info "  git push"
