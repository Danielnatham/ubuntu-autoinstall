#!/usr/bin/env bash
set -euo pipefail

DONE_FILE="/var/lib/ubuntu-autoinstall.done"
LOG_FILE="/var/log/ubuntu-autoinstall.log"
FLATPAK_REMOTE="flathub"

mkdir -p "$(dirname "${DONE_FILE}")"
mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ -f "${DONE_FILE}" ]]; then
  exit 0
fi

TARGET_USER="${TARGET_USER:-$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" { print $1; exit }' /etc/passwd)}"
if [[ -z "${TARGET_USER}" ]]; then
  echo "Nao foi possivel identificar o usuario principal." >&2
  exit 1
fi

TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
if [[ -z "${TARGET_HOME}" ]]; then
  echo "Nao foi possivel identificar o home do usuario ${TARGET_USER}." >&2
  exit 1
fi

run_as_user() {
  su - "${TARGET_USER}" -c "$*"
}

install_fonts() {
  local fonts_root="/usr/local/share/fonts/nerd-fonts"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN

  install_font_family() {
    local family="$1"
    local destination="${fonts_root}/${family}"
    local archive="${tmp_dir}/${family}.zip"

    if [[ -d "${destination}" ]] && find "${destination}" \( -type f \( -name '*.ttf' -o -name '*.otf' \) \) | grep -q .; then
      return
    fi

    mkdir -p "${destination}"
    curl -fsSL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/${family}.zip" -o "${archive}"
    unzip -qo "${archive}" -d "${destination}"
  }

  install_font_family "JetBrainsMono"
  install_font_family "Hack"
  fc-cache -f
}

install_sourcegit() {
  local arch release_json version asset_url tmp_deb

  arch="$(dpkg --print-architecture)"
  case "${arch}" in
    amd64|arm64) ;;
    *)
      echo "Arquitetura sem pacote SourceGit automatizado: ${arch}" >&2
      exit 1
      ;;
  esac

  release_json="$(curl -fsSL https://api.github.com/repos/sourcegit-scm/sourcegit/releases/latest)"
  version="$(printf '%s' "${release_json}" | jq -r '.tag_name | ltrimstr("v")')"
  asset_url="$(printf '%s' "${release_json}" | jq -r --arg arch "${arch}" '.assets[] | select(.name | endswith("_" + $arch + ".deb")) | .browser_download_url' | head -n1)"

  if [[ -z "${asset_url}" ]]; then
    echo "Nao foi possivel localizar o .deb do SourceGit para ${arch}." >&2
    exit 1
  fi

  if dpkg-query -W -f='${Version}\n' sourcegit 2>/dev/null | grep -q "^${version}"; then
    return
  fi

  tmp_deb="$(mktemp --suffix=.deb)"

  curl -fsSL "${asset_url}" -o "${tmp_deb}"
  apt-get install -y "${tmp_deb}"
  rm -f "${tmp_deb}"
}

install_flatpak_apps() {
  local app_ids=(
    com.spotify.Client
    com.rtosta.zapzap
    io.dbeaver.DBeaverCommunity
    io.github.tobagin.sonar
    com.usebruno.Bruno
    me.iepure.devtoolbox
    io.github.pol_rivero.github-desktop-plus
    com.discordapp.Discord
    com.github.tchx84.Flatseal
    org.videolan.VLC
    com.visualstudio.code
    com.vivaldi.Vivaldi
    md.obsidian.Obsidian
  )

  flatpak remote-add --if-not-exists --system "${FLATPAK_REMOTE}" https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y --noninteractive --system "${FLATPAK_REMOTE}" "${app_ids[@]}"
}

install_chezmoi() {
  if command -v chezmoi >/dev/null 2>&1; then
    return
  fi

  sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
}

install_zsh_stack() {
  install_repo() {
    local repo_url="$1"
    local destination="$2"

    if [[ -d "${destination}/.git" ]]; then
      return
    fi

    install -d "$(dirname "${destination}")"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$(dirname "${destination}")"
    run_as_user "git clone --depth=1 '${repo_url}' '${destination}'"
  }

  install_repo "https://github.com/ohmyzsh/ohmyzsh.git" "${TARGET_HOME}/.oh-my-zsh"
  install_repo "https://github.com/romkatv/powerlevel10k.git" "${TARGET_HOME}/.oh-my-zsh/custom/themes/powerlevel10k"
  install_repo "https://github.com/zsh-users/zsh-autosuggestions.git" "${TARGET_HOME}/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
  install_repo "https://github.com/zdharma-continuum/fast-syntax-highlighting.git" "${TARGET_HOME}/.oh-my-zsh/custom/plugins/fast-syntax-highlighting"
  install_repo "https://github.com/marlonrichert/zsh-autocomplete.git" "${TARGET_HOME}/.oh-my-zsh/custom/plugins/zsh-autocomplete"

  chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.oh-my-zsh"
}

main() {
  install_fonts
  install_sourcegit
  install_flatpak_apps
  install_chezmoi
  install_zsh_stack

  run_as_user "chezmoi init --apply Danielnatham/dotfiles"

  touch "${DONE_FILE}"
}

main "$@"
