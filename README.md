This is a Lua client library for [mpd][].

Basic usage:

    require "mpd"
    m = mpd.connect()  --defaults to "localhost", 6600
    m:play()
    m:pause()
    m:unpause()        --alias for m:pause(false)
    m:stop()
    m:play(3)
    m:next()
    m:seek(5, 10)      --jump 10 seconds into 6th track on playlist
    m:move("5:9", 5)   --move range of tracks forward 5
    info_table = m:status()
    songs = m:playlistinfo()
    matches = m:search("artist", "zygotic")
    m:close()
    etc.

[mpd]: http://mpd.wikia.com

For more info, see the API documentation and the MPD wiki.
