local M = {}

function M.current()
  local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ":p"):gsub("/$", "")
  local project = vim.fn.fnamemodify(cwd, ":t")
  local id = vim.fn.sha256(cwd):sub(1, 8)

  return {
    id = id,
    cwd = cwd,
    project = project,
    title = "henchman:" .. project .. ":" .. id,
  }
end

return M
