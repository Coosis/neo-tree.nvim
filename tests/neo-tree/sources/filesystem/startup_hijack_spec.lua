pcall(require, "luacov")

local u = require("tests.utils")
local uv = vim.uv or vim.loop
local repo_root = vim.fn.getcwd()

local function startup(async_directory_scan, position, enabled)
  local dir = assert(uv.fs_realpath(u.fs.create_temp_dir()))
  u.fs.write_file(dir .. "/ready.txt", { "ready" })
  local report = vim.fn.tempname()
  local init = vim.fn.tempname() .. ".lua"
  local code = string.format(
    [[
vim.cmd.source(%q)
local snapshots = {}
local function snapshot()
  return { ft = vim.bo.filetype, lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
    position = vim.b.neo_tree_position, wins = #vim.api.nvim_tabpage_list_wins(0) }
end
vim.api.nvim_create_autocmd("VimEnter", { callback = function() snapshots.enter = snapshot() end })
require("neo-tree.git").status = function() error("startup waited for synchronous Git") end
-- Arbitrarily slow Git must not hold up the initial directory listing.
require("neo-tree.git").status_async = function() end
require("neo-tree").setup({ filesystem = {
  hijack_netrw_behavior = %q, async_directory_scan = %q,
  window = { position = %q }, filtered_items = { hide_gitignored = false },
} })
vim.defer_fn(function()
  snapshots.later = snapshot()
  vim.fn.writefile({ vim.json.encode(snapshots) }, %q)
  vim.cmd("qa!")
end, 300)
]],
    repo_root .. "/tests/mininit.lua",
    type(enabled) == "string" and enabled or enabled == false and "disabled" or "open_current",
    async_directory_scan or "auto",
    position or "left",
    report
  )
  vim.fn.writefile(vim.split(code, "\n", { plain = true }), init)
  local output = vim.fn.system({ vim.v.progpath, "--headless", "--noplugin", "-u", init, dir })
  assert.equals(0, vim.v.shell_error, output)
  return vim.json.decode(table.concat(vim.fn.readfile(report), "\n"))
end

local function contains_file(snapshot)
  return table.concat(snapshot.lines, "\n"):find("ready.txt", 1, true) ~= nil
end

describe("Directory startup hijack", function()
  it("renders nvim <dir> before VimEnter with the default auto scan", function()
    local result = startup()
    assert.equals("neo-tree", result.enter.ft)
    assert.equals("current", result.enter.position)
    assert.equals(1, result.enter.wins)
    assert.is_true(contains_file(result.enter))
    assert.is_true(contains_file(result.later))
  end)

  it("renders a configured current-window tree before VimEnter", function()
    local result = startup("auto", "current")
    assert.is_true(contains_file(result.enter))
    assert.equals(1, result.enter.wins)
  end)

  it("renders a startup sidebar before VimEnter when requested", function()
    local result = startup("auto", "left", "open_default")
    assert.is_true(contains_file(result.enter))
    assert.equals("left", result.enter.position)
    assert.equals(2, result.enter.wins)
  end)

  it("honors an explicitly always-asynchronous directory scan", function()
    local result = startup("always")
    assert.is_false(contains_file(result.enter))
    assert.is_true(contains_file(result.later))
  end)

  it("does not take over the directory when netrw hijacking is disabled", function()
    local result = startup("auto", "left", false)
    assert.are_not.equals("neo-tree", result.enter.ft)
    assert.are_not.equals("neo-tree", result.later.ft)
  end)
end)
