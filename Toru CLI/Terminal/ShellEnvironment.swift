import Foundation

/// Builds a per-app `ZDOTDIR` containing a minimal generated `.zshrc` that
/// keeps the user's real `~/.zshrc` in play but turns off terminal echo
/// and prompt chrome. With echo + prompt off, our `BlockStore` only ever
/// sees the actual command output rather than the user's keystrokes
/// echoed back and zsh's `>` / `%` prompt characters.
enum ShellEnvironment {

    static func zdotdir() -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("toru-zsh", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try? toruZshrc.write(to: dir.appendingPathComponent(".zshrc"),
                             atomically: true, encoding: .utf8)

        // Forward .zshenv so PATH set there still applies.
        let userZshenv = (NSHomeDirectory() as NSString).appendingPathComponent(".zshenv")
        let envContent = """
        # Toru CLI generated.
        if [[ -f "\(userZshenv)" ]]; then
            source "\(userZshenv)"
        fi
        """
        try? envContent.write(to: dir.appendingPathComponent(".zshenv"),
                              atomically: true, encoding: .utf8)
        return dir.path
    }

    static func isZsh(_ shellPath: String) -> Bool {
        (shellPath as NSString).lastPathComponent == "zsh"
    }

    private static let toruZshrc: String = #"""
    # Toru CLI generated .zshrc — regenerated each launch.

    # 1. Source user's ~/.zshrc (unless explicitly bypassed for debugging).
    if [[ -z "$__TORU_USER_ZSHRC_SOURCED" \
        && -z "$TORU_SKIP_USER_ZSHRC" \
        && -f "$HOME/.zshrc" ]]; then
        typeset -g __TORU_USER_ZSHRC_SOURCED=1
        local _toru_saved_zdotdir="$ZDOTDIR"
        unset ZDOTDIR
        source "$HOME/.zshrc" 2>/dev/null
        export ZDOTDIR="$_toru_saved_zdotdir"
        unset _toru_saved_zdotdir
    fi

    # 1b. Fallback: source common version managers explicitly. Some users'
    #     ~/.zshrc only conditionally sources these (e.g. via oh-my-zsh
    #     plugins or guards on $PS1) and that path doesn't fire under
    #     Toru's shell setup. These checks are no-ops when already loaded.
    if ! command -v nvm >/dev/null 2>&1 && [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        export NVM_DIR="$HOME/.nvm"
        source "$HOME/.nvm/nvm.sh" 2>/dev/null
        [[ -s "$HOME/.nvm/bash_completion" ]] && source "$HOME/.nvm/bash_completion" 2>/dev/null
    fi
    if ! command -v asdf >/dev/null 2>&1 && [[ -s "$HOME/.asdf/asdf.sh" ]]; then
        source "$HOME/.asdf/asdf.sh" 2>/dev/null
    fi
    if ! command -v fnm >/dev/null 2>&1; then
        for fnmbin in /opt/homebrew/bin/fnm /usr/local/bin/fnm; do
            if [[ -x "$fnmbin" ]]; then
                eval "$($fnmbin env --use-on-cd)" 2>/dev/null
                break
            fi
        done
    fi
    if ! command -v rbenv >/dev/null 2>&1; then
        for rbenvbin in /opt/homebrew/bin/rbenv /usr/local/bin/rbenv "$HOME/.rbenv/bin/rbenv"; do
            if [[ -x "$rbenvbin" ]]; then
                export PATH="$(dirname $rbenvbin):$PATH"
                eval "$($rbenvbin init - zsh)" 2>/dev/null
                break
            fi
        done
    fi
    if ! command -v pyenv >/dev/null 2>&1; then
        for pyenvbin in /opt/homebrew/bin/pyenv /usr/local/bin/pyenv "$HOME/.pyenv/bin/pyenv"; do
            if [[ -x "$pyenvbin" ]]; then
                export PYENV_ROOT="$HOME/.pyenv"
                export PATH="$PYENV_ROOT/bin:$PATH"
                eval "$($pyenvbin init - zsh)" 2>/dev/null
                break
            fi
        done
    fi

    # 2. Disable echo at *both* layers:
    #    - kernel TTY echo (`stty -echo`)
    #    - zsh's line editor (ZLE), which redraws the typed line via PROMPT
    #      regardless of `stty -echo`. Without this, characters typed by
    #      Toru's SwiftUI input field appear duplicated in block output.
    #    `unsetopt zle` makes zsh fall back to plain kernel line input —
    #    no readline editing, no syntax highlighting, no inline completion.
    #    That's fine for Toru: editing happens entirely in the SwiftUI
    #    TextField, the shell only needs to read whole lines.
    unsetopt zle 2>/dev/null
    stty -echo 2>/dev/null

    # 3. Empty prompts. Toru renders chrome in SwiftUI; the shell shouldn't
    #    paint anything between commands. Override every cycle so frameworks
    #    (powerlevel10k, starship, …) that mutate PROMPT inside their own
    #    precmd cannot reintroduce a visible prompt.
    autoload -Uz add-zsh-hook
    __toru_clear_prompts() {
        PROMPT=''
        PROMPT2=''
        RPROMPT=''
        # Re-assert ZLE off in case a framework re-enabled it.
        unsetopt zle 2>/dev/null
    }
    __toru_clear_prompts
    add-zsh-hook -d precmd __toru_clear_prompts 2>/dev/null
    add-zsh-hook precmd __toru_clear_prompts
    """#
}
