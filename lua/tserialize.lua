-- tserialize.lua: Serialize arbitrary Lua data to Lua code
-- This file is a part of lua-nucleo library
-- Copyright (c) lua-nucleo authors (see file `COPYRIGHT` for the license)

-- Serializes arbitrary lua tables to lua code that can be loaded back via loadstring()
-- Functions, threads, userdata are not supported
-- Metatables are ignored
-- Usage:
-- str = tserialize(explist) --> to serialize data
-- =(loadstring(str)()) --> to load it back

local pairs, type, ipairs, tostring = pairs, type, ipairs, tostring
local table_concat,table_remove = table.concat,table.remove
local string_format, string_match = string.format,string.match
dofile('lua/import.lua')
local tserialize
do
  local lua51_keywords = import 'lua/language.lua' { 'lua51_keywords' }

  local function explode_rec(t,add,added,vis)
    local t_type = type(t)
    if t_type == "table" then
      if not (added[t] or vis[t]) then
        vis[t]=true
        for k,v in pairs(t) do
          explode_rec(k,add,added,vis)
          explode_rec(v,add,added,vis)
        end
      else
        if not added[t] and vis[t] then
          added[t]={declared=true}
          add[#add+1]=t
        end
      end
    end
  end

  local function parse_rec(t,visited,rec_info,added)
    local initial = t
    local started=false
    local function parse_rec_internal(t)
      local t_type = type(t)
      local rec=false
      if t_type == "table" then
        if not added[t]or not started then
          started = true
          for k,v in pairs(t) do
            if parse_rec_internal(k) or parse_rec_internal(v) then
              rec=true
              if type(k)=="table" then
                rec_info[k]=true
              end
              if type(v)=="table" then
                rec_info[v]=true
              end
            end
          end
        else
          return true
        end
      end
      return rec
    end
    rec_info[initial]=true
    parse_rec_internal(initial)
  end
  local function recursive_proceed(t,buf,added,num,rec_info, afterwork,cat)
    local t_type = type(t)
    if t_type == "table" then
      if not added[t] then
        cat("{")
        -- Serialize numeric indices
        local next_i=0
        for i,v in ipairs(t) do
          next_i = i
          if not  (rec_info[i] or rec_info[v]) then
            if i~=1 then cat(",") end
            recursive_proceed(v,buf,added,num,rec_info, afterwork,cat)
          else
            next_i=i-1
            break
          end
        end
        next_i = next_i + 1
        -- Serialize hash part
        -- Skipping comma only at first element if there is no numeric part.
        local comma = (next_i > 1) and "," or ""
        for k, v in pairs(t) do
          local k_type = type(k)
          if not (rec_info[k] or rec_info[v]) then
          --that means, if the value does not contain a recursive link to the table itself
          --and the index does not contain a recursive link...
            if k_type == "string" then
              cat(comma)
              comma = ","
              --check if we can use the short notation eg {a=3,b=5} istead of {["a"]=3,["b"]=5}
              if not lua51_keywords[k] and string_match(k, "^[%a_][%a%d_]*$") then
                cat(k); cat("=")
              else
                cat(string_format("[%q]", k)) cat("=")
              end
                recursive_proceed(v,buf,added,num,rec_info, afterwork,cat)
            elseif
              k_type ~= "number" or -- non-string non-number
              k >= next_i or k < 1 or -- integer key in hash part of the table
              k % 1 ~= 0 -- non-integral key.
            then
              cat(comma)
              comma=","
              cat("[")
              recursive_proceed(k,buf,added,num,rec_info, afterwork,cat)
              cat("]")
              cat("=")
              recursive_proceed(v,buf,added,num,rec_info, afterwork,cat)
            end
          else
            afterwork[#afterwork+1]={k,v}
          end
        end
        cat("}")
      else -- already visited!
        cat(added[t].name)
      end
    elseif t_type == "string" then
      cat(string_format("%q", t))
    elseif t_type == "number" then
      cat(string.format("%.55g",t))
    elseif t_type == "boolean" then
      cat(tostring(t))
    elseif t == nil then
      cat("nil")
    else
      return nil
    end
    return true
  end

  local function afterwork(k,v,buf,name,num,added,rec_buf)
    local cat = function(v) buf[#buf + 1] = v end
    cat(" ")
    cat(name)
    cat("[")
    if not recursive_proceed(k,buf,added,num,rec_buf, buf.afterwork,cat) then
      return false
    end
    cat("]=")
    if not recursive_proceed(v,buf,added,num,rec_buf, buf.afterwork,cat) then
      return false
    end
    cat(" ")
    return true
  end
  tserialize = function (...)
  --===================================--
  --===========THE MAIN PART===========--
  --===================================--
    --PREPARATORY WORK: LOCATE THE RECURSIVE AND SHARED PARTS--
    local narg=#arg
    local additional_vars={} -- table, containing recursive parts of our variables
    local added={}
    local visit={}
    for i,v in pairs(arg) do
      local v=arg[i]
      explode_rec(v, additional_vars,added,visit) -- discover recursive subtables
    end
    visit=nil--need no more
    local nadd=#additional_vars
    local visit={}

    --SERIALIZE ADDITIONAL FIRST--

    local buf={}
    local rec_info={}

    for i=1,nadd do
      local v=additional_vars[i]
      parse_rec(v, visit, rec_info,added)
    end
    visit = nil
    added={}
    for i=1,nadd do
      local v=additional_vars[i]
      buf[i]={afterwork={}}
      if not recursive_proceed(v, buf[i],added,i,rec_info, buf[i].afterwork,function(v) buf[i][#(buf[i]) + 1] = v end) then
        return nil, "Unserializable data in parameter #"..i
      end
      added[v]={name="var"..i,num=i}
    end

    rec_info={}
    for i=1,nadd do
      local v=additional_vars[i]
      buf[i].afterstart=#buf[i]
      for j=1,#(buf[i].afterwork) do
        if not afterwork(buf[i].afterwork[j][1],buf[i].afterwork[j][2],buf[i],added[v].name,i,added,rec_info)then
          return nil, "Unserializable data in parameter #"..i
        end
      end
    end

    --SERIALIZE GIVEN VARS--

    for i=1,narg do
      local v=arg[i]
      buf[i+nadd]={afterwork={}}
      if not recursive_proceed(v, buf[i+nadd],added,i+nadd,rec_info, buf[i+nadd].afterwork,function(v) buf[i+nadd][#(buf[i+nadd]) + 1] = v end) then
        return nil, "Unserializable data in parameter #"..i
      end
    end

    --DECLARE ADDITIONAL VARS--

    local prevbuf={}
    for v,inf in pairs(added) do
        prevbuf[#prevbuf+1] = " local "..inf.name.."="..table_concat(buf[inf.num],"",1,buf[inf.num].afterstart)
    end

    --CONCAT PARTS--
    for i=1,nadd do
      buf[i]=table_concat(buf[i],"",buf[i].afterstart+1)
    end
    for i=nadd+1,nadd+narg do
      buf[i]=table_concat(buf[i])
    end

    --RETURN THE RESULT--

    if  nadd==0 then
      return "return "..table_concat(buf,",")
    else
      local rez={
        "do ",
        table_concat(prevbuf," "),
        ' ',
        table_concat(buf," ",1,nadd),
        " return ",
        table_concat(buf,",",nadd+1),
        " end"
      }
      return table_concat(rez)
    end
  end
end


return
{
  tserialize=tserialize
}
