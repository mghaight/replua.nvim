local ok, replua = pcall(require, "replua")
if not ok then
  return
end

replua.setup()
