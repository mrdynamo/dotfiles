# home dotfiles

This directory is the active chezmoi source root.
It uses chezmoi template data to model two machine classes:

- `personal`
- `work`

Platform is detected automatically from the host:

- `macos`
- `linux`
- `wsl2`

Those two pieces combine into a profile such as `personal-macos` or `work-wsl2`.

## Current model

The current implementation does not use a shared JSON parameter template.
It also does not require each template to re-compute machine class and platform.

Instead, the source of truth is [home/.chezmoi.yaml.tmpl](/home/mrdynamo/.local/share/chezmoi/home/.chezmoi.yaml.tmpl), which:

1. Prompts once for machine class with `promptChoiceOnce`.
2. Detects OS and WSL automatically.
3. Writes derived values into chezmoi config data.
4. Makes those values available directly to every template as top-level variables.

The generated local config shape is:

```yaml
data:
   machineClass: work
   isPersonal: false
   isWork: true
   isLinux: true
   isMacOS: false
   isWSL: true
   platform: wsl2
   profile: work-wsl2
```

That means templates can now use direct checks like:

```gotemplate
{{- if .isWork }}...{{- end }}
{{- if and .isPersonal .isMacOS }}...{{- end }}
{{- if and .isWork .isWSL }}...{{- end }}
```

## Available template variables

These values are available everywhere once `.chezmoi.yaml.tmpl` has been rendered:

| Variable | Type | Example |
|---|---|---|
| `.machineClass` | string | `work` |
| `.platform` | string | `wsl2` |
| `.profile` | string | `work-wsl2` |
| `.isPersonal` | bool | `false` |
| `.isWork` | bool | `true` |
| `.isLinux` | bool | `true` |
| `.isMacOS` | bool | `false` |
| `.isWSL` | bool | `true` |

## Machine profiles

| Profile | Machine class | Platform |
|---|---|---|
| `personal-macos` | personal | macOS |
| `personal-linux` | personal | native Linux |
| `personal-wsl2` | personal | WSL2 |
| `work-macos` | work | macOS |
| `work-linux` | work | native Linux |
| `work-wsl2` | work | WSL2 |

## How current templates use the data

### [home/dot_gitconfig.tmpl](/home/mrdynamo/.local/share/chezmoi/home/dot_gitconfig.tmpl)

Uses the derived booleans directly:

- `.isMacOS` enables the macOS 1Password SSH signer.
- `.isWSL` enables the WSL 1Password SSH signer path and `ssh.exe` as `core.sshCommand`.
- Linux non-WSL systems get neither of those blocks.

### [home/dot_config/zsh/env.zsh.tmpl](/home/mrdynamo/.local/share/chezmoi/home/dot_config/zsh/env.zsh.tmpl)

Exports runtime environment derived from the template data:

- `DOTFILES_MACHINE_CLASS`
- `DOTFILES_MACHINE_PLATFORM`
- `DOTFILES_MACHINE_PROFILE`
- `DOTFILES_PROMPT_TAG`
- `DOTFILES_USE_WINDOWS_SSH`
- `DOTFILES_IS_WSL`

It also exports shared shell defaults such as `EDITOR`, `VISUAL`, and prepends `$HOME/.local/bin` to `PATH`.

### [home/dot_config/zsh/alias.zsh.tmpl](/home/mrdynamo/.local/share/chezmoi/home/dot_config/zsh/alias.zsh.tmpl)

Uses the runtime env from `env.zsh` rather than repeating chezmoi logic.

When `DOTFILES_USE_WINDOWS_SSH=1`, it aliases:

- `ssh` -> `ssh.exe`
- `ssh-add` -> `ssh-add.exe`
- `op` -> `op.exe`

### [home/dot_config/atuin/private_config.toml.tmpl](/home/mrdynamo/.local/share/chezmoi/home/dot_config/atuin/private_config.toml.tmpl)

Uses `.isWork` directly to choose sync backend:

- work systems: `https://api.atuin.sh`
- personal systems: `https://atuin.internal.dynamiclab.org`

## Recommended pattern for new templates

For most new files, do not add a local machine-resolution header anymore.
Use the booleans and strings already provided by `.chezmoi.yaml.tmpl`.

Examples:

```gotemplate
{{- if .isWork }}
...
{{- end }}
```

```gotemplate
{{- if and .isPersonal .isMacOS }}
...
{{- end }}
```

```gotemplate
{{- if eq .profile "work-wsl2" }}
...
{{- end }}
```

Prefer the broadest useful condition:

- use `.isWork` when the behavior applies to all work systems
- use `.isWSL` when it is purely platform-specific
- use `and .isWork .isWSL` when both matter
- use `.profile` only when a specific exact combination is needed

## File structure

```text
home/
├── .chezmoi.yaml.tmpl
├── README.md
├── dot_gitconfig.tmpl
├── dot_zshrc
└── dot_config/
      ├── atuin/
      │   └── private_config.toml.tmpl
      ├── mise/
   │   └── config.toml
   ├── starship/
   │   └── starship.toml.tmpl
      └── zsh/
            ├── alias.zsh.tmpl
            ├── completions.zsh.tmpl
            ├── env.zsh.tmpl
            ├── executable_functions.zsh.tmpl
            ├── init.zsh.tmpl
            ├── packages.zsh.tmpl
            ├── plugin_manager.zsh.tmpl
            └── special_alias.zsh.tmpl
```

## Extending this setup

### Add a new boolean or derived value

Update [home/.chezmoi.yaml.tmpl](/home/mrdynamo/.local/share/chezmoi/home/.chezmoi.yaml.tmpl) and add the derived field under `data:`.

For example, if you wanted a dedicated `isNativeLinux` flag:

```gotemplate
   isNativeLinux: {{ and $isLinux (not $isWSL) }}
```

Then templates can use `.isNativeLinux` directly.

### Add a new profile-specific behavior

Use one of these patterns:

```gotemplate
{{- if .isWork }}
```

```gotemplate
{{- if and .isPersonal .isMacOS }}
```

```gotemplate
{{- if eq .profile "work-wsl2" }}
```

### Add a new templated file

1. Create the file under `home/` with a `.tmpl` suffix if it needs templating.
2. Prefer direct use of `.isWork`, `.isPersonal`, `.isWSL`, `.isMacOS`, `.isLinux`, `.platform`, and `.profile`.
3. If multiple files need the same new concept, add a derived value once in `.chezmoi.yaml.tmpl` instead of repeating the condition everywhere.
