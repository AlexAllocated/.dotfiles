# Chev's .dotfiles

This is my personal development environment. You are welcome to use it or borrow
from it. I'm doing my best to keep all of it as portable as possible, but I make
no guarantees. If you find any issues please feel free to submit a PR or open a
Github issue.

## NixOS-WSL rewrite

The final commit before the Nix rewrite is tagged `pre-nix`.

The current target architecture is Nix-first:

- `NixOS` on WSL is the primary development environment.
- Home Manager owns user-level config for Linux/WSL/macOS.
- nix-darwin owns macOS host integration.
- Docker remains a disposable validation and demo layer.

Install the side-by-side NixOS WSL distro from the existing Ubuntu control-plane
distro:

```sh
./dot-bootstrap nixos-wsl
```

Then, inside the new NixOS distro:

```sh
git clone git@github.com:AlexAllocated/.dotfiles.git ~/.dotfiles
cd ~/.dotfiles
sudo nixos-rebuild boot --flake .#nixos-wsl
dotctl doctor
```

See `docs/nix-wsl-rollout.md` for the full rollout and cutover notes.

Common maintenance commands:

```sh
dotctl check
dotctl apply nixos-wsl
dotctl apply --update
dotctl agents
```

## Try it out with Docker

My full development environment is about 2.22gb in size. The image contains almost
everything I'd ever need for nearly any app I'm working on. Most folks wanting to
try it out are likely just looking for my Neovim setup. So, I have created a
slimmed down Alpine image that is 300.52mb in size. It contains only what is needed
to run my full Neovim setup and nothing extra.

### My full development environment image (2.22gb)

#### `docker run -it chevcast/devenv`

### Alpine Neovim image (300.52mb)

#### `docker run -it chevcast/nvim`

> You can even edit your own files with my Neovim setup by mounting a volume to the
> container and specifying the path for Neovim to open.
>
> `docker run -itv /path/to/your/files:/yourfiles chevcast/nvim /yourfiles`

## Installation

1. Clone the repository into a place of your choosing.

   ```sh
   git clone git@github.com:chevcast/.dotfiles.git
   ```

2. Run the install script.

   > Note that the install script does NOT automatically back up any existing
   > configuration files. Run at your own risk. If you want to try out the setup
   > before installing then see above for how to run the setup in a Docker container.

   ```sh
   cd .dotfiles && install.sh
   ```

3. ???

4. Profit!

## What's Included

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)
- [Bun](https://bun.sh)
- [Dotnet SDK](https://dotnet.microsoft.com/en-us/download)
- [CMake](https://cmake.org/)
- [fd](https://github.com/sharkdp/fd)
- [Git](https://git-scm.com/)
- [Github CLI](https://cli.github.com/)
- [Golang](https://go.dev/doc/install)
- [Homebrew](https://docs.brew.sh/Homebrew-on-Linux)
- [Lazygit](https://github.com/jesseduffield/lazygit#readme)
- [Lua](https://www.lua.org/download.html)
- [Markdown Preview](https://github.com/iamcco/markdown-preview.nvim#readme)
- [Neovim](https://neovim.io/)
- [Oh My ZSH](https://ohmyz.sh/)
- [Powerlevel10k](https://github.com/romkatv/powerlevel10k#readme)
- [Python](https://www.python.org/downloads/)
- [ripgrep](https://github.com/BurntSushi/ripgrep)
- [Volta](https://volta.sh/)
- [Wezterm](https://wezfurlong.org/wezterm/)
- [ZSH](https://www.zsh.org/)
- [Zsh Vi Mode](https://github.com/jeffreytse/zsh-vi-mode#readme)

### Neovim Plugin Manager

- [folke/lazy.nvim](https://github.com/folke/lazy.nvim)
- [LazyVim/starter](https://github.com/LazyVim/starter)

### Neovim Plugins (92)

- [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim.git)
- [FixCursorHold.nvim](https://github.com/antoinemadec/FixCursorHold.nvim.git)
- [SchemaStore.nvim](https://github.com/b0o/SchemaStore.nvim.git)
- [blink-cmp-dictionary](https://github.com/Kaiser-Yang/blink-cmp-dictionary.git)
- [blink-copilot](https://github.com/fang2hou/blink-copilot.git)
- [blink-emoji.nvim](https://github.com/moyiz/blink-emoji.nvim.git)
- [blink.cmp](https://github.com/saghen/blink.cmp.git)
- [bufferline.nvim](https://github.com/akinsho/bufferline.nvim.git)
- [catppuccin](https://github.com/catppuccin/nvim.git)
- [clangd_extensions.nvim](https://github.com/p00f/clangd_extensions.nvim.git)
- [cloak.nvim](https://github.com/laytan/cloak.nvim.git)
- [cmake-tools.nvim](https://github.com/Civitasv/cmake-tools.nvim.git)
- [conform.nvim](https://github.com/stevearc/conform.nvim.git)
- [copilot.lua](https://github.com/zbirenbaum/copilot.lua.git)
- [crates.nvim](https://github.com/Saecki/crates.nvim.git)
- [dial.nvim](https://github.com/monaqa/dial.nvim.git)
- [flash.nvim](https://github.com/folke/flash.nvim.git)
- [friendly-snippets](https://github.com/rafamadriz/friendly-snippets.git)
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim.git)
- [grug-far.nvim](https://github.com/MagicDuck/grug-far.nvim.git)
- [gruvbox.nvim](https://github.com/ellisonleao/gruvbox.nvim.git)
- [helm-ls.nvim](https://github.com/qvalentin/helm-ls.nvim.git)
- [inc-rename.nvim](https://github.com/smjonas/inc-rename.nvim.git)
- [kulala.nvim](https://github.com/mistweaverco/kulala.nvim.git)
- [lazydev.nvim](https://github.com/folke/lazydev.nvim.git)
- [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim.git)
- [markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim.git)
- [mason-lspconfig.nvim](https://github.com/mason-org/mason-lspconfig.nvim.git)
- [mason-nvim-dap.nvim](https://github.com/jay-babu/mason-nvim-dap.nvim.git)
- [mason.nvim](https://github.com/mason-org/mason.nvim.git)
- [mini.ai](https://github.com/nvim-mini/mini.ai.git)
- [mini.files](https://github.com/nvim-mini/mini.files.git)
- [mini.hipatterns](https://github.com/nvim-mini/mini.hipatterns.git)
- [mini.icons](https://github.com/nvim-mini/mini.icons.git)
- [neoconf.nvim](https://github.com/folke/neoconf.nvim.git)
- [neotest](https://github.com/nvim-neotest/neotest.git)
- [neotest-elixir](https://github.com/jfpedroza/neotest-elixir.git)
- [neotest-golang](https://github.com/fredrikaverpil/neotest-golang.git)
- [neotest-pest](https://github.com/V13Axel/neotest-pest.git)
- [neotest-phpunit](https://github.com/olimorris/neotest-phpunit.git)
- [neotest-playwright](https://github.com/thenbe/neotest-playwright.git)
- [neotest-plenary](https://github.com/nvim-neotest/neotest-plenary.git)
- [neotest-python](https://github.com/nvim-neotest/neotest-python.git)
- [neotest-vitest](https://github.com/marilari88/neotest-vitest.git)
- [neotest-vstest](https://github.com/Nsidorenco/neotest-vstest.git)
- [neotest-zig](https://github.com/lawrence-laz/neotest-zig.git)
- [noice.nvim](https://github.com/folke/noice.nvim.git)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim.git)
- [nvim-autopairs](https://github.com/windwp/nvim-autopairs.git)
- [nvim-dap](https://github.com/mfussenegger/nvim-dap.git)
- [nvim-dap-go](https://github.com/leoluz/nvim-dap-go.git)
- [nvim-dap-python](https://github.com/mfussenegger/nvim-dap-python.git)
- [nvim-dap-ui](https://github.com/rcarriga/nvim-dap-ui.git)
- [nvim-dap-virtual-text](https://github.com/theHamsta/nvim-dap-virtual-text.git)
- [nvim-jdtls](https://github.com/mfussenegger/nvim-jdtls.git)
- [nvim-lint](https://github.com/mfussenegger/nvim-lint.git)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig.git)
- [nvim-nio](https://github.com/nvim-neotest/nvim-nio.git)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter.git)
- [nvim-treesitter-context](https://github.com/nvim-treesitter/nvim-treesitter-context.git)
- [nvim-treesitter-textobjects](https://github.com/nvim-treesitter/nvim-treesitter-textobjects.git)
- [nvim-ts-autotag](https://github.com/windwp/nvim-ts-autotag.git)
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons.git)
- [octo.nvim](https://github.com/pwntester/octo.nvim.git)
- [oil.nvim](https://github.com/stevearc/oil.nvim.git)
- [omnisharp-extended-lsp.nvim](https://github.com/Hoffs/omnisharp-extended-lsp.nvim.git)
- [one-small-step-for-vimkind](https://github.com/jbyuki/one-small-step-for-vimkind.git)
- [overseer.nvim](https://github.com/stevearc/overseer.nvim.git)
- [persistence.nvim](https://github.com/folke/persistence.nvim.git)
- [playtime.nvim](https://github.com/rktjmp/playtime.nvim.git)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim.git)
- [rainbow_csv](https://github.com/mechatroner/rainbow_csv.git)
- [refactoring.nvim](https://github.com/ThePrimeagen/refactoring.nvim.git)
- [render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim.git)
- [rustaceanvim](https://github.com/mrcjkb/rustaceanvim.git)
- [screenkey.nvim](https://github.com/NStefan002/screenkey.nvim.git)
- [snacks.nvim](https://github.com/folke/snacks.nvim.git)
- [tiny-devicons-auto-colors.nvim](https://github.com/rachartier/tiny-devicons-auto-colors.nvim.git)
- [todo-comments.nvim](https://github.com/folke/todo-comments.nvim.git)
- [tokyonight.nvim](https://github.com/folke/tokyonight.nvim.git)
- [treesj](https://github.com/Wansmer/treesj.git)
- [trouble.nvim](https://github.com/folke/trouble.nvim.git)
- [ts-comments.nvim](https://github.com/folke/ts-comments.nvim.git)
- [unicode.vim](https://github.com/chrisbra/unicode.vim.git)
- [venv-selector.nvim](https://github.com/linux-cultist/venv-selector.nvim.git)
- [vim-dadbod](https://github.com/tpope/vim-dadbod.git)
- [vim-dadbod-completion](https://github.com/kristijanhusak/vim-dadbod-completion.git)
- [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui.git)
- [vim-visual-multi](https://github.com/mg979/vim-visual-multi.git)
- [which-key.nvim](https://github.com/folke/which-key.nvim.git)
- [window-picker](https://github.com/s1n7ax/nvim-window-picker.git)
- [yanky.nvim](https://github.com/gbprod/yanky.nvim.git)
