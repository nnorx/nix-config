# Neovim configuration

{ pkgs, ... }:
{
  programs.neovim = {
    enable = true;
    
    # Set as default editor
    defaultEditor = true;
    
    # Aliases
    viAlias = true;
    vimAlias = true;
    vimdiffAlias = true;
    
    # Plugins
    plugins = with pkgs.vimPlugins; [
      # Theme
      {
        plugin = catppuccin-nvim;
        type = "lua";
        config = ''
          require("catppuccin").setup({
            flavour = "mocha",
            integrations = {
              treesitter = true,
              native_lsp = { enabled = true },
              telescope = true,
            },
          })
          vim.cmd.colorscheme "catppuccin"
        '';
      }
      
      # Syntax highlighting (only needed grammars for faster builds)
      {
        plugin = nvim-treesitter.withPlugins (p: [
          p.typescript p.javascript p.tsx p.json
          p.rust p.nix p.lua p.bash p.markdown
          p.yaml p.toml p.html p.css p.dockerfile
          p.gitignore p.make p.python
        ]);
        type = "lua";
        config = ''
          require('nvim-treesitter.configs').setup({
            highlight = { enable = true },
            indent = { enable = true },
          })
        '';
      }
      
      # File explorer
      {
        plugin = nvim-tree-lua;
        type = "lua";
        config = ''
          require("nvim-tree").setup({
            view = { width = 30 },
          })
          vim.keymap.set('n', '<leader>e', ':NvimTreeToggle<CR>', { desc = 'Toggle file explorer' })
        '';
      }
      nvim-web-devicons  # Icons for nvim-tree
      
      # Fuzzy finder
      {
        plugin = telescope-nvim;
        type = "lua";
        config = ''
          require('telescope').setup({
            extensions = {
              fzf = {
                fuzzy = true,
                override_generic_sorter = true,
                override_file_sorter = true,
              },
            },
          })
          require('telescope').load_extension('fzf')

          local builtin = require('telescope.builtin')
          vim.keymap.set('n', '<leader>ff', builtin.find_files, { desc = 'Find files' })
          vim.keymap.set('n', '<leader>fg', builtin.live_grep, { desc = 'Live grep' })
          vim.keymap.set('n', '<leader>fb', builtin.buffers, { desc = 'Find buffers' })
          vim.keymap.set('n', '<leader>fh', builtin.help_tags, { desc = 'Help tags' })
        '';
      }
      telescope-fzf-native-nvim  # Native FZF sorter for telescope
      plenary-nvim  # Required by telescope
      
      # Status line
      {
        plugin = lualine-nvim;
        type = "lua";
        config = ''
          require('lualine').setup({
            options = {
              theme = 'catppuccin',
              section_separators = { left = "", right = "" },
              component_separators = { left = "", right = "" },
            },
          })
        '';
      }
      
      # LSP Support
      {
        plugin = nvim-lspconfig;
        type = "lua";
        config = ''
          local lspconfig = require('lspconfig')
          
          -- TypeScript/JavaScript
          lspconfig.ts_ls.setup({})
          
          -- Rust
          lspconfig.rust_analyzer.setup({})
          
          -- Nix
          lspconfig.nil_ls.setup({})
          
          -- Global keybindings for LSP
          vim.keymap.set('n', 'gd', vim.lsp.buf.definition, { desc = 'Go to definition' })
          vim.keymap.set('n', 'gr', vim.lsp.buf.references, { desc = 'Find references' })
          vim.keymap.set('n', 'K', vim.lsp.buf.hover, { desc = 'Hover documentation' })
          vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, { desc = 'Rename symbol' })
          vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, { desc = 'Code actions' })
          vim.keymap.set('n', '<leader>f', function() vim.lsp.buf.format({ async = true }) end, { desc = 'Format buffer' })
        '';
      }
      
      # Snippet engine
      {
        plugin = luasnip;
        type = "lua";
        config = ''
          local luasnip = require('luasnip')
          -- Jump forward/backward through snippet placeholders
          vim.keymap.set({'i', 's'}, '<C-k>', function() luasnip.jump(1) end, { desc = 'Next snippet placeholder' })
          vim.keymap.set({'i', 's'}, '<C-j>', function() luasnip.jump(-1) end, { desc = 'Previous snippet placeholder' })
        '';
      }

      # Autocompletion
      {
        plugin = nvim-cmp;
        type = "lua";
        config = ''
          local cmp = require('cmp')
          local luasnip = require('luasnip')
          cmp.setup({
            snippet = {
              expand = function(args)
                luasnip.lsp_expand(args.body)
              end,
            },
            mapping = cmp.mapping.preset.insert({
              ['<C-b>'] = cmp.mapping.scroll_docs(-4),
              ['<C-f>'] = cmp.mapping.scroll_docs(4),
              ['<C-Space>'] = cmp.mapping.complete(),
              ['<C-e>'] = cmp.mapping.abort(),
              ['<CR>'] = cmp.mapping.confirm({ select = true }),
              ['<Tab>'] = cmp.mapping.select_next_item(),
              ['<S-Tab>'] = cmp.mapping.select_prev_item(),
            }),
            sources = cmp.config.sources({
              { name = 'luasnip' },
              { name = 'nvim_lsp' },
              { name = 'buffer' },
              { name = 'path' },
            }),
          })
        '';
      }
      cmp_luasnip
      cmp-nvim-lsp
      cmp-buffer
      cmp-path
      
      # Git signs in gutter
      {
        plugin = gitsigns-nvim;
        type = "lua";
        config = ''
          require('gitsigns').setup({
            signs = {
              add = { text = '│' },
              change = { text = '│' },
              delete = { text = '_' },
              topdelete = { text = '‾' },
              changedelete = { text = '~' },
            },
          })
        '';
      }
      
      # Auto pairs
      {
        plugin = nvim-autopairs;
        type = "lua";
        config = "require('nvim-autopairs').setup({})";
      }
      
      # Comment toggle
      {
        plugin = comment-nvim;
        type = "lua";
        config = "require('Comment').setup()";
      }
      
      # Which-key for keybinding hints
      {
        plugin = which-key-nvim;
        type = "lua";
        config = ''
          require("which-key").setup({})
          require("which-key").add({
            { "<leader>f", group = "Find" },
            { "<leader>g", group = "Git" },
          })
        '';
      }
    ];
    
    # Extra Lua configuration
    extraLuaConfig = ''
      -- Set leader key to space
      vim.g.mapleader = ' '
      vim.g.maplocalleader = ' '
      
      -- Basic options
      vim.opt.number = true           -- Show line numbers
      vim.opt.relativenumber = true   -- Relative line numbers
      vim.opt.mouse = 'a'             -- Enable mouse
      vim.opt.clipboard = 'unnamedplus' -- Use system clipboard
      vim.opt.breakindent = true      -- Wrapped lines respect indent
      vim.opt.undofile = true         -- Persistent undo
      vim.opt.ignorecase = true       -- Case insensitive search
      vim.opt.smartcase = true        -- Unless uppercase used
      vim.opt.signcolumn = 'yes'      -- Always show sign column
      vim.opt.updatetime = 250        -- Faster completion
      vim.opt.timeoutlen = 300        -- Faster which-key
      vim.opt.splitright = true       -- Splits open right
      vim.opt.splitbelow = true       -- Splits open below
      vim.opt.cursorline = true       -- Highlight current line
      vim.opt.scrolloff = 10          -- Keep cursor centered
      
      -- Tabs and indentation
      vim.opt.tabstop = 2
      vim.opt.shiftwidth = 2
      vim.opt.expandtab = true
      vim.opt.smartindent = true
      
      -- Search highlighting
      vim.opt.hlsearch = true
      vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>', { desc = 'Clear search highlight' })
      
      -- Window navigation
      vim.keymap.set('n', '<C-h>', '<C-w>h', { desc = 'Move to left window' })
      vim.keymap.set('n', '<C-j>', '<C-w>j', { desc = 'Move to lower window' })
      vim.keymap.set('n', '<C-k>', '<C-w>k', { desc = 'Move to upper window' })
      vim.keymap.set('n', '<C-l>', '<C-w>l', { desc = 'Move to right window' })
      
      -- Buffer navigation
      vim.keymap.set('n', '<leader>bn', ':bnext<CR>', { desc = 'Next buffer' })
      vim.keymap.set('n', '<leader>bp', ':bprevious<CR>', { desc = 'Previous buffer' })
      vim.keymap.set('n', '<leader>bd', ':bdelete<CR>', { desc = 'Delete buffer' })
      
      -- Quick save
      vim.keymap.set('n', '<leader>w', ':w<CR>', { desc = 'Save file' })
      vim.keymap.set('n', '<leader>q', ':q<CR>', { desc = 'Quit' })
    '';
  };
}
