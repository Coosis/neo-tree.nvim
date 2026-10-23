pcall(require, "luacov")

local u = require("tests.utils")
local git = require("neo-tree.git")
local utils = require("neo-tree.utils")
local command = require("neo-tree.command")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")
local events = require("neo-tree.events")
local uv = vim.uv or vim.loop

local function wait_for(fn)
  u.wait_for(fn, { timeout = 15000, interval = 20 })
end

local function repo()
  local root = assert(uv.fs_realpath(u.fs.create_temp_dir()))
  vim.fn.system({ "git", "-C", root, "init", "--quiet" })
  assert.equals(0, vim.v.shell_error)
  local file = root .. "/opened.txt"
  u.fs.write_file(file, { "hello" })
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  return root, file
end

describe("Asynchronous buffers Git status", function()
  local original_status = git.status
  local original_job = utils.job
  local original_async = git.status_async

  before_each(function()
    require("neo-tree").setup({
      filesystem = { use_libuv_file_watcher = false },
      buffers = { follow_current_file = { enabled = false } },
    })
    git.status = function()
      error("buffers source called synchronous git.status")
    end
  end)

  after_each(function()
    git.status = original_status
    utils.job = original_job
    git.status_async = original_async
    u.clear_environment()
  end)

  it("shows opened buffers before a stalled Git command completes", function()
    local root, file = repo()
    local pending
    utils.job = function(cmd, opts, callback)
      if vim.tbl_contains(cmd, "status") then
        pending = { cmd = cmd, opts = opts, callback = callback }
        return
      end
      return original_job(cmd, opts, callback)
    end
    command.execute({ source = "buffers", dir = root })
    local state = manager.get_state("buffers")
    assert.is_true(renderer.tree_is_visible(state))
    assert.is_not_nil(state.tree:get_node(file))
    wait_for(function()
      return pending ~= nil
    end)
    utils.job = original_job
    original_job(pending.cmd, pending.opts, pending.callback)
    wait_for(function()
      return git.worktrees[root]
        and git.worktrees[root].status
        and git.worktrees[root].status[file] ~= nil
    end)
    wait_for(function()
      return table
        .concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
        :find("", 1, true) ~= nil
    end)
  end)

  it("redraws cached Git state without starting another scan", function()
    local root, file = repo()
    local requests = 0
    git.status_async = function()
      requests = requests + 1
    end
    command.execute({ source = "buffers", dir = root })
    local state = manager.get_state("buffers")
    assert.is_not_nil(state.tree:get_node(file))
    -- Settle buffer-added events before checking the Git notification alone.
    vim.wait(300, function()
      return false
    end, 20)
    requests = 0
    events.fire_event(events.GIT_STATUS_CHANGED, { git_root = root })
    assert.equals(0, requests)
    assert.is_true(renderer.tree_is_visible(state))
  end)

  it("refreshes a hidden buffers model on a Git event", function()
    local root = repo()
    command.execute({ source = "buffers", dir = root })
    local state = manager.get_state("buffers")
    renderer.close(state)
    local requested
    git.status_async = function(path)
      requested = path
    end
    events.fire_event(events.GIT_EVENT)
    wait_for(function()
      return requested == root
    end)
    assert.is_false(renderer.tree_is_visible(state))
  end)

  it("does not scan Git when Git status is disabled", function()
    local root = repo()
    require("neo-tree").setup({ enable_git_status = false })
    git.status_async = function()
      error("Git should be disabled")
    end
    command.execute({ source = "buffers", dir = root })
    assert.is_true(renderer.tree_is_visible(manager.get_state("buffers")))
  end)
end)
