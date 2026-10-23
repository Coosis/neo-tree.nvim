pcall(require, "luacov")

local u = require("tests.utils")
local verify = require("tests.utils.verify")

describe("Filesystem netrw hijack", function()
  after_each(function()
    u.clear_environment()
  end)

  it("does not interfere with netrw when disabled", function()
    require("neo-tree").setup({
      filesystem = {
        hijack_netrw_behavior = "disabled",
        window = {
          position = "left",
        },
      },
    })

    vim.cmd("edit .")

    assert(#vim.api.nvim_list_wins() == 1, "there should only be one window")

    verify.after(100, function()
      local name = vim.api.nvim_buf_get_name(0)
      return name ~= "neo-tree filesystem [1]"
    end, "the buffer should not be neo-tree")
  end)

  it("opens in sidebar when behavior is open_default", function()
    local file = "Makefile"
    vim.cmd("edit " .. file)

    require("neo-tree").setup({
      filesystem = {
        hijack_netrw_behavior = "open_default",
        window = {
          position = "left",
        },
      },
    })

    vim.cmd("edit .")

    verify.eventually(function()
      return #vim.api.nvim_list_wins() == 2
    end, "there should be two windows")

    verify.buf_name_endswith("neo-tree filesystem [1]")

    verify.eventually(function()
      local expected_buf_name = "Makefile"
      local buf_at_2 = vim.api.nvim_win_get_buf(vim.fn.win_getid(2))
      local name_at_2 = vim.api.nvim_buf_get_name(buf_at_2)
      if name_at_2:sub(-#expected_buf_name) == expected_buf_name then
        return true
      else
        return false
      end
    end, file .. " is not at window 2")
  end)

  it(
    "opens a directory in the current split without replacing it with the previous file",
    function()
      local dir = u.fs.create_temp_dir()
      u.fs.write_file(dir .. "/ready.txt", { "ready" })
      local file = vim.fn.tempname() .. ".txt"
      u.fs.write_file(file, { "previous file" })
      vim.cmd("edit " .. vim.fn.fnameescape(file))
      local previous = vim.api.nvim_get_current_buf()
      require("neo-tree").setup({
        enable_git_status = false,
        filesystem = { hijack_netrw_behavior = "open_current" },
      })
      require("neo-tree").ensure_config()
      local reentered_previous = false
      local autocmd = vim.api.nvim_create_autocmd("BufEnter", {
        callback = function(args)
          if args.buf == previous then
            reentered_previous = true
          end
        end,
      })
      vim.cmd("split " .. vim.fn.fnameescape(dir))
      local winid = vim.api.nvim_get_current_win()
      verify.eventually(function()
        return vim.api.nvim_win_is_valid(winid)
          and vim.bo[vim.api.nvim_win_get_buf(winid)].filetype == "neo-tree"
          and table
              .concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false), "\n")
              :find("ready.txt", 1, true)
            ~= nil
      end, "directory did not render in the target split")
      vim.api.nvim_del_autocmd(autocmd)
      assert.is_false(reentered_previous)
      assert.equals(2, #vim.api.nvim_tabpage_list_wins(0))
      assert.equals("previous file", vim.api.nvim_buf_get_lines(previous, 0, 1, false)[1])
    end
  )

  -- This test is flaky and usually fails in github actions but not always
  -- so I'm disabling it for now.
  -- TODO: fix this test
  --
  --it("opens in in splits when behavior is open_current", function()
  --  local file = "Makefile"
  --  vim.cmd("edit " .. file)

  --  require("neo-tree").setup({
  --    filesystem = {
  --      hijack_netrw_behavior = "open_current",
  --    },
  --  })

  --  assert(#vim.api.nvim_list_wins() == 1, "Test should start with one window")

  --  vim.cmd("split .")

  --  verify.eventually(200, function()
  --    if #vim.api.nvim_list_wins() ~= 2 then
  --      return false
  --    end
  --    return vim.bo[0].filetype == "neo-tree"
  --  end, "neotree is not in the second window")
  --end)
end)
