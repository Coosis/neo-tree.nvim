pcall(require, "luacov")

local u = require("tests.utils")
local git = require("neo-tree.git")
local utils = require("neo-tree.utils")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")
local command = require("neo-tree.command")
local uv = vim.uv or vim.loop

local function git_cmd(root, ...)
  vim.fn.system(vim.list_extend({ "git", "-C", root }, { ... }))
  assert.equals(0, vim.v.shell_error)
end

local function commit(root)
  git_cmd(root, "add", ".")
  git_cmd(
    root,
    "-c",
    "user.name=Neo-tree Test",
    "-c",
    "user.email=test@example.invalid",
    "-c",
    "core.hooksPath=",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-qm",
    "test"
  )
end

local function repo()
  local root = assert(uv.fs_realpath(u.fs.create_temp_dir()))
  git_cmd(root, "init", "--quiet")
  u.fs.create_dir(root .. "/new")
  u.fs.write_file(root .. "/new/one.txt", { "one" })
  u.fs.write_file(root .. "/new/two.txt", { "two" })
  return root
end

local function open(root, source)
  command.execute({ source = source or "git_status", action = "show", dir = root })
end

local function wait_for(fn)
  u.wait_for(fn, { timeout = 15000, interval = 20 })
end

describe("Asynchronous Git source", function()
  local original_status = git.status
  local original_job = utils.job

  before_each(function()
    require("neo-tree").setup({
      filesystem = { use_libuv_file_watcher = true },
      buffers = { before_render = function() end },
    })
    -- The source must never fall back to the blocking status implementation.
    git.status = function()
      error("synchronous git.status called")
    end
  end)

  after_each(function()
    git.status = original_status
    utils.job = original_job
    u.clear_environment()
  end)

  it("opens before Git completes, then shows every untracked file", function()
    local root = repo()
    local pending = {}
    utils.job = function(cmd, opts, callback)
      if vim.tbl_contains(cmd, "status") then
        pending[#pending + 1] = { cmd = cmd, opts = opts, callback = callback }
        return
      end
      return original_job(cmd, opts, callback)
    end
    open(root)
    local state = manager.get_state("git_status")
    assert.is_true(renderer.tree_is_visible(state))
    assert.is_not_nil(state.tree:get_node(root))
    wait_for(function()
      return #pending > 0
    end)
    assert.is_nil(state.tree:get_node(root .. "/new/one.txt"))
    utils.job = original_job
    original_job(pending[1].cmd, pending[1].opts, pending[1].callback)
    wait_for(function()
      return state.tree:get_node(root .. "/new/one.txt") ~= nil
        and state.tree:get_node(root .. "/new/two.txt") ~= nil
    end)
  end)

  it(
    "refreshes the hidden model after an external commit and shows cached results on switch",
    function()
      local root = repo()
      open(root)
      wait_for(function()
        return git.worktrees[root]
          and git.worktrees[root].status
          and git.worktrees[root].status[root .. "/new/one.txt"] ~= nil
      end)
      local state = manager.get_state("git_status")
      open(root, "buffers")
      assert.is_false(renderer.tree_is_visible(state))
      commit(root)
      wait_for(function()
        return git.worktrees[root].status[root .. "/new/one.txt"] == nil
      end)
      assert.is_false(renderer.tree_is_visible(state))

      -- Hold all new scans: switching must display the updated cache immediately.
      utils.job = function(cmd, ...)
        if vim.tbl_contains(cmd, "status") then
          return
        end
        return original_job(cmd, ...)
      end
      open(root)
      assert.is_true(renderer.tree_is_visible(state))
      assert.is_nil(state.tree:get_node(root .. "/new/one.txt"))
      assert.is_nil(state.tree:get_node(root .. "/new/two.txt"))
    end
  )

  it("does not collapse the Git source snapshot during a filesystem refresh", function()
    local root = repo()
    open(root)
    wait_for(function()
      return git.worktrees[root]
        and git.worktrees[root].status
        and git.worktrees[root].status[root .. "/new/two.txt"] ~= nil
    end)
    u.fs.write_file(root .. "/new/three.txt", { "three" })
    local finished = false
    git.status_async(root, {}, require("neo-tree").config.git_status_async_options, function()
      finished = true
    end)
    wait_for(function()
      return finished
    end)
    assert.is_not_nil(git.worktrees[root].status[root .. "/new/three.txt"])
    assert.is_not_nil(git.worktrees[root].status[root .. "/new/one.txt"])
  end)

  it("ignores an older scan that completes after a newer snapshot", function()
    require("neo-tree").setup({ filesystem = { use_libuv_file_watcher = false } })
    local root = repo()
    local held
    local intercepted = false
    utils.job = function(cmd, opts, callback)
      if not intercepted and vim.tbl_contains(cmd, "status") then
        intercepted = true
        return original_job(cmd, opts, function(...)
          local result = { ... }
          held = function()
            callback(unpack(result))
          end
        end)
      end
      return original_job(cmd, opts, callback)
    end
    open(root)
    wait_for(function()
      return held ~= nil
    end)
    u.fs.write_file(root .. "/new/three.txt", { "three" })
    require("neo-tree.sources.git_status").refresh()
    wait_for(function()
      return git.worktrees[root].status
        and git.worktrees[root].status[root .. "/new/three.txt"] ~= nil
    end)
    held()
    assert.is_not_nil(git.worktrees[root].status[root .. "/new/three.txt"])
  end)

  it("discovers a nested repository even when the parent snapshot is cached", function()
    require("neo-tree").setup({ filesystem = { use_libuv_file_watcher = false } })
    local outer = repo()
    local inner = outer .. "/inner"
    u.fs.create_dir(inner)
    git_cmd(inner, "init", "--quiet")
    u.fs.write_file(inner .. "/inside.txt", { "inside" })
    local ready = false
    git.status_async(outer, {}, { untracked_files = "all" }, function()
      ready = true
    end)
    wait_for(function()
      return ready
    end)
    open(inner)
    local state = manager.get_state("git_status")
    wait_for(function()
      return state.path == inner and state.tree:get_node(inner .. "/inside.txt") ~= nil
    end)
    assert.is_nil(state.tree:get_node(outer .. "/new/one.txt"))
  end)

  it("retains repository-wide cached membership when filesystem scans are scoped", function()
    local root = repo()
    require("neo-tree").setup({
      git_status_scope_to_path = true,
      filesystem = { use_libuv_file_watcher = false },
    })
    open(root .. "/new")
    wait_for(function()
      return git.worktrees[root]
        and git.worktrees[root].status
        and git.worktrees[root].status[root .. "/new/one.txt"] ~= nil
    end)
    u.fs.write_file(root .. "/outside.txt", { "outside" })
    local ready = false
    git.status_async(root .. "/new", {}, {}, function()
      ready = true
    end)
    wait_for(function()
      return ready
    end)
    assert.is_not_nil(git.worktrees[root].status[root .. "/outside.txt"])
  end)

  it("updates a watched model without ever opening a Git source window", function()
    local root = repo()
    local ready = false
    git.status_async(root, {}, {}, function()
      ready = true
    end)
    wait_for(function()
      return ready
    end)
    assert.is_not_nil(git.worktrees[root].status[root .. "/new"])
    commit(root)
    wait_for(function()
      return next(git.worktrees[root].status) == nil
    end)
  end)

  it("refreshes requested git bases when another source triggers the scan", function()
    require("neo-tree").setup({ filesystem = { use_libuv_file_watcher = false } })
    local root = repo()
    commit(root)
    u.fs.write_file(root .. "/new/one.txt", { "changed" })
    commit(root)
    command.execute({ source = "git_status", action = "show", dir = root, git_base = "HEAD~1" })
    local state = manager.get_state("git_status")
    wait_for(function()
      return state.tree:get_node(root .. "/new/one.txt") ~= nil
    end)
    u.fs.write_file(root .. "/new/three.txt", { "three" })
    commit(root)
    local ready = false
    -- A watcher/filesystem request has no base lookup of its own.
    git.status_async(root, nil, {}, function()
      ready = true
    end)
    wait_for(function()
      return ready
    end)
    assert.is_not_nil(git.worktrees[root].status_diff["HEAD~1"][root .. "/new/three.txt"])
    wait_for(function()
      return state.tree:get_node(root .. "/new/three.txt") ~= nil
    end)
    assert.is_nil(state.tree:get_node(root .. "/new/one.txt"))
  end)

  it("preserves individual untracked files when a synchronous consumer refreshes", function()
    require("neo-tree").setup({ filesystem = { use_libuv_file_watcher = false } })
    local root = repo()
    open(root)
    wait_for(function()
      return git.worktrees[root]
        and git.worktrees[root].status
        and git.worktrees[root].status[root .. "/new/one.txt"] ~= nil
    end)
    u.fs.write_file(root .. "/new/three.txt", { "three" })
    original_status(root)
    assert.is_not_nil(git.worktrees[root].status[root .. "/new/one.txt"])
    assert.is_not_nil(git.worktrees[root].status[root .. "/new/three.txt"])
  end)
end)
