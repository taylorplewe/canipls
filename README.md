# canipls
(Pronounced "can I please", á la [gopls](https://go.dev/gopls/))

A language server that shows [caniuse.com](https://caniuse.com) support percentages for web features, right in your editor.

(TODO - gif goes here)

---

Implements the following features of Microsoft's [Language Server Protocol](https://microsoft.github.io/https://microsoft.github.io/language-server-protocol):
- **diagnostics** - shows warnings on features whose global support percentage falls below the user-defined desired support threshold (or the default, if none is specified.)
- **hover** - hover over any native HTML element, global attribute, CSS at-rule, property, psuedo-selector, JavaScript API or buultin, to see its global support percentage.

---

This project was researched, designed, and written completely by hand. Among other reasons, quality is a higher priority than quantity for this project. Any pull requests that are presumed to contain AI-generated content of any kind will be rejected.