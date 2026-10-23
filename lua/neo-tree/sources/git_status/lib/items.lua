local renderer = require("neo-tree.ui.renderer")
local file_items = require("neo-tree.sources.common.file-items")
local log = require("neo-tree.log")
local git = require("neo-tree.git")

local M = {}

---Render the shared worktree snapshot without running Git.
---@param state neotree.State
M.show_git_status = function(state)
  local path = state.git_status_path or state.path
  local project_root = path
  local worktree = git.worktrees[project_root]
  if not worktree then
    project_root, worktree = git.find_existing_worktree(path)
  end
  local status_lookup = worktree and worktree.status
  local base = project_root
    and state.git_base_by_worktree
    and state.git_base_by_worktree[project_root]
  local status_lookup_over_base = worktree and base and worktree.status_diff[base]
  state.path = project_root or state.path or vim.fn.getcwd()
  local context = file_items.create_context()
  context.state = state
  -- Create root folder
  local root = file_items.create_item(context, state.path, "directory") --[[@as neotree.FileItem.Directory]]
  root.name = vim.fn.fnamemodify(root.path, ":~")
  root.loaded = true
  root.search_pattern = state.search_pattern
  context.folders[root.path] = root

  local status_lookups = {}
  if status_lookup then
    status_lookups[#status_lookups + 1] = status_lookup
  end
  if status_lookup_over_base then
    status_lookups[#status_lookups + 1] = status_lookup_over_base
  end
  for i, sl in ipairs(status_lookups) do
    for path, status in pairs(sl) do
      ---@type string
      local normalized_status
      if type(status) ~= "table" and status ~= "!" then
        local success, item = pcall(file_items.create_item, context, path)
        if not success then
          log.error("Error creating git_status item for " .. path .. ": " .. item)
        else
          if item.type == "unknown" then
            item.type = "file"
          end
          item.status = normalized_status
          item.extra = {
            git_status = status,
          }
        end
      end
    end
  end

  state.default_expanded_nodes = {}
  for id, _ in pairs(context.folders) do
    table.insert(state.default_expanded_nodes, id)
  end
  file_items.advanced_sort(root.children, state)
  renderer.show_nodes({ root }, state)
end

---Refresh the shared model, whether or not this source is visible.
---@param state neotree.State
M.refresh_git_status = function(state)
  local opts = vim.tbl_extend("force", require("neo-tree").config.git_status_async_options, {
    untracked_files = "all",
  })
  git.status_async(state.git_status_path or state.path, state.git_base_by_worktree, opts)
end

---Show cached results immediately, then refresh in the background.
---@param state neotree.State
M.get_git_status = function(state)
  state.path = state.path or vim.fn.getcwd()
  M.show_git_status(state)
  M.refresh_git_status(state)
end

return M
