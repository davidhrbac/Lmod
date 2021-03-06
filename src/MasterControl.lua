require("strict")

--------------------------------------------------------------------------
-- Lmod License
--------------------------------------------------------------------------
--
--  Lmod is licensed under the terms of the MIT license reproduced below.
--  This means that Lmod is free software and can be used for both academic
--  and commercial purposes at absolutely no cost.
--
--  ----------------------------------------------------------------------
--
--  Copyright (C) 2008-2017 Robert McLay
--
--  Permission is hereby granted, free of charge, to any person obtaining
--  a copy of this software and associated documentation files (the
--  "Software"), to deal in the Software without restriction, including
--  without limitation the rights to use, copy, modify, merge, publish,
--  distribute, sublicense, and/or sell copies of the Software, and to
--  permit persons to whom the Software is furnished to do so, subject
--  to the following conditions:
--
--  The above copyright notice and this permission notice shall be
--  included in all copies or substantial portions of the Software.
--
--  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
--  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
--  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
--  NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
--  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
--  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
--  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
--  THE SOFTWARE.
--
--------------------------------------------------------------------------

require("inherits")
require("myGlobals")
require("colorize")
require("string_utils")
require("utils")

Master             = require("Master")

local BeautifulTbl = require("BeautifulTbl")
local FrameStk     = require("FrameStk")
local M            = {}
local MName        = require("MName")
local Var          = require("Var")
local dbg          = require("Dbg"):dbg()
local base64       = require("base64")
local concatTbl    = table.concat
local cosmic       = require("Cosmic"):singleton()
local decode64     = base64.decode64
local encode64     = base64.encode64
local getenv       = os.getenv
local hook         = require("Hook")
local i18n         = require("i18n")
local pack         = (_VERSION == "Lua 5.1") and argsPack or table.pack
local remove       = table.remove
local s_adminT     = {}
local s_loadT      = {}
local s_moduleStk  = {}


function M.name(self)
   return self.my_name
end

--------------------------------------------------------------------------
-- Return the sType.
-- @param self A MasterControl object
function M.MNameType(self)
   return self.my_sType
end

--------------------------------------------------------------------------
-- Return the tcl_mode.
-- @param self A MasterControl object
function M.tcl_mode(self)
   return self.my_tcl_mode
end

--------------------------------------------------------------------------
-- Convert MC name to MC Object.
-- @param nameTbl Name to MC object table.
-- @param name    Name of an MC objects.
local function valid_name(nameTbl, name)
   return nameTbl[name] or nameTbl.default
end

--------------------------------------------------------------------------
-- Set the type (or mode) of the current MasterControl object.
-- @param self A MasterControl object
function M._setMode(self, mode)
   dbg.start{"MasterControl:_setMode(\"",mode,"\")"}
   self._mode = mode
   dbg.fini("MasterControl:_setMode")
end

--------------------------------------------------------------------------
-- The Factory builder for the MasterControl Class.
-- @param name the name of the derived object.
-- @param[opt] mode An optional mode for building the *access* object.
-- @return A derived MasterControl Object.
local s_nameTbl          = false
function M.build(name,mode)

   if (not s_nameTbl) then
      local MCLoad        = require('MC_Load')
      local MCUnload      = require('MC_Unload')
      local MCMgrLoad     = require('MC_MgrLoad')
      local MCRefresh     = require('MC_Refresh')
      local MCShow        = require('MC_Show')
      local MCAccess      = require('MC_Access')
      local MCSpider      = require('MC_Spider')
      local MCComputeHash = require('MC_ComputeHash')

      s_nameTbl = {
         ["load"]         = MCLoad,        -- Normal loading of modules
         ["mgrload"]      = MCMgrLoad,     -- for collections (loads in modules are ignored)
         ["unload"]       = MCUnload,      -- Unload modules
         ["refresh"]      = MCRefresh,     -- for subshells, sets the aliases again
         ["computeHash"]  = MCComputeHash, -- Generate a hash value for the contents of the module
         ["refresh"]      = MCRefresh,     -- for subshells, sets the aliases again
         ["show"]         = MCShow,        -- show the module function instead.
         ["access"]       = MCAccess,      -- for whatis, help
         ["spider"]       = MCSpider,      -- Process module files for spider operations
      }
   end

   local o                = valid_name(s_nameTbl, name):create()
   o:_setMode(mode or name)

   dbg.print{"Setting mcp to ", o:name(),"\n"}
   return o
end

-------------------------------------------------------------------
-- Setenv / Unsetenv Functions
-------------------------------------------------------------------

--------------------------------------------------------------------------
-- Set an environment variable.
-- @param self A MasterControl object.
-- @param name the environment variable name.
-- @param value the environment variable value.
-- @param respect If true, then respect the old value.
function M.setenv(self, name, value, respect)
   name = name:trim()
   dbg.start{"MasterControl:setenv(\"",name,"\", \"",value,"\", \"",
              respect,"\")"}

   if (value == nil) then
      LmodError{msg="e111", func = "setenv", name = name}
   end

   if (respect and getenv(name)) then
      dbg.print{"Respecting old value"}
      dbg.fini("MasterControl:setenv")
      return
   end

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()
   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:set(tostring(value))
   dbg.fini("MasterControl:setenv")
end


--------------------------------------------------------------------------
-- Unset an environment variable.
-- @param self A MasterControl object.
-- @param name the environment variable name.
-- @param value the environment variable value.
-- @param respect If true, then respect the old value.
function M.unsetenv(self, name, value, respect)
   name = name:trim()
   dbg.start{"MasterControl:unsetenv(\"",name,"\", \"",value,"\")"}

   if (respect and getenv(name) ~= value) then
      dbg.print{"Respecting old value"}
      dbg.fini("MasterControl:unsetenv")
      return
   end

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()
   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:unset()
   dbg.fini("MasterControl:unsetenv")
end

-------------------------------------------------------------------
-- stack: push and pop
-------------------------------------------------------------------

--------------------------------------------------------------------------
-- Set an environment variable and remember previous values in a stack.
-- @param self A MasterControl object.
-- @param name the environment variable name.
-- @param value the environment variable value.
function M.pushenv(self, name, value)
   name = name:trim()
   dbg.start{"MasterControl:pushenv(\"",name,"\", \"",value,"\")"}

   ----------------------------------------------------------------
   -- If name exists in the env and the stack version of the name
   -- doesn't exist then use the name's value as the initial value
   -- for "stackName".

   if (value == nil) then
      LmodError{msg="e111",func = "pushenv", name = name}
   end

   local stackName = "__LMOD_STACK_" .. name
   local v64       = nil
   local v         = getenv(name)
   if (getenv(stackName) == nil and v) then
      v64          = encode64(v)
   end

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   if (varT[stackName] == nil) then
      varT[stackName] = Var:new(stackName, v64, ":")
   end


   v   = tostring(value)
   v64 = encode64(value)
   local nodups  = false
   local priority = 0

   varT[stackName]:prepend(v64, nodups, priority)

   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:set(v)

   dbg.fini("MasterControl:pushenv")
end

--------------------------------------------------------------------------
-- The reverse action of pushenv.  It pops the old value off of the stack
-- and set the *name* to the previous value from the stack.
-- @param self A MasterControl object.
-- @param name the environment variable name.
-- @param value the environment variable value.
function M.popenv(self, name, value)
   name = name:trim()
   dbg.start{"MasterControl:popenv(\"",name,"\", \"",value,"\")"}

   local stackName = "__LMOD_STACK_" .. name
   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   if (varT[stackName] == nil) then
      varT[stackName] = Var:new(stackName)
   end

   dbg.print{"stackName: ", stackName, " pop()\n"}

   local v64 = varT[stackName]:pop()
   local v   = nil
   if (v64) then
      v = decode64(v64)
   end
   dbg.print{"v: ", v,"\n"}

   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end

   varT[name]:set(v)

   dbg.fini("MasterControl:popenv")
end

-------------------------------------------------------------------
-- Path Modification Functions
-------------------------------------------------------------------


-------------------------------------------------------------------
-- Prepend to a path like variable.
-- @param self A MasterControl object
-- @param t A table containing { name, value, nodups=v1, priority=v2}
function M.prepend_path(self, t)
   dbg.start{"MasterControl:prepend_path(t)"}
   local sep      = t.delim or ":"
   local name     = t[1]
   local value    = t[2]
   local nodups   = not allow_dups( not t.nodups)
   local priority = (-1)*(t.priority or 0)

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()


   dbg.print{"name:\"",name,"\", value: \"",value,
             "\", delim=\"",sep,"\", nodups=\"",nodups,
             "\", priority=",priority,"\n"}

   if (varT[name] == nil) then
      varT[name] = Var:new(name, nil, sep)
   end

   -- Do not allow dups on MODULEPATH like env vars.
   nodups = (name == ModulePath) or nodups

   varT[name]:prepend(tostring(value), nodups, priority)
   dbg.fini("MasterControl:prepend_path")
end

--------------------------------------------------------------------------
-- Append to a path like variable.
-- @param self A MasterControl object
-- @param t A table containing { name, value, nodups=v1, priority=v2}
function M.append_path(self, t)
   local sep      = t.delim or ":"
   local name     = t[1]
   local value    = t[2]
   local nodups   = t.nodups
   local priority = t.priority or 0
   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   dbg.start{"MasterControl:append_path{\"",name,"\", \"",value,
             "\", delim=\"",sep,"\", nodups=\"",nodups,
             "\", priority=",priority,
             "}"}

   if (varT[name] == nil) then
      varT[name] = Var:new(name, nil, sep)
   end

   -- Do not allow dups on MODULEPATH like env vars.
   nodups = name == ModulePath or nodups

   varT[name]:append(tostring(value), nodups, priority)
   dbg.fini("MasterControl:append_path")
end

--------------------------------------------------------------------------
-- Remove an entry from a path like variable.
-- @param self A MasterControl object
-- @param t A table containing { name, value, nodups=v1, priority=v2, where=v3}
function M.remove_path(self, t)
   local sep      = t.delim or ":"
   local name     = t[1]
   local value    = t[2]
   local nodups   = t.nodups
   local priority = t.priority or 0
   local where    = t.where
   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   dbg.start{"MasterControl:remove_path{\"",name,"\", \"",value,
             "\", delim=\"",sep,"\", nodups=\"",nodups,
             "\", priority=",priority,
             ", where=",where,
             "}"}

   -- Do not allow dups on MODULEPATH like env vars.
   nodups = name == ModulePath or nodups

   if (varT[name] == nil) then
      varT[name] = Var:new(name,nil, sep)
   end
   varT[name]:remove(tostring(value), where, priority, nodups)
   dbg.fini("MasterControl:remove_path")
end

--------------------------------------------------------------------------
-- Remove an entry from a path-like variable.  This version is the reverse
-- of a prepend_path.
-- @param self A MasterControl object
-- @param t A table containing { name, value, nodups=v1, priority=v2}
function M.remove_path_first(self, t)
   t.where = "first"
   M.remove_path(self, t)
end

-- Remove an entry from a path-like variable.  This version is the reverse
-- of a append_path.
-- @param self A MasterControl object
-- @param t A table containing { name, value, nodups=v1, priority=v2}
function M.remove_path_last(self, t)
   t.where = "last"
   M.remove_path(self, t)
end



--------------------------------------------------------------------------
-- Set a shell alias.  This function can handle a single value for both
-- bash and C-shell.
-- @param self A MasterControl Object.
-- @param name the environment variable name.
-- @param value the environment variable value.
function M.set_alias(self, name, value)
   name = name:trim()
   dbg.start{"MasterControl:set_alias(\"",name,"\", \"",value,"\")"}

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:setAlias(value)
   dbg.fini("MasterControl:set_alias")
end

--------------------------------------------------------------------------
-- Unset a shell alias.
-- @param self A MasterControl Object.
-- @param name the environment variable name.
-- @param value the environment variable value.
function M.unset_alias(self, name, value)
   name = name:trim()
   dbg.start{"MasterControl:unset_alias(\"",name,"\", \"",value,"\")"}

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:unsetAlias()
   dbg.fini("MasterControl:unset_alias")
end


--------------------------------------------------------------------------
-- Set a shell function for bash and a csh alias.
-- @param self A MasterControl Object.
-- @param name the environment variable name.
-- @param value the environment variable value.
function M.set_shell_function(self, name, bash_function, csh_function)
   name = name:trim()
   dbg.start{"MasterControl:set_shell_function(\"",name,"\", \"",bash_function,"\"",
             "\", \"",csh_function,"\""}


   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:setShellFunction(bash_function, csh_function)
   dbg.fini("MasterControl:set_shell_function")
end

--------------------------------------------------------------------------
-- Unset a shell function for bash and a csh alias.
-- @param self A MasterControl Object.
-- @param name the environment variable name.
-- @param value the environment variable value.
function M.unset_shell_function(self, name, bash_function, csh_function)
   name = name:trim()
   dbg.start{"MasterControl:unset_shell_function(\"",name,"\", \"",bash_function,"\"",
             "\", \"",csh_function,"\""}

   local frameStk = FrameStk:singleton()
   local varT     = frameStk:varT()

   if (varT[name] == nil) then
      varT[name] = Var:new(name)
   end
   varT[name]:unsetShellFunction()
   dbg.fini("MasterControl:unset_shell_function")
end


--------------------------------------------------------------------------
-- Return the type (or mode) of the current MasterControl object.
-- @param self A MasterControl object
function M.mode(self)
   return self._mode
end

--------------------------------------------------------------------------
-- Place a string that will be executed when the output from Lmod eval'ed.
-- @param self A MasterControl object
-- @param t A table containing A mode array and a command.
function M.execute(self, t)
   dbg.start{"MasterControl:execute(t)"}
   local a      = t.modeA or {}
   local myMode = self:mode()
   local Exec   = require("Exec")

   for i = 1,#a do
      if (myMode == a[i] or a[i]:lower() == "all" ) then
         local exec   = Exec:exec()
         exec:register(t.cmd)
         break
      end
   end
   dbg.fini("MasterControl:execute")
end

--------------------------------------------------------------------------
-- Return the user's shell
-- @param self A MasterControl object
function M.myShellName(self)
   return Shell and Shell:name() or "bash"
end

--------------------------------------------------------------------------
-- Return the current file name.
-- @param self A MasterControl object
function M.myFileName(self)
   local frameStk = FrameStk:singleton()
   return frameStk:fn()
end

--------------------------------------------------------------------------
-- Return the full name of the current module.  Typically name/version.
-- @param self A MasterControl object.
function M.myModuleFullName(self)
   local frameStk = FrameStk:singleton()
   return frameStk:fullName()
end

--------------------------------------------------------------------------
-- Return the user name of the current module.  This is the name the user
-- specified.  It could a full name (name/version) or just the name.
-- @param self A MasterControl object.
function M.myModuleUsrName(self)
   local frameStk = FrameStk:singleton()
   return frameStk:userName()
end

--------------------------------------------------------------------------
-- Return the name of the modules.  That is the name of the module w/o a
-- version.
-- @param self A MasterControl object
function M.myModuleName(self)
   local frameStk = FrameStk:singleton()
   return frameStk:sn()
end

--------------------------------------------------------------------------
-- Return the version if any.  If there is no version, for example a meta
-- module then the version is "".
-- @param self A MasterControl object
function M.myModuleVersion(self)
   local frameStk = FrameStk:singleton()
   return frameStk:version()
end

local function l_generateMsg(kind, label, ...)
   local sA     = {}
   local twidth = TermWidth()
   local arg    = pack(...)
   if (arg.n == 1 and type(arg[1]) == "table") then
      local t   = arg[1]
      local key = t.msg
      local msg = i18n(key, t)
      msg       = hook.apply("errWarnMsgHook", kind, key, msg) or msg
      sA[#sA+1] = buildMsg(twidth, label, msg)
   else
      sA[#sA+1] = buildMsg(twidth, label, ...)
   end
   return sA
end

--------------------------------------------------------------------------
-- Print msgs to stderr.
-- @param self A MasterControl object.
function M.message(self, ...)
   if (quiet()) then
      return
   end
   local sA     = {}
   local twidth = TermWidth()
   local arg    = pack(...)
   if (arg.n == 1 and type(arg[1]) == "table") then
      local t   = arg[1]
      local key = t.msg
      local msg = i18n(key, t)
      msg       = hook.apply("errWarnMsgHook", "lmodmessage", key, msg) or msg
      sA[#sA+1] = buildMsg(twidth, msg)
   else
      sA[#sA+1] = buildMsg(twidth, ...)
   end
   io.stderr:write(concatTbl(sA,""),"\n")
end

--------------------------------------------------------------------------
-- Print msgs, traceback then set warning flag.
-- @param self A MasterControl object.
function M.warning(self, ...)
   if (not quiet() and  haveWarnings()) then
      local label = colorize("red", i18n("warnTitle",{}))
      local sA    = l_generateMsg("lmodwarning", label, ...)
      sA[#sA+1]   = "\n"
      sA[#sA+1]   = moduleStackTraceBack()
      sA[#sA+1]   = "\n"
      io.stderr:write(concatTbl(sA,""),"\n")
      setWarningFlag()
   end
end

--------------------------------------------------------------------------
-- Print msgs, traceback then exit.
-- @param self A MasterControl object.
function M.error(self, ...)
   local label = colorize("red", i18n("errTitle", {}))
   local sA    = l_generateMsg("lmoderror", label, ...)
   sA[#sA+1]   = "\n"

   local a = concatTbl(stackTraceBackA,"")
   if (a:len() > 0) then
       sA[#sA+1] = a
       sA[#sA+1] = "\n"
   end
   sA[#sA+1]     = moduleStackTraceBack()
   sA[#sA+1]     = "\n"

   io.stderr:write(concatTbl(sA,""),"\n")
   LmodErrorExit()
end

--------------------------------------------------------------------------
-- The quiet function.
-- @param self A MasterControl object
function M.quiet(self, ...)
   -- very Quiet !!!
end

--------------------------------------------------------------------------
-- Remember the user's requested load array into an internal table.
-- This is tricky because the module mnames in the *mA* array may not be
-- findable yet (e.g. module load mpich petsc).  The only thing we know
-- is the usrName from the command line.  So we use the *usrName* to be
-- the key and not *sn*.
-- @param mA The array of MName objects.
local function registerUserLoads(mA)
   dbg.start{"registerUserLoads(mA)"}
   for i = 1, #mA do
      local mname       = mA[i]
      local userName    = mname:userName()
      s_loadT[userName] = mname
      dbg.print{"userName: ",userName,"\n"}
   end
   dbg.fini("registerUserLoads")
end

local function compareRequestedLoadsWithActual()
   dbg.start{"compareRequestedLoadsWithActual()"}
   local mt = FrameStk:singleton():mt()

   local aa = {}
   local bb = {}
   for userName, mname in pairs(s_loadT) do
      local sn = mname:sn()
      if (not mt:have(sn, "active")) then
         aa[#aa+1] = mname:show()
         bb[#bb+1] = userName
      end
   end
   dbg.fini("compareRequestedLoadsWithActual")
   return aa, bb
end

function M.mustLoad(self)
   dbg.start{"MasterControl:mustLoad()"}
   local aa, bb = compareRequestedLoadsWithActual()

   if (#aa > 0) then
      local luaprog = "@path_to_lua@/lua"
      if (luaprog:sub(1,1) == "@") then
         luaprog = find_exec_path("lua")
         if (luaprog == nil) then
            LmodError{msg="e107", name = "lua"}
         end
      end
      local cmdA = {}
      cmdA[#cmdA+1] = luaprog
      cmdA[#cmdA+1] = pathJoin(cmdDir(),cmdName())
      cmdA[#cmdA+1] = "bash"
      cmdA[#cmdA+1] = dbg.active() and "-D" or " "
      cmdA[#cmdA+1] = "-r --no_redirect --spider_timeout 2.0 spider"
      local count   = #cmdA

      local uA = {}  -- unknown names
      local kA = {}  -- known modules (show)
      local kB = {}  -- known modules (usrName)


      if (expert()) then
         uA = aa
      else
         local outputDirection = dbg.active() and "2> spider.log" or "2> /dev/null"
         for i = 1, #bb do
            cmdA[count+1] = "'^" .. bb[i]:escape() .. "$'"
            cmdA[count+2] = outputDirection
            local cmd     = concatTbl(cmdA," ")
            local result  = capture(cmd)
            dbg.print{"result: ",result,"\n"}
            if (result:find("\nfalse")) then
               uA[#uA+1] = aa[i]
            else
               kA[#kA+1] = aa[i]
               kB[#kB+1] = bb[i]
            end
         end
      end

      local a = {}

      if (#uA > 0) then
         mcp:report{msg="e127", module_list = concatTbl(uA, " ") }
      end

      if (#kA > 0) then
         mcp:report{msg="e128", kA = concatTbl(kA, ", "), kB = concatTbl(kB, " ")}
      end
   end
   dbg.fini("MasterControl:mustLoad")
end


-------------------------------------------------------------------
-- Load a list of modules.  Check to see if the user requested
-- modules were actually loaded.
-- @param self A MasterControl object
-- @param mA A array of MName objects.
-- @return An array of statuses
function M.load_usr(self, mA)
   registerUserLoads(mA)
   local a = self:load(mA)
   return a
end


--------------------------------------------------------------------------
-- Build a list of user names based on mA.
-- @param mA List of MName objects
function mAList(mA)
   local a = {}
   for i = 1, #mA do
      a[#a + 1] = mA[i]:userName()
   end
   return concatTbl(a, ", ")
end

function M.load(self, mA)
   local master = Master:singleton()
   if (dbg.active()) then
      local s = mAList(mA)
      dbg.start{"MasterControl:load(mA={"..s.."})"}
   end

   local a = master:load(mA)

   if (not quiet()) then
      self:registerAdminMsg(mA)
   end

   dbg.fini("MasterControl:load")
   return a
end

-------------------------------------------------------------------
-- Load a list of module but ignore any warnings.
-- @param self A MasterControl object
-- @param mA A array of MName objects.
function M.try_load(self, mA)
   dbg.start{"MasterControl:try_load(mA)"}
   deactivateWarning()
   self:load(mA)
   dbg.fini("MasterControl:try_load")
end

-------------------------------------------------------------------
-- Unload a list modules.
-- @param self A MasterControl object
-- @param mA A array of MName objects.
-- @return an array of statuses
function M.unload(self, mA)
   local master = Master:singleton()

   if (dbg.active()) then
      local s = mAList(mA)
      dbg.start{"MasterControl:unload(mA={"..s.."})"}
   end

   local aa     = master:unload(mA)
   dbg.fini("MasterControl:unload")
   return aa
end

-------------------------------------------------------------------
-- Unload a user requested list of modules.
-- @param self A MasterControl object
-- @param mA A array of MName objects.
-- @param force if true then do not reload sticky modules.
-- @return an array of statuses.
function M.unload_usr(self, mA, force)
   dbg.start{"MasterControl:unload_usr(mA)"}

   self:unload(mA)
   local master = Master:singleton()
   local aa = master:reload_sticky(force)
   dbg.fini("MasterControl:unload_usr")
   return aa
end


-------------------------------------------------------------------
-- This load is used by Manager Load to ignore load inside a
-- module.
-- @param self A MasterControl object
-- @param mA A array of MName objects.
function M.fake_load(self,mA)
   if (dbg.active()) then
      local s = mAList(mA)
      dbg.start{"MasterControl:fake_load(mA={"..s.."})"}
      dbg.fini("MasterControl:fake_load")
   end
end

-------------------------------------------------------------------
-- Unload a list modules.
-- @param self A MasterControl object
-- @param mA A array of MName objects.
-- @return an array of statuses
function M.unload(self, mA)
   local master = Master:singleton()

   if (dbg.active()) then
      local s = mAList(mA)
      dbg.start{"MasterControl:unload(mA={"..s.."})"}
   end

   local aa     = master:unload(mA)
   dbg.fini("MasterControl:unload")
   return aa
end

--------------------------------------------------------------------------
-- Check the conflicts from *mA*.
-- @param self A MasterControl object.
-- @param mA An array of MNname objects.
function M.conflict(self, mA)
   dbg.start{"MasterControl:conflict(mA)"}


   local frameStk  = FrameStk:singleton()
   local mt        = frameStk:mt()
   local fullName  = frameStk:fullName()
   local masterTbl = masterTbl()

   if (masterTbl.checkSyntax) then
      dbg.print{"Ignoring conflicts when syntax checking\n"}
      dbg.fini("MasterControl:conflict")
      return
   end

   local a = {}
   for i = 1, #mA do
      local mname = mA[i]
      local sn    = mname:sn()
      if (mt:have(sn,"active")) then
         a[#a+1]  = mname:userName()
      end
   end

   if (#a > 0) then
      LmodError{msg="e112", name = fullName, module_list = concatTbl(a," ")}
   end
   dbg.fini("MasterControl:conflict")
end

--------------------------------------------------------------------------
-- Check the prereq from *mA*.
-- @param self A MasterControl object.
-- @param mA An array of MNname objects.
function M.prereq(self, mA)
   local frameStk  = FrameStk:singleton()
   local fullName  = frameStk:fullName()
   local masterTbl = masterTbl()

   dbg.start{"MasterControl:prereq(mA)"}

   if (masterTbl.checkSyntax) then
      dbg.print{"Ignoring prereq when syntax checking\n"}
      dbg.fini("MasterControl:prereq")
      return
   end

   local a = {}
   for i = 1, #mA do
      local v = mA[i]:prereq()
      if (v) then
         a[#a+1] = v
      end
   end

   dbg.print{"number found: ",#a,"\n"}
   if (#a > 0) then
      LmodError{msg="e113", name = fullName, module_list = concatTbl(a," ")}
   end
   dbg.fini("MasterControl:prereq")
end

--------------------------------------------------------------------------
-- Check the prereq from *mA*.  If any of them are acceptable then return.
-- otherwise error out.
-- @param self A MasterControl object.
-- @param mA An array of MNname objects.
function M.prereq_any(self, mA)
   dbg.start{"MasterControl:prereq_any(mA)"}
   local frameStk  = FrameStk:singleton()
   local fullName  = frameStk:fullName()
   local masterTbl = masterTbl()

   if (masterTbl.checkSyntax) then
      dbg.print{"Ignoring prereq_any when syntax checking\n"}
      dbg.fini("MasterControl:prereq_any")
      return
   end

   local found  = false
   local a      = {}
   for i = 1, #mA do
      local v, msg = mA[i]:prereq()
      if (not v) then
         found = true
         break
      end
      if (msg) then
         a[#a+1] = msg .."(\"" .. v .. "\")"
      else
         a[#a+1] = v
      end
   end

   if (not found) then
      LmodError{msg="e114", name = fullName, module_list = concatTbl(a," ")}
   end
   dbg.fini("MasterControl:prereq_any")
end

------------------------------------------------------------------------
-- Save away the modules that are in the same family.
-- @param oldName The old module name that is getting pushed out by *sn*.
-- @param sn The new module name.
function M.familyStackPush(oldName, sn)
   dbg.start{"familyStackPush(",oldName,", ", sn,")"}
   local mt             = FrameStk:singleton():mt()
   local old_userName   = mt:userName(oldName)
   dbg.print{"removing old sn: ",oldName,",old userName: ",old_userName,"\n"}

   if (old_userName) then
      s_loadT[old_userName] = nil
   end
   s_moduleStk[#s_moduleStk+1] = { sn=oldName, fullName = mt:fullName(oldName),
                                   userName = mt:userName(oldName)}
   s_moduleStk[#s_moduleStk+1] = { sn=sn,      fullName = mt:fullName(sn),
                                   userName = mt:userName(sn)}
   dbg.fini("familyStackPush")
end

function M.familyStackTop()
   local valueN = s_moduleStk[#s_moduleStk]
   local valueO = s_moduleStk[#s_moduleStk-1]
   return valueO, valueN
end   


--------------------------------------------------------------------------
-- Pop the top two value off the stack.
-- @return the top two value on the stack.
function M.familyStackPop()
   local valueN = s_moduleStk[#s_moduleStk]
   remove(s_moduleStk)
   local valueO = s_moduleStk[#s_moduleStk]
   remove(s_moduleStk)
   return valueO, valueN
end

--------------------------------------------------------------------------
-- Check for an empty stack.
-- @return True if the stack is empty.
function M.familyStackEmpty()
   return (next(s_moduleStk) == nil)
end

--------------------------------------------------------------------------
-- Process the family function.  The name of the module is found by the
-- *ModuleStack*.
-- @param self A MasterControl object
-- @param name The name of the family
function M.family(self, name)
   local frameStk  = FrameStk:singleton()
   local mt        = frameStk:mt()
   local fullName  = frameStk:fullName()
   local mname     = MName:new("mt",fullName)
   local sn        = mname:sn()
   local masterTbl = masterTbl()
   local auto_swap = cosmic:value("LMOD_AUTO_SWAP")

   dbg.start{"MasterControl:family(",name,")"}
   if (masterTbl.checkSyntax) then
      dbg.print{"Ignoring family when syntax checking\n"}
      dbg.fini()
      return
   end

   local oldName = mt:getfamily(name)
   if (oldName ~= nil and oldName ~= sn and not expert() ) then
      if (auto_swap ~= "no") then
         self.familyStackPush(oldName, sn)
      else
         LmodError{msg="e115", name = name, oldName = oldName, fullName = fullName}
      end
   end
   mt:setfamily(name,sn)
   dbg.fini("MasterControl:family")
end

--------------------------------------------------------------------------
-- Unset the family name.
-- @param self A MasterControl object
-- @param name A family name.
function M.unset_family(self, name)
   dbg.start{"MasterControl:unset_family(",name,")"}
   local mt = FrameStk:singleton():mt()
   mt:unsetfamily(name)
   dbg.fini("MasterControl:unset_family")
end

function M.registerAdminMsg(self, mA)
   local mt      = FrameStk:singleton():mt()
   local t       = s_adminT
   readAdmin()
   for i = 1, #mA do
      local mname      = mA[i]
      local sn         = mname:sn()
      if (mt:have(sn,"active")) then
         local fn       = mt:fn(sn)
         local fullName = mt:fullName(sn)
         local message
         local key
         if (adminT[fn]) then
            message = adminT[fn]
            key     = fn
         elseif (adminT[fullName]) then
            message = adminT[fullName]
            key     = fullName
         end

         if (message) then
            t[key] = message
         end
      end
   end
end

-------------------------------------------------------------------
-- Output any admin message collected from loading.
function M.reportAdminMsgs()
   local t = s_adminT
   if (next(t) ) then
      local term_width  = TermWidth()
      local bt
      local a       = {}
      local border  = colorize("red",string.rep("-", term_width-1))
      io.stderr:write("\n",border,"\n",
                      "There are messages associated with the following module(s):\n",
                      border,"\n")
      for k, v in pairsByKeys(t) do
         io.stderr:write("\n",k,":\n")
         a[1] = { " ", v}
         bt = BeautifulTbl:new{tbl=a, wrapped=true, column=term_width-1}
         io.stderr:write(bt:build_tbl(), "\n")
      end
      io.stderr:write(border,"\n\n")
   end
end


--------------------------------------------------------------------------
-- Set a property value
-- @param self A MasterControl Object.
-- @param name A property name
-- @param value A property value.
function M.add_property(self, name, value)
   local frameStk  = FrameStk:singleton()
   local sn        = frameStk:sn()
   local mt        = frameStk:mt()
   mt:add_property(sn, name:trim(), value)
end
   

--------------------------------------------------------------------------
-- Unset a property value
-- @param self A MasterControl Object.
-- @param name A property name
-- @param value A property value.
function M.remove_property(self, name, value)
   local frameStk  = FrameStk:singleton()
   local sn        = frameStk:sn()
   local mt        = frameStk:mt()
   mt:remove_property(sn, name:trim(), value)
end

--------------------------------------------------------------------------
-- Return the tcl_mode.
-- @param self A MasterControl object
function M.tcl_mode(self)
   return self.my_tcl_mode
end

--------------------------------------------------------------------------
-- Return True when in spider mode.  This version is always false.
-- @param self A MasterControl object
function M.is_spider(self)
   dbg.start{"MasterControl:is_spider()"}
   dbg.print{"This function is deprecated: use mode instead\n"}
   dbg.fini("MasterControl:is_spider")
   return false
end

--------------------------------------------------------------------------
-- Perform a user requested inheritance.  Note that this function remains
-- the same depending on if it is a load or unload.
-- @param self A MasterControl object
function M.inherit(self)
   dbg.start{"MasterControl:inherit()"}
   local master = Master:singleton()
   master.inheritModule()
   dbg.fini("MasterControl:inherit")
end

return M
