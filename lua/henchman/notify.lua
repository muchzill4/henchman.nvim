return function(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "henchman" })
end
