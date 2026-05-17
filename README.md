# canipls
(Pronounced "can I please", á la [gopls](https://go.dev/gopls/))

A language server that shows [caniuse.com](https://caniuse.com) support percentages for web features, right in your editor.

(TODO - gif goes here)

Implements the following features of Microsoft's [Language Server Protocol](https://microsoft.github.io/https://microsoft.github.io/language-server-protocol):
- **diagnostics** - shows warnings on features whose global support percentage falls below the user-defined desired support threshold (or the default, if none is specified.)
- **hover** - hover over any native HTML element, global attribute, CSS at-rule, property, psuedo-selector, JavaScript API or buultin, to see its global support percentage.

## Usage
Follow the instructions for getting canipls up and running in your editor:
<details>
<summary>VS Code</summary>

Download the canipls extension from the marketplace or from within VS Code.
TODO: marketplace link needed here

[`canipls-vscode` extension source code](https://github.com/taylorplewe/canipls-vscode)
</details>

<details>
<summary>JetBrains IDEs</summary>

Download the canipls extension from the marketplace or from within JetBrains WebStorm or Rider.

TODO: marketplace link needed here

TODO: repo link needed here
</details>

<details>
<summary>Zed</summary>

Download the canipls extension from the marketplace or from within Zed.
TODO: marketplace link needed here

[`canipls-zed` extension source code](https://github.com/taylorplewe/canipls-zed)
</details>

<details>
<summary>Neovim</summary>

1. Download the `canipls` executable from the [Releases page](/releases/latest) for your operating system & architecture.
2. (optional) Add the executable obtained in step 1 to your PATH.
3. Add the following to your `init.lua`:
    ```lua
    -- TODO actual setup here
    vim.lsp.enable('canipls')
    ```
</details>

## Config
`canipls` will search the following places for configuration options, in order of precedence:
1. a file called `.canipls.cfg` in the current project's root directory
2. a file called `canipls.cfg` in the user's global app config directory
    - on Windows, this is found at `%HOME%/AppData/Roaming/canipls/`
    - on macOS and Linux, this is found at `~/.config/canipls/`
3. use the default values (see below table)

The following configuration options are available:

| name | type | default | description |
| - | - | - | - |
| `support_threshold` | number | `90.0` | The minimum global browser support threshold, according to caniuse, that features must meet |
| `show_low_support_warnings` | boolean | `true` | Whether to show warning diagnostics for features that fall below the desired support threshold. (If this is set to `false`, `support_threshold` has no effect.) |

---

This project was researched, designed, and written completely by hand. Among other reasons, quality is a higher priority than quantity for this project. Any pull requests that contain AI-generated content of any kind will be rejected.