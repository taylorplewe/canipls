# canipls
(Pronounced "can I please", á la [gopls](https://go.dev/gopls/))

A language server that shows [caniuse.com](https://caniuse.com) support percentages for web features, right in your editor.

![canipls demo](https://whencaniuse.com/gh/canipls-demo-js.gif)

Implements the following features of Microsoft's [Language Server Protocol](https://microsoft.github.io/https://microsoft.github.io/language-server-protocol):
- **diagnostics** - shows warnings on features whose global support percentage falls below the user-defined desired support threshold (or the default, if none is specified.)
- **hover** - hover over any native HTML element, global attribute, CSS at-rule, property, psuedo-selector, JavaScript API or buultin, to see its global support percentage.

Supported file types:
- HTML
- CSS
- JavaScript/Typescript
- JSX/TSX
- Vue
- Svelte
- Astro

> [!IMPORTANT]
> While global support percentages in canipls rarely match 1:1 those of caniuse's, _they are never more than 1% off_, and rarely more than about 0.1% off. canipls data is refreshed once a day, but caniuse.com does not divulge all of its data sources.

## Usage
Follow the instructions for getting canipls up and running in your editor:
<details>
<summary>VS Code</summary>

Download the canipls extension from the marketplace or from within VS Code.

[`canipls` extension on the Visual Studio Code marketplace](https://marketplace.visualstudio.com/items?itemName=TaylorPlewe.canipls)

[`canipls-vscode` extension source code](https://github.com/taylorplewe/canipls-vscode)
</details>

<details>
<summary>Zed</summary>

Download the canipls extension from within Zed (`ctrl`/`cmd` + `shift` + `x`).

TODO: marketplace link needed here

[`canipls-zed` extension source code](https://github.com/taylorplewe/canipls-zed)
</details>

<details>
<summary>Neovim</summary>

1. Download the `canipls` executable from the [Releases page](https://github.com/taylorplewe/canipls/releases/latest) for your operating system & architecture.
2. (optional) Add the executable obtained in step 1 to your PATH.
3. Add the following to your `init.lua`:
    ```lua
    vim.lsp.config('canipls', {
        cmd = { 'canipls', '--stdio' },
        filetypes = {
            -- include as many of the following languages as you need:
            'html',
            'css',
            'javascript',
            'typescript',
            'javascriptreact',
            'typescriptreact',
            'vue',
            'svelte',
            'astro',
        },
    })
    vim.lsp.enable('canipls')
    ```
</details>

<details>
<summary>Helix</summary>

1. Download the `canipls` executable from the [Releases page](https://github.com/taylorplewe/canipls/releases/latest) for your operating system & architecture.
2. (optional) Add the executable obtained in step 1 to your PATH.
3. Add the following to your `languages.toml`:
    ```toml
    [language-server.canipls]                                          
    command = "canipls"

    # add as many of the following languages as you need:
    
    [[language]]
    name = "html"
    language-servers = ["canipls"]
    
    [[language]]
    name = "css"
    language-servers = ["canipls"]
    
    [[language]]
    name = "javascript"                                                       
    language-servers = ["canipls"]
    
    [[language]]
    name = "typescript"                                                       
    language-servers = ["canipls"]
    
    [[language]]
    name = "jsx"                                                       
    language-servers = ["canipls"]
    
    [[language]]
    name = "tsx"                                                       
    language-servers = ["canipls"]
    
    [[language]]
    name = "vue"
    language-servers = ["canipls"]
    
    [[language]]
    name = "svelte"                                                       
    language-servers = ["canipls"]
    
    [[language]]
    name = "astro"                                                       
    language-servers = ["canipls"]
    ```
</details>

### Ignoring lines
It is possible to opt out of canipls warnings for specific lines of code. This is done via various magic comments:

| comment text | function |
| - | - |
| `canipls-ignore` | Ignore the line this comment is found on |
| `canipls-ignore-nextline` | Ignore the line following the one this comment is found on |
| `canipls-ignore-file` | Ignore the whole file if this comment is found anywhere therein |
| `canipls-ignore-start` | Start ignoring from this line |
| `canipls-ignore-end` | Stop ignoring after this line |

#### Examples
```css
/* canipls-ignore-nextline */
@starting-style {
    /* ... */
}
```

```javascript
const now = Temporal.Now.instant(); // canipls-ignore
```

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

Config files are simply plain text files containing one or more of the above config options, separated by newlines, with key/value pairs separated by a space:
```
support_threshold 80.0
show_low_support_warnings true
```

---

This project was researched, designed, and written completely by hand. Among other reasons, quality is a higher priority than quantity for this project. Pull requests that contain AI-generated content of any kind will be rejected.
