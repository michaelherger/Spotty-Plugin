#!/bin/sh

echo Finding files with playlist folder information:

for FOLDER in "$HOME/.cache/spotify/Storage" "$HOME/Library/Application Support/Spotify/PersistentCache/Storage" "$XDG_CACHE_HOME/spotify/Storage" "$LOCALAPPDATA/Spotify/Storage"
do
   if [ -z "$1" ]; then
      grep -rls "start-group" "$FOLDER"
   else
      grep -rls "start-group" "$FOLDER" --null | xargs -0 -I '{}' curl -F --'data=@"{}"' http://$1/plugins/spotty/uploadPlaylistFolderData
   fi
done