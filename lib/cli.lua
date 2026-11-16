-- cli: shell helpers shared by the adpaint programs (adpaint, adview, ...).
local M = {}

-- True for the usual ways of asking for help.
function M.isHelp(a)
  return a == "help" or a == "-h" or a == "--help" or a == "-?"
end

-- Registers a completion function for the running program (if the shell
-- supports it). fn(shell, index, text, previous) as for shell.setCompletionFunction.
function M.registerCompletion(fn)
  if shell.setCompletionFunction then
    shell.setCompletionFunction(shell.getRunningProgram(), fn)
  end
end

-- Loads cc.shell.completion, or nil on very old CraftOS versions.
function M.completion()
  local ok, c = pcall(require, "cc.shell.completion")
  return ok and c or nil
end

-- Appends the items of `list` to `out` (for combining completion results).
-- Returns out.
function M.addChoices(out, list)
  for _, v in ipairs(list) do out[#out + 1] = v end
  return out
end

-- "<program> setup": makes the startup file run "<program> --register" at
-- boot, so the program's completion function is registered after reboots.
-- `mark` identifies the line (so it's only added once); `fallback` is the
-- file created in /startup/ when there is no startup file yet.
function M.setup(mark, fallback, extra)
  local line = ("shell.run(%q, \"--register\") %s"):format("/" .. shell.getRunningProgram(), mark)
  local target
  for _, f in ipairs({ "/startup.lua", "/startup" }) do
    if fs.exists(f) and not fs.isDir(f) then target = f; break end
  end
  if target then
    local content = M.readFile(target, "r") or ""
    if content:find(mark, 1, true) then print("Already set up in " .. target); return end
    local h = fs.open(target, "a")
    h.write((content:sub(-1) == "\n" or content == "") and line .. "\n" or "\n" .. line .. "\n")
    h.close()
  else
    target = fallback
    local h = fs.open(target, "w")
    h.write(line .. "\n")
    h.close()
  end
  print("Added completion to " .. target .. ".")
  if extra then print(extra) end
end

-- Whole file as a string (binary by default), or nil.
function M.readFile(path, mode)
  local f = fs.open(path, mode or "rb")
  if not f then return nil end
  local s = f.readAll() or ""
  f.close()
  return s
end

-- Returns a function to call often during long work: it yields every ~2s
-- (avoiding "too long without yielding"). Events that arrive meanwhile are
-- passed to onEvent(ev) (if given) instead of being lost; Ctrl+T raises
-- "Terminated".
function M.yielder(onEvent)
  local last = os.epoch("utc")
  return function()
    if os.epoch("utc") - last > 2000 then
      os.queueEvent("adpaint_yield")
      while true do
        local ev = { os.pullEventRaw() }
        if ev[1] == "adpaint_yield" then break
        elseif ev[1] == "terminate" then error("Terminated", 0)
        elseif onEvent then onEvent(ev) end
      end
      last = os.epoch("utc")
    end
  end
end

return M
