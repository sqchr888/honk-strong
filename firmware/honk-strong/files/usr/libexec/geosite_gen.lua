#!/usr/bin/lua
-- geosite_gen.lua -- generate v2ray-format geosite.dat on OpenWrt (no python).
-- Byte-compatible with research/gen_adblock_geosite.py and honk-core
-- routing/geo.rs::parse_geosite_index_inner. Pure Lua 5.1 arithmetic: no bit
-- library required (OpenWrt's /usr/bin/lua has neither bit nor bit32).
--
-- Wire format:
--   GeoSiteList { repeated GeoSite item = 1 }
--   GeoSite     { string country_code = 1; repeated Domain domain = 2 }
--   Domain      { int32 type = 1; string value = 2 }
--
-- IMPORTANT — honk's domain type mapping is NOT the v2ray standard:
--   honk geo.rs::parse_geosite_domain:  0=Keyword, 1=Regex, 2=Domain(suffix), 3=Full
--   v2ray standard:                    0=Plain,   1=Wildcard, 2=Regex,      3=Full
-- We MUST emit type=2 (honk Domain/suffix). Emitting type=1 makes honk compile
-- EVERY ad domain as an independent Regex (~15 KB each): 95k domains pushed
-- honk-core to 1.4 GB and triggered the OOM killer. With type=2 the same 95k
-- domains live in a HashSet and honk uses only ~72 MB (AdGuard-home class).
--
-- Usage:
--   lua geosite_gen.lua <input-list> <output.dat> <category>
--   lua geosite_gen.lua --self-test

local M = {}

-- honk type=2 => GeositeDomain::Domain (dot-boundary suffix, HashSet-backed).
local HONK_DOMAIN = 2

local function varint(n)
  local out = {}
  n = math.floor(n)
  while n >= 128 do
    out[#out + 1] = string.char((n % 128) + 128)
    n = math.floor(n / 128)
  end
  out[#out + 1] = string.char(n)
  return table.concat(out)
end

local function tag(field, wire) return varint(field * 8 + wire) end
local function len_field(field, payload)
  return tag(field, 2) .. varint(#payload) .. payload
end
local function varint_field(field, value)
  return tag(field, 0) .. varint(value)
end

local function domain_msg(value, dtype)
  dtype = dtype or HONK_DOMAIN
  return varint_field(1, dtype) .. len_field(2, value)
end

function M.geosite_dat(categories)
  local out = {}
  for _, cat in ipairs(categories) do
    local entry = { len_field(1, cat.code) }
    for _, d in ipairs(cat.domains) do
      entry[#entry + 1] = len_field(2, d)
    end
    out[#out + 1] = len_field(1, table.concat(entry))
  end
  return table.concat(out)
end

-- Parse hosts / adblock / dnsmasq / plain-domain list into unique lowercase
-- domains. Supports: plain domain, 0.0.0.0 domain, server=/d/, address=/d/ip,
-- ||domain^ (adblock), with optional # / ! comments.
function M.read_domains(path)
  local domains, seen = {}, {}
  local fh = io.open(path, "r")
  if not fh then return domains end
  for raw in fh:lines() do
    local line = raw:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= "!" then
      local name = nil
      name = line:match("^server=/([^/]+)/")
      if not name then name = line:match("^address=/([^/]+)/") end
      if not name then name = line:match("^||([%w%.%-_]+)%^") end
      if not name and line:match("^%d+%.%d+%.%d+%.%d+%s") then
        name = line:match("^%S+%s+(%S+)")
      end
      if not name then name = line:match("^([%w%.%-_]+)") end
      if name then
        name = name:gsub("^%.+", "")
        if name ~= "" and not name:find("*") and not name:find("%s")
           and not name:find("%.%.") and name:sub(-1) ~= "."
           and name:find("^[%w%.%-_]+$") then
          local key = name:lower()
          if not seen[key] then
            seen[key] = true
            domains[#domains + 1] = key
          end
        end
      end
    end
  end
  fh:close()
  return domains
end

function M.build(input, output, category)
  local domains = M.read_domains(input)
  local msgs = {}
  for i, d in ipairs(domains) do msgs[i] = domain_msg(d) end
  local dat = M.geosite_dat({ { code = category, domains = msgs } })
  local fh = assert(io.open(output, "wb"))
  fh:write(dat)
  fh:close()
  return #domains, #dat
end

local function read_varint(buf, pos)
  local value, mult = 0, 1
  while true do
    local b = string.byte(buf, pos)
    pos = pos + 1
    value = value + (b % 128) * mult
    if b < 128 then return value, pos end
    mult = mult * 128
  end
end

function M.decode(dat)
  local result, pos = {}, 1
  while pos <= #dat do
    local t, ln
    t, pos = read_varint(dat, pos)
    assert(math.floor(t / 8) == 1 and t % 8 == 2, "top-level field 1 LEN")
    ln, pos = read_varint(dat, pos)
    local entry = dat:sub(pos, pos + ln - 1)
    pos = pos + ln
    local ep, category, domains = 1, "", {}
    while ep <= #entry do
      local et, eln
      et, ep = read_varint(entry, ep)
      local field, wire = math.floor(et / 8), et % 8
      eln, ep = read_varint(entry, ep)
      local payload = entry:sub(ep, ep + eln - 1)
      ep = ep + eln
      if field == 1 and wire == 2 then
        category = payload
      elseif field == 2 and wire == 2 then
        local dtype, dp, value = 0, 1, ""
        while dp <= #payload do
          local dt
          dt, dp = read_varint(payload, dp)
          local dfld, dw = math.floor(dt / 8), dt % 8
          if dw == 0 then
            dtype, dp = read_varint(payload, dp)
          elseif dw == 2 then
            local dln
            dln, dp = read_varint(payload, dp)
            local val = payload:sub(dp, dp + dln - 1)
            dp = dp + dln
            if dfld == 2 then value = val end
          end
        end
        domains[#domains + 1] = { dtype, value }
      end
    end
    result[category] = domains
  end
  return result
end

function M.self_test()
  local sample = {
    domain_msg("ads.example"),               -- default: honk Domain (type 2)
    domain_msg("tracker.example", 0),        -- Keyword
    domain_msg("^api\\.", 1),                -- Regex (honk type 1)
    domain_msg("exact.example", 3),          -- Full (honk type 3)
  }
  local dat = M.geosite_dat({
    { code = "honk-ads", domains = sample },
    { code = "cn", domains = { domain_msg("baidu.com") } },
  })
  local d = M.decode(dat)
  assert(d["honk-ads"] and d["cn"], "categories missing")
  assert(#d["honk-ads"] == 4, "honk-ads count")
  assert(d["honk-ads"][1][1] == 2 and d["honk-ads"][1][2] == "ads.example", "default must be honk Domain=2")
  assert(d["honk-ads"][2][1] == 0 and d["honk-ads"][2][2] == "tracker.example", "keyword")
  assert(d["honk-ads"][3][1] == 1 and d["honk-ads"][3][2] == "^api\\.", "regex")
  assert(d["honk-ads"][4][1] == 3 and d["honk-ads"][4][2] == "exact.example", "full")
  assert(d["cn"][1][2] == "baidu.com", "cn")
  assert(varint(0) == "\0", "varint 0")
  assert(varint(127) == string.char(127), "varint 127")
  assert(varint(128) == string.char(0x80, 0x01), "varint 128")
  assert(varint(300) == string.char(0xac, 0x02), "varint 300")
  print("LUA_SELF_TEST_OK: geosite.dat encode/decode round-trip valid")
end

local function main(a)
  if a[1] == "--self-test" then M.self_test(); return end
  if not a[1] or not a[2] or not a[3] then
    io.stderr:write("usage: lua geosite_gen.lua <input> <output.dat> <category>\n")
    os.exit(1)
  end
  local n, bytes = M.build(a[1], a[2], a[3])
  print(string.format("OK: %d domains -> %s (%d bytes, category=%s)", n, a[2], bytes, a[3]))
end

-- When run as a script, Lua 5.1 exposes argv in the global `arg` table.
-- When loaded via require(), `arg` is absent and the caller drives M directly.
if type(arg) == "table" and arg[1] then main(arg) end

return M
