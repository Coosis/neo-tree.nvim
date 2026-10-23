pcall(require, "luacov")

local u = require("tests.utils")
local command = require("neo-tree.command")
local manager = require("neo-tree.sources.manager")

local function open(source, position)
  command.execute({ source = source or "buffers", position = position or "left" })
  return manager.get_state(source or "buffers")
end

local function close(source, position)
  command.execute({ source = source or "buffers", position = position or "left", toggle = true })
end

describe("Sidebar width memory", function()
  local columns = vim.o.columns

  before_each(function()
    vim.o.columns = 180
    require("neo-tree").setup({
      enable_git_status = false,
      window = { width = 40 },
    })
  end)

  after_each(function()
    u.clear_environment()
    vim.o.columns = columns
  end)

  it("retains an immediate manual resize through repeated toggles", function()
    local state = open()
    vim.cmd("vertical resize 31")
    assert.equals(31, vim.api.nvim_win_get_width(state.winid))
    for _ = 1, 3 do
      close()
      state = open()
      assert.equals(31, vim.api.nvim_win_get_width(state.winid))
    end
  end)

  it("retains a manual resize when closed with :close", function()
    local state = open()
    vim.cmd("vertical resize 33")
    vim.cmd("close")
    state = open()
    assert.equals(33, vim.api.nvim_win_get_width(state.winid))
  end)

  it("shares sidebar width across sources", function()
    local state = open()
    vim.cmd("vertical resize 35")
    state = open("filesystem")
    assert.equals(35, vim.api.nvim_win_get_width(state.winid))
    close("filesystem")
    state = open("git_status")
    assert.equals(35, vim.api.nvim_win_get_width(state.winid))
    close("git_status")
    state = open()
    assert.equals(35, vim.api.nvim_win_get_width(state.winid))
  end)

  it("shares sidebar width across tabs in the same session", function()
    open()
    vim.cmd("vertical resize 37")
    close()
    vim.cmd("tabnew")
    local state = open()
    assert.equals(37, vim.api.nvim_win_get_width(state.winid))
    close()
    vim.cmd("tabclose")
  end)

  it("keeps independent widths for left and right sidebars", function()
    open()
    vim.cmd("vertical resize 29")
    close()
    open(nil, "right")
    vim.cmd("vertical resize 43")
    close(nil, "right")
    local state = open()
    assert.equals(29, vim.api.nvim_win_get_width(state.winid))
    close()
    state = open(nil, "right")
    assert.equals(43, vim.api.nvim_win_get_width(state.winid))
  end)

  it("does not replace sidebar width with a full-window or floating view", function()
    open()
    vim.cmd("vertical resize 27")
    close()
    open(nil, "current")
    close(nil, "current")
    open(nil, "float")
    close(nil, "float")
    local state = open()
    assert.equals(27, vim.api.nvim_win_get_width(state.winid))
  end)
end)
