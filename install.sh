#!/usr/bin/env bash
# install.sh — aplica a personalização exportada em ./data na máquina atual
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
Uso: ./install.sh [opções]

Aplica tema, ícones, fontes, wallpaper, extensões e preferências do GNOME
a partir dos arquivos em ./data. Faz um snapshot do estado atual antes.

Opções:
  --dry-run               Mostra tudo que seria feito, sem alterar nada.
  --yes                   Não pergunta antes de instalar pacotes via apt.
  --no-apt                Não instala pacotes; só avisa o que falta.
  --only=LISTA            Aplica só os módulos indicados (separados por vírgula):
                          dconf,themes,icons,fonts,wallpaper,extensions,gtk
  --overwrite-assets      Sobrescreve temas/ícones/extensões que já existem.
  --force-extensions      Copia extensões mesmo sem suporte declarado ao GNOME atual.
  --gtk4-theme            Recria os symlinks de tema GTK4 mesmo em GNOME >= 49.
  --preserve-exact        Não normaliza conflitos (ex.: ubuntu-dock + dash-to-dock).
  --reset-shell-theme     Remove o tema de shell customizado (volta ao padrão).
  --no-snapshot           Não cria snapshot antes de aplicar.
  --rollback[=SNAPSHOT]   Restaura o dconf de um snapshot (padrão: o último).
  -h, --help              Mostra esta ajuda.

Exemplos:
  ./install.sh --dry-run
  ./install.sh --only=themes,icons --yes
  ./install.sh --rollback
  ./install.sh --rollback=20261102-101500
EOF
}

ASSUME_YES=0
NO_APT=0
ONLY=""
FORCE_EXT=0
GTK4_THEME=0
PRESERVE_EXACT=0
RESET_SHELL_THEME=0
NO_SNAPSHOT=0
OVERWRITE_ASSETS=0
ROLLBACK=""

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --no-apt) NO_APT=1 ;;
    --only=*) ONLY="${1#*=}" ;;
    --overwrite-assets) OVERWRITE_ASSETS=1 ;;
    --force-extensions) FORCE_EXT=1 ;;
    --gtk4-theme) GTK4_THEME=1 ;;
    --preserve-exact) PRESERVE_EXACT=1 ;;
    --reset-shell-theme) RESET_SHELL_THEME=1 ;;
    --no-snapshot) NO_SNAPSHOT=1 ;;
    --rollback) ROLLBACK="latest" ;;
    --rollback=*) ROLLBACK="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) die "opção desconhecida: $1 (use --help)" ;;
  esac
  shift
done

require_cmd dconf gsettings jq rsync fc-cache

STATE_DIR="$HOME/.local/state/gnome-personalization"
SNAP_ROOT="$STATE_DIR/snapshots"

# ---------------------------------------------------------------------------
# Rollback (não exige ./data)
# ---------------------------------------------------------------------------
do_rollback() {
  local snap="$1"
  if [[ $snap == "latest" ]]; then
    snap="$(ls -1d "$SNAP_ROOT"/*/ 2>/dev/null | sort | tail -n1 || true)"
    snap="${snap%/}"
  elif [[ ! -d $snap && -d "$SNAP_ROOT/$snap" ]]; then
    snap="$SNAP_ROOT/$snap"
  fi
  [[ -n $snap && -d $snap ]] || die "snapshot não encontrado (use: ls $SNAP_ROOT)"
  [[ -f "$snap/dconf-full.dconf" ]] || die "snapshot inválido (sem dconf-full.dconf): $snap"

  log "Restaurando snapshot: $snap"
  run dconf load / < "$snap/dconf-full.dconf"
  local v
  for v in 3.0 4.0; do
    if [[ -d "$snap/gtk-$v" ]]; then
      run mkdir -p "$HOME/.config/gtk-$v"
      run rsync -a "$snap/gtk-$v/" "$HOME/.config/gtk-$v/"
    fi
  done
  ok "dconf e configurações GTK restaurados."
  if (( DRY_RUN )); then
    info "(dry-run: nenhuma alteração foi realmente feita)"
  fi
  warn "Temas, ícones, fontes e extensões copiados NÃO são removidos automaticamente."
  exit 0
}

if [[ -n $ROLLBACK ]]; then
  do_rollback "$ROLLBACK"
fi

# ---------------------------------------------------------------------------
# Validação de argumentos e do ambiente
# ---------------------------------------------------------------------------
VALID_MODULES=(dconf themes icons fonts wallpaper extensions gtk)
if [[ -n $ONLY ]]; then
  IFS=',' read -r -a _mods <<< "$ONLY"
  for m in "${_mods[@]}"; do
    found=0
    for v in "${VALID_MODULES[@]}"; do [[ $m == "$v" ]] && found=1; done
    (( found )) || die "módulo inválido: $m (válidos: ${VALID_MODULES[*]})"
  done
  ONLY=",$ONLY,"
fi
want() {
  [[ -z $ONLY ]] && return 0
  [[ $ONLY == *",$1,"* ]]
}

[[ -d $DATA_DIR ]] || die "diretório de dados não encontrado: $DATA_DIR (rode ./backup.sh primeiro)"
MANIFEST="$DATA_DIR/manifest.json"
[[ -f $MANIFEST ]] || die "manifest.json não encontrado em $DATA_DIR"

in_gui_session || warn "sessão D-Bus não detectada; gsettings/dconf podem falhar fora da sessão gráfica."

GN="$(gnome_major || true)"
[[ -n $GN ]] || die "GNOME Shell não encontrado; este script aplica configurações do GNOME."
if (( GN < 46 || GN > 50 )); then
  warn "GNOME $GN não foi testado (faixa validada: 46 a 50)."
  warn "Chaves e extensões incompatíveis serão filtradas/ignoradas."
fi

BACKUP_GN="$(jq -r '.gnome_major // 0' "$MANIFEST")"
SHELL_THEME="$(jq -r '.assets.shell_theme // empty' "$MANIFEST")"
WALLPAPER_FILE="$(jq -r '.wallpaper.file // empty' "$MANIFEST")"
WALLPAPER_SS_FILE="$(jq -r '.wallpaper.screensaver_file // empty' "$MANIFEST")"

log "GNOME de origem: ${BACKUP_GN:-?} | GNOME de destino: $GN | sessão: $(session_type)"
(( DRY_RUN )) && warn "MODO DRY-RUN: nada será alterado."

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------
create_snapshot() {
  (( NO_SNAPSHOT )) && { info "snapshot desativado (--no-snapshot)"; return 0; }
  local snap
  snap="$SNAP_ROOT/$(date +%Y%m%d-%H%M%S)"
  if (( DRY_RUN )); then
    info "[dry-run] criaria snapshot em $snap"
    return 0
  fi
  mkdir -p "$snap"
  dconf dump / > "$snap/dconf-full.dconf"
  local v
  for v in 3.0 4.0; do
    if [[ -d "$HOME/.config/gtk-$v" ]]; then
      cp -a "$HOME/.config/gtk-$v" "$snap/gtk-$v"
    fi
  done
  if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions list > "$snap/extensions.txt" 2>/dev/null || true
  fi
  printf '%s\n' "$snap" > "$STATE_DIR/last-snapshot"
  ok "snapshot salvo em $snap"
}
create_snapshot

if (( RESET_SHELL_THEME )); then
  log "Resetando tema de shell para o padrão do GNOME"
  run dconf reset /org/gnome/shell/extensions/user-theme/name
  ok "tema de shell resetado (relogar para aplicar)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Pacotes de sistema
# ---------------------------------------------------------------------------
install_one() {
  local p="$1"
  if dpkg -s "$p" >/dev/null 2>&1; then
    return 0
  fi
  if (( NO_APT )); then
    warn "pacote ausente (--no-apt): $p"
    return 1
  fi
  if (( DRY_RUN )); then
    info "[dry-run] sudo apt-get install -y $p"
    return 0
  fi
  sudo apt-get install -y "$p"
}

maybe_install_packages() {
  local -a missing=()
  local p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "extensões de sistema já instaladas"
    return 0
  fi

  info "Pacotes ausentes: ${missing[*]}"
  if (( NO_APT )); then
    warn "pulando instalação por causa de --no-apt"
    return 0
  fi

  if (( ! DRY_RUN && ! ASSUME_YES )); then
    local answer="n"
    if [[ -t 0 ]]; then
      read -r -p "Instalar com apt? [s/N] " answer || answer="n"
    fi
    if [[ ! $answer =~ ^[sSyY]$ ]]; then
      warn "instalação de pacotes pulada (use --yes para automatizar)"
      return 0
    fi
  fi

  if (( ! DRY_RUN )); then
    sudo apt-get update -qq || warn "apt-get update falhou; tentando instalar mesmo assim"
  fi

  for p in "${missing[@]}"; do
    if ! install_one "$p"; then
      case "$p" in
        gnome-shell-extension-appindicator) install_one ubuntu-appindicators || true ;;
        gnome-shell-extension-ubuntu-tiling-assistant) install_one gnome-shell-extension-tiling-assistant || true ;;
        gnome-shell-extension-user-theme) install_one gnome-shell-extensions || true ;;
        *) warn "não foi possível instalar: $p" ;;
      esac
    fi
  done
}

if want extensions; then
  log "Verificando extensões de sistema"
  APT_PKGS=(
    gnome-shell-extension-appindicator
    gnome-shell-extension-desktop-icons-ng
    gnome-shell-extension-ubuntu-dock
    gnome-shell-extension-ubuntu-tiling-assistant
  )
  if (( GN >= 47 )); then
    APT_PKGS+=(gnome-shell-extension-user-theme)
  fi
  maybe_install_packages "${APT_PKGS[@]}"
fi

# ---------------------------------------------------------------------------
# Assets: temas, ícones, fontes, wallpaper
# ---------------------------------------------------------------------------
copy_tree() {
  local src="$1" dest="$2" label="$3" d name
  [[ -d $src ]] || return 0
  for d in "$src"/*/; do
    [[ -d $d ]] || continue
    name="$(basename "$d")"
    if [[ -e "$dest/$name" ]] && (( ! OVERWRITE_ASSETS )); then
      info "mantido (já existe): $label/$name"
      continue
    fi
    run mkdir -p "$dest"
    run rsync -a "${d%/}" "$dest/"
    ok "$label: $name"
  done
}

if want themes; then
  log "Aplicando temas GTK"
  copy_tree "$DATA_DIR/themes" "$HOME/.themes" "tema"
fi

if want icons; then
  log "Aplicando temas de ícones"
  copy_tree "$DATA_DIR/icons" "$HOME/.icons" "ícones"
fi

if want fonts; then
  log "Aplicando fontes"
  if [[ -d "$DATA_DIR/fonts" ]]; then
    run mkdir -p "$HOME/.local/share/fonts"
    run rsync -a "$DATA_DIR/fonts/" "$HOME/.local/share/fonts/"
    run fc-cache -f "$HOME/.local/share/fonts"
    ok "fontes copiadas e cache atualizado"
  fi
fi

if want wallpaper && [[ -n $WALLPAPER_FILE ]]; then
  log "Aplicando papel de parede"
  run mkdir -p "$HOME/.local/share/backgrounds"
  run cp -f "$DATA_DIR/wallpaper/$WALLPAPER_FILE" "$HOME/.local/share/backgrounds/$WALLPAPER_FILE"
  run gsettings set org.gnome.desktop.background picture-uri "file://$HOME/.local/share/backgrounds/$WALLPAPER_FILE"
  run gsettings set org.gnome.desktop.background picture-uri-dark "file://$HOME/.local/share/backgrounds/$WALLPAPER_FILE"
  ok "wallpaper: $WALLPAPER_FILE"

  if [[ -n $WALLPAPER_SS_FILE ]]; then
    run cp -f "$DATA_DIR/wallpaper/$WALLPAPER_SS_FILE" "$HOME/.local/share/backgrounds/$WALLPAPER_SS_FILE"
    run gsettings set org.gnome.desktop.screensaver picture-uri "file://$HOME/.local/share/backgrounds/$WALLPAPER_SS_FILE"
    ok "wallpaper da tela de bloqueio: $WALLPAPER_SS_FILE"
  fi
fi

# ---------------------------------------------------------------------------
# Extensões de usuário
# ---------------------------------------------------------------------------
declare -a SKIPPED_EXT=()
install_extensions() {
  local d uuid meta dest supported
  [[ -d "$DATA_DIR/extensions" ]] || return 0
  for d in "$DATA_DIR"/extensions/*/; do
    [[ -d $d ]] || continue
    uuid="$(basename "$d")"
    meta="$d/metadata.json"

    if [[ $uuid == user-theme@* ]] && (( GN > 46 )); then
      info "user-theme: usando o pacote da distro no GNOME $GN (cópia antiga ignorada)"
      SKIPPED_EXT+=("$uuid (pacote da distro)")
      continue
    fi

    supported="false"
    if [[ -f $meta ]]; then
      supported="$(jq -r --arg gn "$GN" '.["shell-version"] | index($gn) != null' "$meta" 2>/dev/null || echo false)"
    fi

    if [[ $supported != "true" ]] && (( ! FORCE_EXT )); then
      warn "extensão incompatível com GNOME $GN, ignorada: $uuid"
      SKIPPED_EXT+=("$uuid")
      continue
    fi

    dest="$HOME/.local/share/gnome-shell/extensions/$uuid"
    if [[ -e $dest ]] && (( ! OVERWRITE_ASSETS )); then
      info "mantida (já existe): extensão/$uuid"
    else
      run mkdir -p "$dest"
      run rsync -a "$d" "$dest/"
    fi

    if [[ -d "$d/schemas" ]]; then
      run glib-compile-schemas "$dest/schemas"
    fi
    ok "extensão: $uuid"
  done
}

if want extensions; then
  log "Aplicando extensões de usuário"
  install_extensions
fi

# ---------------------------------------------------------------------------
# Dconf
# ---------------------------------------------------------------------------
install_dconf() {
  local raw="$DATA_DIR/dconf/gnome-appearance.dconf"
  [[ -f $raw ]] || { warn "nenhum dconf exportado"; return 0; }

  local sanitized filtered skipped
  sanitized="$(mktemp)"
  filtered="$(mktemp)"
  skipped="$(mktemp)"
  sanitize_dconf "$raw" "$sanitized"
  filter_dconf "$sanitized" "$filtered" "$skipped"

  local n
  n="$(wc -l < "$skipped" | tr -d ' ')"
  if (( n > 0 )); then
    warn "$n chave(s) incompatível(is) com GNOME $GN ignorada(s):"
    head -n 8 "$skipped" | while IFS= read -r line; do dim "$line"; done
    (( n > 8 )) && dim "... ver detalhes no backup: data/dconf/keys.skipped" || true
  fi

  if (( DRY_RUN )); then
    info "[dry-run] dconf load / < arquivo com $(wc -l < "$filtered" | tr -d ' ') linhas"
  else
    dconf load / < "$filtered"
    ok "preferências do GNOME aplicadas"
  fi

  rm -f "$sanitized" "$filtered" "$skipped"
}

if want dconf; then
  log "Aplicando preferências (dconf)"
  install_dconf
fi

# ---------------------------------------------------------------------------
# GTK
# ---------------------------------------------------------------------------
install_gtk() {
  local v src
  for v in 3.0 4.0; do
    src="$DATA_DIR/gtk/gtk-$v/settings.ini"
    [[ -f $src ]] || continue
    run mkdir -p "$HOME/.config/gtk-$v"
    run cp -f "$src" "$HOME/.config/gtk-$v/settings.ini"
  done

  local link_count
  link_count="$(jq '.assets.gtk4_links | length' "$MANIFEST")"
  (( link_count > 0 )) || return 0

  if (( GN <= 48 || GTK4_THEME )); then
    local name theme target
    while IFS=$'\t' read -r name theme target; do
      [[ -n $name ]] || continue
      run mkdir -p "$HOME/.config/gtk-4.0"
      run ln -sfn "$HOME/.themes/$theme/$target" "$HOME/.config/gtk-4.0/$name"
      ok "link GTK4: $name -> $theme/$target"
    done < <(jq -r '.assets.gtk4_links[] | [.name, .theme, .target] | @tsv' "$MANIFEST")
  else
    warn "GNOME $GN: links de tema GTK4 ignorados (use --gtk4-theme para forçar)"
  fi
}

if want gtk; then
  log "Aplicando configurações GTK"
  install_gtk
fi

# ---------------------------------------------------------------------------
# Ajustes pós-instalação
# ---------------------------------------------------------------------------
validate_shell_theme() {
  [[ -n $SHELL_THEME ]] || return 0

  if (( GN > 46 )); then
    local ext_user="$HOME/.local/share/gnome-shell/extensions/user-theme@gnome-shell-extensions.gcampax.github.com"
    local ext_sys="/usr/share/gnome-shell/extensions/user-theme@gnome-shell-extensions.gcampax.github.com"
    if [[ ! -d $ext_user && ! -d $ext_sys ]]; then
      warn "extensão user-theme não encontrada; o tema de shell não será aplicado"
      return 0
    fi
  fi

  if [[ ! -f "$HOME/.themes/$SHELL_THEME/gnome-shell/gnome-shell.css" ]]; then
    warn "tema de shell '$SHELL_THEME' não encontrado no destino; usando o tema padrão"
    (( DRY_RUN )) || dconf reset /org/gnome/shell/extensions/user-theme/name 2>/dev/null || true
    return 0
  fi

  if (( GN >= 49 )); then
    warn "GNOME $GN: o tema de shell '$SHELL_THEME' é antigo e pode quebrar o painel/overview."
    warn "Se a interface ficar estranha, rode: ./install.sh --reset-shell-theme"
  fi
}

normalize_dock() {
  (( PRESERVE_EXACT )) && return 0
  local enabled
  enabled="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '[]')"
  if [[ $enabled == *dash-to-dock* && $enabled == *ubuntu-dock* ]]; then
    warn "ubuntu-dock e dash-to-dock estão ambos ativos; desabilitando ubuntu-dock"
    if (( DRY_RUN )); then
      info "[dry-run] gnome-extensions disable ubuntu-dock@ubuntu.com"
    else
      gnome-extensions disable ubuntu-dock@ubuntu.com 2>/dev/null || true
    fi
  fi
}

reconcile_extensions() {
  (( PRESERVE_EXACT )) && return 0
  command -v gnome-extensions >/dev/null 2>&1 || return 0

  local available current u value
  available="$(gnome-extensions list 2>/dev/null | sort -u || true)"
  [[ -n $available ]] || return 0

  current="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo '[]')"
  current="$(printf '%s' "$current" | tr -d "[]',")"

  local -a kept=()
  for u in $current; do
    if grep -qx -- "$u" <<<"$available"; then
      kept+=("$u")
    else
      warn "extensão não instalada no destino, removendo da lista: $u"
    fi
  done

  value="["
  local first=1
  for u in "${kept[@]}"; do
    (( first )) || value+=", "
    value+="'$u'"
    first=0
  done
  value+="]"

  if (( DRY_RUN )); then
    info "[dry-run] enabled-extensions = $value"
  else
    gsettings set org.gnome.shell enabled-extensions "$value"
  fi
}

if want dconf || want extensions; then
  validate_shell_theme
  normalize_dock
  reconcile_extensions
fi

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
printf '\n'
if (( DRY_RUN )); then
  ok "Simulação concluída (dry-run). Nada foi alterado."
else
  ok "Aplicação concluída."
fi
[[ -n $SHELL_THEME ]] && info "Tema de shell: $SHELL_THEME" || true
if (( ${#SKIPPED_EXT[@]} > 0 )); then
  info "Extensões ignoradas: ${SKIPPED_EXT[*]}"
fi
if [[ -f "$STATE_DIR/last-snapshot" ]]; then
  info "Snapshot: $(cat "$STATE_DIR/last-snapshot")"
else
  info "Snapshot: nenhum"
fi
printf '\n'

if [[ "$(session_type)" == "wayland" ]]; then
  info "Faça logout e login para que extensões e tema de shell sejam recarregados."
else
  info "Recarregue o shell: Alt+F2, digite 'r' e pressione Enter."
fi
info "Para reverter as preferências: ./install.sh --rollback"
