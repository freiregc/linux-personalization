# Linux Personalization — GNOME

Repositório de backup e restauração da **aparência do GNOME**: tema GTK,
ícones, fontes, wallpaper, dock, extensões e preferências do shell.

Foi criado a partir de uma instalação **Ubuntu 24.04.5 + GNOME Shell 46** e
preparado para aplicação em **Ubuntu 24.04 (GNOME 46)** e **Ubuntu 26.04
(GNOME 50, Wayland-only)**.

O fluxo é simples:

1. `./backup.sh` exporta a configuração desta máquina para `./data`.
2. Você versiona `./data` no git e leva o repositório para a outra máquina.
3. `./install.sh` aplica tudo lá, com snapshot e rollback.

---

## O que é salvo

| Item | Origem | Observação |
|---|---|---|
| Preferências do GNOME | dconf | Whitelist de aparência; não copia rede, Bluetooth, teclado etc. |
| Tema GTK | `~/.themes` | Tema ativo, variantes e temas referenciados pelo GTK4 |
| Tema de ícones | `~/.icons` / `~/.local/share/icons` | Tema ativo e heranças que também sejam de usuário |
| Fontes | `~/.local/share/fonts`, `~/.fonts` | Todos os arquivos de fonte do usuário |
| Wallpaper | `~/.config` (dconf) | A imagem em si é copiada para `data/wallpaper/` |
| Extensões de usuário | `~/.local/share/gnome-shell/extensions` | Código copiado; compatibilidade validada no install |
| Configurações GTK | `~/.config/gtk-3.0`, `~/.config/gtk-4.0` | `settings.ini` e alvos dos symlinks do GTK4 |
| Manifesto | — | Versões, data, checksums e lista de arquivos |

Caminhos de dconf incluídos:

```
/org/gnome/desktop/interface/
/org/gnome/desktop/background/
/org/gnome/desktop/screensaver/
/org/gnome/desktop/wm/preferences/
/org/gnome/mutter/
/org/gnome/shell/            (inclui [extensions/*])
/org/gnome/nautilus/preferences/
```

### O que NÃO é salvo (de propósito)

- `monitors.xml` — contém conectores e seriais dos monitores; aplicar em outra
  máquina pode deixar a tela sem imagem.
- Wi-Fi, Bluetooth, contas online, impressoras, teclado/mouse.
- Aliases, `.bashrc`, `.zshrc`, tokens, chaves SSH e credenciais.
- Lista de aplicativos instalados e repositórios apt.
- `preferred-monitor-by-connector` do dash-to-dock (nome do conector é
  específico da máquina; o dock usa o monitor primário).
- `welcome-dialog-last-shown-version` e `last-version-installed` (estado
  interno de versão, não aparência).

---

## Requisitos

Na máquina de destino:

- Ubuntu com GNOME Shell (testado em 24.04 e 26.04).
- `bash` 4.4+, `dconf`, `gsettings`, `jq`, `rsync`, `fc-cache`.
- Sessão gráfica GNOME ativa (para dconf/gsettings e `gnome-extensions`).

```bash
sudo apt install jq rsync fontconfig
```

O Ubuntu já traz `dconf-cli`, `gsettings` (libglib2.0-bin) e `gnome-shell`.

---

## Como usar

### 1. Exportar (máquina atual)

```bash
cd linux-personalization
./backup.sh
```

O padrão copia **somente o que está em uso** (~57 MB neste setup):

- tema ativo + variantes + temas usados pelos symlinks do GTK4;
- tema de ícones ativo + heranças de usuário;
- todas as fontes do usuário;
- wallpaper e, se for customizado, o da tela de bloqueio.

Para copiar **todos** os temas e ícones de `~/.themes` e `~/.icons`:

```bash
./backup.sh --all-assets     # ~206 MB neste setup
```

Outras opções:

```bash
./backup.sh --output /tmp/meu-backup
./backup.sh --include-hostname   # inclui hostname no manifest
./backup.sh --help
```

### 2. Versionar e transportar

```bash
git add -A
git commit -m "backup: $(date +%F)"
git remote add origin git@github.com:SEU_USUARIO/linux-personalization.git
git push -u origin main
```

> O repositório tem dezenas de MB por causa dos temas, ícones e fontes.
> Se for usar `--all-assets` e publicar, considere Git LFS.

### 3. Aplicar (máquina nova)

```bash
git clone git@github.com:SEU_USUARIO/linux-personalization.git
cd linux-personalization

./install.sh --dry-run    # mostra tudo sem alterar nada
./install.sh              # aplica de verdade
```

O `install.sh`:

1. detecta a versão do GNOME e o tipo de sessão;
2. cria um snapshot em `~/.local/state/gnome-personalization/snapshots/`;
3. instala extensões de sistema via apt (pergunta antes; use `--yes`);
4. copia temas, ícones, fontes e wallpaper;
5. copia extensões de usuário compatíveis e compila os schemas;
6. filtra chaves de dconf incompatíveis e aplica;
7. recria os symlinks do GTK4 quando faz sentido;
8. resolve conflito de dock e extensões ausentes;
9. avisa como recarregar o shell.

Depois:

- **X11 (24.04):** `Alt+F2`, digite `r`, Enter.
- **Wayland (26.04):** faça logout e login.

### 4. Reverter

O install guarda um snapshot do dconf completo antes de mexer em qualquer
coisa:

```bash
./install.sh --rollback                 # último snapshot
./install.sh --rollback=20261102-080019 # snapshot específico
ls ~/.local/state/gnome-personalization/snapshots/
```

O rollback restaura **dconf** e os arquivos de `~/.config/gtk-3.0/4.0`.
Temas, ícones, fontes e extensões copiados **não são removidos
automaticamente** — remova manualmente se desejar.

---

## Opções do install.sh

| Opção | Efeito |
|---|---|
| `--dry-run` | Não altera nada; mostra cada ação |
| `--yes`, `-y` | Não pergunta antes de instalar pacotes apt |
| `--no-apt` | Não instala pacotes; apenas avisa o que falta |
| `--only=dconf,themes,...` | Aplica só os módulos indicados |
| `--overwrite-assets` | Sobrescreve temas/ícones/extensões existentes |
| `--force-extensions` | Copia extensões mesmo sem suporte declarado |
| `--gtk4-theme` | Recria symlinks GTK4 mesmo em GNOME ≥ 49 |
| `--reset-shell-theme` | Remove o tema de shell customizado |
| `--preserve-exact` | Não normaliza conflitos (ex.: dock duplicado) |
| `--no-snapshot` | Não cria snapshot antes de aplicar |
| `--rollback[=SNAPSHOT]` | Restaura um snapshot |
| `--help` | Ajuda |

Módulos válidos: `dconf`, `themes`, `icons`, `fonts`, `wallpaper`,
`extensions`, `gtk`.

Exemplos:

```bash
./install.sh --only=themes,icons --yes
./install.sh --only=dconf --dry-run
./install.sh --reset-shell-theme
```

---

## Compatibilidade Ubuntu 24.04 ↔ 26.04

| Item | 24.04 / GNOME 46 / X11 | 26.04 / GNOME 50 / Wayland |
|---|---|---|
| Preferências dconf | ✅ | ✅ (chaves inexistentes são filtradas) |
| Tema GTK, ícones e fontes | ✅ | ✅ para apps GTK3 |
| Wallpaper | ✅ | ✅ |
| blur-my-shell | ✅ | ✅ (declara suporte a 46–50) |
| dash-to-dock | ✅ | ✅ (declara 45–51) |
| just-perfection | ✅ | ✅ (declara 45–51) |
| dash-in-panel | ✅ | ✅ (declara 46–50) |
| user-theme | ✅ cópia local | ✅ pacote `gnome-shell-extension-user-theme` |
| Tema de shell de terceiros | ✅ | ⚠️ pode quebrar no GNOME 50 |
| Recarregar shell | `Alt+F2` → `r` | logout/login |
| `monitors.xml` | ❌ não copiado | ❌ não copiado |

Detalhes importantes:

- **Ubuntu 26.04 é Wayland-only.** Não existe mais sessão X11; por isso o
  script não usa `xrandr` e avisa para relogar em vez de usar `Alt+F2 r`.
- **`user-theme`:** a cópia local declara suporte apenas a GNOME 46. No
  GNOME ≥ 47 o script ignora a cópia e instala o pacote da distro via apt.
- **Tema de shell:** temas antigos podem ter CSS incompatível com GNOME 50.
  Se o painel/overview ficar estranho, rode `./install.sh --reset-shell-theme`.
- **GTK4/libadwaita:** em GNOME ≥ 49 os symlinks de `~/.config/gtk-4.0`
  são ignorados por padrão. Use `--gtk4-theme` para forçar.
- **Dock:** se `ubuntu-dock` e `dash-to-dock` estiverem ativos ao mesmo tempo,
  o script desabilita o `ubuntu-dock` (use `--preserve-exact` para manter).
- **Monitor:** o `dash-to-dock` usa o monitor primário do destino; o nome
  `HDMI-0` da máquina de origem é descartado.
- **GNOME 46–50** é a faixa testada. Outras versões geram aviso, mas o script
  continua filtrando chaves e extensões incompatíveis.

---

## Estrutura do repositório

```
linux-personalization/
├── backup.sh              # exporta esta máquina para ./data
├── install.sh             # aplica ./data nesta máquina
├── lib/common.sh          # funções compartilhadas
├── data/
│   ├── manifest.json      # metadados, versões e lista de assets
│   ├── SHA256SUMS         # checksums de todos os arquivos
│   ├── dconf/
│   │   ├── gnome-appearance.dconf
│   │   ├── keys.skipped   # chaves ignoradas na exportação
│   │   └── paths.txt
│   ├── extensions/
│   ├── themes/
│   ├── icons/
│   ├── fonts/
│   ├── wallpaper/
│   └── gtk/
├── README.md
├── .gitignore
└── .gitattributes
```

### Verificar integridade

```bash
cd data
sha256sum -c SHA256SUMS
```

### Atualizar o backup depois de mudar algo

```bash
./backup.sh
git add -A
git commit -m "backup: $(date +%F)"
git push
```

O `backup.sh` substitui `./data` por uma exportação nova. O snapshot de
restauração fica **fora** do repositório, em
`~/.local/state/gnome-personalization/`.

---

## Segurança e privacidade

- Nenhum token, chave SSH ou credencial é copiado.
- O hostname é omitido do `manifest.json` por padrão. Use
  `--include-hostname` se quiser registrá-lo.
- O `manifest.json` contém apenas distro, versão do GNOME, tipo de sessão,
  data e metadados dos assets.
- A lista de dconf é uma whitelist de aparência; configurações de rede,
  Bluetooth, contas e periféricos não entram.
- Revise o repositório antes de torná-lo público: nomes de apps favoritos e
  layout do app grid podem revelar preferências pessoais.

---

## Solução de problemas

**Extensão não aparece depois do login**
Ela pode ter sido ignorada por incompatibilidade. Veja a saída do install e
confirme:

```bash
gnome-extensions list
gnome-extensions info UUID
```

Se a extensão realmente suportar a versão, tente `--force-extensions`
(ela pode funcionar mesmo sem declarar suporte).

**Interface quebrada / painel estranho após aplicar no 26.04**
Provavelmente é o tema de shell antigo:

```bash
./install.sh --reset-shell-theme
```

**Dock duplicado**
Confirme que só um está ativo:

```bash
gnome-extensions disable ubuntu-dock@ubuntu.com
```

Ou rode o install sem `--preserve-exact`.

**Wallpaper não muda**
Verifique se a imagem foi copiada e se a URI aponta para o novo home:

```bash
ls ~/.local/share/backgrounds/
gsettings get org.gnome.desktop.background picture-uri
```

**Muitas chaves ignoradas**
Normal ao restaurar um backup de GNOME 46 em GNOME 50 (ou vice-versa).
O install mostra um resumo e o arquivo `data/dconf/keys.skipped` tem a lista
da exportação original.

**`jq: command not found`**

```bash
sudo apt install jq
```

**Quero voltar tudo**

```bash
./install.sh --rollback
```

---

## Limitações

- Temas de terceiros podem ficar defasados em versões novas do GNOME/GTK.
- O rollback cobre dconf e configurações GTK, mas não desinstala pacotes apt
  nem remove arquivos copiados.
- O layout de monitores não é restaurado.
- Extensões instaladas pela loja do GNOME podem ser atualizadas
  automaticamente e sobrescrever a cópia do repositório.
- O repositório cresce rápido com `--all-assets`; Git LFS é recomendado nesse
  caso.
