--[=====================================================================[
Copyright (c) 2010 Scott Vokes <vokes.s@gmail.com>

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
--]=====================================================================]

require "socket"

-- TODO:
-- * set up basic typechecking for args,
--    "bad argument to string.format" is not a good error msg...

--Dependencies
local socket = socket
local fmt, concat = string.format, table.concat
local assert, ipairs, print, setmetatable, tostring, type =
   assert, ipairs, print, setmetatable, tostring, type


---A Lua client libary for mpd.
module("mpd")

---If set to true, will trace out transmissions.
DEBUG = false

local function bool(t) return t and "1" or "0" end


local MPD = {}

---Get an MPD server connection handle.
-- @param reconnect Whether to automatically reconnect. Default is true.
-- @param host Default: "localhost"
-- @param port Default: 6600
function connect(host, port, reconnect)
   if reconnect == nil then reconnect = true end
   local host, port = host or "localhost", port or 6600
   local s = assert(socket.connect(host, port))
   local m = setmetatable({_s=s, _reconnect=reconnect,
                           _host=host, _port=port },
                          {__index=MPD})
   local ok, err = m:connect()
   if ok then return m else return false, err end
end

---Connect (or reconnect) to the server.
function MPD:connect()
   local s, err = socket.connect(self._host, self._port)
   if s then
      self._s = s
      return true
   else
      return false, err
   end
end

---Send an arbitrary string.
function MPD:send(cmd)
   local s = assert(self._s)
   if type(cmd) == "string" then cmd = { cmd } end
   local msg = concat(cmd, " ") .. "\r\n"
   if DEBUG then print("SEND: ", msg) end
   local ok, err = s:send(msg)
   if ok then return ok
   elseif err == "closed" and self._reconnect then
      ok, err = self:connect()
      if ok then
         return self:send(cmd) --retry
      else
         return false, err
      end
   else
      return false, err
   end
end

-- Process a response, either a list, k/v table,
-- or list of tables (e.g. list of info for matching songs).
local function parse_buf(rform, buf)
   if rform == "table" or rform == "list" then
      local t = {}
      for _,line in ipairs(buf) do
         local k, v = line:match("(.-): (.*)")
         if k and v then
            if rform == "table" then t[k] = v else t[#t+1] = v end
         end
      end
      res = t
   elseif rform == "table-list" then
      local ts, t = {}, {}
      for _,line in ipairs(buf) do
         local k, v = line:match("(.-): (.*)")
         if k and v then
            if t[k] then ts[#ts+1] = t; t = {} end
            t[k] = v
         end
      end
      ts[#ts+1] = t
      res = ts
   elseif rform == "line" then
      res = concat(buf, "\n")
   else
      return false, ("match failed: " .. rform)
   end
   return res
end

---Read and process a response.
function MPD:receive(rform)
   rform = rform or "line"
   local s = assert(self._s)
   local buf = {}

   while true do
      local line, err = s:receive()
      if not line then return false, err end
      if DEBUG then print("GOT: ", line) end
      if line == "OK" then break
      elseif line:match("^ACK") then return false, line end
      buf[#buf+1] = line
   end

   return parse_buf(rform, buf)
end

--Send command, get response.
function MPD:sendrecv(cmd, response_form)
   local res, err = self:send(cmd)
   if not res then return false, err end
   res, err = self:receive(response_form)
   if res then
      return res
   elseif err == "closed" and self._reconnect then
      local ok, err2 = self:connect()
      if ok then
         return self:sendrecv(cmd, response_form) --retry
      else
         return false, err2
      end
   else
      return false, err
   end
end

---Clear last error.
function MPD:clearerror() return self:sendrecv("clearerror") end

---Get current song (if any).
function MPD:currentsong()
   return self:sendrecv("currentsong", "table")
end

---Wait for changes in one or more subsystem(s).
-- Blocking, so polling is not necessary.
-- @param subsystems subsystems can be one or more of:
--     "database", "update", "stored_playlist",
--     "playlist", "player", "mixer", "output_options"
function MPD:idle(subsystems)
   if type(subsystems) == "string" then subsystems = { subsystems } end
   return self:sendrecv(fmt("idle %s", concat(subsystems, " ")))
end


---Cancel blocking idle command.
function MPD:noidle()
   return self:sendrecv("noidle")
end

---Get table with status.
function MPD:status() return self:sendrecv("status", "table") end

---Get table with stats.
function MPD:stats() return self:sendrecv("stats", "table") end

---Set consume state.
-- When consume is activated, each song played is removed from playlist.
function MPD:set_consume(state)
   return self:sendrecv("consume " .. bool(state))
end

---Sets crossfading between songs (in seconds).
function MPD:set_crossfade(seconds)
   seconds = tostring(seconds or 0)
   return self:sendrecv("crossfade " .. seconds)
end

---Sets random state to true/false.
function MPD:set_random(state)
   return self:sendrecv("random " .. bool(state))
end

--Sets repeat state to true/false.
function MPD:set_repeat(state)
   return self:sendrecv("repeat " .. bool(state))
end

---Sets volume to VOL, the range of volume is 0-100.
function MPD:set_vol(vol)
   return self:sendrecv(fmt("setvol %d", vol))
end

---Sets single state to true/false.
-- When single is activated, playback is stopped after current song, or
-- the single song is repeated if the 'repeat' mode is enabled.
function MPD:set_single(state)
   return self:sendrecv("single " .. bool(state))
end

---Sets the replay gain mode. One of "off", "track", "album".
-- Changing the mode during playback may take several seconds, because
-- the new setting does not affect the buffered data. This command
-- triggers the options idle event.
function MPD:set_replay_gain_mode(mode)
   assert(mode == "off" or mode == "track" or mode == "album",
          "bad replay_gain_mode: " .. tostring(mode))
   return self:sendrecv("replay_gain_mode " .. mode)
end


---Get replay gain options.
-- Currently, only the variable replay_gain_mode is returned.
function MPD:replay_gain_status()
   return self:sendrecv("replay_gain_status", "table")
end

---Plays next song in the playlist.
function MPD:next() return self:sendrecv("next") end

---Set pause to true/false.
-- @param flag Defaults to true.
function MPD:pause(flag)
   if flag == nil then flag = true end
   return self:sendrecv("pause " .. bool(flag))
end

---Unpause.
function MPD:unpause() return self:pause(false) end

---Begins playing the playlist at song number SONGPOS.
function MPD:play(songpos)
   songpos = songpos or 0
   return self:sendrecv(fmt("play %d", songpos))
end


---Begins playing the playlist at song SONGID.
-- @param songid Song ID, which is preserved as playlist is rearranged.
function MPD:playid(songid)
   songid = songid or 0
   return self:sendrecv(fmt("playid %d", songid))
end

---Plays previous song in the playlist.
function MPD:previous() return self:sendrecv("previous") end

---Seeks to the position TIME (in seconds) of entry SONGPOS in the playlist.
function MPD:seek(songpos, time)
   return self:sendrecv(fmt("seek %d %d", songpos, time))
end

---Seeks to the position TIME (in seconds) of song SONGID.
-- @param songid Song ID, which is preserved as playlist is rearranged.
function MPD:seekid(songid, time)
   return self:sendrecv(fmt("seekid %d %d", songid, time))
end

---Stop playing.
function MPD:stop() return self:sendrecv("stop") end

---Adds the file URI to the playlist and increments playlist version.
-- URI can also be a single file or a directory (added recursively).
function MPD:add(uri)
   return self:sendrecv(fmt("add %s", uri))
end

---Adds a song to the playlist (non-recursive) and returns the song id.
--URI is always a single file or URL. For example:
--addid "foo.mp3"
--Id: 999
--OK
function MPD:addid(uri, position)
   return self:sendrecv(fmt("addid %q %s", uri, (position or "")))
end

---Clears the current playlist.
function MPD:clear() return self:sendrecv("clear") end

---Deletes a song from the playlist.
-- @param arg Optional POS (relative to current) or START:END.
function MPD:delete(spec)
   spec = spec or 0
   return self:sendrecv(fmt("deleteid %d", spec))
end

---Deletes the song SONGID from the playlist
function MPD:deleteid(songid)
   return self:sendrecv(fmt("deleteid %d", songid))
end

---Moves the song at FROM or song range at START:END to TO in the playlist.
-- @param pos Either a position in the playlist (counting from 0)
--      or a colon-separated range of positions (e.g. "10:15").
-- @param to Position in playlist.
function MPD:move(pos, to)
   return self:sendrecv(fmt("moveid %s %d", pos, to))
end

---Moves the song with FROM (songid) to TO (playlist index) in
-- the playlist. If TO is negative, it is relative to the current
-- song in the playlist (if there is one).
function MPD:moveid(id, to)
   return self:sendrecv(fmt("moveid %s %d", id, to))
end

---Finds songs in the current playlist with strict matching.
-- @param tag One of the tags known, as returned by MPD:tagtypes().
function MPD:playlistfind(tag, value)
   return self:sendrecv(fmt("playlistfind %s %s", tag, value))
end

---Displays a list of songs in the playlist.
-- @param songid Optional, specifies a single song to display info for.
function MPD:playlistid(songid)
   songid = songid or ""
   return self:sendrecv(fmt("playlistid %s", songid), "table-list")
end

---Displays a list of all songs in the playlist, or if the optional
-- argument is given, displays information only for the song SONGPOS or
-- the range of songs START:END
function MPD:playlistinfo(spec)
   spec = spec or ""
   return self:sendrecv(fmt("playlistinfo %s", spec), "table-list")
end

---Searches case-sensitively for partial matches in the current playlist.
-- @param tag One of the tags known, as returned by MPD:tagtypes().
function MPD:playlistsearch(tag, value)
   return self:sendrecv(fmt("playlistsearch %s %s", tag, value))
end

---Displays changed songs currently in the playlist since VERSION.
-- To detect songs that were deleted at the end of the playlist, use
-- playlistlength returned by status command.
function MPD:plchanges(version)
   return self:sendrecv(fmt("plchanges %d", version))
end

---Displays changed songs currently in the playlist since VERSION. This
-- function only returns the position and the id of the changed song,
-- not the complete metadata. This is more bandwidth efficient. To
-- detect songs that were deleted at the end of the playlist, use
-- playlistlength returned by status command.
function MPD:plchangesposid(version)
   return self:sendrecv(fmt("plchangesposid %d" .. version))
end

---Shuffles the current playlist.
-- @param spec Optional, specifies a range of songs.
function MPD:shuffle(spec)
   spec = spec or ""
   return self:sendrecv(fmt("shuffle %s", spec))
end

---Swaps the positions of SONG1 and SONG2.
-- @param song1 Index of song in playlist, indexed from 0.
function MPD:swap(song1, song2)
   return self:sendrecv(fmt("swap %d %d", song1, song2))
end

---Swaps the positions of SONG1 and SONG2 (both song ids).
function MPD:swapid(song1, song2)
   return self:sendrecv(fmt("swapid %d %d", song1, song2))
end

---Lists the files in the playlist NAME.m3u.
function MPD:listplaylist(name)
   return self:sendrecv("listplaylist " .. name)
end

---Lists songs in the playlist NAME.m3u.
function MPD:listplaylistinfo(name)
   return self:sendrecv(fmt("listplaylistinfo %s", name))
end

---Prints a list of the playlist directory.
-- After each playlist name the server sends its last modification time
-- as attribute "Last-Modified" in ISO 8601 format. To avoid problems
-- due to clock differences between clients and the server, clients
-- should not compare this value with their local clock.
function MPD:listplaylists()
   return self:sendrecv("listplaylists")
end

---Loads the playlist NAME.m3u from the playlist directory.
function MPD:load(name)
   return self:sendrecv(fmt("load %s", name))
end

---Adds URI to the playlist NAME.m3u.
-- NAME.m3u will be created if it does not exist.
function MPD:playlistadd(name, uri)
   return self:sendrecv(fmt("playlistadd %q %s", name, uri))
end

---Clears the playlist NAME.m3u.
function MPD:playlistclear(name)
   return self:sendrecv(fmt("playlistclear %s", name))
end

---Deletes SONGPOS from the playlist NAME.m3u.
function MPD:playlistdelete(name, songpos)
   return self:sendrecv(fmt("playlistdelete %q %d", name, songpos))
end

--playlistmove {NAME} {SONGID} {SONGPOS}
--Moves SONGID in the playlist NAME.m3u to the position SONGPOS.
function MPD:playlistmove(name, songid, songpos)
   return self:sendrecv(fmt("playlistmove %q %d %d",
                            name, songid, songpos))
end

---Renames the playlist NAME.m3u to NEW_NAME.m3u.
function MPD:rename(name, new_name)
   return self:sendrecv(fmt("rename %q %s", name, new_name))
end

---Removes the playlist NAME.m3u from the playlist directory.
function MPD:rm(name)
   return self:sendrecv(fmt("rm %s", name))
end

---Saves the current playlist to NAME.m3u in the playlist directory.
function MPD:save(name)
   return self:sendrecv(fmt("save %s", name))
end

---Counts the number of songs and their total playtime in the db matching
-- TAG exactly.
-- @param tag One of the tags known, as returned by MPD:tagtypes().
function MPD:count(tag, value)
   return self:sendrecv(fmt("count %s %s", tag, value))
end

---Finds songs in the db that are exactly WHAT.
-- @param type "album", "artist", or "title"
-- @param what What to find
function MPD:find(type, what)
   return self:sendrecv(fmt("find %s %s", type, what), "table-list")
end

---Finds songs in the db that are exactly WHAT and adds them to current
-- playlist. TYPE can be any tag supported by MPD. WHAT is what to find.
function MPD:findadd(type, what)
-- @param type "album", "artist", or "title"
-- @param what What to find
   return self:sendrecv(fmt("findadd %s %s", type, what))
end

---Lists all tags of the specified type. TYPE should be album or artist.
-- @param type "album" or "artist"
-- @param artist Optionl. If type is "album", just search for albums
--     by a specific artist (e.g. mpd:list("album", "The Mountain Goats")).
function MPD:list(type, artist)
   if type == "album" then
      artist = fmt("%s", artist or "")
   else
      artist = ""
   end
   return self:sendrecv(fmt("list %s%s", type, artist), "list")
end

---Lists all songs and directories in URI.
function MPD:listall(uri)
   uri = uri or "/"
   return self:sendrecv(fmt("listall %s", uri), "list")
end

---Same as listall, except it also returns metadata info in the same
-- format as lsinfo.
function MPD:listallinfo(uri)
   uri = uri or "/"
   return self:sendrecv(fmt("listallinfo %s", uri), "table-list")
end

---Lists the contents of the directory URI.
-- When listing the root directory, this currently returns the list of
-- stored playlists. This behavior is deprecated; use "listplaylists"
-- instead.
function MPD:lsinfo(uri)
   uri = uri or "/"
   return self:sendrecv(fmt("lsinfo %s", uri), "table-list")
end

---Searches for any song that contains WHAT. TYPE can be title, artist,
-- album or filename. Search is not case sensitive.
function MPD:search(type, what)
   return self:sendrecv(fmt("search %q %s", type, what), "table-list")
end

---Updates the music database: find new files, remove deleted files,
-- update modified files. URI is a particular directory or song/file to
-- update. If you do not specify it, everything is updated. Prints
-- "updating_db: JOBID" where JOBID is a positive number identifying the
-- update job. You can read the current job id in the status response.
function MPD:update(uri)
   uri = uri or ""
   return self:sendrecv(fmt("update %s", uri))
end

---Same as update, but also rescans unmodified files.
function MPD:rescan(uri)
   uri = uri or ""
   return self:sendrecv(fmt("rescan %s", uri))
end



---Reads a sticker value for the specified object.
function MPD:sticker_get(type, uri, name)
   return self:sendrecv(fmt("sticker get %s %s %s",
                            type, uri, name))
end

---Adds a sticker value to the specified object. If a sticker item with
-- that name already exists, it is replaced.
function MPD:sticker_set(type, uri, name, value)
   return self:sendrecv(fmt("sticker set %s %s %s %s",
                            type, uri, name, value))
end

---Deletes a sticker value from the specified object. If you do not
-- specify a sticker name, all sticker values are deleted.
function MPD:sticker_delete(type, uri, name)
   name = name or ""
   return self:sendrecv(fmt("sticker delete %s %q %s",
                            type, uri, name))
end

---Lists the stickers for the specified object.
function MPD:sticker_list(type, uri)
   return self:sendrecv(fmt("sticker list %s %s", type, uri))
end

---Searches the sticker database for stickers with the specified name,
-- below the specified directory (URI). For each matching song, it
-- prints the URI and that one sticker's value.
function MPD:sticker_find(type, uri, name)
   return self:sendrecv(fmt("sticker find %s %s %s",
                            type, uri, name))
end

---Closes the connection to MPD.
function MPD:close() return self:sendrecv("close") end

---Kills MPD.
function MPD:kill() return self:sendrecv("kill") end

---This is used for authentication with the server.
-- @param password the plaintext password.
function MPD:password(password)
   return self:sendrecv("password " .. password)
end

---Does nothing but return "OK".
function MPD:ping() return self:sendrecv("ping") end

---Turns an output off.
function MPD:disableoutput(arg) return self:sendrecv("disableoutput") end

---Turns an output on.
function MPD:enableoutput(arg) return self:sendrecv("enableoutput") end

---Shows information about all outputs.
function MPD:outputs() return self:sendrecv("outputs", "table") end

---Shows which commands the current user has access to.
function MPD:commands() return self:sendrecv("commands", "list") end

---Shows which commands the current user does not have access to.
function MPD:notcommands() return self:sendrecv("notcommands", "list") end

---Shows a list of available song metadata.
function MPD:tagtypes() return self:sendrecv("tagtypes", "list") end

---Gets a list of available URL handlers.
function MPD:urlhandlers() return self:sendrecv("urlhandlers", "list") end
