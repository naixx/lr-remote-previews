# Third-party code in the plug-in

## json.lua (rxi)

- File: `LRRemotePreviews.lrplugin/Json.lua`
- Upstream: https://github.com/rxi/json.lua, file `json.lua`, version 0.1.2 (last upstream change to the
  file: commit `11077824d7cfcd28a4b2f152518036b295e7e4ce`, 2020-04-05)
- Fetched from https://raw.githubusercontent.com/rxi/json.lua/master/json.lua and kept byte-for-byte
  unmodified, only renamed to `Json.lua`. SHA-256:
  `0eaccda57fabc0330736de25f45cf589821a42b5e0fe02e4e3125f7dc0bf2b7e`
- Licence: MIT, Copyright (c) 2020 rxi. The full licence text is the header of the file itself.
- Why: the Lightroom SDK has no JSON module.
- It is excluded from luacheck (`.luacheckrc`); `spec/Json_spec.lua` pins the behaviour the plug-in relies on
  (for example, JSON `null` decodes to `nil`, malformed input raises an error).
